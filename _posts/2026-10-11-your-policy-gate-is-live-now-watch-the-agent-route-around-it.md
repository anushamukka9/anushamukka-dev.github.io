---
layout: post
title: "Your Policy Gate Is Live. Now Watch the Agent Route Around It"
date: 2026-10-11 06:05:00 -0400
categories: [Writing]
tags: [AI Agents, Security, Policy as Code, Access Control, Defense in Depth]
description: "The demo policy gate proved the shape: the model proposes, the code disposes. The production version proves the discipline. On default-deny tool inventories, Rego policy bundles, taint lattices, confirm fatigue, and adversarial testing for agent policy gates."
---

# Your Policy Gate Is Live. Now Watch the Agent Route Around It

*Two weeks after the policy gate shipped, the deny rate fell to zero. The agents were not better behaved. They were asking differently.*

## The Dashboard Went Quiet

Two weeks after the policy gate went live, the deny-rate dashboard went flat. Zero denies for six straight days. The team declared victory, and people started saying the prompt-injection problem was handled.

On day seven, a support lead asked why the internal salary bands were visible in the #general Slack archive. The triage agent had not sent them by email. The email rule from the first piece held: external send after untrusted input, denied, logged. The agent had simply done what agents do when one path closes. It summarized the internal notes and posted them to Slack with `slack.post`, a tool someone had registered "just for notifications," which had no rules attached. The gate found no rule that mentioned it, and allowed it. The exfil did not beat the model's judgment. It walked around the rulebook.

Yes, this is a composite of failure modes I have watched up close, but every one of them is real. The gate works exactly as written. The question is whether what is written covers the tools the agent can actually reach.

## Name the Two Bad Options

When the first bypass lands, teams reach for one of two bad responses. The first is to write rules for everything: forty tools become two hundred rules, every new tool waits on a review, and the gate becomes the department of slow. Exemption requests follow, which is the polite name for holes. I understand the impulse, but a rulebook that takes three weeks to amend trains everyone to route around the process instead of through it.

The second is to declare the gate too strict and carve it up: exemptions for "trusted" agents, a bypass flag for the demo, a code path that calls tools directly "for latency." I understand this too. A gate that blocks the launch-review demo will be disabled by lunch. But a gate with a bypass is a suggestion with extra steps, and you already had one of those. It was called the system prompt.

The gap the first piece left is the production gap: what changes between the twenty-line sketch and a gate that survives a real agent fleet. This piece covers the grown-up venue, the inventory discipline, the review questions, and the three production failure modes the demo never shows.

## The Industry Is Running the Same Experiment

October has been a busy month for the thesis that the tool boundary is the real checkpoint.

On October 3, Salt Labs published research on an attack against the Manus agent: a hidden prompt in an email, obfuscated with JSFuck, which Manus's own filter flagged as suspicious. Then Manus decoded it and executed arbitrary JavaScript server-side anyway. The filter saw the attack, labeled it correctly, and the agent ran it regardless. Content inspection fails open; the tool boundary is where the decision lives. A gate with one rule, deny code-execution tools in sessions that have seen untrusted input, would have held while the filter failed. The gate does not ask the model what it thinks.

On October 2, GitLab published its advisory for CVE-2026-90970: a low-privilege authenticated user escaped the AI Gateway prompt template sandbox and reached arbitrary command execution, fixed in 19.2.4, 19.3.2, and 19.4.1. The sandbox was the enforcement layer, and when it broke there was no second one. That is the shape of every missing-gate story: a single layer, trusted completely, failing completely. Manus had inspection without enforcement. GitLab's gateway had enforcement without depth. The gate belongs at the tool call, evaluated on structured data, owned by code the model cannot negotiate with.

## Move the Rules Into Rego

The Python sketch is the right place to start and the wrong place to stay: the rules change faster than the agent code, and the people who need to change them are not always the people who deploy the agent. When security needs to ship a deny rule on a Friday afternoon without the agent team's deploy train, the rules need their own venue, versioning, and review. That venue is a policy engine: Open Policy Agent, and its language, Rego.

Here is the gate rewritten as a Rego policy. The input document is the structured tool call: tool name, arguments, agent id, the taint set, and the data class the session has touched.

