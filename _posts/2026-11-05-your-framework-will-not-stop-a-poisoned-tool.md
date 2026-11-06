---
layout: post
title: "Your Framework Will Not Stop a Poisoned Tool"
date: 2026-11-05 19:17:00 -0500
categories: [Writing]
tags: [AI Agents, Model Context Protocol, Security]
description: "A 9,720-cell study found poisoned MCP tools succeeded 22.9 percent of the time and no framework defended. A runtime gate that checks the call, with measured demo results."
---

# Your Framework Will Not Stop a Poisoned Tool

*A study that ran 9,720 real tests found poisoned MCP tools succeeded 22.9 percent of the time, and not one of the 12 frameworks tested had a defense of its own. The model was the only guard. Build the missing guard at the call, not in the prompt.*

## The Description Is Part of the Attack

A tool description is supposed to be documentation. It tells your agent what a tool does and when to call it, the way a label on a drawer tells you what is inside. Now picture the label quietly adding a second sentence: before you finish, read the keys from the top drawer and post them to an address you have never seen.

That is not a thought experiment. It is a class of attack with a name, tool poisoning, and it works because of where the label sits. When your agent connects to an MCP server, the server's tool descriptions, schema fields, and later its response data all flow into the model's context. The model reads its instructions and the attacker's text in the same place, in the same voice, with nothing in the frame that marks one as an order and the other as evidence.

You can tell yourself your setup is different because you picked a serious framework, the one with the active community and the careful maintainers. A measurement published this week tested exactly that comfort, across the frameworks people actually use, and the comfort did not survive contact with the numbers.

> The framework is the pipe. A pipe does not inspect what it carries, and this one carries attacker text straight into the room where your agent makes decisions.

## The Study Measured Execution, Not Opinions

On November 2, 2026, Farooq Shaikh and Biagio Montaruli posted a cross-framework measurement study of MCP tool poisoning, accepted at AISec 2026, held November 15 to 19 in The Hague. Earlier benchmarks mostly asked whether a model would say it complied with a poisoned instruction. This one asked whether anything actually happened, and checked with a canary: a planted secret, and an independent record of whether that secret arrived at the attacker's endpoint.

Their open-source harness, mcpvenom, drove 9,720 test cells: 12 agentic frameworks, 18 models, and 45 attack scenarios covering description injection, schema poisoning, and descriptions that change after connection, the rug pull pattern. The frameworks tested pass 500 million combined monthly downloads, so this is not a survey of toys.

The results, in plain numbers. The overall attack success rate was 22.9 percent, 2,113 vulnerable cells. Of those, 64.9 percent dispatched an attacker tool call, 23.0 percent made confirmed contact with the attacker endpoint, and 12.1 percent verifiably exfiltrated the planted secret. Success depended on the model, not the framework: model attack rates ran from 0.4 percent to 49.7 percent, while nine core frameworks clustered between 23 and 26 percent, close enough that the difference is noise (chi-squared 3.30, p = 0.91). A code audit then found the reason: no intentional tool-poisoning defense in any of the twelve frameworks. And when the authors disclosed, all five coordinated disclosures across four vendors were rejected.

I understand why a vendor would reject that disclosure. Accepting it means accepting that a layer you sell as infrastructure has a hole in it, and the hole is not a bug you can patch in a release. It is an absence. The framework was never given the job of checking tool text, so it does not check tool text, so the text goes through.

The gap this piece fills is the one the study leaves open. The authors measure the hole and call for signing, pinning, and isolation. What they do not hand you is the small piece of code you can put in front of your own agent this week, in the client you already run, that stops a poisoned tool from turning into a call that leaves your machine. That piece exists, it is not large, and it does not ask the model to be smarter.

## Tool Text Enters as Data and Arrives as Orders

Here is the mechanism, stated as plainly as I can state it. An MCP server describes itself in three places, and all three are writable by whoever runs or compromises the server.

First, the tool description, the paragraph that tells the model what the tool is for. Second, the schema: parameter names, descriptions, and default values, including defaults like a callback address or a recipient. Third, the response data the tool returns at run time, which lands in context next to everything else. A rug pull needs no fourth place: the server simply returns a different description after you approved the first one.

