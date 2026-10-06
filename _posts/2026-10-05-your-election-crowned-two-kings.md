---
layout: post
title: "Your Election Crowned Two Kings"
date: 2026-10-05 07:00:00 -0500
categories: [Writing]
tags: [Distributed Systems, Leader Election, Consensus, Fencing Tokens, Reliability]
description: "Your leader election worked and crowned two leaders anyway. Elections answer who won the vote, not whose write applies. On zombie leaders, the split-brain window every system has, and fencing tokens: the storage-side integer that rejects a deposed leader's writes without it ever learning it was deposed."
---

# Your Election Crowned Two Kings

*Your leader election worked exactly as designed. It also crowned two leaders, and your database now has duplicate payouts with the same reference number. The election was never the enforcement. It was a hint.*

## The Page That Lies to You

It is 3:47 in the morning. Your phone says the payouts ledger just grew by entries with reference numbers that already exist, and the dashboard shows your scheduler fleet with a green crown next to node A. Nothing is on fire. No leader election failed. That is the part that bothers you: every health check passed, the election protocol did its job, and the money still moved twice.

You look closer. For ninety seconds last night, node B also believed it was the leader. Node A's lease was renewing fine, or so the control plane thought, but a garbage-collection pause froze node A's process for eleven seconds, longer than the lease timeout, and the election did the only sane thing it could do: it crowned node B. Then node A woke up, having no idea it had been deposed, and kept issuing payouts alongside the new king. Two crowns, one ledger.

Yes, this is a hypothetical scenario, but it is hardly an unusual one. The pause could have been a GC stop-the-world, a network partition, or a clock jump. The outcome is always the same shape: the old leader does not know it is old.

## Name the Two Bad Options

When teams live through this once, they usually reach for one of two bad defaults.

The first bad option is to tighten the election. Shorter lease timeouts, faster failure detection, more aggressive preemption. I understand the appeal: the election is the part you can tune, so it is the part you tune. But the timeout is doing double duty. Too long and your failover is slow; too short and a routine GC pause or a slow disk starts deposing healthy leaders, and now you have elections flapping every week instead of split brain once a year. You traded a rare catastrophe for a chronic one, and the tuning knob cannot fix the underlying asymmetry: no timeout can tell a paused leader from a dead one.

The second bad option is to shrug. Split brain is rare, the duplicate payouts get caught by reconciliation, the accountants reverse them, life goes on. This works right up until the day reconciliation is the thing that is down, or the writes are not payouts but deletes, or the system you built after the shrug starts depending on single-leader semantics in ways nobody wrote down. You did not fix the problem. You scheduled it.

The gap every explainer skips is this: both options treat the election as the mechanism that decides whose writes count. It is not. The election decides who *thinks* they are the leader. Deciding whose writes count is a separate job, and it belongs at the storage layer, in the form of fencing tokens.

## What the Election Actually Guarantees

Let me give you the mechanism precisely, because the precision is the whole point. A correct leader election protocol like Raft guarantees at most one leader *per term*. The term is a monotonically increasing number. When node B wins the new election, it campaigns with a higher term than node A's, and a majority of voters agree. Node A, asleep through the vote, still believes it holds the old term. Raft's safety property is intact. Your ledger is not, because the storage server has never heard of terms.

Here is the honest accounting of the tools people reach for. Kubernetes runs its control-plane leader election on Lease objects: you can watch it live with `kubectl get lease -n kube-system kube-controller-manager -o yaml` and see the `holderIdentity` and `renewTime` fields. etcd ships an election API you can drive from the shell: `etcdctl elect locksvc candidate-A` blocks until that candidate holds the election, and `etcdctl observe locksvc` streams the current holder. These are good mechanisms. They answer "who is the leader?" with real engineering behind them. They do not answer "whose write applies?" The moment you confuse the two, you have built the system that pages you at 3:47.

The old leader is not a bug in the protocol. It is a zombie, and zombie leaders are not a rare edge case. They are the normal case: every deposed leader keeps running until something stops it, and between deposition and discovery there is always a window.

