---
layout: post
title: Your Timestamps Cannot Order Your Writes
date: 2026-10-21 11:07:00 -0400
categories: [Writing]
tags: [Distributed Systems, Databases, Software Engineering]
description: "Last-write-wins by timestamp discards writes whenever replica clocks skew. On Lamport's happened-before relation, vector clocks that return before, after, or concurrent, and when to keep both versions instead of losing one quietly."
---

# Your Timestamps Cannot Order Your Writes

*Two replicas can disagree about which write came last, and both can be telling the truth about their own clocks. Ordering writes is a causality problem, and a wall clock was never measuring causality.*

## The Price That Reverted at Midnight

A product price changes twice in five seconds. One replica records the first change, a second replica records the second, and a third replica, asked to reconcile them overnight, keeps the first one. No bug report gets filed, because nothing crashed and nothing logged an error. The price simply reverts, a customer screenshots the lower number, and a support team spends a morning proving that a change everyone remembers making is nowhere in the system of record.

Tell me about the last lost update in your system that left no trace. That is the uncomfortable property of this failure: the losing write is not corrupted, it is deleted by a rule working exactly as written. The rule is last-write-wins, and the clock it trusts belongs to whichever machine happened to be fast that day.

Clock skew is the usual suspect, and an earlier piece in this series covered how far apart healthy servers drift. This piece is about the step after that one. Even with clocks disciplined to a few milliseconds, a timestamp tells you when a machine thought a write happened. It does not tell you whether that write knew about the other one. Ordering is a claim about knowledge, and time is the wrong instrument for it.

## Name the Two Bad Options

The first bad option is last-write-wins by timestamp. It is simple, it is built into more systems than anyone admits, and it resolves every conflict the same way: compare two numbers, keep the larger, discard the other without a log line. When the numbers come from different machines, you have not resolved a conflict. You have run a lottery in which the prize goes to the replica with the fastest clock, and the losing write vanishes so completely that a later audit cannot even prove it existed.

The second bad option is refusing all concurrent writes. Route every write for a key through one leader, serialize everything, and ordering becomes trivial. You have also given up the reason replicas accept writes in the first place: availability during partitions, low latency far from the leader, and progress while the leader is unreachable. Plenty of systems should pay that price, and pay it gladly. The mistake is paying it by accident because nobody trusted the alternative, or refusing to pay it and then ordering the resulting free-for-all with timestamps.

I understand why timestamps win the design meeting. Every language hands you one for free, every database indexes them happily, and the code review for "keep the newer timestamp" takes thirty seconds. The cost arrives later, in a currency that does not show up in the review: writes that lose to a clock.

> A timestamp tells you what one machine's clock said. It says nothing about what that machine knew.

## The Gap Every Timestamp Explainer Skips

Most explanations of distributed ordering start with clock synchronization, as if a tight enough sync would make timestamps trustworthy for ordering. It would not, and the reason is worth stating precisely. Suppose two writes happen on two replicas that have not communicated. Neither write caused the other, and neither replica had seen the other's value. In the only ordering that matters for correctness, those writes are not first and second. They are concurrent. Any rule that stamps them with numbers and sorts the numbers is inventing an order that reality never contained, and then discarding data on the strength of the invention.

Leslie Lamport made this point in 1978, in "Time, Clocks, and the Ordering of Events in a Distributed System." His move was to stop asking what time an event happened and start asking what an event could have known. If event A happened before event B in a way B could observe, through a shared process or a message, then A precedes B. If neither could have observed the other, they are concurrent, full stop. That relation, happened-before, is partial: some pairs are ordered, many are not, and the honesty of the scheme is that it refuses to order the rest.

The gap this piece fills is the step between that relation and a data structure you can store next to a value. Lamport clocks compress happened-before into one number per node, which is enough to order events consistently but not enough to detect concurrency: two events with different scalar clocks may still be concurrent, and the scalar cannot tell you. A vector clock keeps one counter per node, and that extra bookkeeping buys the exact thing last-write-wins pretends to have: a comparison that returns before, after, or concurrent, and means it.

## Count What Each Node Knows

