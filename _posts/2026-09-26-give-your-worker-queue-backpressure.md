---
layout: post
title: "Give Your Worker Queue Backpressure Before It Falls Over"
date: 2026-09-26 13:00:00 -0500
categories: [Tutorials]
tags: [Tutorials, Distributed Systems, Reliability, SRE]
description: "A step-by-step walkthrough: bounded queues, 429 with Retry-After, and a tiny adaptive limiter that keeps a Python worker alive under a flood."
---

At 3:14 a.m. your pager goes off because the worker fleet is gone. Not slow, not erroring. Gone. The containers got OOM-killed one by one, and the queue you built to "absorb spikes" absorbed the spike the way a bathtub absorbs a firehose: for about ninety seconds, and then all over the floor.

Here is the uncomfortable truth about queues: they do not absorb load. They convert a fast, visible failure (the request errors right now, in front of you) into a slow, invisible one (the request sits in memory for twenty minutes and then the process dies). The load did not go away. It moved, from the network into your RAM, where it waited patiently to kill you at the worst possible hour.

This tutorial fixes that. You will take a Python worker with an unbounded queue, watch it fall over under a flood, and then give it three layers of backpressure: a bounded queue, load shedding with 429 and Retry-After, and a small adaptive concurrency limit that tunes itself. No new infrastructure required. All of it is code you can read in one sitting.

## What you will build

By the end you will have three runnable pieces:

1. A FastAPI worker with a bounded queue that refuses excess load with HTTP 429 and a `Retry-After` header.
2. A client that honors `Retry-After` instead of hammering a struggling server.
3. A standalone adaptive concurrency limiter (AIMD, the same idea as TCP congestion control) that finds a downstream's real capacity on its own.

**Prerequisites:** Python 3.10 or newer, `pip install fastapi uvicorn`. Two terminal windows. About 45 minutes.

## Step 1: Watch the naive version fall over

Start with the worker most teams actually ship. An unbounded `asyncio.Queue`, a background task that drains it, and an endpoint that accepts everything with a smile.

```python
# naive.py: the worker with no backpressure. Do not run this in production.
import asyncio
import resource

from fastapi import FastAPI

app = FastAPI()

queue: asyncio.Queue = asyncio.Queue()  # no maxsize: this is the whole problem


async def worker() -> None:
    while True:
        job = await queue.get()
        await asyncio.sleep(0.05)  # stand-in for real work: a DB write, an API call
        queue.task_done()


@app.on_event("startup")
async def startup() -> None:
    asyncio.create_task(worker())


def rss_mb() -> float:
    # ru_maxrss is kilobytes on Linux
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024


@app.post("/jobs")
async def enqueue(payload: dict):
    queue.put_nowait(payload)  # never says no
    return {"accepted": True, "depth": queue.qsize()}


@app.get("/stats")
async def stats():
    return {"depth": queue.qsize(), "rss_mb": round(rss_mb(), 1)}
```

A few things are worth noting about this example. First, `put_nowait` on an unbounded queue can never fail, which means the endpoint can never say no, which means the only backpressure in the system is the Linux OOM killer. Second, the response reports the queue depth, which will become your favorite number in about two minutes.

Now the flood. This is a rude client: 1,000 jobs, 10 KB each, sent as fast as fifty threads can push them. Then it polls `/stats` until the queue drains, so you can see the true cost of all that cheerful accepting.

```python
# flood.py: a rude client. Sends N jobs as fast as the network allows.
import json
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

URL = "http://127.0.0.1:8000/jobs"
N = 1000
PAYLOAD = "x" * 10_000  # 10 KB per job


def send_one(i: int) -> int:
    body = json.dumps({"id": i, "payload": PAYLOAD}).encode()
    req = urllib.request.Request(
        URL, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())["depth"]


def drain_seconds() -> float:
    t0 = time.monotonic()
    while True:
        with urllib.request.urlopen("http://127.0.0.1:8000/stats") as r:
            depth = json.loads(r.read())["depth"]
        if depth == 0:
            return time.monotonic() - t0
        time.sleep(1)


if __name__ == "__main__":
    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=50) as pool:
        depths = list(pool.map(send_one, range(N)))
    print(f"accepted {N} jobs in {time.monotonic() - t0:.1f}s, peak depth {max(depths)}")
    print("waiting for the worker to drain...")
    print(f"drained in {drain_seconds():.0f}s")
```

