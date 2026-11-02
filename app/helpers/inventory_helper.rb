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
                                    tag: @tag, sort: key, dir: next_dir, **inventory_place_params))
    end
  end

  # The supplier and location facets (UX audit 2026-11-01, E5), as the params every chip and header
  # carries forward — composable like `tag`, so narrowing by category inside one supplier keeps the
  # supplier. "All" is the one control that drops them.
  def inventory_place_params
    { supplier: @supplier&.id, location: @location&.id }.compact
  end

  # One quantity, the way every inventory surface prints it: up to three decimals, no trailing zeros.
  def inventory_quantity(value)
    number_with_precision(value, precision: 3, strip_insignificant_zeros: true)
  end
end
