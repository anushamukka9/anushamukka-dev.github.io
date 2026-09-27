---
layout: post
title: "Your Servers Disagree About What Time It Is"
date: 2026-09-27 07:00:00 -0500
categories: [Writing]
tags: [Distributed Systems, Clock Skew, Reliability, SRE]
description: "Clock skew is the quiet bug behind sessions that expire early, charges that appear twice, and certificates valid nowhere. Stop trusting the clock; design like it is lying to you."
---

# Your Servers Disagree About What Time It Is

*Clock skew is the quiet bug behind sessions that expire early, charges that appear twice, and certificates that are valid nowhere. Stop trusting the clock. Design like it is lying to you.*

## The Login That Expired Before It Started

On a Tuesday in March, a team I know started getting tickets from users who were logged out seconds after logging in. Not all users. About four percent. The login succeeded, the dashboard loaded, and then the next click bounced them back to the sign-in page with a session-expired message. Support could not reproduce it. The QA environment was clean. The session service showed 99.99% uptime and the logs showed nothing but successful logins followed by clean expirations.

The cause took three days to find, which is embarrassing in retrospect, because it was a clock. The fleet ran on twelve app servers. Eleven of them agreed on the time. The twelfth ran ninety seconds behind, and the load balancer had started sending it more traffic after a deploy. That server stamped each session ninety seconds in the past, and the session service subtracted the TTL from the stamp and concluded the session had already lived most of its life. Some sessions arrived effectively pre-expired.

Yes, this is a composite of incidents I have watched up close. It is hardly unusual. And the fix the team shipped first is the one I want to argue against: they added five minutes of slack to every TTL and called it resilience.

## Name the Two Bad Options

When your machines disagree about the time, which they always do, you get two bad default reactions, and most systems pick one without noticing.

The first bad option is to trust the clock. Compare timestamps across machines. Order events by their recorded time. Set a token's not-before to now and reject anything older than the TTL. This works right up until it does not, and when it breaks, it breaks as phantom bugs: the session that expires early, the certificate that is not yet valid on the machine checking it. The failure mode is never "the clock is wrong." It is always something downstream and weird.

The second bad option is the slack. Add a margin. Five minutes here, ten minutes there, a generous fudge factor on every expiry, every validity window, every ordering decision. I understand the appeal. It feels pragmatic, it ships today, and it makes the immediate bug go away. But slack is not a strategy. It is where you hide the decision you did not make. Every margin is a lie about how wrong the clocks can be, and the day the skew exceeds it, the bug returns wearing a different costume. You are still trusting the clock. You have just lowered your standards for what counts as agreement.

So the real question is never "how much slack should we add." It is "what does this code assume about time, and what happens when the assumption is wrong."

## Why the Clocks Drift, and Why You Cannot Fully Fix It

Let me give you the mechanism, because the mechanism is the part every explainer skips.

A server's clock is a quartz crystal that vibrates, and the vibration rate changes with temperature, voltage, and age. Left alone, a typical server clock drifts by seconds per day. That is why we run NTP, the Network Time Protocol, which periodically asks a reference server for the time and slews the local clock toward it. Here is the exchange:

```
Client                              Server
  |  ---- t1: request sent --------->  |
  |                                   |  t2: request received
  |                                   |  t3: response sent
  |  <---- t4: response received ---  |
```

The client knows t1 and t4 from its own clock, and the server reports t2 and t3. From these four timestamps, NTP computes two numbers:

- Round-trip delay = (t4 - t1) - (t3 - t2)
- Clock offset = ((t2 - t1) + (t3 - t4)) / 2

The offset formula assumes the network delay is symmetric: that the request took as long as the response. Here is the catch, and it is a fundamental one. You cannot distinguish a clock that is 50 milliseconds fast from a network path that takes 50 milliseconds longer in one direction. The information simply is not in the four timestamps. NTP's estimate is exact only if the path is perfectly symmetric, and real paths never are. So NTP does not actually tell you the time. It tells you an estimate plus an error bound, and the honest engineering move is to design around the bound, not the estimate.

