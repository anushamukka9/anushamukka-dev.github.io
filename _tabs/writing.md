---
layout: page
icon: fas fa-pen-nib
order: 1
title: Writing
description: "Essays and technical writing by software architect Anusha Mukka on AI infrastructure, distributed systems, and security architecture."
---

## Featured

**[Your Firewall Doesn't Speak LLM! We Gave AI Agents the Keys. Nobody Asked If the Locks Still Work.](https://medium.com/@anusha_mukka/we-gave-ai-agents-the-keys-nobody-asked-if-the-locks-still-work-131a7085ab1e)** · April 17, 2026

On agentic AI and the security assumptions it quietly breaks. [Read on Medium](https://medium.com/@anusha_mukka/we-gave-ai-agents-the-keys-nobody-asked-if-the-locks-still-work-131a7085ab1e).

## On this site

{% for post in site.posts %}
- [{{ post.title }}]({{ post.url | relative_url }}) · {{ post.date | date: "%B %-d, %Y" }}
{% endfor %}
