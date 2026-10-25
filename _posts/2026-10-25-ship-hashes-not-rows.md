---
layout: post
title: "Ship Hashes, Not Rows: Merkle Trees Find the Replica That Drifted"
date: 2026-10-25 13:52:00 -0400
categories: [Writing]
tags: [Distributed Systems, Databases, Software Engineering]
description: "Anti-entropy without the full scan. Bucket hashes and a Merkle walk find the exact records that diverged between two replicas, with a runnable demo, bucket-size arithmetic, and the limits of tree-based repair."
---

# Ship Hashes, Not Rows: Merkle Trees Find the Replica That Drifted

*Your replicas diverged during the partition and nobody can say which records moved. Comparing everything costs a full scan. Comparing nothing costs you the cold data nobody reads until the day it is the only copy left.*

## The Weekend One Replica Spent Alone

A replica misses a weekend of writes. The deploy that was supposed to pause traffic to it paused the announcement instead, writes kept flowing to the other two copies, and by Monday this node is behind by some number of records that nobody can name. Not approximately name. Name, as in list, as in these are the keys you need to fix.

Tell me about the job your team runs to answer that question. In most systems I have seen, the honest answer is one of two jobs, and both are bad in opposite directions. The first compares everything: every key, every value, replica against replica, a full scan dressed up as diligence. On a small table it finishes before anyone questions it. On forty million keys it runs for hours, saturates the network it was meant to protect, and gets quietly rescheduled from nightly to weekly to whenever someone remembers, which is another way of saying never. The second job is no job at all. The system trusts read repair: when a read touches a stale key, the read path fixes that key. That works beautifully for the keys your users actually read. The cold ninety percent, the accounts that log in twice a year, the records kept for compliance and touched by nobody, diverge on a weekend in March and are still diverged in October, waiting for the failover that promotes the stale copy to primary.

I understand why the full scan wins the design meeting. It is obviously correct, and obvious correctness is a hard thing to argue against in a room. What the estimate leaves out is that a repair mechanism priced at a full scan is a repair mechanism that will not run, and a mechanism that does not run has the same convergence properties as the second option. Silence.

> A repair you cannot afford to run is not a repair. It is a hope with a cron schedule.

## The Gap the One-Line Answer Skips

Every distributed systems text gives the same one-line answer to this problem: use a Merkle tree. The line is correct and nearly useless, because everything that decides whether the idea works sits underneath it. How big is a bucket. What exactly goes into the hash. What the walk costs when nothing diverged, when seven records diverged, when half the dataset diverged. And the question the one-liner never raises: finding the records that disagree is only half of repair, because the tree can tell you a bucket differs and cannot tell you which side is right.

The gap this piece fills is that layer. A Merkle tree, set out by Ralph Merkle in 1987 and put to work for replica repair in Amazon's Dynamo paper in 2007, turns "which records differ" from a scan into a walk. The mechanism is small enough to build in an afternoon and precise enough to price before you build it.

## Hash the Bucket, Then Hash the Hashes

Start with the smallest version of the idea. Sort your keys. Group them into fixed buckets, say 256 consecutive keys per bucket. For each bucket, hash the keys and values inside it into one short fingerprint. That fingerprint is a leaf. Now group the leaves, four at a time, and hash the fingerprints together into a parent hash. Hash the parents together and you have a root: one short string that stands for the entire dataset, in order, at this moment.

Two replicas that hold identical data compute identical roots. That sentence is the whole trick, because it inverts the cost of the common case. When nothing diverged, and nothing diverging is nearly every run, the entire comparison is one hash against one hash. Equal roots, done, go home. When the roots differ, you do not have a scan, you have a question with a structure: compare the parents under the root, keep only the branches that differ, compare the leaves under those, and descend until the differing buckets are named. Only then do you look at actual records, and only inside those buckets.

Here is the shape of it:

```
                    root hash
                 (whole dataset)
                  /          \
           group hash          group hash
           /        \          /        \
      leaf hash  leaf hash  leaf hash  leaf hash
      (256 keys) (256 keys) (256 keys) (256 keys)

  walk: root differs -> compare groups -> 1 group differs
        -> compare its leaves -> 1 leaf differs
        -> scan 256 keys locally -> ship the records that moved
```

A few things are worth noting about this design. First, the tree is not the data. It is a set of fingerprints over the data, small enough to exchange without thinking about bandwidth: sixteen leaf hashes and a handful of parents cover four thousand records in the demo below, and the ratio only improves as the dataset grows. Second, each level multiplies how much of the dataset one comparison can clear. A matching hash prunes everything underneath it, sight unseen, which is why the no-divergence case costs one comparison instead of four thousand. Third, this process has a name older than most of the tooling around it: anti-entropy, the background work a replicated system does to push replicas back toward agreement, as distinct from read repair, which only heals what a read happens to touch.

## Build the Smallest Honest Version

