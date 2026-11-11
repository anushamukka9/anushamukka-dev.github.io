---
layout: post
title: "Your Agent Installs What It Remembers, Not What Is Safe"
date: 2026-11-11 08:47:00 -0500
categories: [Writing]
tags: [AI Agents, Model Context Protocol, Security]
description: "Glow Labs found coding agents installing archived, unpatched MCP servers from training memory, 17.3 million downloads since July 2025. An install gate that checks the registry, with measured demo results."
---

# Your Agent Installs What It Remembers, Not What Is Safe

*Coding agents are installing MCP servers that were archived in May 2025 and will never be patched, because the package name lives in their training data. In the sessions one study reviewed, the name came from the model 98 percent of the time. Check the install against a registry, not against the model's memory.*

## The Package Name Came From Memory

Ask your coding agent to set up a GitHub MCP server. Watch what it types. There is a good chance it writes a config entry for a package it has never looked up, from a repository that was archived a year and a half ago, maintained by nobody, carrying flaws nobody will fix.

Nothing about that moment looks wrong. The package exists. It downloads. It runs. The only record of the choice is a line in a config file neither of you re-reads. The failure is quiet because every step in it worked.

Your supply chain process assumes a human picks a dependency, reads something about it, and types its name into a manifest a scanner can see. An agent skips all three steps. It recalls a name the way you recall a phone number from ten years ago, with total confidence and no check on whether the number still belongs to the same person.

> A model remembers what a package was called. It does not know what happened to the package after its training ended.

## The Study Counted Installs, Not Intentions

On November 2, 2026, Glow Labs, the research team at Glow Security, published a study it named MCPhantom, reported by researcher Nadav Claude Cohen and covered by Help Net Security on November 3. The team reviewed real coding-session transcripts in which a deprecated MCP server got installed or suggested, and asked a simple question: where did the package name come from?

In 98 percent of those sessions, the agent supplied the name itself, from training data. In the remaining 2 percent, the user asked for the old package by name and the agent obliged. The pattern showed up in every harness in the data: Claude Code, Cursor, Codex CLI, Claude Cowork, and Claude chat, running models from Anthropic, OpenAI, and xAI. In the GitHub case, the agent passed over the MCP server GitHub maintains itself and installed the archived reference server instead.

The servers are Anthropic's original reference set from the 2024 MCP launch. Twenty were published as examples. Thirteen are now archived, their repository closed in May 2025 once the services built servers of their own, which is a normal and healthy way for an ecosystem to mature. Archived has a precise meaning here: no security updates, no bug fixes, from that repository, ever.

The scale is what turns a curiosity into a fleet problem. Glow Labs counted 17,352,267 npm downloads of the deprecated set since July 10, 2025, with the GitHub server alone at 5,266,085, and five of the packages still sit in npm's top 100 MCP packages. A separate count from the public npm downloads API put the twelve deprecated packages at 620,838 downloads in the single week of October 27 to November 2, 2026. Glow also reports four high-severity vulnerabilities across these servers. The worst is in the Puppeteer server: a prompt injection on a page the agent visits can make it start an arbitrary process instead of the browser. The permission granted to browse the web ends up covering any command on the machine.

Glow reported the flaws. The maintainers closed them as out of scope, because the repository is archived and unmaintained, and said no fix will come from it. There are no CVEs, so scanners that work from CVE feeds have nothing to match. Glow says it has seen no exploitation so far.

Two honest caveats. First, the 98 percent is a conditional figure: the study looked only at sessions where a deprecated install happened, and it does not publish a session count or sampling design, so it says nothing about how often agents choose correctly overall. Second, the download counts include CI runs and mirrors, so they are not a head count of developers. The harder facts stand without either number: the packages are archived, the flaws are real and unpatched by design, and npx will still install every one of them with nothing more than a warning.

The gap this piece fills is the control point. The coverage so far tells you to go find these servers on your machines, and you should. What it does not hand you is the small check that stops the next install, including one an agent proposes next month for a service you have never thought about. That check is ordinary code, it runs outside the model, and it fits in an afternoon.

## A Model Cannot Know a Package Died