A vector clock is a small dictionary that travels with a value. Each node owns one entry. When a node writes, it increments its own entry. When a node receives a value or a message, it merges the incoming clock by taking the maximum of each entry, then increments its own entry before its next write. That is the entire mechanism. No coordination, no leader, no round trip.

```
write on A            write on C            B syncs with A, then writes
----------            ----------            ---------------------------
A:1 B:0 C:0           A:0 B:0 C:1           merge -> A:1 B:1 C:0
(wrote knowing        (wrote knowing        then tick -> A:1 B:2 C:0
 nothing of C)         nothing of A)        (wrote knowing A's write)
```

Read the three clocks as knowledge statements. The first says "one write from A, and A had seen nothing from anyone else." The second says the same about C. Compare them entry by entry and neither is less than or equal to the other, so the comparison returns concurrent, which happens to be true. The third clock contains A's entry at 1, because B received A's write before writing. Compare it with A's clock and every entry is greater than or equal, so it returns after. The arithmetic is trivial. What matters is that the numbers count events a node has seen, not seconds a node has lived through, so the comparison is about causality rather than about whose oscillator ran fast.

Here is the shape of the decision at reconciliation time:

```
compare clocks
  incoming <= stored    -> stale copy, ignore it
  stored   <= incoming  -> newer in the causal sense, replace
  neither               -> concurrent: keep both, surface a conflict
```

Notice the detail that makes this design worth its storage cost: the third branch exists. Last-write-wins has two branches, and the missing one is where your lost updates went. A system that can say "these two writes are concurrent" can keep both versions, ask the application which one wins, or merge them with a rule that fits the data. A counter can merge by adding both increments. A shopping cart can merge by union. A product price, which has no honest automatic merge, can go to a human with both values and both clocks attached, instead of going to whichever clock was fast.

## Build the Smallest Honest Version

Here is the mechanism in runnable Python, standard library only. The full file is logical_clock_demo.py next to this draft. Three replicas accept writes to one key. Replica A's wall clock runs ten seconds fast, which is an unremarkable Tuesday in any real fleet.

```python
def compare(a, b):
    keys = set(a) | set(b)
    le = all(a.get(k, 0) <= b.get(k, 0) for k in keys)
    ge = all(a.get(k, 0) >= b.get(k, 0) for k in keys)
    if le and ge:
        return "equal"
    if le:
        return "before"
    if ge:
        return "after"
    return "concurrent"
```

A few things are worth noting about this example. First, compare is the whole product: tick on write, merge on receive, and this one function at reconciliation. Second, the demo gives each write both a wall timestamp and a vector clock, so you can watch the two orderings disagree on the same data. Third, the wall timestamps are not rigged by much. Ten seconds of skew decides the outcome completely, and fleets have shipped worse.

Running the demo prints this:

```
== Part 1: last-write-wins by wall timestamp loses a write ==
write 'price=10' on A: wall_ts=110 vc={'A': 1, 'B': 0, 'C': 0}
write 'price=12' on C: wall_ts=105 vc={'A': 0, 'B': 0, 'C': 1}
LWW keeps: 'price=10' (highest wall_ts=110)
A wrote first in real time but its fast clock makes its older
value look newer than it is.

== Part 2: vector clocks say what actually happened ==
compare(A, C) = concurrent
Neither vector is less than or equal to the other, so neither
write happened before the other.

== Part 3: causality, once established, is ordered for free ==
sync A -> B: B vc becomes {'A': 1, 'B': 1, 'C': 0}
write 'price=11' on B: wall_ts=110 vc={'A': 1, 'B': 2, 'C': 0}
compare(A, B) = before  (A's write came first)
compare(C, B) = concurrent  (still concurrent)

== Part 4: sync surfaces the conflict instead of hiding it ==
conflict to resolve: 'price=10' vs 'price=12'
conflict to resolve: 'price=12' vs 'price=11'
concurrent pairs surfaced: 2
writes silently discarded by vector merge: 0
```

Read the four parts as one argument. Part 1 is the production incident: a value written later in real time loses to an earlier value because the earlier writer's clock was fast. Nothing malfunctioned, and that is the problem. Part 2 is the same two writes judged by causality, and the answer changes from a confident wrong ordering to an accurate admission of concurrency. Part 3 shows that the admission is not ignorance: once B actually receives A's write, the clocks order those two writes correctly, while still calling B and C concurrent, because they are. Part 4 is the bill and the refund in one table. Two conflicts need a decision, and zero writes are discarded silently while nobody is looking.

