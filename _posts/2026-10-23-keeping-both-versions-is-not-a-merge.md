---
layout: post
title: Keeping Both Versions Is Not a Merge
date: 2026-10-23 09:41:00 -0400
categories: [Writing]
tags: [Distributed Systems, Databases, Software Engineering]
description: "Concurrent writes do not need a resolver or a leader when the value carries its own history. G-Counters, PN-Counters, and add-wins sets with a runnable demo, and the invariants CRDTs cannot enforce."
---

# Keeping Both Versions Is Not a Merge

*Yesterday's answer to conflicting writes was to keep both versions and surface the conflict. That is honest bookkeeping, but somebody still has to decide what the value is now, and for most data that decision is arithmetic, not judgment.*

## The Counter That Counted to Eleven

Two replicas hold a count of 10. The network splits. Each side takes one more order, so each side now holds 11, and each side is telling the truth about what it saw. The network heals, the replicas compare notes, and whichever merge rule you reach for first, taking the larger value, keeping the later timestamp, overwriting with whichever replica syncs second, returns 11. Twelve orders were placed. The system of record says eleven, and the twelfth customer gets an apologetic email.

Tell me about the last counter in your system that two nodes could increment at the same time. A plain integer carries no history. It records where it ended up, not how it got there, so when two copies disagree there is nothing inside the value that tells you how to combine them. The merge has to guess, and every guess loses an increment silently.

The piece before this one made the case for vector clocks: compare two writes by what each writer knew, and refuse to discard concurrent writes quietly. That solves detection. It leaves you holding two versions of a shopping cart, two versions of a seat count, two versions of a document, and a standing invitation to write merge code by hand for every data type you own. This piece is about the data types that merge themselves.

## Name the Two Bad Options

The first bad option is the hand-written merge. You keep both versions, you write a resolver for the cart, another for the profile, another for the settings object, and each resolver is a small pile of judgment calls that nobody documented. Resolvers also drift. Six months later the cart merge runs on the client and a slightly different cart merge runs on the server, and now the merge itself needs merging.

The second bad option is to prevent concurrency instead. Route every write through one leader, serialize the counter, and the conflict never forms. You have paid for that safety with the thing replicas were for: the far region waits on the leader's round trip, a partition stops writes instead of degrading them, and a leader failure turns a counter into a meeting. Plenty of data deserves exactly that treatment. A bank balance is not a popularity contest. The mistake is paying the serialization price for data that never needed it, because nobody trusted concurrent writes to land anywhere honest.

I understand why the hand-written merge wins the design meeting. It looks small. One function, one data type, one afternoon. What the estimate leaves out is that the function has to be right under every interleaving your network can produce, including the ones nobody thought to test, and it has to stay right as the schema grows fields. The cost arrives in the currency distributed systems always collect: the rare case, found late, explained badly.

> A conflict you can detect is progress. A value that resolves its own conflicts is a design.

## The Gap the Conflict Detectors Skip

Most writing about replication conflicts stops at detection, as if knowing two writes are concurrent were the hard part. Detection is the easy half. The hard half is a merge rule with three properties, and the properties are the whole subject, so let me state them plainly.

A merge rule needs to be commutative: merging A into B gives the same answer as merging B into A. It needs to be associative: grouping three merges differently changes nothing. And it needs to be idempotent: merging the same state twice changes nothing, because in a real network the same state will absolutely arrive twice. A rule with all three properties has a remarkable consequence. Replicas can merge in any order, over any topology, with duplicates and delays, and every replica that has seen the same updates holds the same value. Engineers call that strong eventual consistency, and the data types built to provide it are conflict-free replicated data types, CRDTs, set out formally by Marc Shapiro and colleagues at INRIA in 2011.

The gap this piece fills is the step from the properties to the mechanism. A CRDT does not achieve those properties by being clever at merge time. It achieves them by changing what gets stored. The integer that lost an order stored a total. A grow-only counter stores one slot per replica and merges slot by slot, so the history that merging needs is inside the value itself. That trade, more storage and more structure in exchange for a merge that cannot lose, is the entire idea. Everything else is variations for sets, maps, and text.

## Carry the History Inside the Value

Here is the pipeline, and notice that there is no coordinator anywhere in it:

