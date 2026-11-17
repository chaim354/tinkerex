module InventoryHelper
  # WHAT NARROWS THE LIST. "All" drops exactly these, and is lit exactly when none is set.
  INVENTORY_FACETS = %i[category low tag supplier location].freeze

  # THE INDEX PAGE'S FILTER STATE, BUILT ONCE. Every chip, the toolbar form's hidden fields and the
  # sort headers start from this hash and state only their difference (`merge`, `except`). They
  # each used to rebuild the parameter set by hand, eight times with eight sets of exclusions, and
  # they disagreed: a column header kept the category and the tag, while searching or re-sorting
  # from the select dropped both; with only a tag set, "All" and the tag were both lit. A new
  # facet is one key here.
  #
  # Only what is SET is in it, so a plain first visit stamps nothing on a link or the form.
  # `sort` and `dir` are the request's own, not the normalized @sort/@dir, which are always
  # concrete ("name"/"asc") and would freeze `&sort=name&dir=asc` into every chip. The supplier and
  # location are the RESOLVED ones (inventory_place_params): a foreign id names nothing to carry.
  def inventory_filters
    @inventory_filters ||= {
      q: @q.presence, category: @category, low: (@low ? 1 : nil), tag: @tag,
      sort: (params[:sort].presence if params[:sort].is_a?(String)),
      dir: (params[:dir].presence if params[:dir].is_a?(String)),
      **inventory_place_params
    }.compact
  end

  # A sortable column header for the inventory index, the same shape as FilesHelper#sort_header
  # but reading the request state off the controller's own ivars (@sort/@dir) rather than taking
  # it as arguments — this index has one params set, not files_query_base's per-view extras, so
  # there is nothing a caller would ever pass differently.
  def inventory_sort_header(label, key, col: nil)
    active = @sort == key
    next_dir = (active && @dir == "asc") ? "desc" : "asc"
    arrow = active ? (@dir == "asc" ? " ▲" : " ▼") : ""
    aria  = active ? (@dir == "asc" ? "ascending" : "descending") : "none"
    tag.th("aria-sort": aria, class: [ ("sorted" if active), col ].compact.join(" ").presence) do
      link_to("#{label}#{arrow}", inventory_items_path(inventory_filters.merge(sort: key, dir: next_dir)))
    end
  end

  # The supplier and location facets (UX audit 2026-11-01, E5), as they sit in inventory_filters —
  # composable like `tag`, so narrowing by category inside one supplier keeps the supplier. "All"
  # is the one control that drops them.
  def inventory_place_params
    { supplier: @supplier&.id, location: @location&.id }.compact
  end

  # One quantity, the way every inventory surface prints it: up to three decimals, no trailing zeros.
  def inventory_quantity(value)
    number_with_precision(value, precision: 3, strip_insignificant_zeros: true)
  end
end
