---
layout: post
title: "Two-Phase Commit Is a Promise No One Can Keep"
date: 2026-10-01 07:00:00 -0500
categories: [Writing]
tags: [Distributed Systems, Transactions, Microservices, Reliability]
description: "Two-phase commit blocks when the coordinator fails, and the participants hold their locks forever. Sagas replace the atomicity promise with compensating actions, one reversible step at a time."
---

# Two-Phase Commit Is a Promise No One Can Keep

*The coordinator dies and the participants wait forever. Here is the blocking flaw every explainer mentions and none of them replace, and the saga pattern that does.*

## The Night the Coordinator Died

At 2:14 in the morning, the transaction coordinator got OOM-killed in the middle of a commit.

It had already collected every YES vote. The inventory service had reserved the stock, the payments service had authorized the charge, the warehouse service had staged the shipment. Each had forced its prepare record to disk, replied YES, and surrendered its right to decide. Then the coordinator, the one process allowed to say COMMIT, died before saying anything.

The on-call engineer found three services holding 3,200 row locks between them, every one of them in the prepared state, every one of them legally forbidden from moving. The runbook said to check the coordinator's decision log. The coordinator was a container that no longer existed. She restarted it, it recovered its log from disk, and the locks released forty-seven minutes after the page.

Yes, this is a composite of incidents I have watched up close. It is hardly unusual. And the postmortem missed the point. The recovery worked because the log survived. Had the disk gone with the container, those locks would have been permanent until a human made a decision no protocol can make. That is not an edge case. That is the design.

## Name the Two Bad Options

When teams discover their cross-service transaction has a single point of failure wearing a trench coat, they pick one of two bad default reactions.

The first bad option is to keep running two-phase commit across services anyway, because the transaction manager library makes it a three-line change. I understand the appeal: the happy path is genuinely clean, one coordinator, one decision, all or nothing. The failure path is a 2:14 AM page and a runbook that starts with "check the coordinator's log" and has no second step for when the log is gone.

The second bad option is to drop coordination entirely. Let each service commit locally, in whatever order the code happens to run, and trust the happy path. The charge succeeds, the inventory reservation fails, and a customer is charged for a room that does not exist. The failure mode is never "the system was inconsistent." It is a refund ticket and a support thread titled "I paid for nothing."

The real question is not "how do we make the coordinator immortal." It is "what do we do instead of a protocol that requires immortality."

## The Promise, Stated Precisely

Let me give you the mechanism, because the mechanism is the part every explainer skips on the way to the punchline.

Jim Gray described two-phase commit in 1978, in "Notes on Data Base Operating Systems." The protocol has exactly one moving part that matters: the surrender. The coordinator sends PREPARE to every participant. Each participant does its local work, forces a prepare record to stable storage, and replies YES or NO. The coordinator collects the votes, forces its decision to its own log, and broadcasts COMMIT or ABORT. After that forced write to disk, the participant has surrendered its right to decide. The disk write is the surrender made durable, and it is the entire protocol.

Here is the moment the promise breaks. Watch the timeline:

```
Coordinator                Participant A              Participant B
    |                          |                           |
    |--- PREPARE ------------->|                           |
    |--- PREPARE ------------------------------------------>|
    |                          |                           |
    |<-- YES ------------------|                           |
    |<-- YES ----------------------------------------------|
    |  decision: COMMIT        |                           |
    |  force to log            |                           |
    |  ... crash ...           |                           |
    |      X                   |                           |
    |                          | (prepared, holding locks, |
    |                          |  forbidden to decide)     |
```

Both participants voted YES and are now in the prepared state. The coordinator is gone. Participant A cannot commit on its own: the decision might have been ABORT, or Participant B might have voted NO and rolled back. It cannot abort either: the decision might have been COMMIT, or B might have already committed. Any unilateral move risks divergence, so the protocol forbids all of them. A waits, holding its locks, until the coordinator returns or a human intervenes.

Two things are worth noting. First, the prepared state is the price of the promise, not a bug in your code: atomicity across failures requires a state where only somebody else can release you. Second, three-phase commit does not save you. It removes blocking under crashes, but a partition recreates the window, and no deterministic protocol closes it in an asynchronous network with one faulty process.

> The prepared state is not a bug in your code. It is the price of the promise.

Postgres says it plainly in the PREPARE TRANSACTION docs: "It is unwise to leave transactions in the prepared state for a long time... the transaction continues to hold whatever locks it held." The protocol assumes your transaction manager never stays dead. Yours is a single container.

## Even the Best Coordinator Dies. So Replicate It.