```
 replica A          replica B          replica C
 +-------+          +-------+          +-------+
 | local |          | local |          | local |
 | edit  |          | edit  |          | edit  |
 +---+---+          +---+---+          +---+---+
     |                  |                  |
     +------- gossip / sync, any order ---+
     |          merge = join of states     |
     v                  v                  v
 same state       same state        same state
 (once each has seen the same updates)
```

Each replica edits locally and answers reads locally, with no round trip and no permission from anyone. Sync is gossip between peers, in whatever order the network delivers. Merge is a join: combine two states by taking, per component, the value that represents more knowledge. Because the join is commutative, associative, and idempotent, the order of the arrows stops mattering. The detail that makes this cheap enough to run is that merge is mechanical. There is no application callback, no resolver, no human. The data type carries its merge rule the way an integer carries addition.

The counter shows why this works. If each replica keeps its own slot and only ever increases its own slot, then merging is taking the maximum of each slot, and the maximum operation has all three properties for free. Two increments that raced each other live in different slots, so both survive the merge. The total is the sum of the slots, computed at read time. Nothing was coordinated, and nothing was lost. Decrements get the same treatment with a second counter: one grow-only counter for additions, one for subtractions, and the value is the difference.

Sets are where it gets interesting, because a set has two operations that fight. If replica A adds an element while replica B removes it, add-wins and remove-wins are both defensible, and a CRDT makes you pick one in the data type rather than in a code review. The observed-remove set picks add-wins with a precise mechanism: every add carries a unique tag, a remove deletes only the tags it has observed, and a concurrent add, whose tag the remover never saw, survives. The rule is not "adds beat removes." The rule is "you can only remove what you have seen," which is a claim about knowledge again, the same claim vector clocks make.

## Build the Smallest Honest Version

Here is the mechanism in runnable Python, standard library only. The full file is crdt_demo.py next to this draft. It builds a grow-only counter, a positive-negative counter, and an add-wins observed-remove set, then abuses them the way a partition would.

```python
class GCounter:
    """Grow-only counter: one slot per replica, merge takes the max."""

    def __init__(self, node):
        self.node = node
        self.counts = {}

    def increment(self, n=1):
        self.counts[self.node] = self.counts.get(self.node, 0) + n

    def value(self):
        return sum(self.counts.values())

    def merge(self, other):
        for k, v in other.counts.items():
            self.counts[k] = max(self.counts.get(k, 0), v)
```

A few things are worth noting about this example. First, increment touches only the caller's own slot, which is why no coordination is ever needed: two replicas can never write the same slot. Second, merge is three lines and has no parameters, no timestamps, and no tie-breaking, because the structure removed everything there was to argue about. Third, value is computed at read time from the slots, which is the storage trade made visible: you store the history so the read can afford to be honest.

Running the demo prints this:

```
== Part 1: a plain integer cannot merge concurrent increments ==
both replicas incremented 10 -> 11 concurrently
merge by max keeps: 11  (true total should be 12)
increments silently lost: 1

== Part 2: G-Counter merges in any order and loses nothing ==
increments: A+3, B+5, C+2 (true total 10)
merge orders tried: 6, distinct results: [10]

== Part 3: PN-Counter handles decrements the same way ==
restock +10, sales -3 and -2, merged value: 5

== Part 4: OR-Set, the add that raced a remove wins ==
before merge: A holds seat-14A = True, B holds seat-14A = False
after merge both ways: A = True, B = True  (add-wins: concurrent add survives)
after an informed remove: A = False, B = False

== Part 5: shuffled gossip converges to one state ==
replica A: ['deploy-freeze', 'freeze-exempt:hotfix', 'on-call:priya']
replica B: ['deploy-freeze', 'freeze-exempt:hotfix', 'on-call:priya']
replica C: ['deploy-freeze', 'freeze-exempt:hotfix', 'on-call:priya']
replica D: ['deploy-freeze', 'freeze-exempt:hotfix', 'on-call:priya']
distinct views across replicas: 1
```

Read the five parts as one argument. Part 1 is the incident from the opening: the plain integer, merged by the obvious rule, loses an increment and says nothing. Part 2 merges the counter in all six orders three replicas allow and gets one answer, which is the three properties doing their job. Part 3 is the seat count with a restock and two partitioned sales landing at 5, the number a serialized system would have produced, reached here with no serialization. Part 4 is the honest surprise: B removed the seat, A re-added it concurrently, and after merging, the seat is present on both, because B's remove only covered the add B had seen. An informed remove, one that has observed both adds, removes it everywhere. Part 5 is the convergence claim tested rather than asserted: four replicas, thirty rounds of random pairwise gossip, one distinct view at the end. Note that deploy-freeze is back in Part 5 even though B removed it. B had only seen its own add at that point. Two adds it had never observed outlived its remove, exactly as the rule promises.

