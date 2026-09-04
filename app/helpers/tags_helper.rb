module TagsHelper
  # The chip row a tagged record's page renders: one .tag-chip link per tag, alphabetical, each
  # to that tag's own /tags/:name page (stage 2, S2-5). "" when the record has no tags -- callers
  # that wrap this in their own conditional (e.g. inventory_items/show's <dt>Tags</dt>) still work
  # unconditionally-called (e.g. projects/show, right after the description) because there is
  # nothing here to wrap: no tags means no <div> at all, not an empty one.
  def tag_chips(record)
    return "".html_safe if record.tags.empty?
    tag.div(class: "tag-chips") do
      safe_join(record.tags.sort_by(&:name).map { |t| link_to t.name, tag_path(t.name), class: "tag-chip" })
    end
  end
end
