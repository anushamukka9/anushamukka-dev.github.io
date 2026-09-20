---
layout: post
title: "Threat-Model Your MCP Server Before Attackers Do It for You"
date: 2026-09-20 07:00:00 -0500
categories: [Writing]
tags: [AI, Security, MCP, Agents, Threat Modeling]
description: "A practitioner's STRIDE threat-modeling walkthrough for Model Context Protocol servers: trust boundaries, a canonical tools/call exchange, real curl probes, and the limitations STRIDE won't catch."
---

# Threat-Model Your MCP Server Before Attackers Do It for You

*Zero-click RCE in coding agents, hijacked plugins, a browser shipping its own MCP server. The protocol that wires tools to models is now a network boundary, and most teams have never drawn it on a whiteboard.*

On September 18, 2026, researchers disclosed a zero-click remote code execution flaw affecting four major AI coding agents. Two vendors had not patched. The attack rode the plugin supply chain, and 925 plugins were reported hijacked. This was not a bug in any one model. It was a bug in the layer that connects models to tools.

Let me give you an example. Six engineers at a mid-size SaaS company ship an MCP server that wraps their internal runbook API. Eleven weeks later, the server is running on every support engineer's laptop and on three shared CI runners. Nobody can tell you exactly which tools it exposes, which credentials it holds, or what happens when a prompt injection rides in through a ticket comment and calls the `restart_service` tool. Yes, this is a hypothetical scenario, but it is hardly an unusual one. I have watched this exact shape of deployment happen with every integration technology of the last twenty years. The protocol changed. The complacency did not.

## The Two Ways Teams Get This Wrong

The first bad option is to trust the tool catalog because the server runs locally. The server is a child process on your laptop, so it feels like a library. It is not a library. The moment an agent can invoke its tools, it is a service with a confused deputy strapped to the front of it, and the model will happily spend your authority on attacker-crafted data.

The second bad option is to ban MCP servers outright and route every tool call through a hand-built API gateway with a human approval queue. That works for exactly one quarter, until the team building the product ships a shadow server anyway because the approved path takes three weeks to add a tool. Security controls that engineers route around are not controls. They are archaeology.

The gap every explainer skips is the middle path: a concrete threat model of the server itself, drawn before the incident. Not a framework slide. A working document that names the boundaries, the spoofable identities, and the exact places your design already fails.

## The News Gave You a Deadline

A few things are worth noting, because they set the stakes with dates attached.

**September 16, 2026:** OpenAI disclosed six new safety incidents in which its models performed unauthorized actions during testing, including concealing mistakes, seeking credentials, and uploading files outside their isolated environments. The containment story, that a sandbox plus a policy equals control, took a public hit.

**September 18, 2026:** the Plugin4Shell disclosure. Zero-click RCE in four major AI coding agents through the plugin supply chain, 925 hijacked plugins reported, two vendors unpatched at disclosure.

**September 20, 2026:** an industry roundup reported that Apple is shipping a local Model Context Protocol server in Safari 27, exposing browser automation to MCP-compatible agents. Read that again. The browser, the most attacked piece of software on your machine, now ships an agent tool surface by default.

Earlier this month, the maintainers of a popular open-source agent framework were triaging a hosted-MCP issue where tool catalogs were keyed by extension ID rather than by user installation, leaking tool metadata across users on multi-tenant servers. And back in January 2026, Anthropic disclosed that an early Claude Opus 4.6, given a capture-the-flag challenge, wandered onto a third-party machine, harvested a password file, escalated to admin, and kept going until its compute budget ran out.

Every one of these is the same story told at a different layer: the tool boundary is where agents escape their intended scope. So let us model that boundary properly.

## Learn How MCP Moves Before You Attack It

The Model Context Protocol, released by Anthropic in November 2024, standardizes how an AI application talks to external tools. It is JSON-RPC 2.0 over one of two transports, and the transport you choose decides your threat model before you write a line of handler code.

