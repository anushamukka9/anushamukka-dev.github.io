---
layout: post
title: "Adding One Node Should Not Move Ninety Percent of Your Keys"
date: 2026-10-09 06:35:00 -0400
categories: [Writing]
tags: [Distributed Systems, Consistent Hashing, Sharding, Scalability, Reliability]
description: "Adding one cache node out of ten should not send 90 percent of your keys to new owners. On hash modulo as a reshuffle button, and consistent hashing: the ring, virtual nodes, and bounded load that move only the keys next door."
---

# Adding One Node Should Not Move Ninety Percent of Your Keys

*You added one cache node to a fleet of ten and your origin database spent the afternoon on fire. The new node was healthy. The arithmetic was not.*

## The Deploy That Emptied the Cache

You added one cache node. One. The fleet went from ten nodes to eleven, the deploy was green inside five minutes, and then the cache hit rate fell off the table: 94 percent at 2:04 in the afternoon, 9 percent by 2:20. The origin database, which had been quietly answering the 6 percent of reads the cache let through, was suddenly answering 91 percent of them. Fifteen times its normal read load, arriving in the time it takes to get back from the coffee machine.

Yes, this is a composite story, but it is hardly an unusual one. If your placement function is `hash(key) mod N`, this is not bad luck. It is the function working exactly as written. Going from ten nodes to eleven changes the answer for 90.7 percent of your keys, and a cache where nine in ten keys just moved is a cache that is empty in every way that matters. The traffic did not spike because users arrived. It spiked because capacity arrived.

## Name the Two Bad Options

Teams that meet this problem usually reach for one of two bad defaults.

The first bad option is the modulo hash itself. I understand why everyone starts here, because it is genuinely lovely for a while: one line of code, no state, load spread almost perfectly evenly. The catch is buried in the signature. The owner of a key depends on how many nodes exist. Every scale-out, every replacement, every node that dies presses the reshuffle button on the whole dataset. Modulo is a perfect answer to a question that stops being true the first time the fleet changes.

The second bad option is the hand-maintained shard map: tenant ranges pinned to nodes in a config file, migrations rehearsed like little planned outages. I understand the appeal here too. A human can see exactly where everything lives, and a careful team can move one range at a time at 3 in the morning. But the map is operational debt that compounds. Growth arrives as a calendar event with a runbook, and the runbook gets longer every quarter. You have replaced an arithmetic problem with a staffing problem.

The gap every explainer skips is this: both options make ownership a function of fleet size. The question that matters is not "which node owns this key." It is "what does a key need to know about the fleet in order to find its node." If the honest answer is "the exact current count," you have scheduled the incident above for every capacity change you will ever make.

## Put the Fleet on a Ring

Here is the mechanism that removes the count from the answer. Take your hash space, the full range your hash function returns, and bend it into a circle. Hash each node onto the circle. Hash each key onto the circle too. The owner of a key is the first node you meet walking clockwise from the key's point. That is the whole design: a ring, some points on it, and one walking rule.

Now watch what a new node does. It claims the arc between its point and the next node counterclockwise, and only the keys in that one arc change owners. Ten nodes become eleven, the new node collects roughly one eleventh of the keys, and the other ten keep what they had. David Karger and his coauthors published this in 1997 as "Consistent hashing and random trees," written for web caches that could not afford the stampede in the opening story. A decade later, Amazon's Dynamo paper (SOSP, 2007) put the same ring under a production key-value store, and it has been load-bearing in caches and databases ever since.

```
                             key "user:41"
                                  |
                                  v
                    . - - - - - - - - - - .
                 /            |             \
               /        cache-3               \
             |              x                   |
             |                                    |
   cache-7 x                                      x cache-1
             |                                    |
             |        "user:41" walks             |
              \       clockwise to cache-1        /
                \            . . .             /
                  - - - - - - - - - - - -
        each x is one point for one node; a key moves
        only when a new point lands in its arc
```

Here is the ring and the modulo side by side, standard library only, on twenty thousand keys. Run it and watch the movement counts.

