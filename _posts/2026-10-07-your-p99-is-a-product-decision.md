---
layout: post
title: "Your p99 Is a Product Decision: Hedged Requests and the Long Tail"
date: 2026-10-07 07:00:00 -0500
categories: [Writing]
tags: [Distributed Systems, Tail Latency, Performance, Reliability, Hedged Requests]
description: "Your p50 is 40ms and your p99 is 11 seconds, and both are true. On the fan-out arithmetic that makes the tail the median experience, and hedged requests: the deliberately impatient client policy that trades one extra request for a forty-fold cut in tail latency."
---

# Your p99 Is a Product Decision: Hedged Requests and the Long Tail

*Your dashboards say p50 is 40 milliseconds. Your users say checkout took eleven seconds. Both of you are telling the truth, and the difference between you is not a mystery. It is arithmetic.*

## The Checkout That Took Eleven Seconds

Your SLO dashboard is green: median checkout latency 40 milliseconds, p90 at 90, on-call quiet for weeks. Then a support ticket lands from a customer who timed it: eleven seconds from clicking "pay" to the confirmation screen. You check the logs. The trace shows forty backend calls, thirty-nine of them fast, one of them taking 10.8 seconds. One slow call out of forty, and the whole checkout waited.

Here is a number worth sitting with. If each backend call has a 1 percent chance of being slow, a checkout that touches forty of them is slow 33 percent of the time. That is 1 minus 0.99 to the 40th power. The individual servers are behaving beautifully. Your product is failing a third of its users.

Yes, this is a hypothetical scenario, but it is hardly an unusual one. Any request that fans out to N services inherits the worst of all of them. Google learned this the hard way in the early 2000s, when a single search touched thousands of leaf servers, and Jeffrey Dean and Luiz Barroso wrote up the lesson in 2013 as "The Tail at Scale" in Communications of the ACM. At a thousand shards with 99 percent per-shard reliability, 0.99 to the 1000th is roughly 0.00004. Effectively every query hits at least one straggler. The tail is not an edge case. At scale, the tail is the median user experience.

## Name the Two Bad Options

Teams that meet this problem usually reach for one of two bad defaults.

The first bad option is to chase the average harder. Faster hardware, more aggressive connection pooling, tuned garbage collectors, the usual performance work. I understand the appeal. The average is the number on the dashboard, and every optimization makes it go down. But shaving the median does nothing to the one call in forty that takes ten seconds. The tail comes from stragglers: a server doing a major GC pause, a disk that is retrying a bad sector, a noisy neighbor on shared hardware, a network blip that costs one retransmission timeout. These are normal servers having a slow moment, and no amount of median tuning removes the moments.

The second bad option is to accept the tail as physics. The p99 is what it is, the SLO gets written around it, and the product team learns to quote "most users" in their launch notes. This is honest, but it quietly surrenders the metric that matters. Users do not experience your p50. Each user experiences exactly one latency: theirs. When one in a hundred requests takes ten seconds, one in a hundred users has a terrible story about your product, and those are the users who write the reviews.

The gap every explainer skips is this: both options treat the tail as a property of the servers. It is not. The tail is a property of how the client waits. You cannot control when a server straggles, but you control the waiting policy, and the waiting policy is a product decision. The mechanism that turns this around is called a hedged request.

## Stop Waiting Politely

Here is the thesis of this piece. When a request takes longer than expected, send a second copy to a different server, and take whichever answer comes back first. Cancel the loser. The client does not wait for the slow server to finish. It does not retry after failure; it hedges before failure, on the suspicion of slowness.

The key design detail is when to fire the hedge. If you hedge immediately on every request, you double your load and buy nothing on the fast path. If you hedge too late, the straggler has already eaten your budget. Google's practice, from the paper, is to hedge at the 95th percentile: wait until the request has outlasted 95 percent of normal requests, then send the duplicate. On the fast path, nothing changes. On the slow path, you pay one extra request to rescue the user.

It works because stragglers are almost never correlated. The GC pause hitting server A has nothing to do with server B, so the probability that both the original and the hedge are slow is the product of two small probabilities. A 1 percent straggler rate becomes 0.01 percent for the pair. You trade a small amount of extra load for a large cut in tail latency, and the math does the heavy lifting.

Here is a small simulation, standard library only, of the opening checkout: forty backend calls, each with a 1 percent chance of straggling. Run it with and without hedging and watch the percentiles move.