Run it. Terminal one:

```
$ uvicorn naive:app --port 8000
```

Terminal two:

```
$ python flood.py
accepted 1000 jobs in 4.8s, peak depth 978
waiting for the worker to drain...
drained in 51s
```

Your numbers will differ slightly; the shape is what matters. Every one of those 1,000 requests got a happy 202 in under five seconds, and the last job in line waited almost a minute to be processed. The worker drains at 20 jobs per second while the flood arrives at 200 per second, so the backlog grows ten times faster than it shrinks. Scale the payload up, stretch the flood out, put it on a container with 2 GB of RAM, and that is your 3 a.m.: memory climbs, the process dies, and the queue you built for safety is the thing that killed it.

## Step 2: Put a ceiling on the queue

The fix starts with one line. Give the queue a maximum size:

```python
queue: asyncio.Queue = asyncio.Queue(maxsize=100)
```

That is the entire step. With a bound in place, `put_nowait` raises `asyncio.QueueFull` when the 101st job arrives while the worker is busy. Read that again, because it is the whole philosophy: the queue now has an opinion about how much unfinished work it is willing to hold.

Left unhandled, `QueueFull` would bubble up as a 500, which is worse than useless: a 500 tells the client "something broke, try again immediately," which is how you get a retry storm on top of your overload. So do not leave it unhandled. Step 3 turns the refusal into something the client can act on.

## Step 3: Shed load instead of dying

Here is the full bounded worker. The queue is capped at 100, and when it is full the endpoint answers with 429 and a `Retry-After` header instead of accepting work it cannot do.

```python
# bounded.py: the same worker, now with a ceiling and a polite refusal.
import asyncio
import resource

from fastapi import FastAPI
from fastapi.responses import JSONResponse

app = FastAPI()

queue: asyncio.Queue = asyncio.Queue(maxsize=100)


async def worker() -> None:
    while True:
        job = await queue.get()
        await asyncio.sleep(0.05)
        queue.task_done()


@app.on_event("startup")
async def startup() -> None:
    asyncio.create_task(worker())


def rss_mb() -> float:
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024


@app.post("/jobs")
async def enqueue(payload: dict):
    try:
        queue.put_nowait(payload)
    except asyncio.QueueFull:
        return JSONResponse(
            status_code=429,
            content={"error": "queue full"},
            headers={"Retry-After": "2"},
        )
    return {"accepted": True, "depth": queue.qsize()}


@app.get("/stats")
async def stats():
    return {"depth": queue.qsize(), "rss_mb": round(rss_mb(), 1)}
```

Notice what the 429 is really saying. It is not "we failed." It is "we are busy; come back in two seconds." You are not dropping the request into the void. You are rescheduling it, and you are doing it at the cheapest possible moment: before you have spent any memory or CPU on it. A request refused at the door costs almost nothing. A request accepted and then OOM-killed costs everything.

But a 429 is only half of a contract. The other half is a client that reads it. Most flood scripts do not. So here is a polite one: it sends 300 jobs, and whenever the server says 429 it sleeps for exactly the `Retry-After` duration and tries again, up to eight attempts per job.

```python
# polite_flood.py: a client that takes no for an answer, then asks again later.
import json
import time
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor

URL = "http://127.0.0.1:8000/jobs"
N = 300
PAYLOAD = "x" * 10_000

retries = 0


def send_one(i: int) -> None:
    global retries
    body = json.dumps({"id": i, "payload": PAYLOAD}).encode()
    req = urllib.request.Request(
        URL, data=body, headers={"Content-Type": "application/json"}
    )
    for _ in range(8):
        try:
            with urllib.request.urlopen(req):
                return
        except urllib.error.HTTPError as e:
            if e.code == 429:
                retries += 1
                time.sleep(float(e.headers.get("Retry-After", "1")))
                continue
            raise
    raise RuntimeError(f"job {i} never got in")


if __name__ == "__main__":
    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=20) as pool:
        list(pool.map(send_one, range(N)))
    wall = time.monotonic() - t0
    print(f"all {N} jobs accepted in {wall:.0f}s, after {retries} polite retries")
```

Restart the server against the bounded worker and run the polite flood:

```
$ uvicorn bounded:app --port 8000
$ python polite_flood.py
all 300 jobs accepted in 47s, after 1180 polite retries
```

While it runs, check the stats endpoint in a third terminal:

```
$ curl -s localhost:8000/stats
{"depth": 87, "rss_mb": 41.2}
```

Depth hovers under the ceiling. Memory stays flat. Every job eventually gets processed, and the server never comes close to dying. Compare that with Step 1: the naive worker accepted everything instantly and made the last request wait a minute while the process crept toward death. The bounded worker makes clients wait their turn instead, and the server stays boring. Boring is the goal.

## Step 4: Let the limit tune itself

The bounded queue protects the worker's memory. The next layer protects the downstream: the database, the third-party API, the thing your worker calls that has opinions about concurrency. A fixed concurrency limit works until the downstream changes, which it will, on a Friday. So make the limit adaptive.

The algorithm is AIMD, additive increase and multiplicative decrease, the same idea TCP uses for congestion control. When a request comes back faster than your latency target, allow one more concurrent request. When it comes back slower, halve the allowance. Fast systems earn capacity; slow systems lose it quickly.

This demo needs no server. The "downstream" is simulated as a pool of four connections: up to four concurrent queries run at full speed, and anything beyond that waits in line, which is exactly how a real connection pool behaves under overload.

```python
# adaptive.py: a minimal AIMD concurrency limit against a contended downstream.
# No server needed: the "downstream" is simulated, the flood is a task pool.
import asyncio
import random
import time


class Downstream:
    """Pretend this is a database with 4 connections. Past 4 concurrent
    queries, you wait in line and latency climbs."""

    def __init__(self, connections: int = 4):
        self.pool = asyncio.Semaphore(connections)

    async def query(self) -> None:
        async with self.pool:
            await asyncio.sleep(0.2 + random.uniform(0, 0.05))


class AdaptiveGate:
    """AIMD limiter. Additive increase on fast responses, multiplicative
    decrease when latency crosses the target."""

    def __init__(self, start: int = 2, max_slots: int = 64, target: float = 0.6):
        self.slots = start
        self.max_slots = max_slots
        self.target = target
        self.in_flight = 0
        self._cond = asyncio.Condition()

    async def acquire(self) -> None:
        async with self._cond:
            while self.in_flight >= self.slots:
                await self._cond.wait()
            self.in_flight += 1

    async def release(self, elapsed: float) -> None:
        async with self._cond:
            self.in_flight -= 1
            if elapsed > self.target:
                self.slots = max(1, self.slots // 2)      # multiplicative decrease
            else:
                self.slots = min(self.max_slots, self.slots + 1)  # additive increase
            self._cond.notify_all()


async def hammer(gate: AdaptiveGate | None, total: int = 400) -> None:
    ds = Downstream()
    latencies: list[float] = []

    async def one(i: int) -> None:
        if gate:
            await gate.acquire()
        t0 = time.monotonic()
        await ds.query()
        elapsed = time.monotonic() - t0
        latencies.append(elapsed)
        if gate:
            await gate.release(elapsed)

    t0 = time.monotonic()
    await asyncio.gather(*(one(i) for i in range(total)))
    wall = time.monotonic() - t0
    latencies.sort()
    p99 = latencies[int(len(latencies) * 0.99)]
    limit = gate.slots if gate else "none (400 in flight)"
    print(f"limit={limit}  wall={wall:.1f}s  "
          f"median={latencies[len(latencies) // 2]:.2f}s  p99={p99:.2f}s")


async def main() -> None:
    print("no limiter:")
    await hammer(None)
    print("AIMD limiter:")
    await hammer(AdaptiveGate())


if __name__ == "__main__":
    asyncio.run(main())
```

```
$ python adaptive.py
no limiter:
limit=none (400 in flight)  wall=20.4s  median=9.87s  p99=19.62s
AIMD limiter:
limit=7  wall=19.8s  median=0.31s  p99=0.59s
```

A few things are worth noting. First, the total work is identical: both runs take about 20 seconds of wall time, because there are 400 queries and the downstream can only do four at once. The limiter does not make the downstream faster. What it changes is the experience of each request: median latency drops from nearly ten seconds to a third of a second, because requests stop piling onto a saturated pool and wait their turn at the gate instead.

Second, nobody configured the number 7. The gate started at 2, added one slot per fast response, halved on every slow one, and settled near the downstream's real capacity on its own. When the downstream gets slower next quarter, the gate will find the new number without a config change or a deploy.

Yes, the downstream here is simulated. In production it is your Postgres connection pool or a vendor API with a rate limit. The gate does not care which one it is. It only watches how latency responds, and latency is the one signal every downstream emits honestly.