Real systems ship these types under real load. Automerge and Yjs put CRDTs under collaborative documents, where the concurrent edits are keystrokes and the merge has to feel invisible. Redis, in its active-active deployment, replicates CRDT-based counters, sets, and hashes across regions so two regions can take writes through a partition. Riak offered CRDT counters, sets, and maps as native data types, carrying the Dynamo lineage from the earlier piece in this series into types a developer could pick from a menu. The pattern survives because the alternative, a resolver per data type per team, kept losing increments.

## Where This Breaks

Say the limits plainly, because a CRDT buys convergence, not correctness:

- Convergence is not a business rule. A CRDT seat counter will happily converge to negative five. Every replica agrees, and the agreement is worthless, because the invariant "never sell more seats than exist" spans replicas and no local merge can enforce it. Invariants that must never break still need coordination, escrow, or a leader. A CRDT tells you everyone will land on the same value; it never promised the value would be legal.
- The state grows. A slot per replica, a tag per add, tombstones for removes: the history that makes merging safe is stored, shipped, and kept. Tombstones in particular need garbage collection, and collecting them safely requires knowing every replica has seen the remove, which is a coordination problem sneaking back in through the side door.
- Text is the expensive case. Collaborative editing CRDTs track individual characters with identifiers and ordering metadata, and a long-lived document accumulates that metadata faster than it accumulates prose. Automerge and Yjs have spent years engineering this cost down. Budget for it before you promise it.
- Some semantics have no CRDT. A unique username claim, a single-winner auction, anything where exactly one concurrent attempt may succeed: these are consensus problems wearing a data type costume. The merge properties cannot manufacture a winner.
- Operation-based variants trade storage for delivery rules. Shipping operations instead of full state is cheaper on the wire, but the operations must arrive reliably and, for some types, in causal order. You have moved the complexity into the transport, not deleted it.

## Decide Whether Your Data Can Merge Itself

Build it if:

- Replicas, regions, or devices must accept writes while disconnected, and the data is counters, sets, presence, carts, preferences, or documents. That list is most of what a product actually stores.
- Your current design has, or is about to grow, a folder of hand-written conflict resolvers. Each one is a CRDT you have not admitted to building, with worse properties.
- A silently lost update costs more than extra storage does. Run the arithmetic on your own incident history before deciding which side of that trade you are on.

Skip it if:

- The data carries a hard global invariant, like a balance that may not go negative or a seat that may not sell twice. Coordinate that data on purpose and pay the latency with your eyes open.
- One writer owns each value anyway. A merge rule for conflicts that cannot occur is bookkeeping in search of a problem.
- Your team cannot yet say which semantics it wants, add-wins or remove-wins, per set. The data type forces the question, and answering it wrong in the type is worse than answering it slowly in a design doc.

The minimal viable version fits in an afternoon: take one counter that two nodes can increment today, give it one slot per writer, merge by per-slot maximum, and sum at read. Run it beside the current counter for a week and diff the totals at every sync. The diff, in your own traffic, is the number of increments you are currently losing without knowing it. Decide from that number.

## Let the Value Carry Its Own History

A plain value tells you where it ended up. A CRDT tells you how it got there, and that history is what turns a merge from a guess into arithmetic. Keep both versions when you must, by all means. But for the data that fills most systems, you can do better than keeping both versions and hoping a resolver is awake. You can store the value so that it resolves itself.

Where in your system does a merge rule exist today that nobody chose, a max, a timestamp, an overwrite, quietly deciding which concurrent write your users get to keep?

## Resources

1. [Shapiro, Preguica, Baquero, Zawirski: Conflict-free Replicated Data Types (INRIA Research Report 7506, 2011)](https://inria.hal.science/inria-00555588/document)
2. [Automerge: a library of data structures for building collaborative applications](https://automerge.org/)
3. [Yjs: shared data types for building collaborative software](https://docs.yjs.dev/)
4. [Redis documentation: conflict-free replicated data types in active-active databases](https://redis.io/docs/latest/operate/rs/databases/active-active/crdt-overview/)
5. [Your Timestamps Cannot Order Your Writes](https://anushamukka.com/posts/your-timestamps-cannot-order-your-writes/)