```python
import bisect
import hashlib


def point_for(text: str) -> int:
    # First 8 bytes of the MD5 digest, read as an unsigned integer.
    # A real hash on purpose: the ring needs avalanche, not order.
    return int.from_bytes(hashlib.md5(text.encode()).digest()[:8], "big")


class Ring:
    def __init__(self, nodes, vnodes=160):
        self.vnodes = vnodes
        self.points = []   # sorted positions on the ring
        self.owner = []    # physical node at each position
        for node in nodes:
            self.add(node)

    def add(self, node):
        for i in range(self.vnodes):
            p = point_for(f"{node}#{i}")
            at = bisect.bisect(self.points, p)
            self.points.insert(at, p)
            self.owner.insert(at, node)

    def remove(self, node):
        keep = [(p, o) for p, o in zip(self.points, self.owner) if o != node]
        self.points = [p for p, _ in keep]
        self.owner = [o for _, o in keep]

    def node_for(self, key):
        p = point_for(key)
        at = bisect.bisect(self.points, p) % len(self.points)
        return self.owner[at]


def modulo_owner(key, count):
    return point_for(key) % count


nodes = [f"cache-{i}" for i in range(10)]
keys = [f"user:{i}" for i in range(20000)]

before = Ring(nodes)
mod_before = {k: modulo_owner(k, 10) for k in keys}
ring_before = {k: before.node_for(k) for k in keys}

before.add("cache-10")
mod_after = {k: modulo_owner(k, 11) for k in keys}
ring_after = {k: before.node_for(k) for k in keys}

mod_moved = sum(mod_before[k] != mod_after[k] for k in keys)
ring_moved = sum(ring_before[k] != ring_after[k] for k in keys)

print(f"keys                : {len(keys)}")
print(f"modulo  10 -> 11    : {mod_moved} moved ({mod_moved / len(keys):.1%})")
print(f"ring    10 -> 11    : {ring_moved} moved ({ring_moved / len(keys):.1%})")

load = {n: 0 for n in nodes + ["cache-10"]}
for k in keys:
    load[ring_after[k]] += 1
print("load per node       :", dict(sorted(load.items())))
```

```
keys                : 20000
modulo  10 -> 11    : 18136 moved (90.7%)
ring    10 -> 11    : 2038 moved (10.2%)
load per node       : {'cache-0': 1971, 'cache-1': 1722, 'cache-10': 2038, 'cache-2': 1936, 'cache-3': 1705, 'cache-4': 1542, 'cache-5': 1982, 'cache-6': 1591, 'cache-7': 1841, 'cache-8': 2005, 'cache-9': 1667}
```

A few things are worth noting about this example. First, the hash earns its keep. I take eight bytes of an MD5 digest because the ring needs each key scattered around the circle with no memory of the key before it; feed the ring a hash with visible patterns and the points clump, and clumps are where your load goes to be uneven. Second, the lookup is a binary search over sorted points, so the ring charges you a logarithm, not a scan. Third, the 10.2 percent moved sits right next to the one eleventh (9.1 percent) the arithmetic promises. The difference is sampling noise in twenty thousand keys, and it shrinks as the key count grows.

## Virtual Nodes Are Not Decoration

Read the load line again. Eleven nodes, twenty thousand keys, and the counts run from 1,542 up to 2,038 against a fair share of about 1,818. That spread comes from 160 points per node doing their work. With a single point per node the spread is far worse: a node whose neighbors happen to land close together inherits almost nothing, while another inherits a quarter of the circle.

That is what the virtual nodes are for. Operators call them tokens if they come from Apache Cassandra, and each physical node scatters them around the circle, so the arcs it owns are many and small and the unevenness averages out. The tokens are not decoration. They are the difference between a design that is even in expectation and a fleet that is even on your dashboard. The count is a real knob with a real price: more tokens mean smoother load and more ring state to store, sort, and ship around every time membership changes. One hundred sixty per node is a decent default for a small fleet. It is not a law of nature.

Tokens also handle uneven hardware honestly. A node with twice the memory gets twice the tokens. Nobody renumbers anything; the bigger machine simply owns more of the circle, in proportion to what it can hold.

One refinement deserves its own paragraph, because it fixes a failure the base design ships with. When a node dies, its keys walk clockwise and land on the next node, which now holds its own share plus a dead peer's share. In 2016, Vahab Mirrokni, Mikkel Thorup, and Morteza Zadimoghaddam at Google published the bounded-loads version: no node holds more than (1 + epsilon) times the fleet average, and a key that arrives at a full node keeps walking to the next node with room. One capacity check in the placement walk, and a single failure stops being a second, smaller outage aimed at one survivor.

Replication rides the same walk. Three owners instead of one is the same clockwise stroll with a notebook:

```python
    def nodes_for(self, key, count):
        # Walk clockwise from the key, collecting distinct physical
        # nodes. This is the replica placement walk. A bounded-load
        # system runs the same walk with one extra check: skip a
        # node already holding (1 + epsilon) times the fleet average,
        # and let the next node clockwise absorb the key instead.
        found = []
        p = point_for(key)
        at = bisect.bisect(self.points, p)
        while len(found) < count:
            node = self.owner[at % len(self.points)]
            if node not in found:
                found.append(node)
            at += 1
        return found
```

The detail that matters in that snippet is the word "physical." With 160 tokens per node, the next several points clockwise may all belong to the node you started on. Collect distinct machines, or your three replicas are one disk failure wearing three name tags.