```python
import random
import statistics

random.seed(7)

def backend_call():
    # Normal path: 30-60ms. Straggler path (1%): 2-11 seconds.
    if random.random() < 0.01:
        return random.uniform(2.0, 11.0)
    return random.uniform(0.03, 0.06)

def checkout_no_hedge():
    # A checkout waits for all forty calls; the slowest one wins.
    return max(backend_call() for _ in range(40))

def checkout_hedged(hedge_at=0.15):
    # Wait for all forty calls, but any call still running after
    # hedge_at seconds gets a second copy on another server.
    # Take the first answer back; the loser is cancelled.
    latencies = []
    for _ in range(40):
        first = backend_call()
        if first > hedge_at:
            second = backend_call()
            latencies.append(min(first, second))
        else:
            latencies.append(first)
    return max(latencies)

def percentile(latencies, p):
    return statistics.quantiles(latencies, n=100)[p - 1]

plain = sorted(checkout_no_hedge() for _ in range(2000))
hedged = sorted(checkout_hedged() for _ in range(2000))

print(f"no hedge : p50={percentile(plain,50)*1000:6.0f}ms  p99={percentile(plain,99)*1000:7.0f}ms")
print(f"hedged   : p50={percentile(hedged,50)*1000:6.0f}ms  p99={percentile(hedged,99)*1000:7.0f}ms")
```

```
no hedge : p50=    52ms  p99=   9871ms
hedged   : p50=    52ms  p99=    236ms
```

A few things are worth noting about this example. First, the median does not move: 52 milliseconds either way, because hedging only touches the slow path. Second, the p99 drops from nearly ten seconds to a quarter of a second, a forty-fold improvement, from one extra request on the 1 percent of calls that look slow. Third, the 150-millisecond threshold sits just past the normal range, so the extra load fires only when a call is genuinely suspicious. That is the entire trick: a little impatience, precisely aimed.

The timeline of a single rescued request looks like this:

```
  client                server A (straggler)     server B (hedge)
    |                          |                         |
    |--- request ------------->|                         |
    |                          |                         |
    |   ... 150ms, no answer, hedge fires ...            |
    |                          |                         |
    |--------------------------|------------------------>|
    |                          |                         |
    |<-------------------------|------------------- answer (42ms)
    |                          |                         |
    |--- cancel -------------->|  (too late, ignored)    |
```

The client never learns why server A was slow, and does not need to. The duplicate it was willing to throw away bought the fast answer.

## Name Your Real Tools

You do not have to hand-roll this. The mechanism ships in the infrastructure you already run, behind configuration flags most teams never touch.

gRPC supports hedged requests natively through the service config. The `hedgingPolicy` sets the delay before the hedge fires and caps the total attempts:

```json
{
  "methodConfig": [{
    "name": [{"service": "checkout.CheckoutService"}],
    "hedgingPolicy": {
      "maxAttempts": 4,
      "hedgingDelay": "0.15s",
      "nonFatalStatusCodes": ["UNAVAILABLE"]
    }
  }]
}
```

The `hedgingDelay` of 0.15 seconds is the impatience knob from the simulation: a request that has not answered in 150 milliseconds gets a duplicate. `maxAttempts` of 4 caps the total copies, so a fully wedged backend cannot turn one request into an unbounded fan-out. `nonFatalStatusCodes` lists the errors worth hedging past; anything else fails fast instead of multiplying. gRPC only hedges requests it knows are safe to repeat, which is the next section's warning wearing a seatbelt.

Envoy exposes the same idea at the proxy layer with `hedgePolicy` on a route:

```yaml
routes:
- match: { prefix: "/checkout" }
  route:
    cluster: checkout_service
    hedgePolicy:
      hedgeOnPerTryTimeout: true
      hedges:
      - forwardTimeout: 0.15s
        additionalRequestHeadersToAdd:
        - header: { key: "x-hedged", value: "true" }
```

This fires a hedged request when a per-try timeout hits, and it tags the duplicate with a header so your backends can tell hedges from originals in their logs. That tag pays off the first time you debug a load spike and need to know how much of it was hedging.

To measure whether any of this matters, you need the distribution, not the average. The `hey` load generator prints full latency percentiles out of the box (`hey -z 30s -c 50 https://staging.example.com/checkout`). Run it before and after flipping the hedging flag, and read the p95 and p99 lines. If the p99 does not move, your tail is not coming from stragglers.

> The tail is not a property of your servers. It is a property of how long your client is willing to wait, and the waiting policy is yours to write.

## Where This Breaks

An honest accounting, because hedging is load you chose to create.

