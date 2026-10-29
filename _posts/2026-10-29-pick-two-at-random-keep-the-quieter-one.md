---
layout: post
title: "Pick Two at Random, Keep the Quieter One"
date: 2026-10-29 11:11:00 -0400
categories: [Writing]
tags: [Distributed Systems, Load Balancing, Software Engineering]
description: "Pick two servers at random and keep the quieter one. The power of two choices measured: max load 132 vs 102 at an average of 100, the herd failure of a full scan under concurrency, Envoy choice_count, and when a scan or consistent hashing is the better rule."
---

# Pick Two at Random, Keep the Quieter One

*Your fleet average looks calm while one server drowns. One random choice creates that server. A full scan prevents it on paper and recreates it under concurrency. Two random choices get you nearly the scan, at the price of one comparison.*

## The Average Says Fine, the Busiest Server Disagrees

Your dashboard shows a fleet at 100 active requests per server, which reads as a healthy, even system. One server in that fleet is carrying 132. Its queue is the one filling. Its latency is the tail your users feel, its timeouts are the retries your other pieces of infrastructure then amplify, and when it finally sheds load or falls over, its 132 requests land on neighbours that were already at their own average. Nothing about the average was wrong. The average was just never the number that was going to page you.

Tell me about the rule that placed those requests. In a surprising number of systems the answer is one of two extremes, and both look defensible in a design doc. Pick a server at random and send the request there: simple, stateless, no coordination, and completely blind to the fact that the server you picked is already the busiest one in the fleet. Or scan every server, find the least loaded one, and send the request there: optimal by construction, priced at a full scan per request, and correct only for as long as your view of every server is fresh and you are the only balancer holding it.

I understand why teams land on either end. Random is the rule you can implement before lunch and never think about again. The full scan is the rule that wins every benchmark you run from a single test client, because a single client decides one request at a time with perfect, current information. Production is neither of those settings. Production is many balancers, many clients, and load information that is already ageing by the time a decision uses it.

> The question is not how much load information you can gather. The question is how little you can use and still keep the busiest server close to the average.

## The Gap the Two Obvious Rules Skip

Most load balancing explainers present a menu: round robin, random, least connections, consistent hashing, weighted variants. The menu is accurate and it skips the part that matters, which is the size of the penalty each rule pays and where that penalty comes from. Random pays in the maximum, not the average. The full scan pays in coordination, and its perfect result depends on decisions being serialised, which is exactly what a fleet of independent balancers does not give you.

The gap this piece fills is the middle rule and its arithmetic. Pick two servers at random. Send the request to whichever of the two is quieter. That is the whole algorithm, described by Azar, Broder, Karlin, and Upfal in 1999 and surveyed by Michael Mitzenmacher in 2001 under the name it still carries: the power of two choices. The claim sounds too small to matter, one extra sample and one comparison. The measured claim is that the second choice collapses the gap between the busiest server and the average from 32 requests to 2 in the run below, and that a third, fifth, or tenth choice buys almost nothing after it. Two is not a compromise between one and a scan. Two is where nearly all of the value sits.

This is not a historical curiosity, either. Envoy, the proxy underneath a large share of service meshes, implements its LEAST_REQUEST policy this way by default: its documentation describes an O(1) algorithm that selects two random healthy hosts and picks the one with fewer active requests, and its choice_count field defaults to 2. When a production system used at that scale defaults to a number, it is worth understanding what the number is buying.

## Sample Twice, Compare Once

Start with the smallest honest model, the one the original analysis uses. Requests are balls, servers are bins. A request arrives, the rule places it in a bin, and the load of a server is the count of requests it holds. Strip out service times, departures, and request sizes for the moment. If the placement rule cannot balance this stripped model, no amount of production detail will save it, and if it can, you have a baseline to argue from.

Here is the shape of it:

```
  request arrives
        |
        +-- sample server 17: 104 active
        |
        +-- sample server 63:  98 active
        |
        +-- place on server 63, the quieter of the two

  one random choice:   sample once, place blind
  full scan:           read all 1,000 loads, place on the minimum
  two choices:         read 2 loads, place on the smaller
```

A few things are worth noting about this design. First, the rule never needs the global minimum. It needs one comparison between two loads, both of which it just read, so the information it acts on is as fresh as a load reading gets. Second, the busiest server in the fleet is almost never chosen, and that is a property, not a hope: for the busiest server to receive a new request, it must be sampled, and the other sample must be a server at least as busy, which by definition barely exists. Envoy states the same property directly for its implementation: a host with the highest number of active requests will never receive new requests and is left to drain. Third, the randomness is doing coordination work. Two balancers acting at the same instant sample different pairs, so they spread their decisions by construction, without ever talking to each other. A scan gives every concurrent balancer the same answer. Random sampling gives each one a different question.