Let me steelman the protocol before replacing it, because there is one honest way to run it. Spanner (Corbett and colleagues, OSDI 2012) runs two-phase commit across Paxos groups, with the coordinator's state itself "stored in the underlying Paxos group (and therefore is replicated)." No single coordinator process to kill; the decision log survives any minority of failures by construction.

That is the honest price of the promise: full consensus underneath your commit protocol. If you are not prepared to pay it, you are running 2PC without its safety net and calling the 2:14 AM page an edge case.

## Think of Your Checkout Flow

Here is the pivot to your world. Your checkout touches four services and four databases: charge the card at payments, reserve the stock at inventory, book the shipment at logistics, send the confirmation at notifications. The textbook draws a coordinator box and labels the arrows 2PC. The runbook at 2:14 AM says the coordinator box is a container and containers die.

Ask the question the textbook skips: which of these four steps actually needs to be atomic with the others, in the database sense? Must the charge and the reservation happen in the same indivisible instant, invisible to all readers until both complete? Or is it acceptable for the inventory to be reserved for ninety seconds while the charge is still processing, as long as a failure in either one reliably undoes the other?

If you can live with the second framing, and nearly every checkout system in production already does, you do not need atomicity. You need a reliable undo. That is a different, cheaper problem.

## Replace the Promise With a Saga

In 1987, Hector Garcia-Molina and Kenneth Salem published "Sagas" in the SIGMOD proceedings. Break the long transaction into a sequence of local transactions, and give each one a compensating transaction that undoes it semantically. The guarantee changes shape: either all steps complete, or the completed steps are compensated, in reverse order.

Here is the checkout as a saga:

```
checkout saga for order 8814
============================

step 1: reserve inventory (warehouse)
   on failure --> compensate: release the hold

step 2: charge card (payments)
   on failure --> compensate: refund the charge

step 3: book shipment (logistics)
   on failure --> compensate: cancel the booking

step 4: send confirmation (notifications)
   on failure --> compensate: send a correction
```

Each step is an ordinary local transaction against one database. No prepared state, no locks held across services, no coordinator whose death freezes everyone. The saga log is a single row in a database you already own: saga id, current step, status. If the orchestrator dies, a new one reads the row and resumes. The state is small, durable, and owned by no single process, which is precisely the property the 2PC coordinator lacked.

## Make Compensation Cheap Enough to Run

Here is the whole orchestrator. It fits in one file, uses one SQLite table as the journal, and has no dependencies:

```python
import sqlite3

DB = sqlite3.connect("saga.db")
DB.execute("""CREATE TABLE IF NOT EXISTS saga_runs
    (saga_id TEXT PRIMARY KEY, step_index INTEGER, status TEXT)""")
DB.commit()

class SagaFailed(Exception):
    pass

def run_saga(saga_id, steps):
    # steps: (name, action, compensation) tuples; actions must be idempotent
    row = DB.execute("SELECT step_index FROM saga_runs WHERE saga_id=?",
                     (saga_id,)).fetchone()
    start = row[0] if row else 0
    if row is None:
        DB.execute("INSERT INTO saga_runs VALUES (?, 0, 'running')", (saga_id,))
        DB.commit()
    completed = []
    for i in range(start, len(steps)):
        name, action, compensation = steps[i]
        try:
            action()
        except Exception as e:
            DB.execute("UPDATE saga_runs SET status='compensating' WHERE saga_id=?",
                       (saga_id,)); DB.commit()
            for cname, compensate in reversed(completed):
                try:
                    compensate()
                except Exception as ce:
                    # A failed compensation is not a retry loop. It is a page.
                    print(f"COMPENSATION FAILED for {cname}: {ce}. Needs a human.")
            DB.execute("UPDATE saga_runs SET status='compensated' WHERE saga_id=?",
                       (saga_id,)); DB.commit()
            raise SagaFailed(f"step '{name}' failed: {e}")
        completed.append((name, compensation))
        DB.execute("UPDATE saga_runs SET step_index=? WHERE saga_id=?",
                   (i + 1, saga_id)); DB.commit()
    DB.execute("UPDATE saga_runs SET status='done' WHERE saga_id=?", (saga_id,))
    DB.commit()
```

A few things are worth noting about this example. First, the journal is one row, and the step index is written after every step. Crash anywhere, restart anywhere, and the next run resumes from `step_index`. That is why every action must be idempotent: the charge request re-sent after a crash must not double-charge. Second, a failed compensation does not retry forever. It prints, it pages, it waits for a person. A compensation that cannot complete is a business problem, a refund API that is down while a charge stands, and no loop will fix a business problem. The saga's job is to make the failure visible and bounded, not to pretend it can always recover alone.