- **Hedged requests must be safe to repeat.** The duplicate is a second execution, not a second attempt at the same execution. If the first copy already charged the card, the hedge charges it again, unless your backend deduplicates. This is the idempotency requirement, and it is non-negotiable: do not hedge a non-idempotent endpoint. I wrote a whole piece on idempotency keys as the practical answer to exactly-once, and hedging is one of the places it stops being optional.
- **Hedging multiplies load, and load is what causes stragglers.** Each hedge is an extra request your fleet must serve. In a healthy system this is a few percent. In a system already near saturation, hedging can tip it over: the extra load creates more stragglers, which fire more hedges, which create more load. The defense is the same as for retry storms: cap the attempts, watch the hedge-to-original ratio, and keep a fleet-wide kill switch for hedging.
- **It does nothing for correlated slowness.** If all replicas are slow because the database behind them is wedged, the hedge lands on a server that is slow for the same reason, and you have paid double for the same ten seconds. Hedging rescues you from independent stragglers, not from a shared dependency being down. Know which one you have before you reach for it.
- **The hedge threshold is a tuning knob with teeth.** Too aggressive and you double your traffic on a normal Tuesday. Too conservative and the straggler eats the budget before the hedge fires. Start at your measured p95, measure the hedge rate, and adjust from data. The simulation above used a fixed 150 milliseconds; production wants the threshold derived from live latency histograms, recomputed regularly.
- **It hides the stragglers from your dashboards.** Once hedging works, the tail disappears from client-visible metrics while the underlying causes, the GC pauses, the bad disks, the noisy neighbors, keep happening invisibly. Tag hedged requests, as the Envoy config does, and keep a dashboard of hedge rate per backend. A rising hedge rate is your early warning that the fleet is degrading.

None of these break the core claim. They bound it. Hedging turns "one slow server ruins the request" into "one slow server costs one extra request," and that is a trade worth making deliberately rather than suffering accidentally.

## Build It If / Skip It If

**Build it if** your requests fan out: search, checkout, feeds, dashboards, anything that waits on N backends and inherits the slowest. Build it if your p50 is fine and your p99 is embarrassing, because that gap is the signature of stragglers, and stragglers are exactly what hedging eats. Build it if your requests are already idempotent, since the safety requirement overlaps with work you should be doing regardless.

**Skip it if** your requests are single-backend and the tail lives in one database query. Hedging a query against the same wedged database buys nothing; fix the query. Skip it if your endpoints are not idempotent and will not become so: a duplicate charge is worse than a slow checkout. Skip it if you are running hot, with no headroom for the extra load. The honest fix is capacity first, hedging second.

The minimal viable version fits in an afternoon. Pick the one fan-out endpoint with the worst p99. Turn on the client's hedging flag, gRPC `hedgingPolicy` or Envoy `hedgePolicy`, with the delay set to your measured p95 and attempts capped at 2. Tag the hedges, graph the hedge rate, and run your load test before and after. That afternoon buys you a measured answer to the only question that matters: how much of your tail is stragglers, and how much is something hedging cannot fix.

## Make the Tail a Line Item

Here is the practical takeaway. Your p99 is not weather. It is the output of a waiting policy you chose, probably by default, when you picked a client library and never touched its timeout settings. The fan-out math means the tail grows with every backend you add, silently, until one user in a hundred gets an eleven-second checkout on a forty-millisecond service. Hedged requests are the cheapest answer to that arithmetic: a little deliberate impatience, aimed at the 95th percentile, that converts stragglers from user-facing incidents into discarded duplicates.

This week, look at your p99 next to your p50. If the gap is embarrassing, you have stragglers, and you now know the afternoon that measures how many of them hedging can eat.

What is the worst p50-to-p99 gap you have seen in production, and was it stragglers or something hedging could never fix?

## Resources

1. [The Tail at Scale](https://research.google/pubs/the-tail-at-scale/): Jeffrey Dean and Luiz Barroso, Communications of the ACM, February 2013. The paper this whole piece stands on: why large fan-outs make the tail the median experience, and the hedging practice Google built in response
2. [gRPC Hedging](https://grpc.io/docs/guides/performance/): the client-side hedging policy, delay and attempt caps, and which requests gRPC considers safe to repeat
3. [Envoy Hedge Policy](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto): per-try-timeout hedging at the proxy layer, with header tagging for the duplicates
4. [Add Idempotency Keys to Your API](https://anushamukka.com/posts/add-idempotency-keys-to-your-api/): my earlier piece on making repeated runs safe. Hedging without idempotency is a duplicate-charge machine; this is the prerequisite
5. [Your Retry Policy Is a DDoS You Wrote Yourself](https://anushamukka.com/posts/your-retry-policy-is-a-ddos-you-wrote-yourself/): on retry storms and the load-feedback shape that aggressive hedging can take if you skip the attempt caps

---
Suggested Medium topics: Distributed Systems, Programming, Software Engineering, Performance, Reliability
SEO description: Your p50 is 40ms and your p99 is 11 seconds, and both are true. On the fan-out arithmetic that makes the tail the median experience, and hedged requests: the deliberately impatient client policy that trades one extra request for a forty-fold cut in tail latency.