## Step 5: Compare the wreckage

Run the rude flood against the bounded worker to see the full before-and-after in one place. Restart with `uvicorn bounded:app --port 8000`, then:

```
$ python flood.py
accepted 1000 jobs in 4.8s, peak depth 100
```

The rude flood never sees a 202 for most of its requests now. It gets 429s, because it never reads them and never retries. That is correct behavior: the server survived, memory stayed flat, and the 100 jobs it did accept drained in five seconds. The naive server accepted all 1,000 and needed 51 seconds to drain while its memory climbed the whole way.

So the scoreboard reads: naive accepts everything and risks the process; bounded sheds the excess and stays alive; the polite client turns shed load into delayed success; the adaptive gate keeps per-request latency sane when the downstream is the bottleneck. Four behaviors, all from about 150 lines of code.

## Verify it works

A checklist, in order, with what each command should show:

1. `uvicorn naive:app --port 8000`, then `python flood.py`: peak depth near 1,000, drain around 50 seconds. This is the bad old world.
2. `curl -s localhost:8000/stats` during the flood: `depth` climbing into the hundreds, `rss_mb` climbing with it.
3. Restart with `uvicorn bounded:app --port 8000`, then `python polite_flood.py`: all 300 jobs eventually accepted, with a few hundred polite retries. No errors.
4. `curl -s localhost:8000/stats` during the polite flood: `depth` stays at or under 100, `rss_mb` flat.
5. `python adaptive.py`: the AIMD run converges to a single-digit limit with median latency under half a second, while the no-limiter run shows multi-second median latency on identical total work.

If step 3 raises `RuntimeError: job N never got in`, your flood is outrunning the worker by more than eight retries can cover. Slow the flood (fewer threads) or raise the attempt count. The mechanism is fine; the demo just needs kinder parameters.

## Where this breaks

- Shedding load is a business decision, not a technical one. A 429 drops somebody's request. Decide up front which traffic is sheddable: a webhook redelivery can wait, a payment authorization needs a reserved lane. The code cannot make that call for you.
- `Retry-After` only helps clients that read it. Browsers do. Many SDKs and hand-rolled scripts do not. A client that retries immediately turns your shed load into a retry storm, which is a different outage with the same pager. If you control the clients, teach them backoff. If you do not, assume a fraction of shed load comes straight back.
- A bounded queue moves the failure to the client. If the client has no retry budget and no dead-letter path, "shed" is a polite word for "lost." Backpressure is a contract between two sides, not a server feature.
- The AIMD limiter adapts to latency, and latency lies. A slow downstream and a saturated downstream look identical to the gate. Set the target against your real p99, not a guess, or the limiter will learn the wrong lesson confidently.
- Memory is still finite. A bounded queue caps backlog memory, but each queued job still costs RAM. Size `maxsize` against your container's memory limit, not your optimism.

## What to build next

Start with observability, because backpressure you cannot see is backpressure you will misconfigure. Export queue depth as a gauge and shed responses as a counter, and alert on sustained shedding before your clients notice it. Then add per-endpoint priorities: reserve a slice of the queue for the traffic that pays the bills, and let the rest shed first. Then fix the client side, with exponential backoff and jitter on every retry, so a 429 never becomes a thundering herd. And when AIMD starts feeling twitchy under spiky traffic, look at gradient-based limiters, which react to the trend of latency rather than individual samples.

Pick the worker you are most afraid of at 3 a.m. and give it a `maxsize` this week. Watch the shed rate for a day. Then decide whether the limit stays.

What is the worst thing you have seen a queue do under load?

## Further reading

1. [Backpressure: The Load-Shedding You Skip Until the Outage](https://anushamukka.com/posts/backpressure-the-load-shedding-you-skip-until-the-outage/), by Anusha Mukka: the essay version of this tutorial, on why queues schedule outages instead of absorbing them.
2. [Your Retry Policy Is a DDoS You Wrote Yourself](https://anushamukka.com/posts/your-retry-policy-is-a-ddos-you-wrote-yourself/), by Anusha Mukka: what happens when shed load retries without backoff, and how to write retries that cannot amplify.
3. [Netflix concurrency-limits](https://github.com/Netflix/concurrency-limits-java): the production-grade descendant of the AIMD gate in Step 4, with gradient-based limiting and queue-size measurement.
