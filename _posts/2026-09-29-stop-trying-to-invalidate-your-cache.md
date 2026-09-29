---
layout: post
title: "Stop Trying to Invalidate Your Cache. Budget the Staleness Instead."
date: 2026-09-29 07:00:00 -0500
categories: [Writing]
tags: [Caching, Distributed Systems, Reliability, Performance]
description: "Cache invalidation cannot be perfect in a distributed system. Stop chasing it. Set a staleness budget per data type and pick the cheapest mechanism that honors it."
---

# Stop Trying to Invalidate Your Cache. Budget the Staleness Instead.

*Your cache will serve stale data. The question is never whether. It is how stale, for how long, and to whom. Pick that number on purpose, or your incidents will pick it for you.*

## The Price That Would Not Change

On a Thursday afternoon, a team I know shipped a pricing change. New plans, new numbers, the kind of deploy where marketing is already tweeting. Within an hour, support had forty tickets from users seeing the old prices. Not all users. About three percent, scattered across regions, no pattern in the accounts.

The on-call engineer did the obvious thing. She checked the deploy. It was live. She checked the database. The new prices were there. She ran the invalidation job, the one that deletes the cached pricing on every write, and watched it report success. Then she loaded the page herself and saw the old price staring back at her.

The cache had been invalidated. The database was correct. And the page was wrong. All three were true at the same time, which is the part that makes cache bugs feel like gaslighting.

Yes, this is a composite of incidents I have watched up close. It is hardly unusual. The root cause was not a broken invalidation job. The job worked exactly as designed. The root cause was the design: the team had built a system that promised fresh data and delivered a race condition instead.

## Name the Two Bad Options

When teams realize their cache can lie, they pick one of two bad default reactions, usually without noticing they picked.

The first bad option is to stop thinking about it. Set a TTL on everything, thirty minutes, maybe an hour, and accept whatever staleness falls out. This works right up until the pricing page, or the permissions check, or the inventory count turns out to be the thing that cannot be stale. The failure mode is never "the cache was stale." It is always a support ticket about wrong data, and the cache is the last place anyone looks, because the TTL was set six months ago by someone who has since left.

The second bad option is the chase. Invalidate on every write. Delete the key, purge the CDN, broadcast the eviction to every node, and build an ever more elaborate deletion pipeline in pursuit of perfect freshness. I understand the appeal. It feels rigorous, it is easy to explain in a design review, and it makes the immediate bug go away. But perfect invalidation is not achievable in a distributed system, and the pipeline you build chasing it becomes its own source of outages: the invalidation storm that hammers the origin harder than the traffic it was meant to protect, the purge API with its own rate limits and its own failures.

So the real question is never "how do we invalidate perfectly." It is "how stale are we willing to be, for this data, and have we written that number down anywhere."

## The Race Every Explainer Skips

Let me give you the mechanism, because the mechanism is the part every explainer skips.

Cache-aside, the pattern most of you run, looks innocent:

```
Client request
  |
  v
[Cache] -- hit? --> return value
  |
  miss
  v
[Database] --> read row --> write to cache --> return value
```

Now add a concurrent writer, and watch what actually happens. Here is the interleaving that caused the Thursday pricing incident, with two processes and one cache key:

```
Time    Reader (serving traffic)          Writer (pricing deploy)
----    ------------------------          ----------------------
t1      cache MISS on price:plan_pro
t2      SELECT * FROM plans ...           (query running, slow replica)
t3                                          UPDATE plans SET price=...;
t4                                          DELETE cache price:plan_pro  (invalidation: success)
t5      query returns OLD price ($29)
t6      SET cache price:plan_pro $29 EX 3600
t7      return $29 to user
```

Read that again. The invalidation succeeded. The database is correct. And at t6, the reader wrote the old price back into the cache with a fresh one-hour TTL, because its database read started before the write and finished after the invalidation. The stale value now sits in the cache, fully "valid," for the next hour. Every invalidation strategy that deletes keys has this hole, because a delete cannot reach into the future and stop a write that is already in flight.

