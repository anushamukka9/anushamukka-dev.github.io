---
layout: post
title: "Add Idempotency Keys to Your API in an Afternoon"
date: 2026-09-26 09:00:00 -0500
categories: [Tutorials]
tags: [Tutorials, APIs, Reliability, Distributed Systems]
description: "A step-by-step walkthrough: add idempotency-key support to a Python API so retried requests never double-execute."
---

Your customer's card gets charged twice. Your code is not wrong. Their phone retried the request because the first response got lost on a flaky connection. The charge went through. The confirmation did not. So the client did the reasonable thing and asked again, and your API did the reasonable thing and charged again. Now you have a support ticket, a refund to process, and a bug that only appears when the network misbehaves, which is to say, constantly.

The fix is not to stop retrying. Retries are correct; the network owes you nothing. The fix is to make the second attempt free. That is what an idempotency key does: the client sends a unique key with the request, and your API promises that repeating the same key repeats the result instead of repeating the work.

## What you will build

By the end of this tutorial you will have a small FastAPI service with a middleware that reads an `Idempotency-Key` header, fingerprints each request, records in-flight and completed responses, replays the recorded response on retry, and expires old keys. About an hour of work, and it generalizes to any framework with middleware.

**Prerequisites:** Python 3.10 or newer, a terminal, and curl. Install the two packages you need:

```bash
pip install fastapi uvicorn
```

**Time estimate:** 60 to 90 minutes, most of it reading the code below and poking at it with curl.

## Step 1: Build the endpoint that double-charges

Start with the bug, so you can watch the fix work. Create a file called `app.py`:

```python
from fastapi import FastAPI
import uuid

app = FastAPI()

charges = []  # stand-in for your database


@app.post("/charge")
def charge(amount_cents: int, customer_id: str):
    charge_id = f"ch_{uuid.uuid4().hex[:12]}"
    charges.append({"id": charge_id, "amount_cents": amount_cents,
                    "customer_id": customer_id})
    return {"charge_id": charge_id, "status": "captured"}


@app.get("/charges")
def list_charges():
    return {"count": len(charges), "charges": charges}
```

Run it:

```bash
uvicorn app:app --reload
```

Now simulate the retry. Send the same charge twice, the way a client would after a timeout:

```bash
curl -s -X POST "http://127.0.0.1:8000/charge?amount_cents=5000&customer_id=cus_42"
curl -s -X POST "http://127.0.0.1:8000/charge?amount_cents=5000&customer_id=cus_42"
curl -s "http://127.0.0.1:8000/charges" | python3 -m json.tool
```

You will see `"count": 2`. Two charges, one customer, zero malice. This is the entire problem: POST is not safe to repeat, and the network repeats things all the time.

## Step 2: Read the key and fingerprint the request

The client will send a header, `Idempotency-Key`, containing a unique value per logical operation (a UUID generated once on the client). Your job is to turn that key, plus everything that defines the request, into a fingerprint. The fingerprint matters because the same key must always mean the same request; if the payload changed, something is wrong and you should say so loudly rather than guess.

Add this to the top of `app.py`, above the endpoint:

```python
import hashlib

KEY_TTL_SECONDS = 24 * 60 * 60  # keep keys for a day

# key -> record. In production this is Redis, not a dict.
_idempotency_store: dict = {}


def _fingerprint(key: str, method: str, path: str, query: str, body: bytes) -> str:
    digest = hashlib.sha256()
    digest.update(key.encode("utf-8"))
    digest.update(method.encode("utf-8"))
    digest.update(path.encode("utf-8"))
    digest.update(query.encode("utf-8"))
    digest.update(body)
    return digest.hexdigest()
```

A few things are worth noticing. First, the fingerprint covers the key, the method, the path, the query string, and the body. Leave out any piece and two different operations can collide under one key. Second, the store is a plain dict. That is deliberate for a tutorial: you can see the whole mechanism. In production this dict becomes Redis, which you will get to in "What to build next."

## Step 3: Track what is in flight and what finished

Now the middleware. It has three jobs: reject a key that arrives with a different payload than before, replay the recorded response for a completed key, and mark new keys as in-flight so a concurrent duplicate gets a clean 409 instead of a race.