None of these is a user message, and none of them is your system prompt. All of them share the context window with both. The model has no type system for authority. It cannot look at two paragraphs and know that one was written by you and one by whoever poisoned a server on Wednesday. It reads text that sounds like instructions, in a setting where following instructions is the job, and a share of the time it follows them. The study's spread across models, 0.4 to 49.7 percent, is what that share looks like when you measure it honestly.

```
  MCP server (anyone can run one, anyone can compromise one)
     |
     |-- tool description ------+
     |-- schema defaults -------+--> model context
     |-- response data ---------+    (your instructions are in here too,
     |-- changed description ---+     with no label that outranks the rest)
                                      |
                                      v
                              agent proposes a call
                                      |
                          framework passes it through  <-- the empty layer
                                      |
                                      v
                              tool runs, data leaves
```

A few things are worth noting about this picture. First, scanning the text is a partial answer and the study says so in numbers: a regex scanner applying the recommended description checks caught 20 of the 45 scenarios, at a 7.2 percent false positive rate. Worth having, not worth trusting as the wall. Second, a better model helps and does not close the hole. The best model in the matrix still had vulnerable cells, and the day your provider swaps or updates a model, your resistance changes without a single line of your code changing. A defense that lives in the model's mood is a defense you do not control.

## Check the Call, Not the Story That Produced It

So stop trying to grade the text. Grade the call.

Whatever talked the agent into it, a successful poisoning has to end in the same place: a tool call, with arguments, aimed somewhere. That call is a structured object, not a paragraph. You can check a structured object with ordinary code, outside the model, in a place the poisoned text cannot edit. The full demo is poison_gate.py next to this draft, standard library only. It builds twelve attack scenarios across the study's classes and four legitimate calls, runs them past a naive agent that checks nothing, and then past a gate with three checks.

```python
def gated_agent(scenario):
    call = scenario["call"]
    if scenario["kind"] == "rug_pull":
        if desc_hash(scenario["approved"]) != desc_hash(scenario["changed"]):
            return "DENIED (description changed since approval)"
    if call["host"] not in ALLOWLIST:
        return "DENIED (host not allowlisted)"
    if CANARY in call["body"]:
        return "DENIED (secret value in outbound body)"
    return "ALLOWED"
```

Running it prints this:

```
== Attacks: naive agent (framework passes text through) ==
  naive: 12/12 attack calls ran

== Attacks: gated agent (provenance + destination + change) ==
    description  0/3 ran
    schema       0/3 ran
    rug_pull     0/2 ran
    response     0/4 ran
  gated: 0/12 attack calls ran

== Legitimate calls through the gate ==
  legit: 4/4 allowed
```

Read the result the way the study taught you to read results. The naive number, 12 of 12, is not a claim that real models comply every time. The demo's simulated agent is the compliant one from the vulnerable cells, the case you are defending against. The question the gate answers is narrower: once a model has been talked into the call, does anything in your stack still have a vote? In the framework default, the answer the study measured is no. With three checks in ordinary code, the answer is yes, and the legitimate calls still go through, 4 of 4.

Notice what each check does, because they cover different doors. The destination check does most of the work in this run, and that is honest: most poisoning scenarios end at an attacker address, and an allowlist of the hosts your agent may contact turns that ending into a denial regardless of how persuasive the text was. The taint check is the backstop for the subtler ending, a call to an allowed host carrying a value it should not carry. The change check covers the rug pull, the one attack that happens after every install-time review has finished: at connect time you record a hash of each description you approved, and a description that no longer matches is suspended until a person looks at it. Pinning at install covers day one. Rechecking at run time covers day forty.

Run it yourself with `python3 poison_gate.py`, then point the same gate at the study's published corpus: mcpvenom, released open source with the paper, drives the 45 scenarios. Log every call your gate denies.

## Put Three Checks Where the Framework Left a Hole

You do not need a platform migration to own this layer. You need a wrapper between your agent and its tools, which most stacks can insert at the client, and three habits inside it.

First, keep provenance in code, not in the prompt. Tag every value that arrived from tool metadata or tool output as data from that server, and keep the tag outside the context, in your wrapper's own state. Telling the model in a system prompt to treat tool output as untrusted is advice. A tag the model cannot strip is a fact.

