---
layout: post
title: You Cannot Update a Database and a Queue in One Breath
date: 2026-10-15 07:37:00 -0400
categories: [Writing]
tags: [Distributed Systems, Microservices, Event-Driven Architecture, Reliability]
description: The dual write is two promises pretending to be one. The transactional outbox writes the event in the same transaction as the state, lets a relay publish at least once, and pairs with a consumer inbox so duplicates cannot apply twice.
---

# You Cannot Update a Database and a Queue in One Breath

*Your order row committed. Your event never left the building. Writing to a database and a message broker is two separate promises pretending to be one, and the transactional outbox is how you turn it back into one promise plus a relay you can watch.*

## The Order Exists and the Event Does Not

Tell me about the last incident review where two systems disagreed about a fact and both were telling the truth about what they had seen. Here is the usual shape. A customer places an order. Your service inserts the order row, commits, and reaches for the message broker to publish OrderCreated so inventory, billing, and shipping can react. In the half second between the commit and the publish, the process dies: a deploy, an out-of-memory kill, a node drain. The order is real. The event does not exist. Inventory never reserves, billing never charges, shipping never hears about it, and every downstream system is working correctly with the information it received, which was nothing.

Yes, this is a theoretical scenario, but it is hardly an unusual one, and the cost is not theoretical. The customer has a confirmation page and an order number. Support can see the order in the database, because the database is where support looks. Nobody can see the missing event, because there is no screen in your admin console for something that was never sent. You find out days later, from the customer, asking where their package is.

## Name the Two Bad Options

The first bad option is the one above: write the database first, publish second. Every crash, timeout, or broker outage in the gap loses the event silently. You can narrow the gap. You cannot close it, because the commit and the publish are acknowledged by two different systems that know nothing about each other.

The second bad option flips the order: publish first, write the database second. Now the crash in the gap produces the opposite lie. The event is out in the world, consumers have reacted, and then the database transaction rolls back. Billing has charged for an order your system of record says never happened. A phantom event is worse than a lost one: a lost event at least leaves your own data consistent, while a phantom teaches every downstream system a fact you then have to un-teach, one compensating action at a time.

I understand why teams ship both versions. The code reads as a single flow, the happy path works in every test, and the failure needs a crash at one specific instant: rare enough to survive code review, common enough at scale to ruin a weekend a year. Retrying the publish does not fix it. A retry loop still dies with the process, and it adds duplicates on the days the broker was merely slow. No component failed at its job here. The failure lives in the gap between the two writes, in code that looked like one operation and was actually two.

> A database commit and a broker publish cannot be made atomic by standing closer together. They become atomic only when one of them stops being a separate write.

## The Gap Every Event Guide Skips

Most explanations of event-driven architecture start at the broker: topics, partitions, consumer groups. They skip the first and most fragile hop, which is getting the event out of the service that produced it. That hop is the gap this piece fills. The question is precise: how do you guarantee that if a state change committed, an event describing it will eventually be published, and if it did not commit, no event ever appears?

The transactional outbox answers it with a move that feels almost like cheating. Stop publishing the event from your request handler at all. In the same database transaction that writes the business row, write one more row: the event itself, in a table in the same database, usually called the outbox. One transaction, one system, one commit. Either both rows exist or neither does, and your database already knows how to promise that. A separate process, the relay, reads committed outbox rows, publishes them to the broker, and marks them sent. Publishing is now a consequence of committed data, not a second act of faith performed by a process that might die mid-sentence.

Notice what the pattern does not claim. It does not deliver your event exactly once. It delivers at least once, and it is honest about why, as the relay crash below shows. The promise it does keep is the one you actually need: no committed change goes unpublished, and no uncommitted change gets announced.

## One Transaction, Then a Relay

Here is the whole pipeline, in the order the data moves:

```
  request handler                relay (separate process)
  ----------------                ------------------------
  BEGIN                           poll outbox where published = 0
    INSERT INTO orders    ---->     publish payload to broker
    INSERT INTO outbox              UPDATE outbox SET published = 1
  COMMIT                          (or: tail the transaction log
                                   with Debezium and skip the poll)
                                        |
                                        v
                                  broker -> consumers
                                  (each event carries a stable
                                   event_id; consumers dedupe)
```