Here is the mechanism in runnable Python, standard library only. The full file is merkle_demo.py next to this draft. It builds two replicas of 4,096 records, plants divergences the way a partition would, and counts every comparison instead of estimating it.

```python
def bucket_hash(store, keys):
    body = "|".join(f"{k}={store[k]}" for k in keys)
    return h(body)


class MerkleStore:
    """Keys sorted into fixed buckets; bucket hashes grouped into a tree."""

    def __init__(self, store, bucket_size=256, fanout=4):
        self.store = dict(store)
        self.keys = sorted(self.store)
        self.buckets = [self.keys[i:i + bucket_size]
                        for i in range(0, len(self.keys), bucket_size)]
        self.leaf_hashes = [bucket_hash(self.store, b) for b in self.buckets]
        self.groups = []
        for i in range(0, len(self.leaf_hashes), fanout):
            self.groups.append(h("|".join(self.leaf_hashes[i:i + fanout])))
        self.root = h("|".join(self.groups))


def find_divergent_buckets(a, b):
    """Walk both trees. Returns (hash comparisons, divergent bucket ids)."""
    comparisons = 1  # the root
    if a.root == b.root:
        return comparisons, []
    divergent = []
    for gi in range(len(a.groups)):
        comparisons += 1
        if a.groups[gi] == b.groups[gi]:
            continue
        start = gi * a.fanout
        for li in range(start, min(start + a.fanout, len(a.leaf_hashes))):
            comparisons += 1
            if a.leaf_hashes[li] != b.leaf_hashes[li]:
                divergent.append(li)
    return comparisons, divergent
```

A few things are worth noting about this example. First, bucket_hash reads the actual keys and values, in sorted order, so a changed value, a missing key, and an extra key all move the leaf. Order matters: hash an unsorted bucket and two identical datasets can produce different leaves, which is a false divergence generator you built yourself. Second, find_divergent_buckets never touches a record. It compares fingerprints until it has bucket numbers, and only the repair step, which scans those buckets locally on each side, looks at real data. Third, the demo hash is truncated to sixteen hex characters to keep the output readable. Do not ship that choice. A truncated hash is a collision budget, and the production version of this code uses the full digest.

Running the demo prints this:

```
== Part 1: no divergence, the common case ==
keys per replica: 4096
naive per-key hash comparisons: 4096
merkle hash comparisons: 1
divergent buckets: []

== Part 2: seven divergent keys in three buckets ==
divergent keys planted: 7
merkle hash comparisons: 17 (1 root + 4 group hashes + 12 leaf hashes under 3 bad groups)
divergent buckets: [2, 9, 14]
keys scanned locally inside divergent buckets: 768
values shipped to repair: 7

== Part 3: one divergent key costs the same walk, not a full scan ==
divergent keys planted: 1
merkle hash comparisons: 9
divergent buckets: [8]
values shipped to repair: 1

== Part 4: bucket size is the trade, measured ==
bucket   64: leaves 64, hash comparisons 33, keys scanned locally 192
bucket  256: leaves 16, hash comparisons 17, keys scanned locally 768
bucket 1024: leaves  4, hash comparisons  6, keys scanned locally 3072
```

Read the four parts as one argument about where the cost moved. Part 1 is the run you will execute ten thousand times: nothing wrong, one comparison, and the confidence is real rather than sampled. Part 2 is the bad weekend from the opening, priced: seven wrong records found in seventeen hash comparisons, with 768 records scanned locally, where local means on disk, on the same machine, never on the wire, and exactly seven values shipped to fix it. Part 3 is the property that makes operators trust the schedule again: the cost tracks how much diverged, not how much exists. One bad record in four thousand costs nine comparisons. One bad record in forty million costs a deeper walk, not a longer scan. Part 4 is the tuning knob, priced in both directions, and it gets its own bullet in the limits below.

Real systems run exactly this shape under real load. Dynamo assigned each key range its own Merkle tree so two replicas could synchronize a range without exchanging the range. Apache Cassandra builds Merkle trees during repair and exchanges them between nodes to find the ranges that disagree, which is why the operator command is a repair command and not a copy command:

```
nodetool repair -pr
nodetool repair --full keyspace_name table_name
```

The -pr flag restricts the work to the primary ranges the node owns, the standard way to make a full repair affordable enough to run on a schedule instead of as an incident. Riak shipped the same idea as active anti-entropy, with hash trees maintained continuously so divergence is found as a matter of routine. The pattern survives because the alternative kept failing the same way: the scan got too expensive, the schedule slipped, and the divergence nobody could afford to look for became the divergence nobody knew about.

One design decision decides whether your tree tells the truth: what goes into the leaf hash. Hash the value alone and the tree is blind to everything except value changes. A record deleted on one replica and present on the other must move the leaf, so the tombstone has to be hashed as a value, not treated as an absence. Two replicas can also hold the same value at different versions, and if the version is not inside the hash the tree will call them equal and be wrong. The working rule is simple to state: hash exactly the state a repair would need to reconcile, key, value or tombstone, and version, nothing less. The earlier pieces in this series are the other half of that sentence. Vector clocks and CRDTs decide which of two divergent values wins. The tree does not decide anything. It finds the disagreement cheaply enough that deciding becomes affordable.

