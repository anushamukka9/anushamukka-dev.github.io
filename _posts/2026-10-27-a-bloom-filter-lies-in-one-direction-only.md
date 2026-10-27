---
layout: post
title: "A Bloom Filter Lies in One Direction Only"
date: 2026-10-27 16:57:00 -0400
categories: [Writing]
tags: [Distributed Systems, Databases, Software Engineering]
description: "A Bloom filter answers membership with false positives but never false negatives. The sizing formula, the optimal hash count, measured error rates, overfill failure, deletion limits, and when ten bits per item beat a disk read."
---

# A Bloom Filter Lies in One Direction Only

*Ten thousand keys fit in ten kilobytes, and the structure answers membership questions in microseconds. Sometimes it says yes when the answer is no. It never says no when the answer is yes, and that asymmetry is the whole product.*

## The Disk Read You Pay for Keys That Are Not There

A read arrives for a key your database has never seen. Not a rare case, either: cache probes, deduplication checks, crawler frontiers, and join filters all ask about keys that mostly do not exist. Your storage engine does its honest work anyway. It walks the index, touches the data file, decides the key is absent, and returns nothing. On a spinning disk that cost was a seek. On an SSD under load it is queue time your real reads needed. Either way, you spent the most expensive operation in the system to learn a fact that a few bits could have told you: do not bother looking, it is not here.

Tell me about the guard your engine puts in front of that read. In most systems I have seen, there is none, and the reason is reasonable. A list of every key that exists is just the index again, priced at full size. A hash set of every key is smaller but still grows with the data, and at a billion keys it is its own storage problem. The choice looks like a full index or nothing.

I understand why teams pick nothing. The absent-key reads feel like overhead you cannot remove without duplicating the thing you were trying to avoid. What that estimate leaves out is that you do not need certainty in both directions. You need certainty in exactly one direction, the cheap one, and a small, priced error rate in the other.

> A Bloom filter does not tell you what you have. It tells you, with certainty, some of what you do not have.

## The Gap the One-Line Answer Skips

Every algorithms course gives the one-line version: a Bloom filter is a bit array plus some hash functions, it has false positives, use it for membership tests. The line is correct and nearly useless, because everything that decides whether the filter earns its memory sits underneath it. How many bits per item buys what error rate. Why there is a best number of hash functions and why both directions away from it lose, measurably. What happens when you keep inserting past the load you sized for. And the question the one-liner never raises: a plain Bloom filter cannot forget, so what does deletion do to the guarantee.

The gap this piece fills is that layer. The filter, published by Burton Bloom in 1970 in Communications of the ACM, is small enough to build in an afternoon and precise enough to price before you build it. The formula predicts the measured error to three decimal places, which is rarer in this field than it should be.

## Set k Bits, and Let a No Mean No

Start with the smallest version of the idea. Take a bit array of m bits, all zero. Take k hash functions. To insert an item, hash it k ways, and set the k bits those hashes point at. To test an item, hash it the same k ways and look at those k bits. If any one of them is zero, the item was never inserted. That answer is certain, because inserting it would have set every one of those bits. If all of them are one, the item might be present. Might, because other items, inserted honestly, may have set exactly those bits between them.

Here is the shape of it:

```
  insert "key-1042":  hashes point at bits  3, 41, 97   -> set them
  insert "key-2077":  hashes point at bits 41, 58, 130  -> set them

  test "key-1042":    bits 3, 41, 97 all set     -> MAYBE present (it is)
  test "key-9999":    bit 12 is zero             -> DEFINITELY absent
  test "key-5555":    bits all set by neighbours -> MAYBE present (it is not)

  bit array:  ...1.....1..........1......1.........1...
               ^3    ^12=0       ^41     ^58       ^97
```

A few things are worth noting about this design. First, the guarantee is asymmetric by construction, not by tuning. A zero bit is proof of absence because bits only move one way, from zero to one, and an inserted item leaves all k of its bits set forever. Second, a yes costs you exactly the work you were trying to avoid, a real lookup, and it is wrong at a rate you choose in advance when you size the array. Third, the filter stores nothing about the items themselves. No keys, no pointers, no values. Ten thousand items at eight bits each is ten kilobytes, and the array looks the same whether the keys are short strings or long URLs.