## Make the Storage the Judge

Here is the thesis of this piece. Move the decision from the leader to the resource. Every time a new leader is elected, it obtains a fencing token, a monotonically increasing number, from a linearizable source. Every write the leader sends to storage carries the token. The storage server records the highest token it has seen and rejects any write whose token is older. The zombie leader can wake up, believe it is still the king, and send all the writes it wants. The storage will look at the stale token and refuse them.

The zombie does not need to be told. That is the point. The system is safe even when the old leader never learns it was deposed.

The shape of it in code is small on purpose. A boundary you cannot read is a boundary you cannot trust.

```python
class FencingStorage:
    """A storage server that only accepts writes from the current
    generation of leader. Stale leaders get a clean rejection,
    not silent corruption."""

    def __init__(self):
        self._fence = -1          # highest fencing token ever seen
        self._log = []            # the ledger

    def write(self, token: int, entry: str) -> dict:
        if token < self._fence:
            return {"ok": False,
                    "reason": f"stale fencing token {token}; "
                              f"current generation is {self._fence}"}
        if token > self._fence:
            self._fence = token   # a new leader generation begins
        self._log.append((token, entry))
        return {"ok": True}

    def read_ledger(self):
        return list(self._log)


# The night of the page, replayed:
db = FencingStorage()

# Node A is the original leader, elected with fencing token 41.
db.write(41, "payout ref-8812 $400.00")        # ok

# A GC pause deposes A; node B wins the next election, token 42.
db.write(42, "payout ref-8813 $120.00")        # ok: new generation

# Node A wakes up, still believes it is the leader, and retries
# the same payout alongside the new king.
print(db.write(41, "payout ref-8812 $400.00"))  # rejected: stale token
```

A few things are worth noting about this example. First, the rejection happens at the resource, which is the one place in the system that cannot be confused by a partition: it sees writes in whatever order they arrive and has exactly one rule. Second, the fencing token doubles as the generation marker, so the storage needs no election state, no lease timer, no gossip; it needs one integer. Third, the zombie's write fails loudly and visibly, which means your monitoring can count rejections and tell you exactly how often you were nearly bitten.

The timeline, as an ASCII diagram of the incident:

```
  node A (token 41)        storage           node B (token 42)
       |                      |                      |
       |--- write(41, payout)  |                      |
       |           accepted    |                      |
       |                      |                      |
       |  [GC pause: 11s]     |                      |
       |                      |                      |
       |                      |<--- elected, gets 42--|
       |                      |                      |
       |                      |--- write(42, payout)  |
       |                      |         accepted      |
       |                      |                      |
       |  [wakes up]          |                      |
       |--- write(41, payout)  |                      |
       |           REJECTED    |                      |
       |   "stale token 41;   |                      |
       |    current is 42"    |                      |
```

Where do the tokens come from? They must come from a single linearizable source, or the ordering guarantee is fiction. The common answers: a consensus store like etcd or ZooKeeper handing out monotonically increasing sequence numbers; a single-row sequence table in Postgres updated in one transaction; `redis-cli INCR fencing:counter` if Redis is your linearizable core. Notice what this means: fencing does not remove the need for consensus. It moves it. The election picks *who gets the token*, and a small, well-understood consensus store issues the token. That is a far smaller consensus surface than asking every resource to understand elections.

And yes, this is the same idea that shows up in distributed locking done right. Martin Kleppmann's fencing-token treatment of Redis locks is the canonical version: the lock is a hint, the token at the resource is the enforcement. The names change; the asymmetry does not.

## Where This Breaks

An honest accounting, because fencing is not magic either.

