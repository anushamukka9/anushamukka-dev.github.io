---
layout: post
title: Your Failure Detector Cannot Tell Dead From Slow
date: 2026-10-19 08:21:00 -0400
categories: [Writing]
tags: [Distributed Systems, Reliability, Software Engineering]
description: Silence is the only signal a heartbeat gives you, and a crashed node and a paused node are silent in exactly the same way. On fixed timeouts, the phi accrual failure detector in Cassandra and Akka, and choosing a threshold from the cost of being wrong in each direction.
---

# Your Failure Detector Cannot Tell Dead From Slow

*Silence is the only signal a heartbeat gives you, and silence has two causes that look exactly alike. A failure detector is a machine for guessing which one you have, and the honest ones tell you it is a guess.*

## The Pause That Triggered a Failover

A node stops sending heartbeats at 02:14. Six seconds later it sends one again, healthy, a little embarrassed, having spent those six seconds in a garbage collection pause that nobody budgeted for. By then the rest of the cluster has already acted on the silence. It declared the node dead, elected a replacement, and started moving its work. Now there are two copies of the work, one of them run by a node the system has written off, and a cleanup problem that will outlast the pause by hours.

Tell me about the last failover your system ran against a node that turned out to be fine. The postmortem usually blames the pause, as if the pause were the defect. The pause was ordinary. Long pauses are what loaded runtimes do. The defect was a detector that looked at six seconds of silence and reported death, when silence was all it had actually observed. A crashed process is silent. A paused process is silent. A process behind a broken network path is silent. From the outside, at the moment you have to decide, those three states produce identical evidence.

That is the uncomfortable fact under every health check, every leader lease, and every cluster membership list you run. This piece is about what a failure detector can honestly claim, the design that states its uncertainty as a number instead of a verdict, and why the threshold you set on that number is a price you pay in one of two currencies whether you chose it or not.

## Name the Two Bad Options

The first bad option is the short timeout. Declare a node dead after two missed heartbeats and your detection is fast, right up until normal bad luck lines up against you: a pause, a congested link, a noisy neighbor stealing CPU for three seconds. Then you convict a living node, trigger a failover, and, if you do it often enough, spend more time recovering from false alarms than from real failures. Flapping is the polite name for it. A detector that cries dead on a schedule teaches the rest of the system to ignore it, which is worse than having no detector.

The second bad option is the long timeout. Wait sixty seconds before you believe a silence and false convictions nearly vanish. Real crashes, meanwhile, get a full minute of grace in which the dead node still holds its leases, still owns its partitions, and still appears in routing tables, while requests pile up against a process that will never answer. Your users experience the outage at full length, plus the detection delay you chose for safety.

I understand why both survive. Short timeouts get set after an incident where detection was too slow. Long timeouts get set after an incident where a healthy node was convicted. Each team is solving the failure it remembers, and the knob can only point one way at a time. The knob is not the problem. A binary timeout is the problem, because it hides the trade instead of exposing it.

> A failure detector never tells you a node is dead. It tells you a node has been silent longer than you decided to tolerate, and those are different sentences.

## The Gap Every Heartbeat Explainer Skips

Most explanations of failure detection stop at heartbeat mechanics: send a ping every second, miss three, declare failure. That skips the only question that matters, which is how much evidence a silence actually carries. Three missed heartbeats on a quiet local network, where arrivals have landed within ten milliseconds of schedule for a month, is a loud signal. Three missed heartbeats across a loaded wide area link at peak hour may be a Tuesday. The same count means different things, and any detector that cannot tell the difference will be wrong in one of those regimes by construction.

This is not an implementation detail that a better library will fix for you. Chandra and Toueg proved the shape of the problem in 1996, in their paper on unreliable failure detectors for reliable distributed systems: in an asynchronous system you cannot distinguish a crashed process from a very slow one, so every detector is allowed to be wrong, and the useful question is how wrong, in which direction, and how often. Their detectors are honest about it in the name. Unreliable is not an insult. It is the specification.

The gap this piece fills is the step between that theorem and your configuration file. There is a well worked out middle path between a fixed timeout and a shrug, it is running inside systems you probably already operate, and it turns the detector output into a number your other components can reason about instead of a verdict they have to obey.

## Silence Is Evidence, Not a Verdict

Start with what the detector actually observes. A peer sends a heartbeat about once a second. You record when each one arrives. The intervals between arrivals have a history, and that history has a shape: a mean, a spread, a tail of late arrivals caused by ordinary load. When a silence starts, it stretches into that tail. The question worth asking is not "has the silence passed five seconds" but "how often, in the history I have, has a healthy peer stayed silent this long."

Answer that question as a probability and you get the phi accrual failure detector, published by Hayashibara, Defago, Yared, and Katayama in 2004 and since adopted by Apache Cassandra and by Akka and Pekko clusters. The detector keeps sampling the inter-arrival times of each peer's heartbeats, fits a distribution to them, and computes:

```
phi = -log10( 1 - F(time since last heartbeat) )

where F is the cumulative distribution of past inter-arrival times
```