The sizing arithmetic is short enough to do on paper. For n items in m bits with k hash functions, the false positive rate is roughly (1 - e^(-kn/m))^k. It is minimized when k equals (m/n) times ln 2, about 0.69 hashes per bit-per-item, and at that optimum the rate is close to 0.6185 raised to the power of bits per item. Read that the practical way: each extra bit per item multiplies your error rate by about 0.62. Eight bits per item at the best k lands near 2 percent. Sixteen bits per item lands near 0.05 percent. You are not buying a structure, you are buying down an error rate, one bit at a time.

## Build the Smallest Honest Version

Here is the mechanism in runnable Python, standard library only. The full file is bloom_demo.py next to this draft. It derives k positions from one SHA-256 digest by double hashing, which is the standard shortcut: two real hashes simulate k independent ones well enough that the formula still predicts the outcome.

```python
def hashes(item, k, m):
    """k positions in a bit array of size m, via double hashing."""
    d = hashlib.sha256(item.encode()).digest()
    h1 = int.from_bytes(d[:8], "big")
    h2 = int.from_bytes(d[8:16], "big") | 1
    return [(h1 + i * h2) % m for i in range(k)]


class Bloom:
    def __init__(self, m, k):
        self.m = m
        self.k = k
        self.bits = bytearray((m + 7) // 8)

    def add(self, item):
        for p in hashes(item, self.k, self.m):
            self.bits[p // 8] |= 1 << (p % 8)

    def __contains__(self, item):
        return all(self.bits[p // 8] >> (p % 8) & 1
                   for p in hashes(item, self.k, self.m))
```

A few things are worth noting about this example. First, `__contains__` returns early in spirit: the `all()` stops at the first zero bit, which is the common case for absent keys and the reason the negative answer is not just certain but fast. Second, nothing in `add` records the item, so there is no path from the filter back to the data. Third, the demo counts errors instead of asserting them. A probabilistic structure deserves measured output, not a unit test that happens to pass on one seed.

Running the demo prints this:

```
== Part 1: the lie only goes one way ==
inserted: 10000, absent tested: 20000
false negatives: 0
false positive rate measured: 0.0211
false positive rate predicted (m=80000, n=10000, k=6): 0.0216

== Part 2: bits per item is the price, k is the tuning ==
bits/item  4 (m=40000, k=3): measured FPR 0.1474, predicted 0.1469
bits/item  8 (m=80000, k=6): measured FPR 0.0211, predicted 0.0216
bits/item 12 (m=120000, k=8): measured FPR 0.0034, predicted 0.0031
bits/item 16 (m=160000, k=11): measured FPR 0.0003, predicted 0.0005

== Part 3: too few hashes and too many hashes both lose ==
k= 1: measured FPR 0.1174, predicted 0.1175
k= 2: measured FPR 0.0488, predicted 0.0489
k= 6: measured FPR 0.0211, predicted 0.0216
k=12: measured FPR 0.0507, predicted 0.0483
k=20: measured FPR 0.1845, predicted 0.1803
```

Read the three parts as one argument about where the error comes from. Part 1 is the guarantee, counted: twenty thousand absent keys, zero items the filter claimed were missing after they were inserted, and a lie rate of 2.11 percent against a prediction of 2.16. Part 2 is the price list. Doubling from eight bits per item to sixteen does not halve the error, it divides it by roughly forty, because each bit multiplies. Part 3 is the tuning mistake people actually make. One hash function wastes the array, because a single collision decides the answer. Twenty hash functions fill the array so fast that almost every test finds all its bits set by somebody. The optimum at k equals 6 is not a guideline. It is a minimum you can watch from both sides.

Part 4 of the demo is the operational one. The same filter, built for ten thousand items, then loaded with thirty thousand:

```
== Part 4: overfill the filter and the lie rate climbs ==
at design load (10000 items): measured FPR 0.0211
at 3x design load (30000 items): measured FPR 0.5020, predicted 0.5126
```

At three times its design load, the filter says maybe to half of everything, which is a coin flip with extra steps. Nothing crashed. Nothing logged a warning. The structure degraded silently from a 2 percent tax to a 50 percent tax, and the only symptom is a storage engine that gradually stops skipping the reads it used to skip.

Real systems run exactly this shape, sized exactly this way. Apache Cassandra builds a Bloom filter per SSTable and checks it before touching disk, and exposes the target directly as a table option:

```
CREATE TABLE lookups (
  id text PRIMARY KEY,
  payload text
) WITH bloom_filter_fp_chance = 0.01;
```