Here is the mechanism, stated plainly. A language model picks a package name the way it picks any other token: by what was frequent and well-regarded in its training data. The reference servers were the canonical examples for a year, in tutorials, in blog posts, in thousands of config files the model trained on. The current official server for a service is, by comparison, recent and thinly documented. Memory wins that contest every time, because memory is all the model has. It does not browse the registry before it answers. It does not check an archived flag. Its training ended, and the ecosystem kept moving.

Now follow the install path and count how many of your existing controls see it:

```
  you: "set up a GitHub MCP server"
     |
     v
  agent recalls a package name from training data
     |
     |-- no registry lookup, no archived check,
     |   no deprecation check, no human pick
     v
  agent writes the name into your MCP config
     |
     v
  npx downloads and runs it   <-- no project manifest,
     |                            so SCA never sees it
     v
  server runs with your token, your filesystem,
  your shell   <-- no CVE exists, so the scanner stays quiet
```

A few things are worth noting about this path. First, there is no manifest. A human adding a dependency edits a package.json that your composition scanner reads on every build. An MCP server launched through npx lives in an agent config file, outside the project, and most scanners never open that file. Second, endpoint tools see a trusted Node process installing a public package at a developer's request, which is Tuesday. Third, deprecation on npm is a label, not a lock: a deprecated package disappears from search results, and npx installs it anyway. Every layer is doing its job. The job descriptions just never included this door.

I understand why nobody built a gate here. Installing a tool server felt like configuring an editor, not like adding a production dependency. The servers run with your credentials and your shell, though, and that makes the config file a dependency manifest whether you treat it as one or not.

## Check the Install, Not the Agent That Asked For It

So stop asking the model to remember better. Check the install.

An install proposal is a structured object: a service, a package name, a version or the absence of one. You can check a structured object with ordinary code, in a place the model cannot talk its way past. The full demo is install_gate.py next to this draft, standard library only. It takes ten setup proposals in the shape the study describes: five agent-recalled archived packages, one archived package the user asked for by name, two approved and pinned installs, one approved package with no version, and one community package nobody reviewed. It runs them past a naive installer that installs whatever it is handed, and then past a gate with three checks.

```python
def gated_install(proposal):
    service, package, version, _source = proposal
    if package in DEPRECATED:
        replacement = APPROVED.get(service, ("?", "?"))[0]
        return f"DENIED (archived and deprecated, use {replacement})"
    approved_pkg, _approved_ver = APPROVED.get(service, (None, None))
    if package != approved_pkg:
        return "HELD (not the approved server for this service)"
    if version is None:
        return "DENIED (version not pinned)"
    return "ALLOWED"
```

Running it prints this:

```
== Naive installer (agent proposes, machine installs) ==
  naive: 10/10 installed, 6 of them archived and deprecated

== Gated installer (registry check outside the model) ==
  gated: 2 allowed, 7 denied, 1 held
  gated: 0 archived packages installed
  legit: 2/2 approved and pinned installs allowed
```

Read the three checks in order, because each one covers a different failure. The archived check does the heavy work in this run, and it is a lookup, not a judgement call: a package on the archived and deprecated list is denied, and the denial names the approved replacement, so the agent gets a next step instead of a dead end. The approved-server check covers the long tail the study has not named yet: one approved server per service, owned by the service itself, and anything else is held for a person to look at. That check catches next year's archived package before anyone writes a study about it, because a new name cannot pass by being familiar. The pin check is the quiet one. A bare npx install takes whatever the registry serves today, so the same config can run different code in March than it ran in January. A pinned version makes the install a fact you can audit.

Notice what the gate does not do. It does not ask the model whether the package is safe, and it does not scan the package code. It answers three questions a registry and a list can answer, at the one moment when the answer still matters: before the code runs. Run it yourself with `python3 install_gate.py`, then swap the demo lists for your own approved set.

## Sweep the Machines You Already Have

The gate stops the next install. You still owe a look at the installs already sitting in config files, which is the sweep Glow Labs recommends, in concrete commands.

Find the references first:

```bash
grep -R "@modelcontextprotocol/server-" ~/.claude ~/.cursor ~/.config 2>/dev/null
```

Every line that prints is a config entry pointing at the archived set. Then check what the registry itself says about any package you are unsure of:

```bash
npm view @modelcontextprotocol/server-github deprecated
npm view @modelcontextprotocol/server-github time.modified
```

The first command prints the deprecation message the registry carries. This is the fact your agent never looked up, available in one call, which is the whole argument for putting the lookup in code. Replace each hit with the service owner's own server, pin the version in the config, and record the swap wherever you record dependency changes. If a config on a machine you manage still names an archived server after the sweep, that is a finding, not a preference.

## Where This Breaks

Say the limits plainly, because an install gate is a real control and it still has edges:

- The approved list is the control, and lists rot. A service replaces its official server, your list still names the old one, and the gate starts enforcing yesterday's answer with total confidence. Review the list on a schedule, the way you review firewall rules.
- The gate checks names, not code. An approved, pinned package can be compromised tomorrow, and the gate will allow it tomorrow, correctly, by its own rules. Pinning buys you auditability and a rollback target. It does not buy you safety.
- Held does not mean reviewed. An unknown package held for a person becomes a queue, and queues under deadline pressure become approvals. If nobody owns the queue, the gate is a delay, not a decision.
- Agents are not the only installers. The 2 percent in the study were users asking for the old package by name, from an old tutorial, and your own muscle memory does the same thing. The gate has to sit on human-run installs too, or the door you closed reopens at the keyboard.
- The deprecated set in the demo is one ecosystem at one moment. PyPI, Docker images, and editor extensions have the same shape: an agent recalling a name, a registry that warns instead of refusing, and no manifest a scanner reads. The demo code does not travel there for free.
- Ten simulated proposals are not a fleet measurement. The demo shows the shape of the control. Point the sweep at your own machines and count what it finds before you quote anyone's numbers, including mine.

## Decide Whether You Gate Installs

Build it if:

- Anyone on your team lets an agent configure its own tools, which in practice means anyone running a coding agent with MCP enabled.
- Your agents hold real credentials: a GitHub token, a database connection, a cloud key. An archived server runs with all of them.
- You cannot currently list, from a file, every MCP server running on your developers' machines. That list is the control. The gate is just how the list stays true.

Skip it if:

- Your agents run against one server your team operates, installed from your own repository, with no registry installs at all. Verify that in the config files, not from memory, and then spend your week elsewhere.
- Your environment already builds developer machines from an image with a fixed tool set and no per-user config writes. You have a gate. It is the image. Keep it current.

The minimal viable version fits in an afternoon. Write down one approved server per service your team actually uses, with a pinned version. Add the archived check as a small script your agent setup runs before it writes a config, or as a CI check on the config files themselves. Run the sweep once, replace what it finds, and log every held package for a month. Decide from that log whether the full gate earns its keep.

## Stop Letting Memory Pick Your Dependencies

You would not let a colleague add a production dependency because they remembered its name from a tutorial they read two years ago. You would ask what maintains it, what replaced it, and why this one. An agent deserves the same questions, and unlike a colleague, it cannot answer them: the answers changed after its training ended, and nothing in its loop goes looking. That lookup is yours to build, and it is small: a list you approve, a registry fact you check in code, a version you pin. Build the check, run the sweep this week, and count what your machines were already running.

When did you last read your own MCP config end to end, and do you know who, or what, chose every package name in it?

## Resources

1. [Glow Labs: MCPhantom, agents installing deprecated MCP servers](https://theinjection.dev/items/glow-mcphantom/)
2. [Agents install what they remember, not what is safe](https://www.agent-intelligence.net/coding-agent-compromise-mcphantom-haiou/)
3. [MCPhantom: agents chose deprecated MCP servers in 98 percent of tracked sessions](https://dev.to/piekwerk/mcphantom-agents-chose-deprecated-mcp-servers-in-98-of-tracked-sessions-and-no-patch-is-coming-1adk)
4. [WebMCP Attack Lab: Can an E-Shop Hijack Your AI Agent?](https://dev.to/gramli/webmcp-attack-lab-can-an-e-shop-hijack-your-ai-agent-4oe5)
5. [Your Coding Agent Reads the Folder First: Scan the Workspace Before You Start It](https://dev.to/anusha_mukka/your-coding-agent-reads-the-folder-first-scan-the-workspace-before-you-start-it-299f)
