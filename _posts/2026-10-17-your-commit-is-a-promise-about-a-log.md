---
layout: post
title: Your Commit Is a Promise About a Log, Not About Your Tables
date: 2026-10-17 09:11:00 -0400
categories: [Writing]
tags: [Databases, Distributed Systems, Reliability, Software Engineering]
permalink: /posts/your-commit-is-a-promise-about-a-log/
description: "A commit does not mean your data pages reached disk. It means the write-ahead log did: log before data, log before acknowledgment. Runnable Python WAL with torn-tail recovery, checkpoints, and group commit."
---

# Your Commit Is a Promise About a Log, Not About Your Tables

*Postgres can lose every changed data page in a crash and still keep its promise to you. It cannot lose the log. The write-ahead log is the reason, and the two rules underneath it are worth stealing for your own services.*

## The Crash That Lost Nothing

A database server loses power in the middle of a busy minute. Hundreds of transactions had committed in the seconds before the lights went out. Almost none of their changes had been written to the data files yet, because writing data files is slow, scattered work the database deliberately postpones. By any reasonable reading, those commits should be gone.

They are not. The server comes back, spends a few seconds reading a log file from the point of the last checkpoint, and every committed transaction is present, with every uncommitted one removed. The data files were stale. The promise held anyway, because the promise was never about the data files. It was about a sequential log that got flushed to disk before the database told anyone their commit succeeded.

Tell me about the last time you read a durability guarantee carefully. Most of us treat COMMIT as a word that means "saved," full stop, and move on. Saved where, in what order, and against which failure are the questions that decide whether the guarantee survives contact with a dead power supply. This piece is about the mechanism that answers them, the same mechanism sitting underneath your replication and the outbox relay from the last piece in this series.

## Name the Two Bad Options

The first bad option is the honest, slow one: on every commit, write every changed page to its real place on disk and flush. One transaction can touch pages in a table, two indexes, and a visibility structure, all in different files at different offsets. Forcing all of that to permanent storage before acknowledging the commit turns every transaction into a burst of random writes, and your commit rate becomes your disk's seek rate.

The second bad option is the fast, lying one: keep changes in memory, acknowledge commits immediately, and write pages whenever it is convenient. This is wonderfully quick right up to the crash, after which you get to explain which confirmed payments the company has decided to un-remember. A cache that acknowledges writes it has not made durable is not a storage design. It is a loan taken against the next outage.

I understand why both survive. The first is what gets sketched when durability is the only requirement in the room. The second is what ships when latency is. The write-ahead log exists because a real system has both in the room at once, plus a third nobody mentions: recovery has to finish before the business notices.

> A commit does not mean your data reached its final resting place. It means a description of your data reached the log, and the log reached the disk.

## The Gap Every WAL Explainer Skips

Most explanations of write-ahead logging stop at the slogan: write the log first. The slogan is true and almost useless, because it skips the parts that make the design work in practice: what exactly has to be flushed before the caller hears "committed," how recovery knows where the trustworthy part of the log ends, and what a checkpoint is actually buying you. Those three details are the gap this piece fills, and each maps to a decision you will face in any append-only design of your own.

The full design was worked out in the ARIES recovery method, published by C. Mohan and colleagues at IBM in 1992, and nearly every serious database since has implemented a descendant of it. The ideas are old enough to collect a pension. The failure modes they prevent are from this morning.

## Two Rules Carry the Whole Design

Say them precisely, because everything else in this piece is a consequence.

Rule one: the log goes to disk before the data it describes. Before a changed page may be written to its place in a data file, the log records describing that change must already be flushed. Postgres enforces this per page: each page carries the log sequence number, the LSN, of the last change applied to it, and the page cannot leave memory until the WAL has been flushed at least that far. If the page lands and the machine dies, recovery can still reconstruct what the page should have said, because the description arrived first.

Rule two: the log goes to disk before the acknowledgment. When a transaction commits, its commit record must be flushed before the database tells the caller the commit succeeded. The changed pages do not have to move at all. They can sit dirty in memory for seconds or minutes, and the commit is still durable, because the log holds enough information to redo the change from the older page on disk.

Those two rules buy two freedoms with unfortunate names. Steal: a page from an uncommitted transaction may be written to disk early, because rule one guarantees the log can undo it. No-force: commit does not force pages out, because rule two guarantees the log can redo them. Together they are why a database can use memory aggressively without gambling, and both are purchased entirely by the discipline of the two rules.

Here is the shape of it:

