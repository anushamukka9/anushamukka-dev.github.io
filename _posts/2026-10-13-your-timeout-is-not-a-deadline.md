---
layout: post
title: "Your Timeout Is Not a Deadline"
date: 2026-10-13 11:21:00 -0400
categories: [Writing]
tags: [Distributed Systems, Reliability, Backend, Software Engineering]
description: "A timeout stops one caller from waiting. A deadline stops the whole chain from doing work nobody will read. On propagating one request budget across every hop, refusing work that cannot finish, and killing zombie queries during incidents."
---

# Your Timeout Is Not a Deadline

*Your client gave up at two seconds. Your database kept working for nine. A timeout stops one caller from waiting. A deadline stops the whole chain from wasting work nobody will read.*

## The Caller Left and the Work Stayed

A checkout request times out at the gateway after two seconds. The user sees an error, refreshes, and starts a second request. Behind the gateway, the first request is still alive: the orders service is mid-query, the inventory service is holding a connection, and the database is running a join that will finish, be serialized, and be thrown away because there is no one left to receive it.

Now multiply that by an incident. A slow dependency stretches every call, callers time out and retry, and each retry starts fresh downstream work while the original work keeps running. The system is doing two and three copies of work whose results will be discarded, at exactly the moment it has the least capacity to spare. That is zombie work: queries for requests that already failed at the edge. A per-hop timeout answers one narrow question: how long will this caller wait. It says nothing about how long the work itself is allowed to live.

## Name the Two Bad Options

The first bad option is generous timeouts everywhere. Every service gets thirty seconds because nobody wants to be the hop that failed a legitimate request. The result is predictable: threads and connections pile up behind the slowest dependency, queues fill with work that will expire before it is read, and the failure takes minutes to become visible because nothing fails fast enough to trip an alert. Generous timeouts feel safe. They convert a small dependency problem into a fleet-wide stall.

The second bad option is tight timeouts everywhere, tuned hop by hop in isolation. The gateway allows two seconds, the service behind it allows two seconds, the service behind that allows two seconds, and the database gets two seconds of its own. Each number looks reasonable in its own config file. Together they promise the user an answer in two seconds while authorizing eight seconds of work. Worse, the inner timeouts fire after the outer one, so the deepest work is the work most likely to be wasted.

I understand both instincts. Timeouts are usually set during an incident, by the team that got paged, for the hop they own. Nobody owns the whole chain, so the whole chain never gets a budget. That missing owner is the problem this piece is about.

> A timeout is a local decision about waiting. A deadline is a global decision about whether the work is still worth doing.

## The Gap Every Timeout Guide Skips

Most timeout advice stops at picking the number: measure your p99, add margin, set the timeout a little above it. That advice is fine for a single call. It skips the question that decides whether your system wastes capacity during incidents: when a request moves from service to service, does its remaining time move with it.

That is the gap this piece fills. A deadline is an absolute point in time by which the whole request must finish. It is created once, at the edge, and it travels with the request. Every hop can compute the same simple value: time left equals deadline minus now. A hop with too little time left does not start work it cannot finish. A hop that calls downstream passes the same deadline along, not a fresh budget. And when the deadline passes, cancellation follows it, so in-flight work stops instead of finishing into the void.

gRPC has done this natively for years: set a deadline on the client context and it propagates as the grpc-timeout header, with each server seeing the remaining budget in its own context. HTTP services usually have to build the convention themselves, which is why so many HTTP fleets have timeouts at every hop and deadlines at none.

## A Timeout and a Deadline Are Different Objects

Say it precisely, because the two get conflated in config files all the time.

A timeout is a duration owned by one caller for one call: wait at most this long, then give up. It resets at every hop. Three hops with a two second timeout each authorize up to six seconds of sequential work, plus whatever the last hop starts.

A deadline is a timestamp owned by the request: finish by this moment, whoever you are. It never resets. Three hops share the same two seconds, and each hop sees a smaller remainder than the hop before it.