## Where This Breaks

Say the limits plainly, because a cheap way to find divergence is not the same as convergence:

- The tree finds disagreement, not truth. A differing bucket tells you the replicas parted company. It says nothing about which side holds the newer write, the tombstone, or the value your merge rule would keep. Repair still needs versions, timestamps with all their known faults, or a CRDT merge waiting underneath. Teams that wire tree output straight to copy-from-left have built a very efficient way to overwrite good data.
- Building the tree is not free. Hashing every record costs a read of the dataset, and Cassandra operators know this cost by name: a full repair on a large node is heavy enough that scheduling it is its own discipline. The savings are real only if you maintain the hashes as writes land, or rebuild them on a cadence your nodes can carry. A tree rebuilt by scanning everything, every run, gives back most of what the walk saved.
- Divergence at scale degrades the walk. If half the dataset moved, the walk visits most of the tree and then ships half the dataset, which is the full scan plus overhead. Merkle repair is priced for the ordinary case, a replica that missed a slice of traffic. A replica that missed a month is a restore problem, solved by streaming a snapshot, not by anti-entropy.
- The hash is a claim, not a proof. Equal hashes are treated as equal data, and with a full-length modern hash that is a sound bet. Shorten the digest to save space, or hash a serialization that two versions of your code produce differently, and the tree starts certifying agreement that never happened.
- Buckets are a trade you have to pick a side on. In the demo, shrinking the bucket from 1,024 keys to 64 cut the local scan after a hit from 3,072 keys to 192, and raised the walk from 6 comparisons to 33. Small buckets localize repair and multiply the hashes you store and maintain. Large buckets do the reverse. There is no correct number, only a number matched to how much divergence you expect.
- The window between runs is still a window. Anti-entropy on a nightly schedule means a record can sit diverged for a day, and a failover inside that day serves the stale copy. The tree shortens the search. It does not close the interval, and any design that needs the interval closed needs synchronous replication for that data, at synchronous prices.

## Decide Whether Your Replicas Can Afford to Agree

Build it if:

- You run replicas that accept writes through partitions, hinted handoffs, or outages, and your current answer to "which records differ" is a scan, a guess, or a shrug.
- Your dataset has a cold majority. If most records are rarely read, read repair is not a repair strategy for them, it is a coincidence strategy.
- Repair keeps getting deprioritized because of its cost. That is the signal the mechanism exists for: make the common run cost one comparison and the schedule stops being negotiable.

Skip it if:

- One writer owns each record and replicas are read-only copies of a log. Divergence there is a replication-lag question, and a tree over the data answers a question nobody is asking.
- Your replicas disagree constantly by design and converge through a CRDT or a log replay you already trust. You have a reconciliation engine. A second one that finds the same disagreements faster adds machinery, not safety.
- The divergence you fear is a replica that lost everything. Restore it from a snapshot. Anti-entropy is for drift, not for resurrection.

The minimal viable version fits in an afternoon: pick one replicated table, sort its keys into buckets of a few hundred, store a full-length hash of key, value or tombstone, and version per bucket in a side table updated on write, and run a nightly job that compares roots, then buckets, and reports the divergent keys without repairing anything. Read the report for a week. The size and shape of your actual divergence, counted instead of feared, tells you whether to wire the repair step, shrink the buckets, or discover that the weekend problem was never the problem you had.

## Let the Fingerprint Do the Travelling

A replica holds records. Its tree holds a claim about those records, short enough to send anywhere and precise enough to compare. Ship the claim first, descend only where the claims part, and let real data cross the network only at the exact point where two copies stopped agreeing. Your replicas will still drift. Drift is what partitions do. The change is that drift stops being a rumor you price at a full scan and becomes a list you can read over coffee.

When did your system last prove, bucket by bucket, that two of its replicas hold the same data, and what did that proof cost you to run?

## Resources

1. [DeCandia et al.: Dynamo, Amazon's Highly Available Key-value Store (SOSP 2007)](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf)
2. [Apache Cassandra documentation: nodetool repair and anti-entropy](https://cassandra.apache.org/doc/latest/cassandra/operating/repair.html)
3. [Merkle: A Digital Signature Based on a Conventional Encryption Function (CRYPTO 1987)](https://people.eecs.berkeley.edu/~dawnsong/teaching/f12-cs161/readings/merkle.pdf)
4. [Keeping Both Versions Is Not a Merge](https://anushamukka.com/posts/keeping-both-versions-is-not-a-merge/)
5. [Your Timestamps Cannot Order Your Writes](https://anushamukka.com/posts/your-timestamps-cannot-order-your-writes/)
