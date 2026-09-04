module InventoryHelper
  # A sortable column header for the inventory index, the same shape as FilesHelper#sort_header
  # but reading the request state off the controller's own ivars (@sort/@dir/@q/@category/@low)
  # rather than taking them as arguments — this index has one params set, not files_query_base's
  # per-view extras, so there is nothing a caller would ever pass differently.
  def inventory_sort_header(label, key, col: nil)
    active = @sort == key
    next_dir = (active && @dir == "asc") ? "desc" : "asc"
    arrow = active ? (@dir == "asc" ? " ▲" : " ▼") : ""
    aria  = active ? (@dir == "asc" ? "ascending" : "descending") : "none"
    tag.th("aria-sort": aria, class: [ ("sorted" if active), col ].compact.join(" ").presence) do
      link_to("#{label}#{arrow}",
              inventory_items_path(q: @q.presence, category: @category, low: (@low ? 1 : nil),
                                    tag: @tag, sort: key, dir: next_dir))
    end
  end
end
