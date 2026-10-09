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