```python
import time
from fastapi import Request
from fastapi.responses import JSONResponse, Response
from starlette.middleware.base import BaseHTTPMiddleware


def _prune_expired(now: float) -> None:
    expired = [k for k, v in _idempotency_store.items()
               if v["expires_at"] <= now]
    for k in expired:
        del _idempotency_store[k]


class IdempotencyMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        key = request.headers.get("Idempotency-Key")
        if not key:
            # No key, no idempotency. The endpoint runs as before.
            return await call_next(request)

        body = await request.body()
        fingerprint = _fingerprint(
            key, request.method, request.url.path,
            str(request.url.query), body,
        )
        now = time.time()
        _prune_expired(now)

        record = _idempotency_store.get(key)

        if record is not None and record["fingerprint"] != fingerprint:
            return JSONResponse(
                status_code=422,
                content={"detail": "Idempotency-Key was already used "
                                  "with a different request."},
            )

        if record is not None and record["status"] == "completed":
            headers = dict(record["headers"])
            headers["Idempotent-Replayed"] = "true"
            return Response(
                content=record["response_body"],
                status_code=record["status_code"],
                headers=headers,
                media_type=record["media_type"],
            )

        if record is not None and record["status"] == "in-flight":
            return JSONResponse(
                status_code=409,
                content={"detail": "A request with this Idempotency-Key "
                                   "is already in flight."},
            )

        _idempotency_store[key] = {
            "status": "in-flight",
            "fingerprint": fingerprint,
            "expires_at": now + KEY_TTL_SECONDS,
        }

        try:
            response = await call_next(request)
        except Exception:
            # The handler blew up. Remove the record so the client
            # can retry with the same key.
            _idempotency_store.pop(key, None)
            raise

        response_body = b""
        async for chunk in response.body_iterator:
            response_body += chunk

        _idempotency_store[key].update({
            "status": "completed",
            "status_code": response.status_code,
            "response_body": response_body,
            "headers": dict(response.headers),
            "media_type": response.media_type,
        })

        headers = dict(response.headers)
        headers["Idempotent-Replayed"] = "false"
        return Response(
            content=response_body,
            status_code=response.status_code,
            headers=headers,
            media_type=response.media_type,
        )


app.add_middleware(IdempotencyMiddleware)
```

Walk through the branches in order. The 422 fires when a key is reused with a different payload. That is a client bug, and 422 tells the client exactly that: do not guess, do not silently run the wrong operation. The replay branch returns the stored bytes with the stored status code, so the retry sees the identical response, down to the charge ID. The 409 handles the concurrent case: two identical requests arrive at once, the second waits for nothing and learns the first is still running. And the exception handler is the quiet hero: if your endpoint raises, the in-flight record is removed, so the client can retry with the same key instead of being stuck behind a record that will never complete.

One honest caveat about this design: the in-flight mark and the completion write are not atomic. Two truly simultaneous first-seen requests could both slip through. The dict keeps the tutorial readable; Redis with a single atomic operation fixes it, and that is in "What to build next."

## Step 4: Restart and prove it with curl

Restart uvicorn so the middleware loads, then run the retry scenario again, this time with a key:

```bash
KEY=$(uuidgen)
curl -s -i -X POST "http://127.0.0.1:8000/charge?amount_cents=5000&customer_id=cus_42" \
  -H "Idempotency-Key: $KEY" | head -20
```

The first response carries `idempotent-replayed: false` and a fresh `charge_id`. Now the retry, same key, same request:

```bash
curl -s -i -X POST "http://127.0.0.1:8000/charge?amount_cents=5000&customer_id=cus_42" \
  -H "Idempotency-Key: $KEY" | head -20
```

This time the header reads `idempotent-replayed: true`, and the body is byte-identical to the first response, same charge ID. Confirm the customer was charged once:

```bash
curl -s "http://127.0.0.1:8000/charges" | python3 -m json.tool
```

`"count": 1`. The retry cost nothing.

Two more cases to try. Same key, different amount:

```bash
curl -s -X POST "http://127.0.0.1:8000/charge?amount_cents=9999&customer_id=cus_42" \
  -H "Idempotency-Key: $KEY"
```

You get a 422 with the "different request" message, and no new charge. And a request with no key at all runs the old naive path, which is the point: idempotency is opt-in per request, so existing clients keep working while new ones adopt keys.

## Where this breaks

No hedging here; these are the real edges.

- **Keys are scoped to nothing in this tutorial.** In production, scope the key to the account or API credential. Otherwise one customer's key can replay another customer's response.
- **The store dies with the process.** Restart the server and every key is forgotten, so a retry after a deploy double-executes. This is why the store is Redis in production: shared, persistent, and fast enough to sit in the request path.
- **A 24-hour TTL is a policy decision, not a law.** Too short and a legitimate late retry double-executes; too long and you store junk. Pick the window from your domain: how late can a retry honestly arrive?
- **In-flight marking is not atomic here.** Under true concurrency, two first-seen requests can both execute. The dict is a teaching tool; the production version needs one atomic check-and-set.
- **Exactly-once delivery is still a lie.** Idempotency keys do not make the network reliable. They make repeated execution safe, which is the practical answer. Do not let anyone on your team claim the stronger guarantee.

## What to build next

Three concrete upgrades, in the order that pays off:

1. **Move the store to Redis.** One hash per key with a TTL, and a single Lua script or `SET NX` for the atomic in-flight mark. That fixes both the durability and the concurrency edge above.
2. **Scope keys per account.** Prefix the store key with the authenticated account ID, and reject keys that cross account boundaries.
3. **Make it opt-in per endpoint.** A decorator like `@idempotent` on the routes that need it, instead of middleware on everything. Read-only GETs do not need keys; money-moving POSTs do.

You now have the whole mechanism in one file and under a hundred lines of new code. The next time a client retries into your API at 2 a.m., the second attempt will be free, and you will sleep through it. Which endpoint in your system would hurt the most if it ran twice?