When you outgrow the file, the real tools are waiting. Postgres gives you the one place 2PC belongs, inside a single database:

```sql
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 8814;
PREPARE TRANSACTION 'order-8814';
-- later, from any session: COMMIT PREPARED 'order-8814';
-- find the forgotten ones: SELECT gid FROM pg_prepared_xacts;
```

Temporal runs saga orchestrations as versioned workflows with the journal built in:

```bash
temporal workflow start --type CheckoutSaga --task-queue checkout \
  --input '{"order_id": 8814}'
```

The engine is not the point. The point is the shape: steps, compensations, a journal, and a recovery path that does not require the original process to be alive.

## Where This Breaks

Unhedged limitations, because every mechanism above has a failure mode and you should know them before you adopt them.

- Compensation can fail, and then you own a half-undone saga. The refund API is down, the charge stands, and the journal says "compensating" until a human intervenes. Budget on-call time for this. It will happen, and the correct response is a page, not a retry loop.
- Some actions cannot be undone, only offset. The email already sent cannot be unsent; the compensation is a second email that says "please disregard the first." If your business cannot tolerate undo-by-apology, do not put that step in a saga. Put it last, after everything that can fail has succeeded, and accept the small window.
- Sagas give you semantic consistency, not ACID. Between step 2 and step 3, the inventory is reserved and the card is not charged, and any reader can see that state. The 1987 paper is explicit: other transactions may view partial results. If your readers cannot tolerate intermediate states, co-locate the data instead of distributing the transaction.
- Compensations must be idempotent and retryable, or the retried compensation becomes the second incident. The refund sent twice is a new bug with the old bug's name on it.
- Reverse order is a business decision, not just an implementation detail. Refunding the charge before releasing the inventory hold may violate your own accounting rules. Write the compensation order down and get the business to sign it.

## Build It If / Skip It If

Build a saga if your transaction spans services that do not share a database, each step has a natural compensating action (reserve and release, charge and refund, book and cancel), and your readers can tolerate seeing intermediate states. That covers most checkout, provisioning, and onboarding flows in production today.

Skip it if everything lives in one database. Use the database's transactions; that is what they are for, and Postgres holds locks correctly within one node without any coordinator. Skip it if you can redesign the boundary so no distributed transaction exists: an outbox plus idempotent consumers removes the need for most cross-service transactions. Skip it if your latency budget cannot absorb sequential steps; parallelizing them reintroduces the coordination you were escaping.

The minimal viable version fits in an afternoon. One table (`saga_runs`: id, step_index, status), the orchestrator above, and three steps with real compensations against staging. Run the happy path. Then `kill -9` the process between steps 2 and 3, restart it, and watch it resume from the journal and compensate. That one test exercises the exact path your 2:14 AM page will take.

## Find Your Blocking Transaction

Find the distributed transaction in your system that would hold locks if its coordinator died tonight. You know the one: the cross-service checkout, the provisioning flow, the migration that touches two databases. Read its recovery runbook and ask what happens if the coordinator's log is gone. If the answer is "a human decides," you are already running a saga with extra steps and none of the tooling. Replace the promise with compensation, test it by killing the process mid-run, and measure how quickly the 2:14 AM page becomes a non-event.

What is the most expensive action in your system that cannot be undone?

## Resources

1. [Two-phase commit protocol, Wikipedia](https://en.wikipedia.org/wiki/Two-phase_commit_protocol): the mechanism and the blocking failure mode, stated precisely, including the coordinator-plus-participant failure case that no new coordinator can resolve.
2. [Garcia-Molina, H. and Salem, K., "Sagas", ACM SIGMOD 1987 (PDF)](https://www.cs.cornell.edu/andru/cs711/2002fa/reading/sagas.pdf): the original paper. Compensating transactions, the airline reservation example, and the honest admission that partial executions remain visible to other transactions.
3. [Corbett et al., "Spanner: Google's Globally-Distributed Database", OSDI 2012 (PDF)](https://static.googleusercontent.com/media/research.google.com/en//archive/spanner-osdi2012.pdf): two-phase commit done the expensive honest way, with the coordinator's state replicated in Paxos groups so no single death blocks the transaction.
4. [PostgreSQL documentation: PREPARE TRANSACTION](https://www.postgresql.org/docs/current/sql-prepare-transaction.html): the caution worth reading twice. Prepared transactions hold their locks, and forgotten ones can shut the database down to prevent transaction ID wraparound.