Two details in that diagram do the real work. First, the handler's job ends at the commit: if it dies a microsecond later, nothing is lost, because the event is durable in a table, waiting for a relay that does not care which process wrote the row. Second, the event carries a stable event_id, assigned at write time and never changed by retries. That identity is what lets a consumer survive the relay's own failure mode, which is duplication.

Build the relay one of two ways. Polling is the simple version: a small loop that selects unpublished rows, publishes them, and marks them sent, queryable with plain SQL. Change data capture is the heavier version: Debezium tails the transaction log and streams each committed row to Kafka, its Outbox Event Router turning the aggregate type into the topic and the aggregate id into the message key. Polling costs you a poll interval of latency. Capture costs you Kafka Connect and a replication slot to monitor. Pick based on the volume and latency you actually have.

The Postgres schema is small enough to keep in your head:

```sql
CREATE TABLE outbox (
    event_id      uuid PRIMARY KEY,
    aggregate_id  text NOT NULL,
    event_type    text NOT NULL,
    payload       jsonb NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    published_at  timestamptz
);
CREATE INDEX outbox_unpublished
    ON outbox (created_at) WHERE published_at IS NULL;
```

The partial index is the detail worth stealing even if you change everything else: the relay only ever asks for unpublished rows, so the index only ever holds unpublished rows. It stays small no matter how many events you have already sent, and the relay query stays cheap under pressure.

## Watch It Survive Two Crashes

Here is the pattern in runnable Python, standard library only, using SQLite as the database and a list as the broker. It runs both failures on purpose: the process crash that loses a dual-written event, and the relay crash that duplicates an outbox event. The full file is `outbox_demo.py` next to this draft.

```python
def place_order_outbox(conn, item, total_cents):
    order_id = str(uuid.uuid4())[:8]
    event_id = str(uuid.uuid4())
    payload = json.dumps(
        {"order_id": order_id, "type": "OrderCreated",
         "total_cents": total_cents}
    )
    with conn:  # ONE transaction: business row and event row, or neither
        conn.execute(
            "INSERT INTO orders VALUES (?, ?, ?)",
            (order_id, item, total_cents),
        )
        conn.execute(
            "INSERT INTO outbox (event_id, aggregate_id, event_type, payload)"
            " VALUES (?, ?, ?, ?)",
            (event_id, order_id, "OrderCreated", payload),
        )
    return order_id, event_id


def relay(conn, broker, crash_after_publish=False):
    rows = conn.execute(
        "SELECT event_id, payload FROM outbox WHERE published = 0"
        " ORDER BY rowid"
    ).fetchall()
    for event_id, payload in rows:
        msg = json.loads(payload)
        msg["event_id"] = event_id
        broker.append(msg)  # publish first
        if crash_after_publish:
            raise RuntimeError("relay died after publish, before marking sent")
        with conn:  # then mark sent: a second, separate step
            conn.execute(
                "UPDATE outbox SET published = 1 WHERE event_id = ?",
                (event_id,),
            )
```

A few things are worth noting about this example. First, `place_order_outbox` never touches the broker. There is no publish call to crash between, which is the entire point: you removed the gap instead of narrowing it. Second, the relay still has a gap of its own, publish first and mark sent second, and the demo crashes inside it deliberately. Those two steps can never be made atomic either, because they are again two systems. The pattern does not eliminate the two-write problem. It moves it to a place where the failure is safe, and here is the measured proof.

Running the demo prints this:

```
== Part 1: dual write ==
crash: process died after commit, before publish
orders in database: 1, events on broker: 0
the order exists and no event does. that gap never heals itself.

== Part 2: outbox, relay crashes after publish ==
crash: relay died after publish, before marking sent
events on broker: 2, unpublished rows left: 0

== Part 3: consumer with an inbox ==
applied once: 1, duplicates skipped: 1
```

Read the three numbers as the whole argument. Part 1 is the bug you have today: one order, zero events, nothing anywhere that knows an event is missing. Part 2 is the outbox doing its job imperfectly on purpose: the restarted relay cannot tell whether its predecessor published before dying, so it publishes again, and the same event arrives twice. No event is lost. One is duplicated. Part 3 is the consumer's half of the contract, an inbox table that records each event_id it has applied, in the same transaction as the work the event triggers:

```python
def consume(conn, broker):
    applied = skipped = 0
    for msg in broker:
        cur = conn.execute(
            "INSERT OR IGNORE INTO inbox (event_id) VALUES (?)",
            (msg["event_id"],),
        )
        if cur.rowcount:  # first time we have seen this event id
            applied += 1
        else:
            skipped += 1
    conn.commit()
    return applied, skipped
```

The insert-or-ignore is the consumer-side twin of an idempotency key, and it has to live in the consumer's database, checked in the same transaction as the effect. A deduplication check in memory, or in a cache with an expiry, is a promise with a time limit on it. The relay will eventually deliver a duplicate later than your cache remembers, usually during the replay you run to fix something else.

## Order Is Per Aggregate, Not Global

One ordering fact saves teams a full redesign later. The outbox gives you a reliable sequence per aggregate, not across your whole system. Publish in insertion order with the aggregate id as the broker key, and OrderCreated for order 42 arrives before OrderPaid for order 42, because both land in the same partition in the order you sent them. Nothing orders order 42 against order 43, and a consumer that secretly assumes a global order will work in testing and corrupt state in production. Write the assumption down where the consumer lives: per-aggregate order, stable event ids, duplicates expected. Those three sentences are the real interface. The topic name is decoration.

Cleanup is part of the contract too. Published rows are dead weight with one remaining use: answering "did we send it" during an incident. Keep them for days, not forever, and delete them nightly in small batches.

## Where This Breaks

Say the limits plainly, because an outbox is not a spell:

- The consumer contract is mandatory, not optional. At-least-once delivery into a consumer with no deduplication is a duplicate-charge machine with good uptime. Shipping the outbox without the inbox is doing the glamorous half of the pattern.
- A poison event blocks a naive relay forever. One row that fails to publish gets retried at the head of the queue while valid events pile up behind it. You need a retry count, a dead-letter path, and an alert on unpublished age.
- The outbox adds write load to the database you were trying to protect. Every event is an insert, an index update, a publish mark, and an eventual delete. That churn is the honest price of the guarantee.
- It does not order across aggregates or make a non-transactional store transactional. If your state lives somewhere with no local transaction spanning both tables, there is no outbox to build on.
- Latency is now part of the design. A polling relay publishes on its interval, not at commit time. An event your product promises as instant is now as instant as your poll interval or your capture pipeline.

## Decide Before the Next Phantom Order

Build it if:

- A service writes state and publishes events about that state, and a lost or phantom event costs money, inventory, or a support ticket you cannot explain.
- You already run a relational database with real transactions. The pattern asks for one table and one background loop, not a new platform.
- Your consumers can record the event ids they have applied. If they cannot, fix that first, because it decides whether the rest of the pattern is safe.

Skip it if:

- The event is a nice-to-have notification whose loss nobody would ever detect or mind. A log line is cheaper than a table, a relay, and a cleanup job.
- One process owns both the write and the reaction to it, in the same call stack. You do not have a dual write. You have a function call.
- Your platform already gives you a transactional stream, such as a database change feed your consumers read directly. Publishing twice from two mechanisms is its own consistency bug.

The minimal viable version fits in an afternoon: one outbox table, one polling relay on a one-second interval, a published_at column, an inbox table in the one consumer that moves money, and an alert on the age of the oldest unpublished row. Measure two numbers before and after: events consumers report as missing, and duplicate deliveries your consumers had to skip. The first should go to zero. The second will not, and watching it stay above zero while nothing breaks is how you know the contract is working.

## Stop Publishing From the Request Handler

Pick the one service where a lost event would hurt the most. Move its publish call out of the request path this week: write the event next to the state, let a relay carry it, and give the consumer an inbox before you give it anything else. Then go looking for the dual writes you shipped years ago, because they are still there, working perfectly, right up to the half second that matters.

What is the longest an event of yours has sat unpublished, and how did you find out: from a dashboard, or from a customer?

## Resources

1. [Chris Richardson: Pattern, Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html)
2. [Debezium documentation: Outbox Event Router](https://debezium.io/documentation/reference/stable/transformations/outbox-event-router.html)
3. [Two-Phase Commit Is a Promise No One Can Keep](https://anushamukka.com/posts/two-phase-commit-is-a-promise-no-one-can-keep/)
4. [Exactly-Once Delivery Is a Lie. Idempotency Keys Are the Practical Answer.](https://anushamukka.com/posts/exactly-once-delivery-is-a-lie-idempotency-keys-are-the-practical-answer-3351/)
