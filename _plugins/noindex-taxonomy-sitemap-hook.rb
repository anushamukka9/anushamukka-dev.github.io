#!/usr/bin/env ruby
#
# SEO trim (2026-10-19): keep tag/category listing pages out of sitemap.xml.
#
# The /tags/* and /categories/* pages (jekyll-archives pages plus the tags and
# categories tabs) are thin auto-generated listings. They carry a noindex meta
# via _includes/metadata-hook.html; this hook also drops them from the sitemap
# by flagging sitemap: false before jekyll-sitemap reads page data.
# Reversible: delete this file and the metadata-hook block to restore.

Jekyll::Hooks.register :pages, :post_init do |page|
  url = page.url.to_s
  if url.start_with?('/tags/', '/categories/') || url == '/tags' || url == '/categories'
    page.data['sitemap'] = false
  end
end

Jekyll::Hooks.register :site, :pre_render do |site|
  site.pages.each do |page|
    url = page.url.to_s
    if url.start_with?('/tags/', '/categories/') || url == '/tags' || url == '/categories'
      page.data['sitemap'] = false
    end
  end
end
