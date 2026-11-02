module Settings
  # THE SHELVES PAGE'S DATA, FOR EVERY DOOR THAT RENDERS IT (UX audit B3, F3). Three controllers post
  # from that page -- Shelves, ShelfGroups, FilingRules -- and a refusal from any of them re-renders
  # the page with 422, the error beside the form it came from and the typed value still in that form,
  # where it used to redirect with a toast that dropped what was typed. So the page's loading lives
  # here once rather than in #index alone.
  #
  # THE REFUSED RECORD RIDES IN ITS OWN IVAR -- @new_shelf, @failed_shelf, @new_group, @failed_group,
  # @new_rule, @failed_rule -- and NEVER @shelf, @shelf_group or @filing_rule. Those are the names the
  # page's scoped `form_with url:` forms fall back to for their field values, so a refused record
  # under one of them would refill an unrelated form; each form states its value instead.
  #
  # ONE QUERY PER TABLE, GROUPED IN MEMORY -- a `where(folder:)` per card is a query per shelf
  # (page_query_budget_test.rb grows shelves to prove it does not).
  module ShelvesPage
    private

    def load_shelves_page
      Maker::Shelves.ensure!(current_user)
      @groups = current_user.maker_shelf_groups.order(:position, :name).to_a
      shelves = current_user.maker_shelves.order(:position, :name).to_a
      @ungrouped = shelves.reject(&:shelf_group_id)
      @by_group = shelves.select(&:shelf_group_id).group_by(&:shelf_group_id)
      @by_folder = current_user.maker_filing_rules.order(:ext).to_a.group_by(&:folder)
      @shelf_names = shelves.map(&:name)
    end

    def render_shelves_refusal
      load_shelves_page
      render "settings/shelves/index", status: :unprocessable_entity
    end
  end
end