```
  transaction            WAL (one sequential file)         data files
  -----------            -------------------------         ----------
  UPDATE orders  ---->   append record, LSN 881
  UPDATE stock   ---->   append record, LSN 882
  COMMIT         ---->   append commit record, LSN 883
                         FLUSH up to 883  <-- the promise happens here
                         caller hears "committed"
  (later, whenever)      checkpointer writes dirty pages,
                         each page stamped with its LSN,
                         never ahead of the flushed WAL
  on crash               replay from last checkpoint LSN,
                         redo committed, undo the rest
```

Notice the detail that makes it cheap enough to run: at commit time there is exactly one file to flush, and it is appended to, not sought around. The scattered page writes still happen, but later, batched, in the background, where no user is waiting on them. The log converts random work at commit time into sequential work at commit time plus housekeeping later. That conversion, not any cleverness about formats, is the performance argument.

## Build the Smallest Honest Version

Here is the pattern in runnable Python, standard library only. The full file is `wal_demo.py` next to this draft. A record is a length, a CRC32 checksum, and a JSON payload, appended to one file. Commit means the record is flushed and fsynced. The data file is a snapshot that only a checkpoint writes, so between checkpoints it is as stale as it wants to be.

```python
HEADER = struct.Struct(">II")  # payload length, crc32 of payload


def encode(payload: bytes) -> bytes:
    return HEADER.pack(len(payload), zlib.crc32(payload)) + payload


class WAL:
    def append(self, key, value, sync=True):
        self.lsn += 1
        payload = json.dumps(
            {"lsn": self.lsn, "key": key, "value": value}
        ).encode()
        self.f.write(encode(payload))
        self.f.flush()
        if sync:
            os.fsync(self.f.fileno())  # the commit is durable HERE
        return self.lsn
```

A few things are worth noting about this example. First, the fsync is inside the append, before the return, because that ordering is rule two and there is nothing else to the promise. Code that returns success and syncs later, in a background thread, on a timer, has quietly chosen the second bad option from the top of this piece. Second, the checksum is not decoration. It is how recovery will know where the truth ends, which is the part of the design people forget until their first torn write.

Recovery is a replay with a stopping rule:

```python
def recover(wal_path, snapshot):
    state = dict(snapshot)
    applied = 0
    torn = 0
    size = os.path.getsize(wal_path)
    with open(wal_path, "rb") as f:
        while True:
            start = f.tell()
            header = f.read(HEADER.size)
            if not header:
                break
            if len(header) < HEADER.size:
                torn = size - start
                break
            length, crc = HEADER.unpack(header)
            payload = f.read(length)
            if len(payload) < length or zlib.crc32(payload) != crc:
                torn = size - start
                break
            rec = json.loads(payload)
            state[rec["key"]] = rec["value"]
            applied += 1
    return state, applied, torn
```

The stopping rule deserves a sentence of its own. A crash mid-append leaves half a record at the end of the file, and there is no version of events where that half record is a maybe. Its checksum cannot verify, so recovery treats it as a commit that never happened and truncates the tail before new writes begin. The caller never got an acknowledgment, because the fsync never returned. The log and the caller's view of the world agree exactly, which is the entire point.

Running the demo prints this:

```
== Part 1: crash with a stale data file (no-force) ==
records replayed: 3, torn bytes dropped: 0
recovered state: {'order:42': 'shipped', 'order:43': 'packed'}
the tables were never written. the log was enough.

== Part 2: crash in the middle of an append (torn tail) ==
records replayed: 3, torn bytes dropped: 11
order:44 present after recovery: False
a half-written record is not a maybe. recovery treats it as never sent.

== Part 3: checkpoint bounds the replay ==
replay before checkpoint: 53 records
WAL records kept after checkpoint: 0
replay after checkpoint: 0 records, state intact: True
checkpoints do not add safety. they subtract recovery time.

== Part 4: group commit pays the flush once ==
200 commits, fsync each: 200 flushes
200 commits, one shared fsync: 1 flush
same durability promise for the batch, paid for once.
```

Read the four parts as one argument. Part 1 is no-force working as designed: the snapshot on disk is empty, the state comes back whole. Part 2 is the torn tail, eleven bytes of a fourth write, discarded without ceremony. Part 3 is the checkpoint: it adds no safety whatsoever, it only bounds how much log recovery has to replay, which is why checkpoint tuning is a recovery-time decision, not a durability decision. Part 4 is group commit: when two hundred transactions commit in the same instant, one flush can carry all of them, because the flush is a property of the log position, not of any single transaction. What one flush costs depends on your storage. That it can be shared does not.

## Watch the Real Thing Do It

Your production database is running this design right now, and it will show you the moving parts if you ask. In Postgres:

```sql
SELECT pg_current_wal_lsn();
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0');
SELECT wal_records, wal_bytes, wal_buffers_full FROM pg_stat_wal;
```

```bash
pg_waldump $PGDATA/pg_wal/000000010000000000000001 | head -20
```

