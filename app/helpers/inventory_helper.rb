module InventoryHelper
  # WHAT NARROWS THE LIST. "All" drops exactly these, and is lit exactly when none is set.
  INVENTORY_FACETS = %i[category low tag supplier location].freeze

  # The sort's words, in the select's order: the select and the Stock section's head both read them.
  SORT_LABELS = { "name" => "Name", "quantity" => "On hand", "category" => "Category", "updated" => "Updated" }.freeze

  # THE INDEX'S LEAD (Shop manual slice 7): counted off the rows the page loaded and the low-stock
  # count it already asks for, never a further query. A filtered page says how many matched; an
  # inventory with nothing in it says nothing, because its empty state does.
  def inventory_lead
    count = @items.size
    return nil if count.zero? && !@filtered
    return "#{count_words(count).capitalize} #{count == 1 ? "item matches" : "items match"}." if @filtered

    places = @items.map(&:location_id).compact.uniq.size
    where = places.positive? ? " in #{count_words(places)} #{places == 1 ? "place" : "places"}" : ""
    low = @low_count.zero? ? "None is low." : "#{count_words(@low_count).capitalize} #{@low_count == 1 ? "is" : "are"} low or out."
    short = @to_buy.empty? ? "" : " Your open projects are short of #{count_words(@to_buy.size)}."
    "#{count_words(count).capitalize} #{count == 1 ? "item" : "items"}#{where}. #{low}#{short}"
  end

  # THE TO BUY SECTION'S NOTE: how many items, and what buying them costs at their unit costs. An
  # item with no unit cost is in the count and not in the sum, and the note says the sum covers
  # fewer than all of them rather than pass it off as the whole bill.
  def to_buy_note(rows)
    costs = rows.filter_map(&:cost)
    note = count_label(rows.size, "item")
    return note if costs.empty?

    total = "about #{number_to_currency(costs.sum)}"
    total += " for #{count_words(costs.size)} of them" if costs.size < rows.size
    "#{note} · #{total}"
  end

  # WHY A TO BUY ROW IS THERE, in words: each project that needs the item, linked, with how many
  # it needs, then what is on hand, so the Buy column is the difference a reader can check.
  def to_buy_why(row)
    needs = row.needs.map do |need|
      safe_join([ link_to(need.project.name, project_path(need.project)), " needs #{inventory_quantity(need.quantity)}." ])
    end
    safe_join(needs + [ "#{inventory_quantity(row.on_hand)} on hand." ], " ")
  end

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

  # THE OTHER THINGS IN AN ITEM'S PLACE, for its page's left column: one query, capped, by name. The
  # column's last row opens the place's whole list on the index.
  PLACE_ITEMS = 12

  def inventory_place_items(item)
    @inventory_place_items ||= current_user.maker_inventory_items.where(location_id: item.location_id)
                                           .order(:name, :id).limit(PLACE_ITEMS).to_a
  end

  # One quantity, the way every inventory surface prints it: up to three decimals, no trailing zeros.
  def inventory_quantity(value)
    number_with_precision(value, precision: 3, strip_insignificant_zeros: true)
  end
end
