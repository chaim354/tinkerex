atom_feed(root_url: @page_url,
          url: public_feed_url(@pub.handle, @pub.project.slug, **@pub.link_params),
          id: "tag:tinkerex,#{@pub.project.created_at.to_date}:project/#{@pub.project.id}") do |feed|
  feed.title "#{@pub.project.name} — @#{@pub.handle}"
  # THE NEWEST ITEM'S TIME, falling back to the project's own — a feed with no entries and no
  # releases still has to carry an `updated`, and "now" would make every poll look like a change.
  feed.updated(@items.first&.time || @pub.project.updated_at)

  @items.each do |item|
    # `id:`, `url:`, `updated:` AND `published:` ARE ALL PASSED EXPLICITLY, and none of the four is
    # decoration. AtomFeedBuilder#entry defaults `id` to "tag:<host>,<schema_date>:<class>/<id>",
    # `url` to `polymorphic_url(record)`, and the two times to the record's `created_at`/
    # `updated_at` — every one of which assumes an ActiveRecord. These items are a Data
    # (Maker::PublicProject::FeedItem) carrying the merged build-log/release stream, so the
    # defaults would be a NoMethodError on `polymorphic_url` and a feed with no timestamps at all.
    # Verified by rendering, not by reading the helper.
    #
    # THE TAG URI IS OURS AND DOES NOT NAME THE HOST. A feed reader keys on the id, so deriving it
    # from `request.host` (the helper's default) would make every item in a reader's history a NEW
    # item the day this app is reached through another hostname.
    feed.entry(item, id: "tag:tinkerex,#{item.time.to_date}:#{item.kind}/#{item.id}",
               url: item.url, updated: item.time, published: item.time) do |e|
      e.title item.title
      # `type: "html"` and NOT "xhtml": the string is Action Text's already-rendered, already
      # sanitized markup, and the xhtml form would require it to be well-formed XML — which
      # ordinary HTML is not obliged to be. Builder escapes it into the element as text, so the
      # reader unescapes exactly what the page shows.
      e.content item.html, type: "html"
      e.author { |a| a.name "@#{@pub.handle}" }
    end
  end
end
