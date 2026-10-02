---
layout: post
title: "Your Prompt Template Is a Code Execution Surface"
date: 2026-10-02 07:00:00 -0500
categories: [Writing]
tags: [AI Security, Prompt Injection, Application Security, DevSecOps]
description: "GitLab disclosed CVE-2026-90970: an attacker with basic privileges escaped the AI Gateway's prompt template sandbox and ran arbitrary commands. On the template boundary nobody audits, why sandboxes fail, and how to harden yours."
---

# Your Prompt Template Is a Code Execution Surface

*GitLab disclosed CVE-2026-90970 this morning: an authenticated user with basic privileges escaped the AI Gateway's prompt template sandbox and ran arbitrary commands on the gateway. The template engine is the part of your AI stack nobody audited, and it was always code.*

## This Morning's Advisory

Friday, October 2, 2026. GitLab warned every self-hosted AI Gateway customer to patch immediately. The flaw, tracked as CVE-2026-90970, is an improper neutralization weakness: an authenticated user with basic privileges and Duo Agent Platform access could escape the prompt template sandbox with a specially crafted flow configuration and execute arbitrary commands on the AI Gateway. That is GitLab's own wording in the advisory, and it is worth reading twice. Not "view prompts." Not "spoof a flow." Run commands on the gateway host.

The fix shipped in versions 19.2.4, 19.3.2, and 19.4.1. Customers on GitLab-hosted AI Gateway are already protected. Everyone else is patching today.

If this feels familiar, it should. Last month GitLab patched CVE-2026-85706, a path traversal flaw that let unauthenticated attackers read secrets off vulnerable servers. CISA added it to the known-exploited list one day later. September was read the secrets. October is run the commands. The AI gateway is becoming the most interesting box on the network, and attackers have noticed before most defenders have finished inventorying it.

## The Two Bad Reactions

When an advisory like this lands, teams pick one of two bad default reactions.

The first bad reaction is patch and forget. You upgrade to 19.4.1, close the ticket, and move on. The patch fixes this instance. It does not fix the bug class, and if your own team ships an AI gateway, a prompt templating step, or a "custom instructions" feature with a template engine underneath, you just shipped the same bug class with a different logo.

The second bad reaction is to file this under "configuration issue" and keep the mental model that templates are just config. Config does not run `id` on your host. This one did. The distinction between configuration and code is not a technical property. It is a hope, and hopes are not a trust boundary.

The real question is not "did we patch GitLab." It is "where in our own stack does an attacker-authored string meet a template engine, and what does that engine run as."

## The Gap This Piece Fills

The security conversation about AI systems is almost entirely about the model. Prompt injection, jailbreaks, data exfiltration through the model's output. All real. All worth the attention. But the model sits inside machinery, and the machinery has a boundary nobody talks about: the template step that renders the prompt before the model ever sees it.

AI gateways build prompts from flow configurations. A flow config says: take these variables, the user's repo, the task type, the retrieved context, and render this template into the system prompt. Rendering is done by a template engine, usually a sandboxed one. The sandbox is supposed to make template authoring safe for people who should not have code execution. CVE-2026-90970 is what happens when the sandbox has a hole: the "configuration" becomes a shell, and the person holding it only needed basic privileges.

> The prompt template is not the wrapping around the code. On a gateway, it is the code.

## A Template Engine Is Code Execution With a Friendlier Name

Let me give you the mechanism, because the mechanism is the part every explainer skips.

A flow configuration is a template with holes in it. At request time, the gateway fills the holes and hands the result to the model as a prompt. Here is a flow config rendering the ordinary, legitimate way, in Jinja2's sandboxed environment:

{% raw %}
```python
from jinja2.sandbox import SandboxedEnvironment
env = SandboxedEnvironment()

flow_template = """You are a code review assistant.
Repository: {{ repo }}. Focus on {{ focus }}.
Diff context lines: {{ context_lines | default(3) }}."""

print(env.from_string(flow_template).render(
    repo="checkout-service", focus="SQL injection"))
```
{% endraw %}

Output:

```
You are a code review assistant.
Repository: checkout-service. Focus on SQL injection.
Diff context lines: 3.
```

