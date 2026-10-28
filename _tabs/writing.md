---
layout: page
icon: fas fa-pen-nib
order: 1
title: Writing
description: "Essays and technical writing by software architect Anusha Mukka on AI infrastructure, distributed systems, and security architecture."
seo:
  type: WebPage

---

## Featured
**[A Bloom Filter Lies in One Direction Only](https://anushamukka.com/posts/a-bloom-filter-lies-in-one-direction-only/)** · by Anusha Mukka

Ten thousand keys fit in ten kilobytes, and the structure sometimes says yes when the answer is no. It never says no when the answer is yes. On the sizing formula, the optimal number of hash functions, measured error rates, silent overfill, and why you cannot delete from a plain filter.

**[Ship Hashes, Not Rows: Merkle Trees Find the Replica That Drifted](https://anushamukka.com/posts/ship-hashes-not-rows/)** · by Anusha Mukka

Two replicas diverged over a weekend and nobody can list the records that moved. On anti-entropy with Merkle trees: bucket hashes, a walk that finds seven bad records in seventeen comparisons, and repair that ships the records that changed instead of the dataset.

**[Keeping Both Versions Is Not a Merge](https://anushamukka.com/posts/keeping-both-versions-is-not-a-merge/)** · by Anusha Mukka

Two replicas increment the same counter during a partition and the obvious merge loses one of them. On conflict-free replicated data types: per-replica counter slots, add-wins sets where you can only remove what you have seen, convergence in any merge order, and the invariants no CRDT can enforce.

**[Your Timestamps Cannot Order Your Writes](https://anushamukka.com/posts/your-timestamps-cannot-order-your-writes/)** · by Anusha Mukka

Two replicas can disagree about which write came last, and both can be telling the truth about their own clocks. On Lamport's happened-before relation, vector clocks that return before, after, or concurrent, and keeping both versions instead of losing one quietly.

**[Your Failure Detector Cannot Tell Dead From Slow](https://anushamukka.com/posts/your-failure-detector-cannot-tell-dead-from-slow/)** · by Anusha Mukka

Silence is the only signal a heartbeat gives you, and a crashed node and a paused node are silent in exactly the same way. On fixed timeouts, the phi accrual detector in Cassandra and Akka, and choosing a threshold from the cost of being wrong in each direction.

**[Your Commit Is a Promise About a Log, Not About Your Tables](https://anushamukka.com/posts/your-commit-is-a-promise-about-a-log/)** · by Anusha Mukka

Postgres can lose every changed data page in a crash and still keep its promise to you. It cannot lose the log. On write-ahead logging: log before data, log before acknowledgment, and the two rules under every durability promise.

**[You Cannot Update a Database and a Queue in One Breath](https://anushamukka.com/posts/you-cannot-update-a-database-and-a-queue-in-one-breath/)** · by Anusha Mukka

Your order row committed. Your event never left the building. On the dual-write problem and the transactional outbox: write the event in the same transaction as the state, let a relay publish at least once, and pair it with a consumer inbox so duplicates cannot apply twice.

**[Your Timeout Is Not a Deadline](https://anushamukka.com/posts/your-timeout-is-not-a-deadline/)** · by Anusha Mukka

Your client gave up at two seconds. Your database kept working for nine. On timeouts versus deadlines: one budget created at the edge, carried with the request, checked before work starts, and used to refuse work that cannot finish in time.

**[Adding One Node Should Not Move Ninety Percent of Your Keys](https://anushamukka.com/posts/adding-one-node-should-not-move-ninety-percent-of-your-keys/)** · by Anusha Mukka

Adding one cache node out of ten should not send 90 percent of your keys to new owners. On hash modulo as a reshuffle button, and consistent hashing: the ring, virtual nodes, and bounded load that move only the keys next door.

**[Your p99 Is a Product Decision: Hedged Requests and the Long Tail](https://anushamukka.com/posts/your-p99-is-a-product-decision/)** · by Anusha Mukka

Your p50 is 40ms and your p99 is 11 seconds, and both are true. On the fan-out arithmetic that makes the tail the median experience, and hedged requests: the deliberately impatient client policy that trades one extra request for a forty-fold cut in tail latency.

**[Your Election Crowned Two Kings](https://anushamukka.com/posts/your-election-crowned-two-kings/)** · by Anusha Mukka

Your leader election worked and crowned two leaders anyway. On zombie leaders, the split-brain window every system has, and fencing tokens: the storage-side integer that rejects a deposed leader's writes without it ever learning it was deposed.

**[Your Prompt Filter Passed and the Attack Still Ran](https://anushamukka.com/posts/your-prompt-filter-passed-and-the-attack-still-ran/)** · by Anusha Mukka

Salt Labs hid a prompt inside an email, encoded it as JSFuck, and the Manus agent decoded it and ran the code server-side. On why the prompt filter flagged the attack and lost anyway, and the deny-by-default tool gate that is the real boundary.

**[Your Prompt Template Is a Code Execution Surface](https://anushamukka.com/posts/your-prompt-template-is-a-code-execution-surface/)** · by Anusha Mukka

GitLab's CVE-2026-90970 let an authenticated user with basic privileges escape the AI Gateway's prompt template sandbox and run arbitrary commands. On the template boundary nobody audits, why sandboxes fail, and the afternoon-sized hardening pass for your own stack.

**[Two-Phase Commit Is a Promise No One Can Keep](https://anushamukka.com/posts/two-phase-commit-is-a-promise-no-one-can-keep/)** · by Anusha Mukka

When the coordinator dies mid-commit, the participants hold their locks forever. On the blocking window every explainer mentions and none of them replace, why no protocol variant closes it, and the saga pattern that does: sequential local transactions with compensating actions, a durable journal, and a runnable Python orchestrator.


**[Stop Trying to Invalidate Your Cache. Budget the Staleness Instead.](https://anushamukka.com/posts/stop-trying-to-invalidate-your-cache/)** · by Anusha Mukka

Cache invalidation cannot be perfect in a distributed system, so stop chasing it. On the delete-versus-in-flight-read race every explainer skips, and four mechanisms that honor an explicit staleness budget: TTLs with jitter, versioned keys, request coalescing, and stale-while-revalidate.

**[Your Servers Disagree About What Time It Is](https://anushamukka.com/posts/your-servers-disagree-about-what-time-it-is/)** · by Anusha Mukka

Clock skew is the quiet bug behind sessions that expire early, charges that appear twice, and certificates valid nowhere. On NTP's real guarantees, TrueTime's commit-wait, fencing tokens, and the afternoon-sized monitoring setup that catches drift before it pages you.

**[Backpressure: The Load-Shedding You Skip Until the Outage](https://anushamukka.com/posts/backpressure-the-load-shedding-you-skip-until-the-outage/)** · by Anusha Mukka

Queues do not absorb load. They schedule the outage for later, with interest. On bounded queues, 503 with Retry-After, adaptive concurrency limits, and the afternoon-sized backpressure policy.

**[Never Let the Confined Process Dial Home](https://anushamukka.com/posts/never-let-the-confined-process-dial-home/)** · by Anusha Mukka

CVE-2026-82533 let DeepSeek's sandboxed coding agent switch off its own sandbox with a single request to localhost. On the design lesson behind the flaw: a confinement boundary that the confined party can call is not a boundary.

**[Policy-as-Code for AI Systems: Governance at Infrastructure](https://dzone.com/articles/policy-as-code-for-ai-systems-enforcing-governance)** · by Anusha Mukka

Your AI governance policy shouldn't be a document. It should be code. On turning every governance assertion into a machine-enforced gate: at training time, at the serving gateway, and in continuous runtime monitoring. Editorially reviewed and published on DZone. [Read the article by Anusha Mukka on DZone](https://dzone.com/articles/policy-as-code-for-ai-systems-enforcing-governance).

**[Your Firewall Doesn't Speak LLM! We Gave AI Agents the Keys. Nobody Asked If the Locks Still Work.](https://medium.com/@anusha_mukka/we-gave-ai-agents-the-keys-nobody-asked-if-the-locks-still-work-131a7085ab1e)**

On agentic AI and the security assumptions it quietly breaks. [Read on Medium](https://medium.com/@anusha_mukka/we-gave-ai-agents-the-keys-nobody-asked-if-the-locks-still-work-131a7085ab1e).

## Tutorials

Hands-on walkthroughs you can build in an afternoon. Each one starts from a real failure, gives you runnable code, and tells you honestly where the approach breaks. [Browse all tutorials](/tutorials/)

{% assign tutorials = site.posts | where_exp: "post", "post.categories contains 'Tutorials'" %}
{% for post in tutorials %}
- [{{ post.title }}]({{ post.url }})
{% endfor %}

## On this site

{% for post in site.posts %}
{% unless post.categories contains 'Tutorials' %}
- [{{ post.title }}]({{ post.url }})
{% endunless %}
{% endfor %}

## On DEV Community

I also publish on [DEV Community](https://dev.to/anusha_mukka) - essays on scale, security, and the craft of building systems that hold up.

- [The Admin Script That Became a Security System](https://dev.to/anusha_mukka/the-admin-script-that-became-a-security-system-1ljm)
- [Your Cache Is Part of the Security Model](https://dev.to/anusha_mukka/your-cache-is-part-of-the-security-model-44n2)
- [Stop Returning "Access Denied"](https://dev.to/anusha_mukka/stop-returning-access-denied-197b)
- [The Retry That Restored Access](https://dev.to/anusha_mukka/the-retry-that-restored-access-3cec)
- [The Policy Was Right. The Data Wasn't.](https://dev.to/anusha_mukka/the-policy-was-right-the-data-wasnt-2meb)
- [From Policy to Pipeline: Making Compliance an Engineering Property](https://dev.to/anusha_mukka/from-policy-to-pipeline-making-compliance-an-engineering-property-35ap)
- [Data Is the Real Model: Governance, Lineage, and Provenance](https://dev.to/anusha_mukka/data-is-the-real-model-governance-lineage-and-provenance-1eo3)
- [Securing AI Agents: Containment Over Trust](https://dev.to/anusha_mukka/securing-ai-agents-containment-over-trust-2mp0)
- [You Can't Secure What You Can't See: Shadow AI and the Inventory Problem](https://dev.to/anusha_mukka/you-cant-secure-what-you-cant-see-shadow-ai-and-the-inventory-problem-kd4)
- ["Don't Learn to Code" Is the Worst Career Advice of 2026](https://dev.to/anusha_mukka/dont-learn-to-code-is-the-worst-career-advice-of-2026-k4l)
- [The Illusion of Scale, Part 5: The System That Outlives the Team](https://dev.to/anusha_mukka/the-illusion-of-scale-part-4-the-system-that-outlives-the-team-part-5-38lh)
- [The Illusion of Scale, Part 4: Latency Is a Design Decision, Not a Measurement](https://dev.to/anusha_mukka/the-illusion-of-scale-part-4-latency-is-a-design-decision-not-a-measurement-1h4n)
- [The Illusion of Scale, Part 3: Access Control Doesn't Scale Linearly](https://dev.to/anusha_mukka/access-control-doesnt-scale-linearly-part-3-33h6)
- [The Illusion of Scale, Part 2: When Your Data Model Becomes Your Bottleneck](https://dev.to/anusha_mukka/when-your-data-model-becomes-your-bottleneck-part-2-3b6m)
- [The Illusion of Scale, Part 1: When Your "Scalable" System Isn't](https://dev.to/anusha_mukka/the-illusion-of-scale-part-1-when-your-scalable-system-isnt-1337)
- [When the Cloud is Too Slow: Enter Fog Computing](https://dev.to/anusha_mukka/when-the-cloud-is-too-slow-enter-fog-computing-2egh)
- [Exactly-Once Delivery Is a Lie. Idempotency Keys Are the Practical Answer.](https://dev.to/anusha_mukka/exactly-once-delivery-is-a-lie-idempotency-keys-are-the-practical-answer-3351)
- [Your Agent Took an Action You Did Not Intend](https://dev.to/anusha_mukka/your-agent-took-an-action-you-did-not-intend-2koi)
- [Your Agent Reads Your Database. Your Attacker Writes to It.](https://dev.to/anusha_mukka/your-agent-reads-your-database-your-attacker-writes-to-it-57l9)
- [Your Attacker Runs an Agent Too: Detecting Agent-Shaped Attacks](https://dev.to/anusha_mukka/your-attacker-runs-an-agent-too-detecting-agent-shaped-attacks-4p6n)
- [Consensus Is the Most Expensive Word in Your Architecture](https://dev.to/anusha_mukka/consensus-is-the-most-expensive-word-in-your-architecture-2npd)
- [Your Guardrail Cannot Read What Your Agent Is About to Run](https://dev.to/anusha_mukka/your-guardrail-cannot-read-what-your-agent-is-about-to-run-3eci)
- [Your Agent Should Not Borrow Your API Key](https://dev.to/anusha_mukka/your-agent-should-not-borrow-your-api-key-3gi2)
- [Your Agent Forgot What It Did: Build an Audit Trail It Cannot Edit](https://dev.to/anusha_mukka/your-agent-forgot-what-it-did-build-an-audit-trail-it-cannot-edit-349h)
- [Your Rate Limiter Is a Stampede at the Window Boundary](https://dev.to/anusha_mukka/your-rate-limiter-is-a-stampede-at-the-window-boundary-16ga)
- [Your Agent Platform Fails Open: No Identity Provider Should Mean No Access](https://dev.to/anusha_mukka/your-agent-platform-fails-open-no-identity-provider-should-mean-no-access-2bil)
- [One Prompt Took Over Every Agent in the Account: The Default Role Is the Blast Radius](https://dev.to/anusha_mukka/one-prompt-took-over-every-agent-in-the-account-the-default-role-is-the-blast-radius-2h4l)
- [Your Eval Harness Is a Production Agent You Forgot to Secure](https://dev.to/anusha_mukka/your-eval-harness-is-a-production-agent-you-forgot-to-secure-1c0l)
- [Revocation Is the Real Test: If You Cannot Kill One Agent in Minutes, You Never Controlled It](https://dev.to/anusha_mukka/revocation-is-the-real-test-if-you-cannot-kill-one-agent-in-minutes-you-never-controlled-it-5e0a)
- [The Subagent Talked Its Way Onto Your Task: Assignment Is Not a Prompt](https://dev.to/anusha_mukka/the-subagent-talked-its-way-onto-your-task-assignment-is-not-a-prompt-f1b)
- [The Agent Logged In as You: A Session Is Not an Instruction](https://dev.to/anusha_mukka/the-agent-logged-in-as-you-a-session-is-not-an-instruction-3iog)
- [Denied Is Not a Stop Sign If Another Key Is in the Room](https://dev.to/anusha_mukka/denied-is-not-a-stop-sign-if-another-key-is-in-the-room-hc)
- [The Agent Turned Off Its Own Alarm: Put the Monitor Outside the Agent's Reach](https://dev.to/anusha_mukka/the-agent-turned-off-its-own-alarm-put-the-monitor-outside-the-agents-reach-52i2)