The theory behind the model is unusually clean. With one random choice and as many requests as servers, the busiest server carries a load that grows like log n over log log n. With two choices, the busiest server sits at about log log n above the average. Read that the practical way: the advantage of the second choice grows with the fleet, and it grows in the exponent. At a thousand servers the difference is a handful of requests in the light run below and a gap of 32 against 2 in the heavy one. At larger fleets the one-choice maximum keeps climbing while the two-choice maximum barely moves.

## Run the Placement Rules and Count the Maximum

Here is the mechanism in runnable Python, standard library only. The full file is p2c_demo.py next to this draft. Parts 1 to 3 place requests with no departures, so the placement rule is the only variable. Part 4 changes the setting to the one production actually has: many balancers deciding at the same instant from the same snapshot.

```python
def place(n_bins, n_balls, choices):
    loads = [0] * n_bins
    for _ in range(n_balls):
        if choices == 0:  # global least loaded, full scan
            pick = min(range(n_bins), key=lambda i: loads[i])
        else:
            cands = [random.randrange(n_bins) for _ in range(choices)]
            pick = min(cands, key=lambda i: loads[i])
        loads[pick] += 1
    return loads
```

Running the demo prints this:

```
== Part 1: 1,000 servers, 1,000 requests, average load 1 ==
one random choice           : max load 5, average 1.00, gap 4.00
two choices                 : max load 3, average 1.00, gap 2.00
three choices               : max load 3, average 1.00, gap 2.00
global least (full scan)    : max load 1, average 1.00, gap 0.00

== Part 2: 1,000 servers, 100,000 requests, average load 100 ==
one random choice           : max load 132, average 100.00, gap 32.00
two choices                 : max load 102, average 100.00, gap 2.00
global least (full scan)    : max load 100, average 100.00, gap 0.00

== Part 3: more choices buy less each time (1,000 x 1,000) ==
choices= 1: max load 6
choices= 2: max load 3
choices= 3: max load 3
choices= 5: max load 2
choices=10: max load 2

== Part 4: the herd, 100 balancers decide from one snapshot ==
global least from a shared snapshot: server 42 ends at 100
two choices from the same snapshot:  max server ends at 13, server 42 ends at 1
```

Read the four parts as one argument, including the part that cuts against this piece. Parts 1 and 2 say the full scan wins, and in this serialised toy it does, perfectly: every decision sees every load, updated by the decision before it, so the scan fills servers in exact order. Hold that result honestly, because Part 4 is where it stops describing your system. Give 100 balancers the same snapshot, with one quiet server in it, and the scan sends all 100 arrivals to that one server, which ends at 100 while its neighbours sit at 10. The perfect information was shared, so the perfect decision was a herd. Two choices, reading the same stale snapshot, ends with no server above 13, because each balancer sampled a different pair and most pairs never included the quiet server at all. Staleness did not hurt the sampled rule the way it hurt the scan, since the sampled rule was never claiming to know the fleet in the first place.

Part 2 is the number to take to a design review. At an average load of 100, one random choice leaves a busiest server at 132, which is a third more queue, a third more concurrency, and roughly a third more latency on exactly the server least able to carry it. Two choices hold the maximum to 102. Part 3 then closes the obvious follow-up question before someone proposes sampling half the fleet: going from two choices to ten moves the maximum from 3 to 2. The second choice is the purchase. The rest is decoration with a read cost.

In a real proxy you do not write this loop, you state it. In Envoy the cluster configuration names the policy, and the choice count only needs setting if you want something other than the default:

```yaml
clusters:
  - name: backend
    connect_timeout: 2s
    type: STRICT_DNS
    lb_policy: LEAST_REQUEST
    least_request_lb_config:
      choice_count: 2
    load_assignment:
      cluster_name: backend
      endpoints:
        - lb_endpoints:
            - endpoint:
                address:
                  socket_address: { address: backend, port_value: 8080 }
```

A few things are worth noting about this example. First, choice_count defaults to 2 in Envoy, so the block above is documentation as much as configuration: it records that the team chose the sampled rule on purpose. Second, the load Envoy compares is active requests, a live count at the proxy, not a scraped CPU figure that is seconds old by the time it arrives. The fresher and cheaper your load signal, the better a two-sample comparison works. Third, weights change the behaviour: Envoy notes that when host weights differ, its least request policy shifts away from the pure two-choice form into a weighted schedule, so a weighted fleet is not running quite the algorithm the demo measures. Know which mode your configuration actually selects.