Read it in plain words. F(t) is the probability that a heartbeat would have arrived by now if the peer were behaving as it usually does. One minus F(t) is the probability that a healthy peer would still be silent. Phi is that probability on a log scale, flipped so bigger means more suspicious: phi 3 means a healthy peer would be this silent about once in a thousand silences, phi 8 about once in a hundred million. The detector does not declare anything. It accrues suspicion, continuously, and the application picks the phi level at which it will act. Cassandra ships that pick as phi_convict_threshold, default 8. Akka exposes the same idea as a threshold plus two settings that matter more than they look: a minimum standard deviation, and an acceptable heartbeat pause that is subtracted before suspicion starts counting.

Here is the shape of the difference:

```
fixed timeout                     phi accrual
-------------                     -----------
silence: 0s ---- 5s ----> DEAD    silence grows, suspicion accrues
         alive   alive   verdict          1.0s  phi 0.2   normal
         (no information                  1.5s  phi 1.1   late
          is produced in                   2.0s  phi 3.2   unusual
          between)                         2.5s  phi 6.7   rare
                                           3.0s  phi 11.6  act here, if phi 8
                                                     is your chosen price
```

Notice the detail that makes phi more than a dressed up timeout: the scale adapts to the peer in front of it. A peer whose arrivals jitter by hundreds of milliseconds accrues suspicion slowly, because long silences are part of its normal behavior. A peer that has been metronome regular for a week accrues suspicion fast. One fixed number of seconds cannot do both jobs. A distribution per peer can, because it learned each peer's normal instead of assuming one normal for everyone.

## Build the Smallest Honest Version

Here is the detector in runnable Python, standard library only. The full file is failure_detector_demo.py next to this draft. It learns from a thousand measured inter-arrival times, shows what a fixed timeout does with a pause and a crash, then computes phi as the silence stretches.

```python
def phi(elapsed_s, mean_s, std_s):
    if std_s <= 0:
        std_s = 0.05
    z = (elapsed_s - mean_s) / std_s
    cdf = 0.5 * (1.0 + math.erf(z / math.sqrt(2.0)))
    tail = max(1.0 - cdf, 1e-15)
    return -math.log10(tail)
```

A few things are worth noting about this example. First, the whole mechanism is that function plus bookkeeping: fit the distribution, ask how surprising the current gap is, report the surprise. There is no probe, no consensus round, no special message. Second, the demo learns its history from a synthetic trace built to look like a loaded node: heartbeats sent every second, with scheduling and network delay adding a right hand tail, so arrivals average 1.114 seconds with a standard deviation of 0.273. That tail is not decoration. Without it, suspicion would climb absurdly fast and the numbers would flatter the design.

Running the demo prints this:

```
learned from 1000 heartbeats: mean=1.114s std=0.273s

== Part 1: a fixed timeout cannot tell dead from slow ==
silence 6.2s, timeout 5s -> DEAD  (node in a 6.2s GC pause, alive)
silence 6.2s, timeout 5s -> DEAD  (node crashed, dead)
same silence, same verdict. the detector saw no difference.

== Part 2: phi turns silence into a suspicion level ==
silence 1.0s -> phi  0.18
silence 1.5s -> phi  1.11
silence 2.0s -> phi  3.24
silence 2.5s -> phi  6.74
silence 3.0s -> phi 11.64
phi climbs as the silence stops looking like the history.
it never proves death. it prices how surprising the silence is.

== Part 3: the threshold is a price, in both directions ==
phi threshold | healthy silence that reaches it | delay on a real crash
phi  3        | about 1 in 1,000              | declared at 1.96s of silence
phi  5        | about 1 in 100,000            | declared at 2.28s of silence
phi  8        | about 1 in 100,000,000        | declared at 2.64s of silence
phi 12        | about 1 in 1,000,000,000,000  | declared at 3.03s of silence
```

Read the three parts as one argument. Part 1 is the fixed timeout convicting a paused node and a dead node with the same word, because it has only one word. Part 2 is the information the binary verdict throws away: at two seconds the silence is unusual, at two and a half it is rare, at three it is something a healthy version of this peer essentially never does. Systems that consume suspicion instead of verdicts can act in stages on that gradient: shed load at phi 3, refuse new work at phi 5, fail over at phi 8. The binary detector does all of that at one cliff edge, or none of it. Part 3 is the bill. Moving the threshold from phi 3 to phi 8 buys five orders of magnitude of protection against false conviction and costs you 0.68 seconds of detection delay on this trace. Whether that trade is good depends entirely on what a false conviction costs in your system, which is a question about your system, not about the detector.

## Acting on Suspicion Without Obeying It

Two practices decide whether accrual helps you in production or just gives you a fancier way to be wrong.

First, pair every conviction with fencing. A detector will sometimes convict a living node, no matter where you set the threshold, because the theorem says it must. The damage from that mistake is not the conviction. The damage is the convicted node continuing to write after its replacement starts. That is a separate problem with a separate mechanism, covered in the earlier piece on fencing tokens: the storage layer checks a monotonically increasing token and rejects the old leader's writes, convicted or not. Suspicion decides who should lead. Fencing decides whose writes count. Keep those jobs separate and a wrong suspicion becomes a brief disruption instead of split-brain data.

