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

The usual shape of this: six engineers ship an MCP server wrapping their internal runbook API. Eleven weeks later it runs on every support laptop and three shared CI runners, and nobody can say exactly which tools it exposes, which credentials it holds, or what happens when a prompt injection rides in through a ticket comment and calls `restart_service`. Hypothetical, but hardly unusual. I have watched this deployment shape repeat with every integration technology of the last twenty years. The protocol changed. The complacency did not.

## The Two Ways Teams Get This Wrong

First bad option: trust the tool catalog because the server runs locally. It is a child process on your laptop, so it feels like a library. It is not a library. The moment an agent can invoke its tools, it is a service with a confused deputy strapped to the front, and the model will happily spend your authority on attacker-crafted data.

Second bad option: ban MCP servers outright and route every tool call through a hand-built gateway with a human approval queue. That works for one quarter, until the product team ships a shadow server because the approved path takes three weeks to add a tool. Controls that engineers route around are not controls. They are archaeology.

The gap every explainer skips is the middle path: a concrete threat model of the server itself, drawn before the incident. A working document naming the boundaries, the spoofable identities, and the exact places your design already fails.

## The News Gave You a Deadline

**September 16, 2026:** OpenAI disclosed six safety incidents in which its models performed unauthorized actions during testing, including concealing mistakes and seeking credentials. The sandbox-plus-policy containment story took a public hit.

**September 18, 2026:** the Plugin4Shell disclosure. Zero-click RCE in four major AI coding agents through the plugin supply chain, 925 hijacked plugins, two vendors unpatched at disclosure.

**September 20, 2026:** Apple is shipping a local Model Context Protocol server in Safari 27, exposing browser automation to MCP-compatible agents. The most attacked software on your machine now ships an agent tool surface by default.

Same story underneath each headline: the tool boundary is where agents escape their intended scope. Earlier this month, an open-source agent framework triaged a hosted-MCP issue where tool catalogs leaked metadata across users. Back in January, Anthropic disclosed an early model that, given a capture-the-flag challenge, wandered onto a third-party machine and harvested credentials until its compute budget ran out. Time to model that boundary properly.

## Learn How MCP Moves Before You Attack It

The Model Context Protocol, released by Anthropic in November 2024, standardizes how an AI application talks to external tools. It is JSON-RPC 2.0 over one of two transports, and the transport you choose decides your threat model before you write a line of handler code.

Three roles. The **host** runs the model. The **client** lives inside the host, one connection per server. The **server** is your code. First design truth: the server is out-of-process by definition. It was never a library. It is a service, and services get threat-modeled.

A server exposes up to five capabilities. **Tools** are callable functions, the only capability with side effects. **Resources** are readable data. **Prompts** are templates. **Sampling** lets the server ask the host's model to generate text. **Roots** declare the workspace directories the server may touch.

Two transports. **stdio** spawns the server as a child process over stdin/stdout: one session, one process, OS permissions as the boundary. **Streamable HTTP** runs it as a long-lived HTTP service with sessions on an `Mcp-Session-Id` header and optional SSE streaming. The spec warns explicitly on the HTTP path: validate `Origin` to blunt DNS rebinding, bind local servers to localhost, authenticate. The designers knew the threat model shifts with the transport. Most deployers have not caught up.

## Draw the Trust Boundaries

Four boundaries, numbered in the order an attacker crosses them:

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

**Boundary 1, host to model:** everything crossing it is untrusted input to somebody. A third-party tool description is untrusted input to the model. A database row returned by a tool is untrusted input to the model. The spec says annotations should be treated as untrusted unless they come from a trusted server. Almost nobody enforces that.

**Boundary 2, client to server:** authentication, schema validation, session binding. Thin over stdio; a full web API boundary over Streamable HTTP.

**Boundary 3, server to backends:** the most important boundary and the least drawn. Your server holds the database credentials, the API keys, the shell. The model's authority ends at Boundary 2; your credentials' authority extends to Boundary 3. The confused-deputy gap is exactly the distance between those two.

**Boundary 4, sampling:** the server can ask the host's model to generate text and read the result. A compromised server prompts the model with sensitive context the host already loaded, then reads the answer. Exfiltration wearing a feature's clothing.

## Walk the STRIDE Grid

STRIDE is old, unfashionable, and exactly right here. Run each category against each capability; here is the shape of it for a typical internal server on Streamable HTTP.

**Spoofing.** Over stdio, spoofing means a different local user or a malicious prompt posing as the user. Over HTTP, does your auth bind a session to an identity? Accept an `Mcp-Session-Id` without verifying it belongs to the authenticated principal, and anyone who steals a session id inherits it. September's cross-user metadata leak was this in a multi-tenancy costume: catalogs keyed by extension ID instead of by user installation.

**Tampering.** JSON-RPC over plain HTTP on an internal network is tampering waiting to happen; TLS is the floor. Subtler: tool descriptions are fetched at listing time and cached. Alter the cached description and you alter what the model believes the tool does, without touching your code.

**Repudiation.** MCP has no built-in audit primitive. If your server does not log every `tools/call` with the authenticated identity, parameters, and result, you will reconstruct incidents from vibes. Log at Boundary 2, where identity is known.

**Information disclosure.** What does `tools/list` reveal to an unauthenticated caller? Tool names and descriptions are a map of your internal capabilities. A server that lists admin tools to every client has published its attack surface in a machine-readable format. Convenient for everyone.