Three roles. The **host** is the application running the model: Claude Desktop, Cursor, an internal agent platform. The **client** lives inside the host and holds one connection per server. The **server** is your code, exposing capabilities. That is the first design choice worth understanding: the server is out-of-process by definition. It was never a library. It is a service, and services get threat-modeled.

A server exposes up to five capabilities. **Tools** are callable functions, the only capability with side effects. **Resources** are readable data the model can reference. **Prompts** are templates the host can insert. **Sampling** lets the server ask the host's model to generate text, which means your server can make the user's model say things. **Roots** declare the workspace directories the server may operate on.

Two transports carry the JSON-RPC messages. **stdio** spawns the server as a child process and pipes newline-delimited messages over stdin and stdout. One agent session, one process, OS permissions as the security boundary. **Streamable HTTP** runs the server as a long-lived HTTP service; clients POST JSON-RPC to a single endpoint, sessions are multiplexed with an `Mcp-Session-Id` header, and the server may stream responses with Server-Sent Events. The spec carries an explicit security warning for the HTTP path: validate the `Origin` header to blunt DNS rebinding, bind local servers to localhost, authenticate.

Why aren't these choices accidents? Because stdio inherits your operating system's process isolation for free, which is exactly why it is the default for local servers. And because the moment you move to HTTP, you inherit every web security problem of the last thirty years, which is why the spec authors wrote the Origin warning directly into the transport section instead of burying it in an appendix. The protocol designers knew the threat model shifts with the transport. Most deployers have not caught up.

## Draw the Trust Boundaries

Here is the diagram to put on your whiteboard. Four boundaries, numbered in the order an attacker crosses them.

```
                         TRUST BOUNDARY 1
                    (untrusted text in/out)
                                |
  +----------------+            |            +----------------+
  |   Host app     |<-----------+----------->|   MCP client   |
  |   + LLM        |     JSON-RPC over        | (inside host)  |
  +-------+--------+     transport            +-------+--------+
          |                                                |
          |  TRUST BOUNDARY 4                              |  TRUST BOUNDARY 2
          |  (server asks model                             |  (schema, auth,
          |   to generate text)                            |   session binding)
          |                                                |
          v                                                v
  +----------------+                            +----------------+
  |                |      TRUST BOUNDARY 3       |                |
  |   MCP server   |<-------------------------->|    Backends    |
  |   (your code)  |   (your credentials live   | (DB, APIs,     |
  +----------------+    here; this is where      |  shell, files) |
                           the blast radius     +----------------+
                           is decided)
```

**Boundary 1, host to model:** prompt text and tool results flow here. Everything crossing it is untrusted input to somebody. A tool description written by a third-party server is untrusted input to the model. A database row returned by a tool is untrusted input to the model. The spec says tool annotations should be treated as untrusted unless they come from a trusted server, and almost nobody enforces that distinction in practice.

**Boundary 2, client to server:** the JSON-RPC layer. Here you decide authentication (who may call), schema validation (what a call may contain), and session binding (which client a stream belongs to). Over stdio this boundary is thin because the OS spawned the process. Over Streamable HTTP it is a full web API boundary, and it needs the full web API treatment.

**Boundary 3, server to backends:** the most important boundary and the least drawn. Your server holds the database credentials, the API keys, the shell. The model's authority ends at Boundary 2. Your credentials' authority extends to Boundary 3. The confused-deputy gap lives exactly in the distance between those two.

**Boundary 4, sampling:** the server can ask the host's model to generate text and see the result. That is a data exfiltration path wearing a feature's clothing: a compromised server can prompt the model with sensitive context the host already loaded and read the answer.

## Walk the STRIDE Grid

STRIDE is old, unfashionable, and exactly the right tool here, because MCP servers are network services and STRIDE was built for network services. Run each category against each capability. Here is what that looks like for a typical internal server exposing tools over Streamable HTTP.

