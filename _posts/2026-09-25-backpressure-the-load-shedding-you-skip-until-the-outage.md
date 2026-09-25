---
layout: post
title: "Backpressure: The Load-Shedding You Skip Until the Outage"
date: 2026-09-25 07:00:00 -0500
categories: [Writing]
tags: [Distributed Systems, Backpressure, Reliability, SRE]
description: "Queues do not absorb load. They schedule the outage for later, with interest. On bounded queues, 503 with Retry-After, adaptive concurrency limits, and the afternoon-sized backpressure policy."
---

# Backpressure: The Load-Shedding You Skip Until the Outage

*Your queues do not absorb load. They schedule the outage for later, with interest. Here is how to hear the warning in time.*

## The Queue That Ate the Deploy

A team I know doubled their queue capacity the week before a big launch. Traffic was going to spike, the workers held a steady four thousand jobs a minute, and nobody wanted to drop an event. So they doubled the queue and went home feeling prepared.

The launch spike hit at 9:14. The queue absorbed it beautifully. By noon the dashboard showed 800,000 queued jobs and the team relaxed: the number was falling and nothing had failed. At 2:40 the consumers stopped making progress. Not crashed, not erroring. Just stuck. Every worker alive, every health check green, throughput flatlined.

What happened took eleven hours to untangle. The queue had not absorbed the spike; it had converted a fast, visible failure into a slow, invisible one. Jobs queued for five hours were now poison: sessions expired, idempotency windows closed, callers long since timed out and retried, which queued the same jobs again. Doubling the queue bought eleven hours of false confidence and a full day of replaying stale work. It cost them the launch and the next two sprints of credibility.

Yes, this is a composite of incidents I have watched up close. It is hardly unusual. And the fix the team reached for afterward is the one I want to argue against: a bigger queue.

## Name the Two Bad Options

When a producer outruns a consumer, you get two bad default behaviors, and most systems pick one without noticing.

The first bad option is to fail fast and ugly: the producer throws, the worker crashes, the process runs out of memory, the connection times out with no explanation. The failure is honest but indiscriminate. A payment and a telemetry ping get the same treatment, and the on-call engineer gets paged at 3 a.m. with a stack trace and no policy.

The second bad option is the unbounded queue, which is what the team above chose. It feels responsible. Nothing is dropped, nothing errors, the graphs look calm. But a queue without a ceiling is not a buffer. It is a loan against future capacity at a terrible interest rate. Every queued item ages: sessions expire, locks time out, callers retry, and the older the item, the more likely it is useless work that still has to be processed. When the queue drains, much of what it delivers is garbage with a timestamp.

I understand the appeal. Dropping work feels like failure, memory is cheap, and a bigger queue feels like a bigger safety margin. But the queue is not the strategy. It is where you hold the decision. The strategy is what happens when it fills.

## Backpressure Is a Signal, Not a Setting

Here is the part every explainer skips. Backpressure is not a knob. It is information traveling in the wrong direction.

In a request pipeline, data flows downstream: client to server, producer to consumer. But capacity information lives upstream of where it is needed. The consumer knows it is drowning; the producer does not. Backpressure carries the news backward: slow down, stop for a moment, or send this elsewhere.

The math is Little's law: the average number of items in a system equals the arrival rate times the average time each item spends in it. L = arrival_rate x wait_time. Read it as a warning: if arrivals run even slightly above what your consumer can process, the wait grows without bound, and so does the queue. No queue size fixes this. A bigger queue just gives the wait more room to grow before anyone notices, moving the failure from fast and obvious to slow and mysterious, the most expensive kind.

So the real design question is never "how big should the queue be." It is "what happens when the queue fills." That answer is your backpressure policy, and if you did not choose one, the operating system chose for you: the OOM killer, the TCP backlog dropping connections, the container hitting its memory limit at the worst moment. You are running a policy either way. The only question is whether it is yours.

## Say No Before You Fall Over

Here is a work queue in Python with the entire backpressure policy visible in six lines:

```python
from queue import Queue, Full

work = Queue(maxsize=500)

def submit(job):
    try:
        work.put_nowait(job)
    except Full:
        count_drop(job.kind)     # count it, by kind, so you can alert on it
        return 503               # the edge translates this to 503 + Retry-After
    return 202
```

Three things matter here. The ceiling is explicit: 500, chosen, not inherited. The full queue has a policy, and the policy is "say no." And the rejection is countable: a dropped job that increments a metric is an operational signal; one that vanishes into a full buffer is a 3 a.m. mystery.

The same shape works for in-flight requests, where the queue is not a data structure but a count of concurrent work:

```python
import threading

in_flight = threading.Semaphore(64)

def handle(request):
    if not in_flight.acquire(blocking=False):
        return too_busy(request)   # 503, with a Retry-After header
    try:
        return serve(request)
    finally:
        in_flight.release()
```

The semaphore is the ceiling; the non-blocking acquire is the policy. The 64 requests inside get full resources and finish fast, while the 65th gets a fast, honest no. Without the ceiling, all 65 slow down together. Saying no to one request protects the ones you accepted.

The 503 is the backpressure signal, traveling backward to the caller. With a `Retry-After` header it even carries instructions:

```
HTTP/1.1 503 Service Unavailable
Retry-After: 2
Content-Type: application/json

{"error": "server at capacity, retry in 2 seconds"}
```

Not every client honors `Retry-After`, which I will come back to. But a client that retries on a schedule is one you can reason about.

## Slow the Sender Instead of Dropping the Work

Saying no is the simplest policy, not the only one. When the producer is your own code, or a client you can teach, the better move is to slow it down before the queue fills. Adaptive concurrency limits do exactly this, and the mechanism is worth understanding precisely.

The idea is borrowed from TCP Vegas, which watches round-trip time. If packets start taking longer, it assumes a queue is building somewhere and backs off before packets get dropped. Netflix's concurrency-limits library applies the same instinct to service calls: watch request latency, and treat rising latency as the early signal of a forming queue.

Here is the shape of the algorithm, simplified:

```python
class GradientLimiter:
    """Shrink the concurrency limit when latency says a queue is forming."""
    def __init__(self, initial=20, queue_size=4):
        self.limit = initial
        self.queue_size = queue_size
        self.min_rtt = None

    def sample(self, rtt):
        self.min_rtt = rtt if self.min_rtt is None else min(self.min_rtt, rtt)
        gradient = max(0.5, self.limit / rtt) if rtt > 0 else 1.0
        # How much concurrency the system absorbs before queueing starts,
        # plus a small allowance for the queue itself.
        self.limit = max(1, int(gradient * self.min_rtt + self.queue_size))
        return self.limit
```

`min_rtt` is the latency of the system with no queueing, the best it can do. When current latency rises above that floor, the gradient drops below one and the limit shrinks toward the concurrency the system can sustain. When latency clears, the limit grows back. The client never sees a 503; it just sends fewer concurrent requests. The full library adds sampling windows and smoothing so one slow request does not panic the limiter, but this is the core.

You do not have to build this. The point is the pattern: the sender adjusts its own concurrency from a signal the receiver sends. HTTP/2 does a simpler version with `WINDOW_UPDATE` frames, and gRPC inherits it, which is why a gRPC client slows down when the server stops reading. The mechanism varies. The direction of the information does not.

## Push Back at Every Layer

Draw the pipeline and the missing piece becomes obvious:

```
  Upstream                              Your service
  +------------+     requests     +----------------------------------+
  | Client or  |  --------------> |  Semaphore: 64 concurrent max    |
  | Producer   |                  |  Queue: 500 items max           |
  +------------+                  +----------------------------------+
        ^                                    |
        |                                    |  queue full or semaphore
        |                                    |  exhausted
        +---- 503 + Retry-After  <------------+
               (or a slowed sender)

  The signal travels BACKWARD, against the data flow.
```

Most systems build only the top arrow. The bottom arrow is the entire article.

In practice the bottom arrow lives at several layers. Name the real tools. At the edge, NGINX can shed load before it ever reaches your code:

```nginx
limit_req_zone $binary_remote_addr zone=api:10m rate=20r/s;
limit_req zone=api burst=40 nodelay;
```

That is a token bucket: 20 requests per second sustained, bursts of 40 absorbed, everything beyond rejected with a 503. The bucket is the queue, `burst` is its ceiling, the rejection is the policy, in three lines.

One layer in, Envoy's circuit breaker caps the load your service places on a dependency, which is backpressure aimed downstream instead of up:

```yaml
circuit_breakers:
  thresholds:
  - priority: DEFAULT
    max_connections: 100
    max_pending_requests: 100
    max_requests: 200
```

Past those caps Envoy fails fast instead of queueing, so one slow dependency cannot turn your service into a parking lot.

On the messaging side the same idea hides in consumer config. Kafka's `max.poll.records` bounds work per poll; NATS JetStream's `MaxAckPending` caps unacknowledged messages per consumer. Both are ceilings with policies, and both exist because someone learned this the hard way.

## Where This Breaks

Shedding load is not free. Here is where the pattern fails.

- A 503 to your biggest customer is a business conversation, not a technical one. Across an organizational boundary you need agreed semantics: who gets shed first, what the client does about it, who gets paged when shedding starts. The header is easy. The contract is the work.

- Rejected work is work you must have a policy for. A dropped request is either retried by the client inside a retry budget, parked in a dead-letter queue for later, or accepted as loss. "Drop it" is not a policy. "Drop it, count it, alert on it, and replay it from the dead-letter queue within the hour" is a policy.

- If every layer slows instead of shedding, backpressure becomes a traffic jam with no exits. A chain of services all holding connections open for one slow dependency does not relieve pressure; it relocates it into connection pools, file descriptors, and thread stacks, which run out with less warning than queues do. Somewhere in the chain, someone has to say no.

- Adaptive limiters need traffic to learn. A gradient algorithm converges under load; at three requests a minute it tells you nothing and its `min_rtt` floor goes stale. Expect cleverness during the spike, which is when you need it.

- `Retry-After` is advisory. Some clients honor it; some retry immediately; some predate the header. A polite 503 becomes a retry storm when the client fleet ignores your instructions, which is its own outage with its own article.

- Backpressure buys time. It does not buy capacity. If the spike is the new normal, the correct response is more servers, a faster consumer, or less work per request. The signal tells you where the ceiling is. It does not raise it.

## Build It If, Skip It If

Build it if a producer you do not control feeds a consumer you cannot speed up. Build it if you have ever said "the queue will absorb it" and meant it as a strategy rather than a hope. Build it if your last incident involved a queue that looked fine right up until it did not.

Skip it if the load is genuinely bounded: a single-tenant internal tool, a nightly batch with a known input size, a queue that drains in seconds under the worst case you can construct. Skip it if your autoscaling reacts faster than your queues fill, verified under load and not just in a design doc. Not every system needs a fortress. The ones with strangers on the other end of the socket do.

The minimal viable version fits in an afternoon. Put a max size on every in-memory queue in the request path. Return 503 with `Retry-After` when any fills. Add a counter and an alert on every rejection. Give every client a timeout and a bounded retry budget so your signal does not become their storm. Four small changes, and "the queue will absorb it" becomes a policy with a ceiling, a signal, and a paper trail.

Audit one service this week: list every queue in its path, find the ones with no ceiling, and ask what happens when each fills. The answer should be a sentence you wrote on purpose. If it is a shrug, you already know what to fix.

What is the largest unbounded queue in your stack right now, and what fills it?

## Resources

1. [Netflix concurrency-limits: adaptive concurrency limits for service calls](https://github.com/Netflix/concurrency-limits-java)
2. [Envoy documentation: circuit breaking for upstream clusters](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking)
3. [NGINX documentation: rate limiting with limit_req](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html)
4. [gRPC flow control: how HTTP/2 WINDOW_UPDATE provides backpressure](https://grpc.io/docs/guides/flow-control/)
5. [Wikipedia: Little's law](https://en.wikipedia.org/wiki/Little%27s_law)
