---
layout: post
title: "Every Tool You List Taxes Every Call"
date: 2026-10-30 09:05:00 -0400
categories: [Writing]
tags: [AI Agents, Model Context Protocol, Software Engineering]
description: "Every MCP tool you list costs tokens on every turn. Measured: a 15-tool list at 1,408 tokens per turn against 533 trimmed and 422 deferred, the published medians, and how to budget a tool list."
---

# Every Tool You List Taxes Every Call

*Connect an MCP server and your agent pays for every tool it advertises, on every turn, whether it calls any of them or not. The fix is not a bigger context window. The fix is a smaller list.*

## You Pay for the Menu, Not Just the Meal

Open a fresh session with your coding agent, type nothing yet, and you have already spent tokens. Not on your code, not on your question, not on any work. You spent them on a menu: the names, descriptions, and input schemas of every tool on every server you connected, serialized into the model's context so it knows what it is allowed to call.

Tell me about the server you added last month because one task needed one of its tools. It probably brought ten friends. A file server brings separate verbs for reading a whole file, reading a file in chunks, and reading a file with an encoding. A tracker brings one tool to create an issue, another to update it, another to list, another to fetch, another to comment. Each one reads as a small, sensible decision in a pull request. Together they are a fixed tax on every turn of every session, paid by every user who connects the server, including the users who only ever call two of the tools.

I understand why servers grow this way. Fine-grained tools are easier to document, easier to permission, and easier for a model to pick correctly than one tool with nine modes. Each addition is defensible on its own. What nobody owns is the total, because the total never appears as a line item. It appears as a context window that fills sooner than you expected, and an agent that picks a plausible wrong tool from a long list of near duplicates.

> The cost of a tool is not the call. The cost of a tool is its advertisement, repeated on every turn until the session ends.

## The Conversation Finally Started Counting

This used to be an aesthetic complaint. In the last few weeks it turned into arithmetic that people are publishing.

On October 26, 2026, a post that reached the top of dev.to this week described cutting a file-management MCP server from 15 tools to 4. The author's system prompt was 4,800 tokens before the user said a word. After trimming to four coarse tools and loading the rest on demand, the baseline dropped to about 1,100 tokens, and the agent got faster and cheaper in the bargain.

That author's server was not an outlier. A second measurement, published on dev.to from a sample of live servers, sent each one an unauthenticated tools/list request and measured the JSON that came back. The median server exposed 11 tools costing about 3,150 tokens. The 75th percentile exposed 33 tools costing 14,113 tokens. Loading all 33 responding servers would have spent roughly 215,000 tokens describing capabilities, which is most of a 200,000-token window spent before a task begins.

The large end is worse. A measurement run on October 2, 2026 found GitHub's official server costing 11,114 tokens for its default 46 tools, and 14 common servers together adding 204 tools and 42,156 tokens of schema. Anthropic's engineering post on code execution with MCP, from November 4, 2025, reported the extreme version: a Google Drive to Salesforce workflow that dropped from 150,000 tokens to 2,000, a 98.7 percent reduction, once the agent loaded only what the task needed.

The gap these numbers point at is the part most tool-cost discussions skip. They argue about protocols, MCP against CLI against code execution, as if the surface were fixed. It is not fixed. The list your server returns is a design decision you control today, on whatever client you already run, and in the measurements above the difference between a careless list and a budgeted one is not a few percent. It is most of the bill.

## A Tool Definition Is Rent, Charged Per Turn

Here is the mechanism, stated plainly. When a client connects to an MCP server, it asks for the tool list. The protocol answer is a set of definitions, and each definition has three parts: a name, a natural-language description telling the model when to use it, and a JSON Schema describing its inputs. The client places those definitions in the model's context, because a model cannot call a tool it has not been shown.

Two properties of that arrangement do the damage. First, the definitions stay in context for the whole session. Turn two does not need the read tools re-explained, and turn twenty needs them even less, but the list rides along anyway, because the model is stateless between calls and the client resends the context each time. Second, the charge scales with everything except use. A tool called fifty times costs the same definition space as a tool called never. A verbose schema costs more than a terse one doing the same job. An enum with eighty values, spelled out inline, costs rent on every turn for a parameter the model sets twice a month.

```
  you connect 3 servers
        |
        v
  tools/list: 15 + 11 + 46 definitions
        |
        v
  context: [system][tool definitions][your task][history]
                          ^                    ^
                     paid every turn      the part you meant to buy
        |
        v
  turn 20: definitions still there, history now competing with them
```