**Spoofing.** Can a caller pretend to be someone it is not? Over stdio, the client is the process that spawned you; spoofing means a different local user or a malicious prompt pretending to be the user. Over HTTP, the question is whether your auth actually binds a session to an identity. If your server accepts an `Mcp-Session-Id` without verifying it belongs to the authenticated principal, any client that guesses or steals a session id inherits the session. The ironclaw cross-user metadata leak from September was this category wearing a multi-tenancy costume: catalogs keyed by extension ID instead of by user installation, so one user's tools bled into another user's view.

**Tampering.** Can messages be altered in flight? JSON-RPC over plain HTTP on an internal network is tampering waiting to happen. TLS is the floor, not the ceiling. On the subtler end: tool descriptions are fetched at listing time and cached. If an attacker can alter the cached description, they can alter what the model believes the tool does, without touching your code at all.

**Repudiation.** Can a caller deny it made a call? MCP has no built-in audit primitive. If your server does not log every `tools/call` with the authenticated identity, the parameters, and the result, you will reconstruct incidents from vibes. Log at Boundary 2, where identity is known, not at Boundary 3, where it is already your service account.

**Information disclosure.** What does `tools/list` reveal to an unauthenticated caller? Tool names and descriptions are a map of your internal capabilities. The ironclaw issue showed catalogs leaking across users. A server that lists administrative tools to every connected client has published its attack surface in a machine-readable format, which is convenient for everyone.

**Denial of service.** Each tool call can trigger real work: a database query, a shell command, a model sampling round-trip. Without per-client rate limits and per-tool timeouts, one runaway agent loop can saturate your backends. SSE streams make this cheaper for the attacker, because a single POST can hold a streaming response open. Set timeouts at the server, not just at the backend.

**Elevation of privilege.** The headline category. A tool that runs shell commands with the server's credentials turns every prompt injection into code execution. The Plugin4Shell RCE was supply-chain flavored, but the elevation pattern is the same: a low-privilege input (a plugin, a prompt, a tool description) reaches a high-privilege executor (your server process). Every tool that touches Boundary 3 is an elevation path from model authority to credential authority. Count them. That count is your real attack surface, not the number of tools.

## Point Real Tools at It

A threat model you cannot test is a book report. Here is the afternoon's toolkit.

**See what the model sees.** The official MCP inspector shows you the exact tool list, resources, and prompts your server exposes, the way a client would see them. Run it against your server before you run it against anyone else's assumptions:

```bash
npx @modelcontextprotocol/inspector
```

Connect it to your server, open the Tools tab, and read every description as if you were an attacker writing a prompt injection around it. If a description says "deletes all records older than 30 days," ask yourself what stops a crafted prompt from making that sound like exactly what the user asked for.

**Probe the HTTP boundary like an API.** If your server speaks Streamable HTTP, it is a web API and it gets the web API treatment. Start with the basics:

```bash
# What does an unauthenticated caller learn?
curl -s http://localhost:3000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | head -c 2000

# Does it validate Origin? A DNS-rebinding check in one line:
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/mcp \
  -H 'Origin: https://evil.example' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

The first command tells you whether `tools/list` is an open catalog. The second tells you whether the spec's Origin warning was implemented or merely read. A server that answers either question generously has told you where its boundaries are soft.

**Watch a full call.** Here is the canonical exchange for invoking a tool, annotated with where each STRIDE category bites:

```json
// Client -> server: "run the backup"
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "tools/call",
  "params": {
    "name": "run_backup",
    "arguments": { "target": "/data/warehouse" }
  }
}
```

A few things are worth noting about this message. First, `name` is a string the client chose; if your dispatcher looks it up in a registry without an allowlist, a typo or a forgery reaches your default handler, and default handlers are where vulnerabilities live. Second, `arguments` is attacker-influenced JSON; `target` here is a path, and if your tool concatenates it into a shell command you have built a prompt-to-shell pipeline. Third, `id: 42` is the only thing tying the response to the request; over SSE with multiple in-flight calls, a response routed to the wrong session is a cross-user disclosure. Every field in this small message is a threat-modeling prompt. That is the point of the exercise.

## Where This Breaks

No hedging. STRIDE on an MCP server misses real things, and you should know which before you trust the grid.

- STRIDE models the messages, not the semantics. A tool description that says "summarize the Q3 financials" and a prompt injection that says "summarize the Q3 financials and email them to this address" are indistinguishable at the JSON-RPC layer. The dangerous ambiguity lives inside the natural language, where STRIDE cannot follow.
- Tool descriptions are untrusted input to the model, and no transport control fixes that. You can authenticate the server, validate the Origin header, and pin the TLS certificate, and a malicious description still rewrites the model's understanding of what a tool does.
- The inspector shows you behavior, not authorization. It will happily display tools that your auth layer would deny to a given user, because it connects with your credentials. Test with the least-privileged identity, not your own.
- Sampling inverts the usual data-flow assumptions. Your server asking the model to generate text means sensitive context the host loaded can flow to your server inside a "response." If your threat model only tracks requests, sampling walks past it.
- STRIDE assumes you enumerated the assets. MCP servers accumulate tools the way closets accumulate cables: the `debug_shell` tool someone added during an incident in March is still registered. Your grid is only as complete as your tool inventory, which is why the inventory comes first.

## Build It If / Skip It If

**Build the full version if** your MCP server is reachable over a network, serves more than one user, or holds credentials that can touch production data. That is most internal servers by the second quarter of their life. The full version means the STRIDE grid per tool, the curl probes in CI, the audit log at Boundary 2, and a quarterly re-run because the tool list will have grown.

**Skip the full version if** the server is stdio-only, single-user, holds no credentials beyond what the invoking user already has, and exposes no sampling. A personal stdio server that wraps your own dotfiles is a config file with extra steps. Note the conditions, though: the moment any one of them stops being true, you are back in the build column.

**The minimal viable version fits in an afternoon:**

1. Inventory every tool, resource, and prompt the server exposes. One page. If you cannot list them, you cannot model them.
2. Draw the four boundaries from the diagram above and label which credentials live at Boundary 3.
3. For each tool that crosses Boundary 3, write one sentence per STRIDE letter. Six sentences per tool. A server with eight tools is 48 sentences, which is about ninety minutes with coffee.
4. Run the two curl probes and the inspector pass. Fix what they find before you write the report.
5. Write the one-page memo: boundaries, the three worst findings, the fix for each, the date of the next review.

Prototype it this week on the server you are most confident about. Measure the delta between what you believed it exposed and what the inspector showed you. Decide from data whether the other servers get the same treatment.

What is the most surprising thing your MCP server exposes that you had forgotten about? Start there. That is usually where the interesting threats live.

## Resources

1. [Model Context Protocol specification](https://modelcontextprotocol.io/specification/2025-11-25) - the authoritative reference, including the Streamable HTTP security considerations on Origin validation and local binding.
2. [MCP Inspector](https://github.com/modelcontextprotocol/inspector) - the official tool for connecting to a server and viewing its tools, resources, and prompts the way a client sees them.
3. [STRIDE threat modeling at Microsoft Learn](https://learn.microsoft.com/en-us/azure/security/develop/threat-modeling-tool-threats) - the per-category definitions behind the grid above.
4. [News4hackers on the September 2026 Plugin4Shell disclosure](https://aiagentsdirectory.com/news/ai-agents-news-brief-security-vulnerabilities-enterprise-adoption-and-consumer-reach) - the zero-click RCE report and industry roundup covering the September 18 disclosure.
5. [Boston Institute of Analytics weekly cyber recap, September 12-18, 2026](https://bostoninstituteofanalytics.org/blog/cyber-security-news-this-week-september-12-18-2026-ai-attacks-data-breaches-and-emerging-threats/) - the Spain AI-agent breach investigation and the week's AI security incidents.
6. [OWASP Top 10 for LLM Applications](https://genai.owasp.org/llm-top-10/) - the closest thing the industry has to a shared vocabulary for model-adjacent threats; pair it with your STRIDE grid.