## Where This Breaks

Say the limits plainly, because a rule this cheap invites overclaiming:

- Active requests is a proxy for load, not load itself. Two servers with five active requests each are not equally busy if one is serving health checks and the other is serving report exports. The rule balances the count you give it. Give it the wrong count and it will balance that, precisely.
- Two choices assume the samples are independent. Balancers that share a seed, a deterministic sampler, or a heavily restricted subset can sample the same pairs and quietly rebuild the herd the randomness was supposed to prevent.
- The benefit shrinks with the fleet. With three servers, two choices sample most of the fleet and the rule is a slightly randomised scan, with a scan-like cost and little mystery left. The arithmetic earns its keep at tens of servers and up.
- Sticky and stateful work does not belong here. If a request must reach the server holding its session or its cache shard, placement is a routing question first. That is the consistent hashing problem, and sampling against it destroys the locality the routing existed to create.
- A draining or failing server must leave the sample set, not merely look busy. Sampling only chooses between the hosts it is offered. Health checking and outlier ejection decide the offered set, and a dead server that stays in it will keep winning its share of comparisons against busy live ones if its active count reads zero.
- Heterogeneous servers break the symmetry the model assumes. A server twice as fast should carry roughly twice the load, and the plain rule has no way to know that. Weighted variants exist, and as the Envoy note above shows, they change the algorithm, not just a parameter.

## Decide How Much Load Information You Actually Need

Build it if:

- You place stateless requests across tens or hundreds of comparable servers, and your current rule is plain random, plain round robin, or a scan whose cost or staleness you have started to notice.
- Your balancers are numerous and independent, such as sidecars or client-side balancers, where no single decider holds a fresh global view and a shared global view would be a herd waiting to happen.
- You can read a cheap, live load signal at decision time. Active requests at the proxy is the standard one and it is good enough for the effect measured above.

Skip it if:

- Your fleet is a handful of servers behind one balancer with fresh state. Scan them. The full scan is affordable and exact at that scale, and Part 1 of the demo is your honest result.
- Placement must respect keys, sessions, or shards. Solve the routing problem with consistent hashing first and balance inside that constraint only if the constraint leaves you a choice to make.
- Your real problem is that requests have wildly different costs. No placement rule fixes a cost problem. Measure request cost, split the expensive work onto its own pool, and then balance each pool.

The minimal viable version fits in an afternoon: take your existing random or round robin placement for one stateless service, sample two hosts instead of one, compare active requests, and log the maximum and the average load per server for a week on each rule. The average will not move, and anyone who judges the change by the average will call it a wash. Judge it by the gap between the busiest server and the average, and by the tail latency of the busiest server, because those are the numbers the second choice is buying down.

## Judge the Balancer by Its Busiest Server

No user ever experienced your fleet average. Every user experienced one server, and the users you hear from experienced the busiest one at the busiest moment. A load balancer should be judged the same way: not by how even its placements look in aggregate, but by how far its most loaded server drifts from the rest and what that drift costs in queueing and retries. One random choice lets that drift grow with your fleet. One extra sample, chosen at random and compared honestly, holds it to a few requests, and it does so without a coordinator, without a global view, and without asking any other balancer what it is doing. Pick two, keep the quieter one, and measure the maximum for a week before you argue about a third choice.

When you last looked past the average, how far ahead of the fleet was your busiest server, and which placement rule put it there?

## Resources

1. [Azar, Broder, Karlin, and Upfal: Balanced Allocations (SIAM Journal on Computing, 1999)](https://epubs.siam.org/doi/10.1137/S0097539795288490)
2. [Mitzenmacher: The Power of Two Choices in Randomized Load Balancing (IEEE Transactions on Parallel and Distributed Systems, 2001)](https://www.eecs.harvard.edu/~michaelm/postscripts/tpds2001.pdf)
3. [Envoy documentation: Load balancers, least request and the power of two choices](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/load_balancing/load_balancers)
4. [Envoy API: LeastRequest load balancing policy, choice_count defaults to 2](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/load_balancing_policies/least_request/v3/least_request.proto.html)
5. [Adding One Node Should Not Move Ninety Percent of Your Keys](https://anushamukka.com/posts/adding-one-node-should-not-move-ninety-percent-of-your-keys/)
6. [Your p99 Is a Product Decision](https://anushamukka.com/posts/your-p99-is-a-product-decision/)