A few things are worth noting about this picture. First, prompt caching softens the money and not the space. A cached prefix is billed at a lower rate on many providers, and that is real savings, but the cached tokens still occupy the window, still crowd out history and code, and still present the model with every option on every decision. Second, selection is a cost alongside tokens. Fifteen tools with overlapping descriptions are fifteen chances to pick the chunk reader when the whole-file reader was right. Cutting the list helps accuracy for the same reason a short menu helps a tired human: fewer near duplicates, fewer wrong turns. Third, this tax is the visible half of a problem you may already know from the security side. A tool in the list is also a tool a manipulated agent can be talked into calling. A smaller list is a smaller bill and a smaller surface, from the same edit.

## Count Your Own List Before Arguing About It

Here is the mechanism in runnable Python, standard library only. The full file is tool_tax_demo.py next to this draft. It builds a plausible 15-tool file and issue server, prices each definition at characters divided by four, the rough token estimate the published measurements use, then prices two alternatives: a trimmed surface of four coarse tools, and a names-only index that loads full definitions only for the tools a task actually picks.

```python
def tokens(payload) -> int:
    return round(len(json.dumps(payload)) / 4)

full = tokens(FULL)          # 15 fine-grained tools, verbose schemas
trimmed = tokens(TRIMMED)    # 4 coarse tools, variations as parameters
index = tokens(names_only(FULL))
picked = [t for t in FULL if t["name"] in ("read_file", "search_regex")]
deferred = index + tokens(picked)
```

Running the demo prints this:

```
== Per-turn definition cost (tokens, chars/4 estimate) ==
  search_regex              125
  read_file_chunked         122
  create_issue              114
  read_file_with_encoding   112
  update_issue              104
  full 15-tool list       : 1408
  trimmed 4-tool list     : 533
  names-only index        : 214
  index + 2 loaded tools  : 422

== A 20-turn session pays the list on every turn ==
  full     :  1408 x 20 turns = 28,160 tokens
  trimmed  :   533 x 20 turns = 10,660 tokens
  deferred :   422 x 20 turns = 8,440 tokens

== Four servers connected at once ==
  4 x full list per turn  : 5,632 tokens before the task text
  4 x trimmed per turn    : 2,132 tokens before the task text
```

Read the per-tool rows first, because they locate the money. No single tool is outrageous. The most expensive, a regex search with three described parameters, costs 125 tokens, and the cheapest costs 67. The tax is not a villain tool, it is accumulation: fifteen reasonable definitions sum to 1,408 tokens, and the sum is what every turn pays. Note also where the trimmed surface wins. It does not win by describing things worse. It wins by refusing to mint a new verb for every variation. Reading with an offset is a parameter of reading, not a second tool with its own schema. Listing recursively is a flag, not a sibling. Five issue verbs collapse into one tool with an action field. The capability is unchanged. The advertisement shrank by almost two thirds.

The deferred row deserves an honest read as well. A names-only index of all fifteen tools costs 214 tokens, and a task that needs two of them pays 422 in total once those two load. That is the smallest number in the table, and it is not free: something has to decide which definitions to fetch, the first call to an unloaded tool takes an extra step, and clients differ in whether they support this pattern at all. Where they do, the October measurements suggest it is where the industry is heading. The 14-server measurement found deferring clients paying about 2,839 tokens per request for a set that costs 42,156 loaded in full.

You can run the same count against your own servers in an afternoon, with no new tooling:

```bash
# Ask a local stdio server for its list the way a client does,
# then price the answer the same way the demo does.
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | npx -y @modelcontextprotocol/server-filesystem /tmp \
  | python3 -c 'import sys, json
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get("id") == 2:
        tools = msg["result"]["tools"]
        print(len(tools), "tools,", round(len(json.dumps(tools)) / 4), "tokens per turn")'
```

Treat the number it prints as your budget line. If you would not approve that spend as a written line in a design doc, do not approve it as a default in a config file either.

## Spend the List Like a Budget

Four moves cover most of the savings, in the order I would make them.

First, set a token budget for the default surface and measure against it. Budget in tokens, not tool count, because count is a poor proxy for cost: in the live-server sample, an 84-tool server cost 7,569 tokens while a 54-tool server cost 19,923, the difference being schema verbosity alone. A server whose default list fits in a few thousand tokens is a reasonable starting target for most tasks.

Second, merge near duplicates into coarse tools with parameters, as the demo does. Read, list, search, and one action-dispatched tool per resource will carry most file and tracker work. Keep a merged tool only where the modes genuinely share inputs. A write tool that also deletes, with the difference buried in a flag, is a permission problem wearing a costume.