A well-run NTP setup, or chrony, its modern replacement, keeps a LAN-synced server within a millisecond or two of true time. Over the public internet, tens of milliseconds is normal. That sounds small until you remember the session bug above, which needed only ninety seconds, and the certificate bug, which needed only the thirty seconds of a container starting before its first sync.

## Ask a Different Question

The best answer to "what time is it" I have seen in production does not answer that question at all. It comes from Google's Spanner paper, published at OSDI in 2012, and the idea is called TrueTime.

TrueTime's `now()` does not return a timestamp. It returns an interval, [earliest, latest], with the guarantee that the true time falls somewhere inside. Under the hood, time masters fed by GPS receivers and atomic clocks widen the interval to cover the known worst-case drift since the last sync. The application never learns the exact time. It learns a range it can trust.

Here is why that design choice is not an accident. Spanner needs to order transactions across continents. If it ordered them by estimated timestamps, two transactions committed "at the same time" on two continents could be ordered wrong whenever the estimate was off. So Spanner uses commit-wait: a transaction that wants to commit at timestamp T waits until TrueTime's `now().earliest` has passed T. At that point, every future transaction anywhere will get a timestamp later than T, because no clock could still believe it is before T. The wait is typically a few milliseconds. The ordering is exact, and it never once required any machine to know the true time.

I am not suggesting you install atomic clocks. I am suggesting you steal the question. Stop asking your code "what time is it." Ask "what time is it definitely not," and build your critical decisions on the safe side of that answer.

## Four Patterns That Survive Skew

Here is what that looks like in ordinary systems, no GPS required.

**First, measure durations with a monotonic clock.** Every language has two clocks and most bugs come from using the wrong one. The wall clock (`time.time()` in Python, `System.currentTimeMillis()` in Java) can jump backward when NTP corrects it, or leap forward on a VM resume. The monotonic clock (`time.monotonic()`, `System.nanoTime()`) only moves forward and exists for measuring elapsed time. If you are timing a request, a retry delay, or a TTL countdown, use the monotonic clock. If you are stamping something a human will read, use the wall clock. Mixing them up is how a ninety-second correction turns into sessions that expire in negative time.

**Second, never order events across machines by timestamp.** If two servers both write "happened at 10:04:31," you do not know which happened first, and no amount of NTP tuning changes that. Order with sequence numbers from a single writer, with Lamport clocks, or with hybrid logical clocks if you need both causality and rough wall-clock readability. The timestamp is a label for humans. The ordering needs its own mechanism.

**Third, replace expiry checks with fencing where it matters.** A TTL says "this is valid until time T," which is a statement about a clock you do not control. A fencing token says "this writer holds generation 14; anything older is stale," which is a statement about your own state machine. Here is the whole pattern in Python:

```python
# Each writer holds a token. The store remembers the highest token seen.
def write_with_fence(store, token, key, value):
    current = store.get_fence(key)
    if token <= current:
        # A stale writer: its clock, its retry, its confusion.
        # The data may be fine. The authority is expired.
        raise StaleWriterError(f"token {token} <= {current}")
    store.put(key, value)
    store.set_fence(key, token)
```

A few things are worth noting. First, the token need not be a timestamp; a monotonically increasing number from ZooKeeper, etcd, or a database sequence works, and unlike a timestamp it cannot misorder. Second, the check is local to the store, so it survives any amount of clock disagreement between writers. Third, it composes with retries: a retried write carries the same token and is correctly recognized as a duplicate, not a new write. The session bug from the opening would not have happened with fencing, because the ninety-second clock would have been irrelevant.

**Fourth, monitor the offset and alert on it.** Skew is a metric, not a mystery. On any Linux host running chrony:

```bash
$ chronyc tracking
Reference ID    : 169.254.169.123
Stratum         : 4
Ref time (UTC)  : Sun Sep 27 14:12:03 2026
System time     : 0.000123 seconds slow of NTP time
Last offset     : -0.000087 seconds
RMS offset      : 0.000214 seconds
```