Nothing scary. Now the same engine, fed the classic server-side template injection payload, the one that has worked against naive template steps for a decade:

{% raw %}
```python
payload = "{{ ''.__class__.__mro__[1].__subclasses__() }}"
print(env.from_string(payload).render())
```
{% endraw %}

The sandbox stops it:

```
SecurityError: access to attribute '__class__' of 'str' object is unsafe.
```

Good. That is the sandbox doing its job. But watch what happens when the template step is the plain, unsandboxed engine, which is what a hand-rolled "prompt builder" behaves like when a team writes its own rendering step and forgets the sandbox exists:

{% raw %}
```python
from jinja2 import Environment
env = Environment()

finder = """{% for c in ''.__class__.__mro__[1].__subclasses__() %}\
{% if c.__name__ == '_wrap_close' %}\
{{ c.__init__.__globals__['popen']('id').read() }}\
{% endif %}{% endfor %}"""

print(env.from_string(finder).render())
```
{% endraw %}

Output:

```
uid=0(root) gid=0(root) groups=0(root)
```

A few things are worth noting about this example. First, the payload I ran is the textbook subclass crawl: from an empty string, walk up to `object`, enumerate every loaded class, find the one whose globals include `os.popen`, and call it. I ran it myself this morning and verified the output. This is not theoretical. Second, the sandbox version of the same engine blocks exactly this chain. The security of the whole flow rests on one filter: which attribute accesses the sandbox permits. Third, GitLab's advisory says an attacker escaped their prompt template sandbox. GitLab has not published the exact payload, and I am not going to invent one. The precise chain does not matter. What matters is the class: improper neutralization. Some sequence the sandbox was supposed to neutralize, it did not.

Template engines are Turing-complete by design. Jinja2 has loops, conditionals, filters, and full attribute traversal. A "sandboxed" template engine is the full engine with a bouncer at the door checking attribute names. Every sandbox escape in history, and there is a long history, is the bouncer missing one name.

## Why Every AI Gateway Rebuilds This Bug

I understand why every AI gateway builds prompt templates. Flow configurations are genuinely useful. Different teams need different system prompts, different context assembly, different guardrails, and nobody wants a redeploy every time the support team tweaks the triage prompt. Templating the prompt and letting operators edit the template is the obvious, reasonable design.

The mistake is in the trust boundary, and it is an easy mistake to make. Draw the pipeline:

```
  flow config (attacker-authored)
        |
        v
  +------------------+
  | template renderer|  <-- the sandbox lives here
  | "sandboxed"      |
  +------------------+
        |
        v
  rendered prompt --> model --> tool calls
        |
        +----> RCE on the gateway host (CVE-2026-90970)
```

The template author is an authenticated user with basic privileges. The renderer runs on the gateway host, which is the box that also holds credentials, network access, and the trust of everything downstream. The sandbox is the only thing between "basic privileges" and "commands on the gateway," and the sandbox is a string filter maintained by people who are not thinking about it as a security boundary.

This is the same bug as server-side template injection, which the web has been patching since 2015. The AI industry reintroduced it by rebuilding the web stack's template layer inside the gateway and calling the templates "flows." New vocabulary, same attribute traversal.

## Harden the Template Boundary Like Code

Here is what to do, in order of how much it costs.

First, patch. If you run a self-hosted GitLab AI Gateway, the versions are 19.2.4, 19.3.2, and 19.4.1. Do that today, before you do anything clever.

Second, treat flow configurations as code. They are code; see above. That means they live in version control, changes get reviewed, and the diff of a flow config gets the same scrutiny as the diff of a route handler. If your gateway lets operators edit templates in a web UI with no review, you have deploy-without-review for the most privileged component in the chain. Fix that before you fix anything else.

Third, assume the sandbox will fail and design for the failure. The renderer should run as an unprivileged user, in a container image with no shell, no package manager, and no network egress except to the model endpoint. If a template escape ever lands again, it lands in a room with nothing in it. When you read "arbitrary command execution on the AI Gateway," ask what the gateway host can reach. Then shrink the answer.

