---
layout: page
icon: fas fa-graduation-cap
order: 4
title: Tutorials
description: "Hands-on walkthrough tutorials by Anusha Mukka: build real systems in an afternoon, step by step."
---

Step-by-step tutorials you can build in an afternoon. Each one starts from a real failure, gives you runnable code, and tells you honestly where the approach breaks.

{% assign tutorials = site.posts | where_exp: "post", "post.categories contains 'Tutorials'" %}
{% for post in tutorials %}
- [{{ post.title }}]({{ post.url }}) · {{ post.date | date: "%B %-d, %Y" }}

  {{ post.description }}
{% endfor %}