RocksDB and LevelDB attach a filter policy to each data block for the same reason: a point lookup for a missing key should end in memory, not on disk. Fan and co-authors put the same arithmetic to work in the Summary Cache paper in 2000, tracking which web cache held which document so proxies could ask each other a cheap maybe instead of an expensive fetch. The pattern survives because the question it answers is everywhere: before you pay for the lookup, ask the bits.

## Where This Breaks

Say the limits plainly, because a one-directional guarantee is easy to over-read:

- You cannot delete from a plain Bloom filter. Clearing an item's k bits may clear bits another item needs, and the moment it does, that other item tests absent and the zero false negatives guarantee is gone. Counting Bloom filters fix this with a small counter per position instead of one bit, at roughly four times the memory. Cuckoo filters, described by Fan and co-authors in 2014, support deletion in the base design.
- The no is certain only inside the assumptions. Same hash functions, same array, no deletions, and the item actually inserted. Rebuild the filter from a snapshot that missed the last hour of writes and its no means "not in the snapshot," stated with total confidence.
- Overfilling is silent, as Part 4 shows. The filter has no load gauge of its own. If you do not count insertions and rebuild or grow on schedule, your error rate drifts from the number on the design doc to a number nobody chose.
- The filter leaks a little by design. Anyone who can query it can test whether a specific item was inserted, and anyone holding the array and the hash functions can test offline, at full speed, forever. For usernames or document IDs that is a membership oracle you built yourself. Keyed hashes narrow it to people who hold the key. They do not remove it.
- Adversaries can aim at the error rate. An attacker who learns the hash functions can craft items that collide with a victim's bits and inflate false positives, or flood inserts until the filter saturates. Public-facing filters need keyed hashing and an insert path that is not open to the people being filtered.
- A maybe still costs the full lookup. At a 2 percent error rate on a workload that is 98 percent present keys, the filter saves almost nothing and adds a hash step to every read. The structure pays only when absent keys are a real share of traffic.

## Decide Whether Your Absent Keys Are Worth Bits

Build it if:

- Your workload asks about keys that usually do not exist: deduplication, cache admission, join pre-filtering, one-hit-wonder detection, or storage reads you want to skip.
- You can name n in advance, at least within a factor of two, and you have a rebuild or growth path for when the data outgrows it.
- A wrong yes costs a lookup and nothing more. The filter guards work, never correctness, and never an authorization decision.

Skip it if:

- You need to enumerate what you inserted, delete freely on the base structure, or count occurrences. The bits hold none of that, and each missing feature is a different structure wearing a similar name.
- Almost every key you test is present. Measure the absent share first. Below a few percent, the filter is ceremony.
- Membership itself is the secret. If learning that an item is in the set is the breach, a queryable membership oracle is the wrong tool at any error rate.

The minimal viable version fits in an afternoon: size for your real n at ten bits per item, set k from the formula rather than by feel, count insertions next to the filter and alarm at 80 percent of design load, and log the measured false positive rate by sampling absent keys you verify another way. Run it in shadow mode first, answering but not skipping, and compare the measured rate against the prediction. When the two agree for a week, let the no start saving you reads.

## Let the No Do the Work

Most structures in a system earn their keep on the yes path, the hit, the found record, the matched row. This one earns its keep on the no. A zero bit is a certain, cheap, final answer that lets an expensive question go unasked, millions of times a day, and the price of that certainty is a small array and a lie that only ever goes the harmless way. Size it honestly, count what you put in it, and it will tell you the truth in the only direction you needed.

What is the most expensive lookup in your system that a ten-kilobyte array could have talked you out of?

## Resources

1. [Bloom: Space/Time Trade-offs in Hash Coding with Allowable Errors (Communications of the ACM, 1970)](https://dl.acm.org/doi/10.1145/362686.362692)
2. [Fan et al.: Summary Cache, A Scalable Wide-Area Web Cache Sharing Protocol (IEEE/ACM Transactions on Networking, 2000)](https://www.cs.princeton.edu/courses/archive/spring06/cos461/papers/summarycache.pdf)
3. [Fan et al.: Cuckoo Filter, Practically Better Than Bloom (CoNEXT, 2014)](https://www.cs.cmu.edu/~dga/papers/cuckoo-conext2014.pdf)
4. [Apache Cassandra documentation: bloom_filter_fp_chance and SSTable filters](https://cassandra.apache.org/doc/latest/cassandra/managing/configuration/cassandra_yaml_file.html)
5. [Your Servers Disagree About What Time It Is](https://anushamukka.com/posts/your-servers-disagree-about-what-time-it-is/)