This is why "we invalidated the cache" can be true and the page can still be wrong. The delete won the race against the writer and lost the race against the reader. There is no deletion order that fixes this. It is not a bug in your invalidation code. It is the design.

## Spend the Budget on Purpose

Once you accept that some staleness is unavoidable, the engineering changes shape. You stop asking "how do we keep this fresh" and start asking "what is the staleness budget for this data, and what is the cheapest mechanism that honors it." A staleness budget is an SLO for freshness: this data may be up to N seconds old, and here is the mechanism that guarantees the bound.

Four mechanisms cover nearly everything. Pick per data type, not per system.

**First, TTLs with jitter, for data where approximate freshness is fine.** Product catalogs, recommendation lists, config that changes rarely. The trick that matters is the jitter: if every key expires on a round TTL, they all expire together, and the resulting thundering herd replays your worst traffic spike against the database at the worst moment.

```
# Every key gets a slightly different TTL: base 300s, plus up to 60s of jitter
SET catalog:category:phones <payload> EX 342
```

A few things are worth noting about this example. First, the jitter is not decoration. Without it, a deploy that warms the cache at 14:00 creates a synchronized expiry at 14:05, and your database meets every client at once. Second, the TTL is the staleness budget made explicit: 342 seconds is the oldest this data can ever be. If the business cannot tolerate six-minute-old catalog data, the TTL is wrong, and no amount of invalidation cleverness fixes a budget the business never agreed to.

**Second, versioned keys, for data where invalidation races are unacceptable.** Instead of deleting the key on write, never reuse the key. The version moves forward; old versions simply stop being read.

```
# Write path: bump the version, write under the new key
INCR pricing:schema_version        # -> 47
SET pricing:v47:plan_pro <payload> EX 3600

# Read path: always read the current version
ver = GET pricing:schema_version   # "47"
GET pricing:v47:plan_pro
```

Here is why this design choice is not an accident. A delete races with in-flight reads, as the timeline above showed. A version bump does not: the slow reader at t5 writes its stale value under `pricing:v46:plan_pro`, a key nobody will ever read again. The stale write lands harmlessly in a dead version. You trade a small amount of memory, the dead versions linger until their TTLs expire, for the complete elimination of the invalidation race. This is the same idea behind immutable deployments, applied to cache keys.

**Third, request coalescing, for the thundering herd itself.** When a hot key expires, hundreds of requests miss at once and all of them hit the database. The fix is to let exactly one request do the expensive work while the rest wait for its result. Go's `singleflight` package is the canonical implementation; every language has an equivalent.

```go
var group singleflight.Group

func getPrice(plan string) (string, error) {
    v, err, _ := group.Do("price:"+plan, func() (interface{}, error) {
        // Only one caller executes this per key.
        // Everyone else waits and shares the result.
        return fetchPriceFromDB(plan)
    })
    if err != nil {
        return "", err
    }
    return v.(string), nil
}
```

The walkthrough: `group.Do` takes a key and a function. The first caller for `"price:plan_pro"` runs the function. Every concurrent caller with the same key blocks until it completes, then receives the same result. One database query instead of hundreds. The detail that makes it cheap enough to run is that the deduplication is in-process and key-scoped: you are not building a distributed lock, you are just refusing to ask the same question twice at the same moment.

**Fourth, stale-while-revalidate at the edge, for the CDN layer.** Sometimes the cheapest fresh data is slightly stale data served instantly while the fresh copy loads in the background.

```
Cache-Control: public, max-age=60, stale-while-revalidate=300
```

The walkthrough: for sixty seconds, the edge serves the cached copy as fresh. For the next five minutes, it serves the cached copy as stale while fetching a new one in the background. The user never waits for the origin. The staleness budget is written directly into the header: sixty seconds of guaranteed freshness, five minutes of maximum staleness. Anyone debugging a stale page can read the budget off the response headers instead of guessing.