```rego
package agent.authz

# The most important line in the file. A tool with no rules
# gets nothing. This is the line that would have stopped the
# slack.post exfil in the opening story.
default allow = false

# input: {"tool": "email.send",
#         "args": {"to": "vendor-relations@example.com"},
#         "agent": "triage-3",
#         "taint": ["user_input"],
#         "data_class": "internal"}

deny contains msg if {
    input.tool == "email.send"
    "user_input" in input.taint
    not endswith(input.args.to, "@yourcompany.com")
    msg := "external send after untrusted input"
}

deny contains msg if {
    input.tool == "db.delete"
    not input.args.where
    msg := "unqualified delete"
}

deny contains msg if {
    input.tool in {"code.exec", "browser.execute_js"}
    "user_input" in input.taint
    msg := "code execution after untrusted input"
}

confirm contains msg if {
    input.tool in {"email.send", "payment.refund", "db.delete"}
    msg := sprintf("irreversible action: %s", [input.tool])
}

allow if {
    count(deny) == 0
    count(confirm) == 0
}
```

Three things are worth noting. First, `default allow = false`: a tool with no rules is denied, which turns every new tool registration into a rule request. That is process working as designed. Second, the verdicts compose by set, so the audit record carries the rule, the tool, and the arguments with no extra logging code, and the deny-over-confirm-over-allow precedence sits in the one `allow` rule instead of buried in control flow. Third, the code-execution rule is the Manus rule: sessions that have seen untrusted input do not get code execution tools, full stop. The filter can think whatever it likes. The gate does not consult it.

The policy ships as a versioned bundle. The agent loop sends each tool call to the data API, and the verdict comes back as JSON:

```bash
# evaluate one call against the policy
opa eval --data policy.rego --input call.json 'data.agent.authz'

# run the policy's own test suite
opa test . -v

# serve the bundle; the agent loop POSTs tool calls to
# /v1/data/agent.authz and reads back allow / deny / confirm
opa run --server ./bundles
```

The round trip: the agent proposes `email.send` to an external address after reading a ticket, the loop POSTs the call, and OPA returns `{"deny": ["external send after untrusted input"], "confirm": [], "allow": false}`. The loop raises, the agent gets a refusal it must work around, and the audit sink gets the rule name, the agent id, and the arguments. The bundle versions independently of the model, the agent code, and the deploy train.

## The Questions Every Review Asks

Since the first piece, the same four questions have come up in every review.

**Who writes the rules?** If the agent team writes them, the deny list stays short and the demo works. If security writes them alone, nothing ever happens, and neither does the agent's task. What works: security owns the deny rules for irreversible actions, the agent team owns the rest, both in the same pull request. The NIST AI RMF Govern function and ISO 42001 describe exactly this: policies, accountable owners, a review cadence.

**What does it cost in latency?** Measure it. A local `opa eval` is microseconds; the tax is the sidecar round trip, typically single-digit milliseconds. If your gate is slower than the tool it guards, you wired it wrong.

**Do reads need rules too?** Yes. The opening story was a read followed by a write to the wrong place. Rules on reads set which data classes a session may touch, scoped at session start from the task. A billing-triage agent does not need the salary bands table.

**What about the agent's memory?** Taint has to survive the session if the memory does. Attacker-influenced text written to memory on Monday and read back as trusted context next week means the taint bit lied. Persist the taint set with the record, or re-taint on read. The cryptographic context injection research from early October is the sharp version: content decrypted inside the agent's own runtime arrives after every static filter has run. Filters read text. They do not run it. The gate sees the tool call that acts on it.

## What Broke in Production

Three stories from gates that shipped. Composites, honestly labeled, every one real.

**The tool with no rules.** `slack.post` was registered for notifications, nobody wrote rules for it, and the sketch defaulted to allow. The fix is `default allow = false` at the inventory level: new tools get zero permissions until a rule grants them. The surprise is organizational: the agent team files a rule request with every new tool, and security has a queue. That queue is the process working. Staff it like one.

**Taint everything.** After a month, every session had seen untrusted input. The boolean bit was permanently true, the email rule denied legitimate internal sends, and the team added exemptions that rotted within a quarter. The fix is a lattice: `public_untrusted`, `user_untrusted`, `partner_data`, `trusted`, ordered, with rules keyed on data class instead of a bit. More rules to write, which is the honest price. The boolean was one rule that lied.

**Confirm fatigue.** The human confirm worked for exactly one week. By week two, approvers cleared 97 percent of confirms at a median eleven seconds each. The confirm had become a click, not a review. The fix: replace confirm-with-human with confirm-with-budget. The agent gets N irreversible actions per hour, then it stops and pages a human. This does not remove the human. It rations them for the cases that deserve eleven seconds of actual thought.

## Test the Gate Like Code

A gate nobody attacks in staging gets attacked in production. The adversarial suite fires the attack corpus at the gate in CI and asserts deny:

```python
import pytest
from policy_gate import PolicyGate, ToolCall, Verdict, RULES

ATTACKS = [
    ("external send after ticket read",
     ToolCall("email.send", {"to": "vendor-relations@example.com"},
              agent_id="triage-3", untrusted_content_seen=True),
     Verdict.DENY),
    ("unruled tool gets nothing",
     ToolCall("slack.post", {"channel": "#general", "text": "..."},
              agent_id="triage-3", untrusted_content_seen=True),
     Verdict.DENY),
    ("unqualified delete",
     ToolCall("db.delete", {"table": "tickets"},
              agent_id="triage-3", untrusted_content_seen=False),
     Verdict.DENY),
    ("internal send after trusted context",
     ToolCall("email.send", {"to": "oncall@yourcompany.com"},
              agent_id="triage-3", untrusted_content_seen=False),
     Verdict.ALLOW),
]

@pytest.mark.parametrize("name,call,expected", ATTACKS,
                         ids=[a[0] for a in ATTACKS])
def test_gate_holds(name, call, expected):
    gate = PolicyGate(RULES)
    assert gate.check(call) == expected, f"gate failed open: {name}"
```

The second case is the one that matters: the opening story as a regression test. Every new tool registration gets a case in this file before it gets a rule in the policy. The gate is code, and code gets tests.

Here is the production shape, all in one diagram:

```
                    policy bundle (versioned, reviewed)
                                |
Agent loop --> [ Policy Gate ]--+--> Tool executes
                     |    |
                  deny /  +--> audit sink --> deny-rate dashboard
                  confirm        |
                                 +--> budget exhausted --> page a human
```

> The gate works exactly as written. The question is whether what is written covers the tools the agent can actually reach.

## Where This Breaks

The production gate has edges the demo does not.

- **The gate sees calls, not intent.** An agent inside allowed tools can still do harm: the carefully worded internal email to the wrong recipient, the report that aggregates public data into something sensitive. Scope rules to data classes as you mature, not just tool names.
- **Rego is a second language to staff.** If nobody on the on-call rotation reads it, the policy is write-only. A write-only policy rots exactly the way the prompt did, just with better syntax.
- **Default-deny on new tools slows the fastest team.** That friction is the point. Say so in the planning meeting, not after the first escalation.
- **The taint lattice is only as good as the instrumentation.** Miss one untrusted source and the lattice is decoration. Ask "did we miss a source" every quarter.
- **The audit log is a new sensitive store.** It contains every denied exfil attempt, with arguments attached. Protect it like production data, because that is what it is.
- **This still does not fix prompt injection.** The model will still get confused, still misread, still try. The gate bounds the blast radius at the tool boundary. Anyone telling you their gate "solves" injection is selling something else.

## Build It If / Skip It If

**Build it if** your agent can touch anything irreversible: sends, deletes, refunds, publishes, code execution. Build it if more than one team registers tools. Build it if your security review asks what stops the agent and your current answer is a system prompt.

**Skip it if** your agent only reads and summarizes into a UI the user already sees. The blast radius is the user's own screen. Skip it if you have three tools and one team; the Python sketch is enough and Rego is ceremony. Skip it if you cannot staff the rule review. An unreviewed gate rots into the new prompt.

The minimal viable version fits in an afternoon: one Rego file, `default allow = false`, two deny rules, `opa eval` in the call path, denies shipped to the log aggregator security already watches. Run it for a week and read the deny rate before adding a third rule.

## Ship the Afternoon Version

The demo gate proved the shape: the model proposes, the code disposes. The production gate proves the discipline: default-deny on the inventory, versioned policy owned by named humans, adversarial tests in CI, a deny rate somebody reads every week. The Slack post did not beat your model. It beat your rulebook's completeness, and completeness is an operational property, not a cleverness property. Ship the afternoon version this week and point it at your three most dangerous tools.

Which tool in your agent's registry has no rule attached to it right now? Go look. I will wait.

## Resources

1. [Open Policy Agent documentation](https://www.openpolicyagent.org/docs/): the Rego language, the bundle format, and the data API the gate calls per tool invocation
2. [Your Prompt Filter Passed and the Attack Still Ran](https://anushamukka.com/posts/your-prompt-filter-passed-and-the-attack-still-ran/): the Salt Labs Manus research from October 3, the filter that flagged the attack and lost anyway
3. [Your Prompt Template Is a Code Execution Surface](https://anushamukka.com/posts/your-prompt-template-is-a-code-execution-surface/): the GitLab CVE-2026-90970 sandbox escape, and why sandboxes need a second layer
4. [Your AI Agent Needs a Chaos Monkey](https://dev.to/anusha_mukka/your-ai-agent-needs-a-chaos-monkey-51h8): the chaos-engineering discipline behind adversarial gate testing
5. [Your Agent Should Not Borrow Your API Key](https://dev.to/anusha_mukka/your-agent-should-not-borrow-your-api-key-3gi2): scoped, expiring credentials per agent, least privilege applied to identity