> Ownership should depend on where the key lands, not on how many nodes happen to exist that week.

## Where This Breaks

An honest accounting, because the ring is a placement rule and placement rules have edges.

- **A hot key is still one key.** The ring maps a key to a point, and a point to one owner. If one tenant or one configuration row takes half your traffic, hashing cannot split it. Split hot keys deliberately, cache them in another tier, or provision for the hot node on purpose.
- **The ring is a view, and views disagree.** Every client must walk the same ring, or the same key routes to two nodes and your reads start disagreeing with your writes. Membership changes have to reach everyone in the same order, which is a coordination problem wearing a placement costume. My piece on leader election and fencing tokens covers the sibling failure: the vote is rarely the enforcement.
- **Your hash function is part of the design.** Sequential keys through a weak hash cluster in one arc, and one node melts while nine idle. Engineers conclude from this that consistent hashing "does not balance," when the ring was fine and the scatter was not. Use a hash with real avalanche behavior and audit the actual point distribution, not the intention.
- **Virtual nodes are state you have to move.** One hundred sixty tokens across ten nodes is 1,600 points. Across ten thousand nodes it is 1.6 million points to gossip, sort, and keep consistent, and every membership change touches the structure. The token count that smooths a small fleet can tax a very large one.
- **Bounded load makes placement depend on load.** Once full nodes get skipped, two clients holding different load snapshots can route the same key to different owners. That is survivable when reads check the replica set, and confusing when one client treats the first owner as the only address a key has. Say out loud which invariant you are spending.
- **Placement is not migration.** The ring tells you where a key belongs starting now. It does not copy bytes, warm caches, or backfill a shard, and a key that "moved" still means a miss and an origin read on first touch. The 10.2 percent in the demo is a triumph next to 90.7, and it is still two thousand cold keys your origin is about to meet.

None of this rescues the modulo. It bounds the ring. The claim that survives is narrow and worth having: adding capacity should cost the new node's fair share of movement, about one key in eleven, not a ninety percent reshuffle with an incident review attached.

## Build It If / Skip It If

**Build it if** you place keys for a living: shared caches in front of an origin that cannot take a cold-start stampede, a key-value tier you shard yourself, per-tenant counters or rate limits that must survive the fleet growing. Build it if capacity changes are routine, because routine is exactly when the reshuffle tax stops being an anecdote and becomes a line item.

**Skip it if** your fleet is small, fixed, and honestly never changes; modulo with a stable N is simple, and simple wins the arguments it deserves. Skip it if every node already holds every key, since replication has made placement somebody else's problem. Skip it if a consensus group already assigns ownership of your ranges; a second placement opinion under Raft buys you two sources of truth and the debugging sessions that come with them.

The minimal viable version is the class above, and it fits in an afternoon. Copy the ring, keep MD5 unless you have a faster hash you trust, set 160 tokens per node, and run your real key sample through both functions the way the demo does. The two numbers you get out, keys moved and spread across nodes, are the entire sales pitch and the entire warning label. Decide from those numbers, not from this article.

## Add Capacity Without the Fire Drill

Here is the practical takeaway. Capacity is supposed to relieve load, and a placement function that punishes you for adding it trains the whole team to fear the one operation that should be boring. Put ownership on the ring, treat the token count as the tuning decision it is, and let a scale-out move the one eleventh of keys it honestly owes you. Then go measure what your current placement does on the next node you add, while the answer is still a measurement and not an incident.

What is the worst reshuffle you have ever caused by adding capacity, and how long did your origin take to forgive you?

## Resources

1. [Consistent hashing and random trees](https://dl.acm.org/doi/10.1145/258533.258660): David Karger and coauthors, ACM STOC 1997. The original paper, written for distributed caching, and still the clearest statement of what the ring promises
2. [Dynamo: Amazon's Highly Available Key-value Store](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf): Giuseppe DeCandia and coauthors, SOSP 2007. The ring running a production store, replication walk included
3. [Consistent Hashing with Bounded Loads](https://arxiv.org/abs/1608.01350): Vahab Mirrokni, Mikkel Thorup, and Morteza Zadimoghaddam. The capacity cap that keeps one node's failure from becoming its neighbor's outage
4. [Stop Trying to Invalidate Your Cache. Budget the Staleness Instead.](https://anushamukka.com/posts/stop-trying-to-invalidate-your-cache/): my earlier piece on the consistency problem hiding behind cache deletion. The ring decides where a cached key lives; the staleness budget decides how wrong it may be
5. [Your Election Crowned Two Kings](https://anushamukka.com/posts/your-election-crowned-two-kings/): on zombie leaders and fencing tokens. The ring has the same shape: the walk is a hint, and membership decides whether two clients walk the same circle