`pg_waldump` prints the actual records, LSN by LSN. Read twenty lines once and the abstract design becomes a file you can hold. Two settings decide how your instance trades on the edges. `synchronous_commit` defaults to on, meaning rule two holds before the caller hears back. Set it off and the acknowledgment can return before the flush, with a documented loss window of up to three times `wal_writer_delay` (200 milliseconds by default): a deliberate decision to un-remember the last fraction of a second of commits in a crash. SQLite makes the same trade with different words: `PRAGMA journal_mode=WAL`, and `PRAGMA synchronous` for how hard it leans on the flush.

Replication is this design wearing a second hat. A Postgres standby is, mechanically, a machine replaying the primary's WAL, which is why the outbox relay in the previous piece could tail the transaction log with Debezium instead of polling a table: the log was already the ordered, durable record of everything that changed. Choose a system with a good log and you tend to get recovery, replication, and change capture from the same artifact. That is the design paying rent three times.

## Where This Breaks

Say the limits plainly, because a log is only as honest as the storage under it:

- The flush can lie. Storage that acknowledges a flush before data reaches persistent media breaks rule two silently, and you find out during the crash, which is the worst possible code review. The 2018 fsyncgate episode made this concrete: when an fsync itself fails, some kernels discard the dirty pages and report success on retry, so Postgres changed to treat a WAL fsync failure as fatal rather than retried. Test your storage's flush behavior before you trust it with the promise.
- The log replays corruption faithfully. A WAL protects against crashes, not against a bad `DELETE` that committed cleanly. Recovery will reproduce your mistake with perfect fidelity. Point-in-time recovery works only because you pair the log with a base backup taken before the mistake.
- A forgotten consumer fills the disk. Anything that reads the log at its own pace, a replication slot for a dead standby or a stalled capture job, pins the segments it has not consumed. Postgres will keep them, the disk will fill, and the database will stop for a reason that has nothing to do with writes. Alert on retained WAL, not just on disk percentage.
- Relaxed settings are relaxed. `synchronous_commit = off`, SQLite `synchronous = NORMAL`, every vendor's version of the same knob: each one trades a slice of acknowledged commits for speed. The trade can be right. It is never free, and it should never be discovered in a postmortem.
- The log is a serialization point. Every change in the system funnels through one append stream, which is what makes the ordering guarantee possible and what makes write-heavy workloads measure themselves in WAL bytes per second. Group commit and fast storage widen the funnel. They do not remove it.

## Decide What Deserves a Log of Its Own

Build it if:

- Your service acknowledges writes that users treat as permanent: money movement, entitlements, audit events, anything you would have to apologize for un-remembering. An append-only log with a flush before the acknowledgment is the cheapest honest version of that promise.
- Your recovery story is currently a backup and a hope. A log plus periodic snapshots turns it into arithmetic: snapshot age plus replay rate equals recovery time, and you can measure both.

Skip it if:

- Losing the last few seconds of writes is a product decision you have actually made, out loud, with the number written down. Then take the database's relaxed setting and skip building machinery to re-create a guarantee you declined.
- A single database transaction already covers the write and everything that must survive with it. You do not need a second log next to the one your database is already keeping for you.

The minimal viable version fits in an afternoon: one append-only file, length-prefixed records with a checksum, an fsync before you acknowledge, a replay function that stops at the first bad record, and a snapshot job that lets you truncate the log. That is the demo above, and it is honestly most of the idea. Measure two numbers before you call it done: acknowledged writes lost by a kill mid-append (the answer has to be zero), and replay time per million records, because that number is your recovery time wearing a name tag.

## Steal the Two Rules, Not Just the Format

Pick the one place in your system where a caller hears "done" today. Ask what has actually been flushed at that moment, and what a power cut in the next second would leave behind. If the honest answer involves the words "should be fine," you have found the spot where a small log and a flush before the acknowledgment would turn a hope into a promise. Databases have kept that promise for three decades with two rules and one sequential file. Your service can too.

When your database last restarted after a crash, how long did replay take, and had anyone measured that number before the day it mattered?

## Resources

1. [PostgreSQL documentation: Introduction to Write-Ahead Logging](https://www.postgresql.org/docs/current/wal-intro.html)
2. [PostgreSQL documentation: Reliability and the Write-Ahead Log](https://www.postgresql.org/docs/current/wal-reliability.html)
3. [SQLite documentation: Write-Ahead Logging](https://www.sqlite.org/wal.html)
4. [Mohan et al.: ARIES, a transaction recovery method using write-ahead logging (ACM, 1992)](https://dl.acm.org/doi/10.1145/128765.128770)
5. [Two-Phase Commit Is a Promise No One Can Keep](https://anushamukka.com/posts/two-phase-commit-is-a-promise-no-one-can-keep/)