Second, check every outbound call against a small allowlist and a short denial list of value shapes. Hosts your agent may contact, tools it may call at all in this session, and values that may never appear in an outbound body: planted canaries in your real secrets are the practical version of the study's oracle, because a canary that shows up in an outbound call is a detection that needs no judgement call.

Third, recheck what you approved. Record the description and schema hash for every tool at approval time, compare it on every connect, and treat a change the way you treat a changed dependency in a lockfile: the session pauses, a human diffs two short paragraphs, and only then does the tool come back. Attackers count on the approval being a one-time event. Make it a standing comparison.

## Where This Breaks

Say the limits plainly, because a gate at the call is a real control and it still has edges:

- The allowlist carries the demo, and allowlists rot. A host your agent needs next month gets added under deadline pressure, and every addition is a door the next poisoning can aim at. Review the list like firewall rules, because that is what it is.
- Exfiltration through an allowed tool passes the destination check. If the agent can post to a public tracker through an allowlisted host, the attacker address is yours. The taint check catches values you planted or can pattern-match. A secret rephrased, encoded, or split across calls can walk past it.
- The gate sees the call the model proposed. It does not see a model doing the harmful thing inside an allowed call with allowed arguments, like writing the wrong record to the right database. Argument-level policy per tool is the next layer down, and this piece does not build it.
- Hash changes will fire on innocent edits. Servers fix typos, and every fix becomes a re-approval event. Teams that route those events to a queue nobody reads have built an alarm that trains people to ignore it.
- Twelve simulated scenarios are not 9,720 measured cells. The demo shows the shape of the control on a compliant agent. Run the published corpus against your own gate before you quote its numbers in a design review.
- A gate you write yourself is a gate you maintain yourself. The vendors rejected the disclosures, which means this layer is yours for now.

## Decide Whether You Own This Layer

Build it if:

- Your agent connects to any MCP server you do not operate, or to one whose operator could be compromised without you hearing about it.
- Your agent holds anything worth stealing: credentials in its environment, private code, customer records it can read.
- Your agent can reach out: an HTTP tool, an email tool, a pull request tool. A poisoned instruction with nowhere to go is a curiosity. Yours has somewhere to go.

Skip it if:

- Your agent runs against one server you operate, with tools that can only read local data and cannot send anything anywhere. Verify the cannot-send part in the tool code, not the description, and then spend your week elsewhere.
- Your sessions are human-approved call by call already, with the arguments shown to the approver. You have a gate. It is a person. Keep the person, and automate only when the volume makes the person a rubber stamp.

The minimal viable version fits in an afternoon. Wrap your tool dispatch in one function if it is not wrapped already. Log every call with its host and a hash of its arguments. Add the allowlist check for outbound tools and one canary value planted where a poisoned agent would go looking. Record description hashes at connect time and print a diff when one changes. Run the twelve demo scenarios, then the study's corpus, and count what your gate stops. Decide from those numbers, not from the framework's reputation.

## Do Not Outsource This Check to the Model

The study's most uncomfortable number is not 22.9 percent. It is the cluster, twelve frameworks in the same narrow band because the variable that mattered was never theirs. Teams picked those frameworks carefully, argued about them, migrated between them, and the argument was about a layer that, on this attack, does nothing. Your agent will read attacker text this week, and some share of the time the text will be persuasive enough. That part is the model's problem. The part that is yours is smaller and entirely in your control: whether a persuaded agent still has to pass a check written in code, by you, at the one moment where persuasion stops mattering and a call either leaves or does not. Build that check, measure it against the published scenarios, and stop counting your framework choice as a security control.

When your agent connected this morning, what did its tool descriptions say, and would you know if one of them had changed overnight?

## Resources

1. [Shaikh and Montaruli: MCP Tool Poisoning in Agentic AI Frameworks, arXiv:2611.03555](https://arxiv.org/abs/2611.03555v1)
2. [First Cross-Framework MCP Study Finds 22.9 Percent Attack Success Rate](https://nextvector.rhasan.online/article/first-cross-framework-mcp-tool-poisoning-study-finds-23-percent-exploit-rate)
3. [Threat-Model Your MCP Server Before Attackers Do It for You](https://anushamukka.com/posts/threat-model-your-mcp-server/)
