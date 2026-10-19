#!/usr/bin/env ruby
#
# SEO trim (2026-10-19): keep tag/category listing pages out of sitemap.xml.
#
# The /tags/* and /categories/* pages (jekyll-archives pages plus the tags and
# categories tabs, which live in the tabs collection) are thin auto-generated
# listings. They carry a noindex meta via _includes/metadata-hook.html; this
# hook also drops them from the sitemap by flagging sitemap: false before
# jekyll-sitemap reads page data.
# Reversible: delete this file and the metadata-hook block to restore.
#
# FIX (2026-10-19): the original version also registered :pages/:documents
# :post_init hooks that read page.url/doc.url. Reading a document's URL that
# early memoizes it BEFORE front-matter defaults are merged, which locked
# every post into Jekyll's fallback /posts/<full-filename>/ URL (dated form)
# and broke the site's /posts/:title/ permalinks. Only the :pre_render hook
# below is safe: by then every URL is final. Do not re-add post_init URL reads.

def taxonomy_url?(url)
  u = url.to_s
  u.start_with?('/tags/', '/categories/') || u == '/tags' || u == '/categories'
end

Jekyll::Hooks.register :site, :pre_render do |site|
  site.pages.each do |page|
    page.data['sitemap'] = false if taxonomy_url?(page.url)
  end
  site.collections.each_value do |collection|
    collection.docs.each do |doc|
      doc.data['sitemap'] = false if taxonomy_url?(doc.url)
    end
  end
end