```
Timeout world (fresh budget at every hop):

  gateway --2s--> orders --2s--> inventory --2s--> database
  caller gives up at 2s; work can legally run to 6s+

Deadline world (one budget, carried with the request):

  t=0.0s          t=0.7s          t=1.4s          t=2.0s
  gateway --------> orders --------> inventory ----X deadline
  remaining 2.0s    remaining 1.3s   remaining 0.6s   stop
```

Two consequences fall out of that arithmetic, and neither is an accident. First, a deadline makes the total cost of a request knowable at the edge, before any work starts. Second, a deadline gives every hop a cheap refusal rule: if the remaining budget is smaller than the smallest useful unit of work, fail immediately and cheaply instead of expensively and late.

There is a clock problem hiding here, and it is worth naming. An absolute timestamp only means the same thing on two machines if their clocks agree, which is the clock skew problem covered in an earlier piece in this series. The practical workaround most systems use is to propagate a duration, the remaining budget, rather than a raw timestamp: the gRPC grpc-timeout header carries a relative value for exactly this reason. Each hop decrements by its own elapsed time, measured on its own monotonic clock, so skew between machines never enters the calculation.

## Carry the Budget, Check It at Every Hop

Here is the whole pattern in runnable Python. It is standard library only: a deadline object that travels with the request, a check before starting work, and refusal when the budget cannot cover the work.

```python
import time

class Deadline:
    """One budget for the whole request, created once at the edge."""

    def __init__(self, budget_s: float):
        self._end = time.monotonic() + budget_s

    def remaining(self) -> float:
        return self._end - time.monotonic()

    def expired(self) -> bool:
        return self.remaining() <= 0


def hop(name: str, work_s: float, deadline: Deadline) -> bool:
    rem = deadline.remaining()
    verdict = "START" if rem > work_s else "REFUSE (would overrun)"
    print(f"{name}: remaining={rem:.2f}s work_needed={work_s:.2f}s -> {verdict}")
    if rem <= work_s:
        return False
    time.sleep(work_s)  # stand-in for the real call
    return True


deadline = Deadline(budget_s=2.0)
hop("gateway", 0.7, deadline)
hop("service", 0.7, deadline)
hop("database", 1.2, deadline)
```

Running it prints this:

```
gateway: remaining=2.00s work_needed=0.70s -> START
service: remaining=1.30s work_needed=0.70s -> START
database: remaining=0.60s work_needed=1.20s -> REFUSE (would overrun)
```

A few things are worth noting about this example. First, the refusal is the feature, not the failure. The database hop declined in microseconds work that would have run for 1.2 seconds and been discarded. Second, the deadline object holds no per-hop configuration at all. Nobody tuned three numbers; one budget was set where the user promise is made, and every hop derived its behavior from what was left. Third, the check happens before work starts, not after it finishes. A check at the end only tells you that you wasted the time. A check at the start prevents the waste.

In a real service the same shape holds, with the deadline arriving from the caller instead of being created locally:

```python
def handle_request(headers, db):
    budget = float(headers.get("x-deadline-ms", "0")) / 1000.0
    deadline = Deadline.from_remaining(budget) if budget > 0 else Deadline(2.0)

    if deadline.remaining() < 0.25:
        return 503, {"error": "deadline too close to serve", "retry_after_s": 1}

    result = db.query(timeout_s=deadline.remaining() * 0.8)
    return 200, result
```

Notice the database call receives eighty percent of what is left, not all of it. A hop that spends the entire remainder downstream leaves itself nothing to serialize the response, write the log line, or fail gracefully. Keep a margin at every hop. The margin is not waste; it is the time your own cleanup takes, priced in advance.

## Wire It Into the Stack You Already Run

You do not need a new platform for this. You need the budget to survive each boundary it crosses.

For gRPC, set the deadline once at the edge and stop resetting it downstream:

```go
// Edge: create the one budget for this request.
ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
defer cancel()

// Downstream: pass ctx through unchanged. Do NOT wrap it in a
// fresh WithTimeout at every hop; the child call inherits the
// smaller of its own limit and the parent's remaining budget.
resp, err := client.GetInventory(ctx, req)
if errors.Is(err, context.DeadlineExceeded) {
    // The budget ran out. Fail cheap, do not retry inside it.
}
```