## Where This Breaks

Unhedged limitations, because every mechanism above has a failure mode and you should know them before you adopt them.

- Versioned keys leak memory. Every version bump orphans the old keys until their TTLs expire. At high write rates, the dead versions can exceed the live data. Cap versions with short TTLs on the old keys, or this becomes a slow memory leak with a clever name.
- TTLs do not know about your deploys. A pricing change ships, and the old price stays cached until the TTL expires. If the business treats pricing as "must be fresh within seconds," a TTL is the wrong mechanism no matter how short you make it. Short TTLs just move the load to the database.
- Request coalescing has a blast radius. If the single-flighted database call is slow, every waiter is slow together. One bad query becomes a correlated latency spike across all requests for that key. Set a timeout on the coalesced call, and serve stale on timeout rather than failing everyone at once.
- Stale-while-revalidate hides origin failures. If the background revalidation fails, the edge keeps serving the stale copy, and your monitoring sees green while users see yesterday. Alert on revalidation failures separately from user-facing errors, or the staleness budget becomes infinite without anyone noticing.
- None of these fix the "who is allowed to see this" problem. Caching a permissions check or a personalized price and serving it to the wrong user is not staleness, it is a security bug. Never share cache keys across trust boundaries. The key must include the identity it was computed for, or the cache becomes a confused deputy.

## Build It If / Skip It If

Build a staleness budget if your cache serves data where "wrong for a while" has a different cost than "slow for a moment." Pricing, inventory, permissions, feature flags: these need explicit budgets because the cost of staleness is measured in money or access, not milliseconds. Write the budget down next to the TTL, in a comment or a runbook, so the next person knows the number was chosen and not inherited.

Skip it if your cache is a pure performance layer over data that is already versioned or immutable. Content-addressed blobs, compiled assets with hashed filenames, database rows fetched by primary key and never updated in place: these cannot go stale in ways that matter, and a budget for them is process theater.

The minimal viable version fits in an afternoon. Pick your three highest-traffic cached data types. For each one, write down the staleness the business can actually tolerate, as a number, confirmed with whoever owns that data. Then check whether the current TTL honors it. In my experience, one of the three will not, and that gap is your next incident, already scheduled. Fix that one with the cheapest mechanism from the list above. You do not need a caching platform. You need three numbers and the honesty to treat them as requirements.

## Pick the Number

Stop treating cache freshness as a property your system either has or does not have. It is a budget: an amount of staleness you spend deliberately, on specific data, with a mechanism that enforces the bound. The teams that get bitten are not the ones with stale caches. Every cache is stale sometimes. The teams that get bitten are the ones who never decided how stale was acceptable, and found out from a support ticket on a Thursday afternoon.

Audit one cached data type this week. Find its TTL, find who chose it, and ask what staleness the business actually tolerates. What is the most expensive stale read your team has shipped?

## Resources

1. [Cache-Aside Pattern, Microsoft Azure Architecture Center](https://learn.microsoft.com/en-us/azure/architecture/patterns/cache-aside): the standard pattern, including the consistency caveats most summaries omit.
2. [Redis SET command with EX/PX options](https://redis.io/commands/set/): TTL mechanics and atomic set-with-expiry.
3. [Go singleflight package](https://pkg.go.dev/golang.org/x/sync/singleflight): request coalescing with worked semantics.
4. [RFC 5861: HTTP Cache-Control Extensions for Stale Content](https://www.rfc-editor.org/rfc/rfc5861.html): stale-while-revalidate and stale-if-error, specified precisely.
5. [Cloudflare: What is Cache Invalidation](https://www.cloudflare.com/learning/cdn/what-is-cache-invalidation/): the CDN operator's view of purge mechanics and limits.