Second, watch phi as a metric before you ever wire it to a trigger. A peer whose phi regularly climbs to 4 and recovers is telling you something true about itself or its network path, weeks before it tells you with an outage. Graph the maximum phi per peer per hour. The peers that live in the tail of that graph are your next incidents, introducing themselves early, at a volume you can still ignore on purpose instead of by accident.

Real systems expose the pieces if you ask. In Cassandra, the threshold lives in cassandra.yaml:

```yaml
# phi value that must be reached for a host to be marked down.
phi_convict_threshold: 8
```

In Kubernetes, the detector hiding inside your liveness probes is the fixed kind, and its threshold is arithmetic you should do out loud once:

```yaml
livenessProbe:
  periodSeconds: 10
  failureThreshold: 3   # 3 missed probes x 10s = 30s of silence tolerated
```

Neither is wrong. What is wrong is shipping either number without knowing which error it buys.

## Where This Breaks

Say the limits plainly, because accrual is a better guess, not knowledge:

- The model is a normal distribution and reality has heavier tails. Real inter-arrival times have fat tails from load spikes and network events, so a normal fit understates how often long healthy silences occur, and phi climbs too eagerly exactly when the fleet is stressed. Production implementations defend against this with floors on the standard deviation and an acceptable pause margin. A demo formula without those guards will convict during incidents, which is when you can least afford extra failovers.
- Suspicion is local. Two observers with different network paths to the same peer will accrue different phi values, and both are correctly reporting what they see. A peer can be dead to half the cluster and fine to the other half. Accrual does not give you agreement. If the response to suspicion changes shared state, agreement has to come from consensus or fencing, not from comparing phi values.
- A slow detector cannot be fixed by a lower threshold alone. Detection delay is suspicion time plus the time your system takes to act: election, connection draining, routing updates. Shaving the threshold to save two seconds while your failover takes ninety is optimizing the small number for the comfort of having optimized something.
- Heartbeats measure the heartbeat path, not the work. A node can send perfect heartbeats from a dedicated thread while its request handlers are wedged behind a lock. Phi will sit at zero while users time out. Detect liveness of the thing users use, or accept that you are detecting the liveness of a metronome.
- New peers have no history. At startup the detector bootstraps its distribution from a guess, and suspicion for a young peer is built on that guess. Treat convictions in the first minutes of a peer's life as the least reliable output your cluster produces.

## Decide What a Wrong Answer Costs You

Build it if:

- You run a fleet where peers differ: mixed instance sizes, multiple zones, network paths with different normal jitter. Per-peer distributions earn their keep exactly where one timeout cannot fit everyone.
- False failovers have happened to you and were expensive. If conviction triggers data movement, leadership churn, or customer visible restarts, you want a threshold stated as a false conviction rate, not as a number of seconds somebody picked in 2019.
- You can act in stages. Accrual pays best when suspicion unlocks graduated responses: shed load first, drain the peer if suspicion keeps climbing, and reserve failover for the top of the scale.

Skip it if:

- Your system is three nodes on one quiet network and your timeout has never been wrong in either direction. The fixed detector you understand beats the adaptive one you will misconfigure.
- A wrong conviction is cheap and reversible, and slow detection is the expensive direction. Then take the short timeout on purpose, say so in the runbook, and spend the saved complexity elsewhere.

The minimal viable version fits in an afternoon: log the inter-arrival times you already have, compute a mean and standard deviation per peer, expose phi for the current silence as a metric, and alert on it for a week without acting on it. Compare that signal against your last few failovers. If phi would have spoken earlier, or more honestly, you have your decision from data instead of from the next incident.

## Pick Your Error on Purpose

Every failure detector you will ever run convicts some living nodes or forgives some dead ones, and usually both, in proportions set by a number someone chose. Choose the number from the cost of your two errors, write the reasoning next to it in the config, and pair it with fencing so the inevitable wrong answer stays small. A detector that admits it is guessing is not a weaker detector. It is the only kind that was ever on offer.

When your system last declared a node dead, did anyone check afterward whether it had actually died, and if it had not, did the threshold change?

## Resources

1. [Chandra and Toueg: Unreliable Failure Detectors for Reliable Distributed Systems (Journal of the ACM, 1996)](https://en.wikipedia.org/wiki/Chandra%E2%80%93Toueg_consensus_algorithm)
2. [Akka documentation: Phi Accrual Failure Detector](https://docs.huihoo.com/javadoc/akka/2.4/akka/remote/PhiAccrualFailureDetector.html)
3. [Pekko documentation: PhiAccrualFailureDetector](https://pekko.apache.org/japi/pekko/snapshot/org/apache/pekko/remote/PhiAccrualFailureDetector.html)
4. [Your Election Crowned Two Kings](https://anushamukka.com/posts/your-election-crowned-two-kings/)
5. [Your Servers Disagree About What Time It Is](https://anushamukka.com/posts/your-servers-disagree-about-what-time-it-is/)