Third, defer the long tail. Keep the tools a task is likely to need in the default list, and put the rare, expensive, or dangerous ones behind an index, a namespaced second server, or a per-task profile that loads them only for sessions that ask. Rare and dangerous belong together here on purpose: the tool that runs twice a month should not be advertised, or callable, in every session.

Fourth, trim the schemas themselves. Shorten descriptions to the decision the model has to make, move examples and long explanations out of the schema and into documentation the agent can fetch, and watch for enums and nested objects that repeat the same values in every definition. Schema text is interface text. Edit it like interface text.

## Where This Breaks

Say the limits plainly, because a smaller list is not a free win:

- Coarse tools can be worse tools. One issue tool with an action field asks the model to fill fields that only apply to one action and ignore the rest, and some models handle that measurably worse than five clean verbs. If your error rate rises after a merge, the token savings bought you mistakes. Measure both.
- Deferred loading adds a step and a failure mode. The index has to be accurate, the fetch has to work, and a model that does not know a capability exists will not ask for it. Tasks that silently underperform because the right tool was never loaded are hard to spot in a log.
- The chars-per-four estimate is an estimate. Real tokenizers price JSON punctuation and short keys worse than prose, and each model counts differently. Use the number to compare your own options, not as an invoice.
- Prompt caching changes the money, sometimes a lot. On a provider with cheap cached input, the dollar argument shrinks and what remains is the context-space and selection argument. Run your own arithmetic for your provider before quoting the 98.7 percent figure, which came from a workflow rewrite, not a list trim alone.
- Some tools are listed rarely and matter completely. The recovery tool you call once during an incident is exactly the one a budget review deletes. Defer it if you can. Do not delete it to make a chart look clean.
- A small list does not fix a bad tool. A vague description on a four-tool server still misleads, and a dangerous tool in a short list is still dangerous. Budgeting is housekeeping, not a security control.

## Decide What Your Default List Owes You

Build it if:

- You run agents with two or more connected servers, or one server past roughly a dozen tools, and you have never priced its tool list.
- Your sessions are long or numerous, so a per-turn tax multiplies into real money and real context pressure: twenty turns at the demo's full list is 28,160 tokens spent describing capabilities.
- Your agent picks wrong tools often enough that you have noticed, and your list contains verbs that differ only in a parameter.

Skip it if:

- You connect one small server for short sessions. A 500-token list over five turns is noise, and your afternoon is worth more than the savings.
- Your client already defers definitions and your measured per-request cost is already in the low thousands. Verify that with the count above, then spend your effort elsewhere.
- Your tools are already coarse and your schemas already terse. The budget still applies, but you are the example, not the audience.

The minimal viable version fits in an afternoon. Price every connected server's list with the snippet above. Write the totals down. Merge the two worst near-duplicate pairs, move the tools no session has called in a month behind a profile or an index, and price the list again. Then run the same handful of real tasks against both lists and compare cost and wrong-tool calls side by side, because the second number decides whether the first one was a saving or a trade.

## Charge Rent, Then Collect It on Purpose

A tool list feels like documentation, so teams treat it as free. It behaves like rent: a fixed charge on every turn, collected whether the capability earns its place or not. The teams publishing measurements this month are not discovering a protocol flaw. They are discovering their own totals, most of them for the first time, and finding that a third to two thirds of the charge was for tools their agents rarely call. You do not need a new protocol to act on that. You need a number for your own list, a budget you are willing to defend, and the discipline to make every new tool argue its way onto the default surface instead of drifting onto it. Price your list this week, cut it to what your tasks actually call, and let the long tail load only when a task asks for it by name.

When did you last count what your agent pays before it reads the first word of the task, and which tools on that list has it never once called?

## Resources

1. [MCP Token Cost: I Cut My MCP Server From 15 Tools to 4](https://dev.to/gu_cci_f94bedb90083e6aab4/mcp-token-cost-i-cut-my-mcp-server-from-15-tools-to-4-521a)
2. [The Median MCP Server Costs 3,150 Tokens Before Your Agent Calls Anything](https://dev.to/onlyoneaman/the-median-mcp-server-costs-3150-tokens-before-your-agent-calls-anything-4np3)
3. [Best MCP Servers for Coding Agents in 2026, Measured by Token Cost](https://octomind.run/blog/best-mcp-servers)
4. [Anthropic: Code Execution with MCP, Building More Efficient Agents](https://www.anthropic.com/research/code-execution-with-mcp)
5. [Threat-Model Your MCP Server Before Attackers Do It for You](https://anushamukka.com/posts/threat-model-your-mcp-server/)