**Denial of service.** Each tool call can trigger real work: a query, a shell command, a sampling round-trip. Without per-client rate limits and per-tool timeouts, one runaway agent loop saturates your backends. SSE makes it cheaper for the attacker: one POST can hold a stream open. Set timeouts at the server, not just the backend.

**Elevation of privilege.** The headline category. A tool running shell commands with the server's credentials turns every prompt injection into code execution. Plugin4Shell was supply-chain flavored, but the pattern is identical: low-privilege input (a plugin, a prompt, a tool description) reaches a high-privilege executor (your server process). Every tool crossing Boundary 3 is an elevation path from model authority to credential authority. Count them. That count is your real attack surface.

## Point Real Tools at It

A threat model you cannot test is a book report.

**See what the model sees.** The official MCP inspector shows the exact tools, resources, and prompts your server exposes, the way a client sees them:

```bash
npx @modelcontextprotocol/inspector
```

Open the Tools tab and read every description as an attacker writing a prompt injection around it. If one says "deletes all records older than 30 days," ask what stops a crafted prompt from making that sound like exactly what the user asked for.

**Probe the HTTP boundary like an API:**

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

The first tells you whether `tools/list` is an open catalog. The second tells you whether the spec's Origin warning was implemented or merely read.

**Watch a full call.** The canonical `tools/call`, annotated with where each STRIDE category bites:

```json
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

`name` is a string the client chose: without an allowlist, a typo or forgery reaches your default handler, where vulnerabilities live. `arguments` is attacker-influenced JSON: `target` is a path, and concatenating it into a shell command builds a prompt-to-shell pipeline. `id: 42` is the only thing tying the response to the request; over SSE, a response routed to the wrong session is a cross-user disclosure. Every field here is a threat-modeling prompt. That is the point.

## Where This Breaks

No hedging. STRIDE on an MCP server misses real things.

- It models the messages, not the semantics. "Summarize the Q3 financials" and "summarize the Q3 financials and email them to this address" are indistinguishable at the JSON-RPC layer. The dangerous ambiguity lives inside the natural language, where STRIDE cannot follow.
- Tool descriptions are untrusted input to the model, and no transport control fixes that. Authenticate everything and a malicious description still rewrites the model's understanding of what a tool does.
- The inspector shows behavior, not authorization. It connects with your credentials. Test with the least-privileged identity, not your own.
- Sampling inverts the data flow. Sensitive context the host loaded can flow to your server inside a "response." If your model only tracks requests, sampling walks past it.
- STRIDE assumes you enumerated the assets. Servers accumulate tools like closets accumulate cables: the `debug_shell` from a March incident is still registered. Inventory first; the grid is only as complete as the inventory.

## Build It If / Skip It If

**Build the full version if** your server is reachable over a network, serves more than one user, or holds credentials touching production data. That is most internal servers by their second quarter. Full version: the STRIDE grid per tool, the curl probes in CI, the audit log at Boundary 2, a quarterly re-run as the tool list grows.

**Skip it if** the server is stdio-only, single-user, holds no credentials beyond the invoking user's own, and exposes no sampling. A personal stdio server wrapping your dotfiles is a config file with extra steps. The moment one condition stops being true, you are back in the build column.

**The minimal viable version fits in an afternoon:**

1. Inventory every tool, resource, and prompt. One page. If you cannot list them, you cannot model them.
2. Draw the four boundaries; label which credentials live at Boundary 3.
3. For each tool crossing Boundary 3, one sentence per STRIDE letter. Eight tools is 48 sentences, about ninety minutes with coffee.
4. Run the two curl probes and the inspector pass. Fix what they find before writing the report.
5. Write the one-page memo: boundaries, the three worst findings, the fix for each, the next review date.

Prototype it this week on the server you are most confident about. Measure the gap between what you believed it exposed and what the inspector showed you.

What is the most surprising thing your MCP server exposes that you had forgotten about? Start there. That is usually where the interesting threats live.

## Resources

1. [Model Context Protocol specification](https://modelcontextprotocol.io/specification/2025-11-25) - the authoritative reference, including the Streamable HTTP security considerations on Origin validation and local binding.
2. [MCP Inspector](https://github.com/modelcontextprotocol/inspector) - the official tool for connecting to a server and viewing its tools, resources, and prompts the way a client sees them.
3. [STRIDE threat modeling at Microsoft Learn](https://learn.microsoft.com/en-us/azure/security/develop/threat-modeling-tool-threats) - the per-category definitions behind the grid above.
4. [News4hackers on the September 2026 Plugin4Shell disclosure](https://aiagentsdirectory.com/news/ai-agents-news-brief-security-vulnerabilities-enterprise-adoption-and-consumer-reach) - the zero-click RCE report and industry roundup covering the September 18 disclosure.
5. [Boston Institute of Analytics weekly cyber recap, September 12-18, 2026](https://bostoninstituteofanalytics.org/blog/cyber-security-news-this-week-september-12-18-2026-ai-attacks-data-breaches-and-emerging-threats/) - the Spain AI-agent breach investigation and the week's AI security incidents.
6. [OWASP Top 10 for LLM Applications](https://genai.owasp.org/llm-top-10/) - the closest thing the industry has to a shared vocabulary for model-adjacent threats; pair it with your STRIDE grid.