For plain HTTP, carry the remaining budget in a header and decrement it at each hop: the edge sends x-deadline-ms: 2000, and each service forwards what is left rather than the original number.

For the database, pass the remaining budget into the driver instead of accepting its default. In Postgres that means statement_timeout set per session from the request budget; in most drivers it is a context or timeout parameter on the query call itself. A query that outlives its request is the single most common form of zombie work, and it is the easiest to kill because the database will cancel it for you if you ask.

Retries belong inside the budget, never outside it. A retry is only legal while time remains to complete it, and the retried call inherits the original deadline, not a new one. That one rule quietly fixes the ugliest interaction in this whole area: the caller timing out, retrying, and doubling the load on a dependency that is still processing the first attempt. If you take one cross-link from this series, take that one: retries without a shared deadline are how a timeout becomes a retry storm.

## Where This Breaks

Be honest about the limits, because deadlines are not magic:

- Work that cannot be cancelled ignores deadlines. A database query without a timeout, a file write mid-flight, a call into a library with no context support: the deadline passes and the work continues. Propagation only helps where each layer actually honors cancellation.
- Queues break the chain. Once a request becomes a queued job, the deadline has to travel in the job payload and the worker has to check it on pickup. A job that waited four minutes in a queue with a two second request budget should be dropped on arrival, and most queues will happily run it instead unless you check.
- Not every request deserves the edge budget. Batch work, exports, and background reconciliation should carry their own longer deadlines, set deliberately, not inherit a two second interactive budget and fail forever.
- A deadline tells you when to stop, not whether stopping is safe. Abandoning a write mid-flight leaves partial state. Pair deadlines with idempotency keys for any operation you might abandon and retry, so the second attempt can recognize the first.
- Clock skew still matters at the edges. Propagating a remaining duration avoids most of it, but any system that also logs or compares absolute timestamps across machines will meet skew again in its observability data.

## Decide With a Budget, Not a Hunch

Build it if:

- Your call graph is more than one hop deep, which means per-hop timeouts are silently multiplying your real request cost.
- Post-incident reviews find load from requests nobody was waiting for. That is zombie work, and deadlines are its direct cure.
- Retries exist anywhere in the chain. A retry outside a shared budget is a load multiplier with no off switch.

Skip it if:

- You run a single service with no downstream calls. A plain timeout is the same thing when there is only one hop.
- Your downstream calls are all fire-and-forget by design, with a queue and workers built to check budgets on pickup. Handle the deadline there instead.

The minimal viable version fits in an afternoon: pick your five most called endpoints, set one budget at the edge, propagate it as a header, refuse work with less than 250 milliseconds remaining, and pass what is left into your database calls. Measure zombie work before and after by counting queries that complete after their request already returned an error. That count is your result.

## Start at the Edge

Set the budget where the promise to the user is made. Carry it with the request, check it before work starts, pass what remains to everything downstream, and let work die when its budget does. Do that for one chain this week and look at what your database was doing for callers who had already left.

What is the longest your system keeps working on a request after the person who asked for it has already seen an error?

## Resources

1. [gRPC documentation: deadlines and cancellation](https://grpc.io/docs/what-is-grpc/core-concepts/#deadlines)
2. [Google SRE Book, Chapter 22: Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/)
3. [Your Retry Policy Is a DDoS You Wrote Yourself](https://anushamukka.com/posts/your-retry-policy-is-a-ddos-you-wrote-yourself/)
4. [Your Servers Disagree About What Time It Is](https://anushamukka.com/posts/your-servers-disagree-about-what-time-it-is/)
5. [Exactly-Once Delivery Is a Lie. Idempotency Keys Are the Practical Answer.](https://anushamukka.com/posts/exactly-once-delivery-is-a-lie-idempotency-keys-are-the-practical-answer-3351/)
