module Settings
  # THE SHELVES (2026-10-20): one card per folder the intake sweep files into under
  # Projects/<project>/ -- its extensions, its default view on a project page, its group. This was
  # the Filing page (Settings::FilingRulesController#index) and kept its markup classes; the
  # extension chips still post to FilingRulesController. Session-authed (§14d); reads and writes
  # only maker_shelves, maker_shelf_groups and maker_filing_rules -- no port, nothing to gate.
  class ShelvesController < ApplicationController
    def index
      Maker::Shelves.ensure!(current_user)
      @groups = current_user.maker_shelf_groups.order(:position, :name).to_a
      shelves = current_user.maker_shelves.order(:position, :name).to_a
      @ungrouped = shelves.reject(&:shelf_group_id)
      @by_group = shelves.select(&:shelf_group_id).group_by(&:shelf_group_id)
      # ONE QUERY, GROUPED IN MEMORY -- a `where(folder:)` per card is a query per shelf
      # (page_query_budget_test.rb grows shelves to prove it does not).
      @by_folder = current_user.maker_filing_rules.order(:ext).to_a.group_by(&:folder)
    end

    def create
      shelf = current_user.maker_shelves.new(name: params.require(:shelf).permit(:name)[:name],
                                             position: next_position)
      if shelf.save
        redirect_to settings_shelves_path, notice: "Shelf #{shelf.name}/ added."
      else
        redirect_to settings_shelves_path, alert: shelf.errors.full_messages.to_sentence
      end
    end

    # The view and the group. NOT the name: a shelf's name is a folder inside every project on
    # disk, so renaming one would mean moving folders, which this page does not do.
    def update
      shelf = current_user.maker_shelves.find(params[:id])
      if shelf.update(params.require(:shelf).permit(:default_view, :shelf_group_id))
        redirect_to settings_shelves_path, notice: "Shelf #{shelf.name}/ updated."
      else
        redirect_to settings_shelves_path, alert: shelf.errors.full_messages.to_sentence
      end
    end

    # THE RULES GO WITH THE SHELF, in one transaction: a rule naming a folder with no shelf would
    # recreate the shelf on the next visit (Maker::Shelves.ensure!). Its extensions then file into
    # `other`, which is why `other` itself cannot go.
    def destroy
      shelf = current_user.maker_shelves.find(params[:id])
      if shelf.fallback?
        return redirect_to settings_shelves_path,
                           alert: "#{shelf.name}/ is where files with no shelf go, so it can't be removed."
      end

      Maker::Shelf.transaction do
        current_user.maker_filing_rules.where(folder: shelf.name).delete_all
        shelf.destroy!
      end
      redirect_to settings_shelves_path,
                  notice: "Shelf #{shelf.name}/ removed. Its extensions file into other now."
    end

    private

    def next_position = (current_user.maker_shelves.maximum(:position) || -1) + 1
  end
end