Real systems made exactly this trade in public. Amazon's Dynamo paper, published in 2007, put vector clocks on shopping cart data and returned sibling versions to the application when writes conflicted, accepting messy merges at the application layer as the price of a cart service that stayed writable. Riak carried the same design into a general database, and its later versions moved toward dotted version vectors, which keep the causal history while shrinking what has to be stored and compared. The pattern survives because the alternative kept losing carts.

## Where This Breaks

Say the limits plainly, because a vector clock is honest bookkeeping, not magic:

- The clock grows with the number of writers. One counter per node is small at three replicas and unwieldy at ten thousand clients writing directly. Systems answer this with server side clocks, pruned histories, or dotted version vectors, and every one of those answers adds machinery the simple version does not need. If your writer set churns constantly, budget for pruning from day one.
- Detecting a conflict is not resolving one. The clock hands you two versions and a proof that neither wins. Some data has no sensible merge: a price, a username claim, a seat reservation. For that data the clock buys you a visible conflict and a human decision, which is better than a silent loss and worse than never having the conflict.
- Garbage collection of old versions needs a rule, and the rule needs care. Discarding a sibling version before every replica has seen its clock can resurrect it later as an apparent new write. Stores that prune by age are reintroducing a timestamp through the back door, with the same skew problems, one layer down.
- Causality only covers what flows through the system. If two users coordinate by phone and then write on two replicas, their writes are concurrent as far as any clock can tell, because the causal link happened outside your messages. The clock orders the knowledge your system carried, not the knowledge the world had.
- A scalar clock is sometimes the right tool. If you need a consistent total order for a log or an event stream and you do not need to detect concurrency, a Lamport timestamp or a hybrid logical clock gives you one number, cheaper to store and simpler to reason about. Reach for the vector when concurrent writes to shared state are the thing you must not lose.

## Decide Whether Your Writes Can Afford to Lose Quietly

Build it if:

- Replicas accept writes for the same data without coordinating, and a lost update costs money, inventory, or trust. Carts, counters, presence state, and collaborative documents are the classic cases.
- Your application can merge, or can present a conflict honestly. A clock that surfaces conflicts you have no way to resolve is an alert generator, not a design.
- You already suspect timestamps. If a postmortem has ever ended with "the clocks must have been off," the ordering rule was the defect and the clocks were the excuse.

Skip it if:

- One leader serializes writes for each key and you accept the availability cost on purpose. Ordering is already real in that design, and vector clocks add bookkeeping for conflicts that cannot occur.
- The data is append only or naturally commutative, so concurrent writes compose without a winner. Order is not your problem there, and a conflict detector solves a problem you do not have.

The minimal viable version fits in an afternoon: add a per writer counter dictionary beside one contested value, tick on write, merge on read repair or sync, and log every concurrent comparison instead of resolving it. Run it in shadow for a week. Count how many silent discards your current rule would have made. That count, in your own data, settles the design argument better than this article can.

## Order by Knowledge, Not by Clock

Your replicas do not share a clock worth trusting, and they never will. They do share something better, if you record it: a history of what each write knew when it happened. Record that history, compare it honestly, and let concurrent mean concurrent. The writes you save will be the ones nobody would ever have reported missing.

When your system last reconciled two versions of the same record, did it compare timestamps, and if it did, do you know which write it threw away?

## Resources

1. [Lamport: Time, Clocks, and the Ordering of Events in a Distributed System (1978)](https://lamport.azurewebsites.net/pubs/time-clocks.pdf)
2. [DeCandia et al.: Dynamo, Amazon's Highly Available Key-value Store (SOSP 2007)](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf)
3. [Riak documentation: causal context and version vectors](https://docs.riak.com/riak/kv/2.2.3/learn/concepts/causal-context/)
4. [Your Servers Disagree About What Time It Is](https://anushamukka.com/posts/your-servers-disagree-about-what-time-it-is/)
5. [Your Election Crowned Two Kings](https://anushamukka.com/posts/your-election-crowned-two-kings/)