- **You moved the consensus problem, not solved it.** The token issuer must be linearizable, which means you still need one piece of infrastructure whose correctness you trust completely. If your etcd cluster is down, nobody gets a token and nobody writes. That is availability you are spending on correctness. Budget it deliberately.
- **Fencing protects writes, not reads.** The zombie leader can still serve stale reads until it is told to stop. If your old leader answers queries from a cache, readers see the old world. Fencing is a write gate; read-your-writes and read freshness are separate problems.
- **Clock-based tokens die on clock skew.** If you mint tokens from timestamps instead of a monotonic counter, a clock jump hands a zombie a *higher* token than the real leader. I wrote a whole piece on what servers disagreeing about time does to you, and this is one of the places it bites. Use counters, not clocks.
- **Per-resource, not per-transaction.** A fencing token gates one resource. A transaction spanning five resources needs five gates, or a coordinator, which is a different article about why two-phase commit is a promise no one can keep. Do not assume one token fences a workflow.
- **The rejections need an audience.** A rejected write is the system telling you the election flapped. If nobody graphs the rejections, you have converted a corruption into a silent dropped write, and silent drops have their own incident report. Count them, alert on bursts.

None of these break the core claim. They bound it. Fencing turns "two leaders" from a data-corruption event into a rejected-write event, and rejected writes are a monitoring problem, which is a strictly better problem.

## Build It If / Skip It If

**Build it if** you have exactly one writer by design: a scheduler, a ledger, a coordinator, a failover manager. Build it if the cost of a double write is money, deletes, or externally visible state changes. Build it if your leader election already exists and you want the guarantee to survive the day the election gets it wrong, because one day it will.

**Skip it if** your writers are already idempotent and your downstream tolerates duplicates by construction. A queue consumer with idempotency keys does not need fencing; the dedup is the enforcement. Skip it if you have no single-writer invariant at all and never will: fencing a system that does not need a leader is a lock you added to a door nobody uses.

The minimal viable version fits in an afternoon. Take the one resource whose double-write keeps you up at night. Add one integer column or field: `fence_token`, initialized to zero. Issue tokens from a single monotonic source your writers already reach. Change the write path to compare and reject, and change the leader's startup to fetch a fresh token before its first write. Run your failover test and watch the zombie's writes bounce. That afternoon buys you the guarantee that the next 3:47 page is about a slow failover, not a duplicated ledger.

## Elect Loudly, Fence Quietly

Here is the practical takeaway. Keep your leader election; it is doing a real job. But stop asking it a question it cannot answer. The election tells you who won the vote. Only the resource, holding a fencing token, can tell you whose write applies. Build the write path so that a deposed leader needs no notification to be harmless, and the zombie becomes a monitoring metric instead of an incident.

This week, pick your single-writer resource and answer one question: if a second leader appeared right now, which write would you regret? Then add the integer.

What is the strangest split-brain incident you have debugged, and did the fix land on the election or on the resource?

## Resources

1. [How to do distributed locking](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html): Martin Kleppmann's canonical treatment; the fencing-token section is the short version of this entire article
2. [In Search of an Understandable Consensus Algorithm (Raft)](https://raft.github.io/raft.pdf): Diego Ongaro and John Ousterhout, 2014; the at-most-one-leader-per-term guarantee and why the old leader never learns
3. [etcd leader election](https://etcd.io/docs/v3.5/dev-guide/election/): the election API (`elect`, `observe`) and the concurrency primitives behind `etcdctl elect`
4. [Consensus Is the Most Expensive Word in Your Architecture](https://dev.to/anusha_mukka/consensus-is-the-most-expensive-word-in-your-architecture-2npd): my earlier piece on the quorum tax, what consensus actually buys, and when to pay it
5. [Your Servers Disagree About What Time It Is](https://anushamukka.com/posts/your-servers-disagree-about-what-time-it-is/): why clock-based tokens are a trap, and the afternoon-sized drift monitoring that catches it

---
Suggested Medium topics: Distributed Systems, Programming, Software Engineering, Reliability, Databases
SEO description: Your leader election worked and crowned two leaders anyway. Elections answer who won the vote, not whose write applies. On zombie leaders, the split-brain window every system has, and fencing tokens: the storage-side integer that rejects a deposed leader's writes without it ever learning it was deposed.