Fourth, scan what you already have. List every place a user-influenced string meets a template engine: flow configs, custom instruction templates, email templates, report builders. A first pass fits in an afternoon:

{% raw %}
```bash
# find template syntax in flow configs and custom templates
grep -rn "{{" flows/ templates/ prompts/ --include="*.yaml" --include="*.json" | head -50

# list who can author or edit those templates
# (your IAM console, your gateway's role bindings: whoever shows up here
#  holds code execution on the renderer until proven otherwise)
```
{% endraw %}

Then run your static scanner's template-injection rules over the same paths. Semgrep's default rule set includes Jinja2 SSTI rules. They catch known patterns, not novel neutralizations, but known patterns are what most hand-rolled template steps contain.

Fifth, restrict template authorship to the smallest set of roles that genuinely need it, and log every template render with the author, the template version, and the output size. A template render that spawns a process is not a performance anomaly. It is an incident. Alert on it like one.

## Where This Breaks

Unhedged, because hedging here costs someone a gateway.

- Patching GitLab does not fix the flow templating your own team built. The bug class is in your codebase now, not just theirs.
- Sandboxes are denylists wearing allowlist clothes. Each version's escape is someone else's zero-day, and you will not hear about it until the advisory.
- Low-privilege template authors are still authors. "Basic privileges" was enough for CVE-2026-90970. Privilege level of the author is not the control; the sandbox and the renderer's own privileges are.
- If the renderer shares a host or identity with anything holding secrets, template RCE becomes secret theft. Last month's GitLab flaw was unauthenticated secret reading. This month's is authenticated command execution. The two boxes rhyme because they are often the same box.
- Static scanning catches the payloads everyone knows. The GitLab escape was, by definition, a payload nobody's scanner knew. Scanning is hygiene, not a boundary.

## Build It If, Skip It If

Build the template-boundary review if anyone below your admin tier can author or edit templates that render on shared infrastructure. That is the exact shape of CVE-2026-90970: basic privileges, shared gateway, escaped sandbox.

Skip the full program if your templates are baked at deploy time, authored only by your own team, reviewed like code, and rendered by a locked-down sandbox on an unprivileged host. You still want the scan, but you do not need the incident runbook.

The minimal viable version fits in an afternoon. Grep your configs for template syntax. List every template engine in the request path and check whether each one is the sandboxed variant. List who can author templates and confirm each of them should hold that power. Document what user the renderer runs as and what the host can reach. Four lists. If any list surprises you, you found the work.

## Audit the Template Step Before the Next Advisory Does

Patch the gateway today. Then spend the afternoon on your own template boundary, because the next CVE in this class will not be GitLab's. It will be someone's internal prompt builder, someone's "custom instructions" feature, someone's flow config UI with a sandbox nobody has fuzzed. The template engine was always code execution. Treat it like code, confine it like an attacker holds it, and the advisory becomes someone else's bad Friday.

What is the most template-shaped code in your stack right now, the string someone edits in a UI that gets rendered by an engine you have never audited?

---

**Resources**

1. [GitLab warns of critical RCE vulnerability in AI Gateway service](https://www.bleepingcomputer.com/news/security/gitlab-warns-of-critical-rce-vulnerability-in-ai-gateway-service/): BleepingComputer, October 2, 2026. The advisory this piece is built on: CVE-2026-90970, prompt template sandbox escape, fixed in 19.2.4, 19.3.2, 19.4.1.
2. [GitLab AI Gateway security advisory](https://docs.gitlab.com/ee/update/versions.html): GitLab docs. Patch versions and upgrade guidance for self-hosted AI Gateway.
3. [Server-side template injection](https://portswigger.net/web-security/cross-site-scripting/server-side-template-injection): PortSwigger Web Security Academy. The bug class, with the attribute-traversal chains this piece's demo is drawn from.
4. [Server Side Template Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Template_Injection_Prevention_Cheat_Sheet.html): OWASP. Sandboxing, allowlisting, and why logic-less templates are the safer default.
5. [Sandboxing in Jinja2](https://jinja.palletsprojects.com/en/stable/sandbox/): Jinja2 documentation. What `SandboxedEnvironment` actually restricts, and what it explicitly does not promise.

---