The line to watch is `System time`: how far off this machine believes it is. `Last offset` is the most recent single correction, noisy and unimportant on its own. `RMS offset` is the longer-term average error, the honest version of your clock's accuracy. `Stratum` tells you how many hops from a reference clock this machine sits; stratum 1 is the reference itself. Export these numbers, alert when the absolute offset crosses your threshold (500 milliseconds is a sane default for most fleets; tighten it if you do certificate or token validity), and you will catch the drifting machine on Tuesday morning instead of in a three-day support-ticket archaeology dig.

## Where This Breaks

- Virtual machines pause. When a hypervisor migrates or snapshots a VM, its clock can jump forward by seconds or minutes on resume. NTP will slew it back, but anything stamped during the jump is wrong, and monotonic clocks on some hypervisors jump too. If you run on VMs, this is your most likely source of sudden skew.
- Leap seconds still happen, and the industry handles them by smearing: spreading the extra second over 24 hours so clocks never step. Google and AWS both smear. But not everything smears the same way, so two systems can disagree by up to a second around the event. No new leap second has been scheduled since the 2022 vote to abolish them by 2035, which means the current calm is provisional.
- TrueTime's guarantee costs real hardware: GPS receivers and atomic clocks per datacenter, plus the engineering to widen uncertainty bounds honestly. You cannot apt-get your way to commit-wait.
- Hybrid logical clocks and Lamport clocks give you ordering, not time. They will happily tell you event A preceded event B while both carry wall-clock labels from last Thursday. Do not show them to users.
- Container clocks are the host's clock. There is no per-container NTP. If the host drifts, every container on it drifts together, which means correlated failures across your whole fleet on that host.
- The 500-millisecond alert threshold is a starting point, not a law. Token validity windows and certificate lifetimes need tighter bounds; batch analytics can tolerate looser ones. Set the threshold from the decision that depends on it.

## Build It If, Skip It If

Build the offset monitoring if you run more than a handful of machines, issue tokens or certificates, or have ever debugged a timing bug that turned out to be a clock. The minimal viable version fits in an afternoon: install chrony, point it at a reliable source (your cloud provider's time service, such as 169.254.169.123 on AWS), scrape `chronyc tracking` into your metrics, and alert at 500 milliseconds. Then grep your codebase for cross-machine timestamp comparisons and replace the load-bearing ones with monotonic durations or fencing tokens, one at a time.

Skip the full TrueTime treatment unless you are ordering transactions across regions and can already articulate the cost of getting the order wrong. Skip hybrid logical clocks unless you have a real causality bug today; they are a precise tool for a specific problem, not a general upgrade. And skip the urge to "fix" skew by adding slack to every TTL. Slack is the bigger queue of time handling: it converts a fast, diagnosable failure into a slow, mysterious one.

## Stop Trusting the Clock

Pick one service this week and read every place it consults the time. For each one, ask whether it needs a timestamp or a duration, and whether the decision it makes would survive the machine being ninety seconds wrong. Fix the durations with a monotonic clock, fence the writes that must not go stale, and put the offset on a dashboard. Time is the one dependency every distributed system shares and nobody chose. Treat it like the unreliable narrator it is, and your 3 a.m. pages will find something else to be about.

What is the strangest clock-skew bug you have seen in production? I am collecting them, and the best ones always involve a certificate.

## Resources

1. Mills et al., "Network Time Protocol Version 4: Protocol and Algorithms Specification," RFC 5905, June 2010. The offset and delay math, straight from the source.
2. Corbett et al., "Spanner: Google's Globally-Distributed Database," OSDI 2012. Section 3 introduces TrueTime and commit-wait.
3. The chrony project documentation: chrony.tuxfamily.org. `chronyc tracking` and `chronyc sources` are the two commands that matter.
4. AWS, "Set the time for your EC2 instance" (Time Sync Service, 169.254.169.123). The same pattern exists on GCP and Azure under different names.

