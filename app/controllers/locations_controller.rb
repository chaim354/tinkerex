# Locations: the same reference-list shape as Suppliers/Shelves (§14d). A location can nest under
# another (Maker::Location#parent, self-referential), and both its children and any inventory item
# pointing at it are nullified on removal rather than locked or destroyed -- see that model's
# comment. Renamed, re-placed and annotated on its own page; the column for its notes is
# `description`, which the forms call Notes.
#
# A REFUSAL RE-RENDERS WITH ITS ERRORS AND WHAT WAS TYPED (UX audit 2026-11-01, B3), as Suppliers'.
class LocationsController < ApplicationController
  before_action :find_location, only: %i[edit update destroy]

  def index
    load_index
    # The add form's empty values, as SuppliersController#index's.
    @location = Maker::Location.new
  end

  def create
    @location = current_user.maker_locations.new(location_params)
    if @location.save
      redirect_to locations_path, notice: "Added #{@location.name}."
    else
      load_index
      render :index, status: :unprocessable_entity
    end
  end

  def edit
    load_parents
  end

  def update
    if @location.update(location_params)
      redirect_to locations_path, notice: "Saved #{@location.name}."
    else
      load_parents
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @location.destroy!
    redirect_to locations_path, notice: "Removed #{@location.name}."
  end

  private

  def load_index
    @locations = current_user.maker_locations.includes(:parent).order(:name)
    # ONE GROUPED COUNT -- see SuppliersController#index for the argument; this page is budgeted
    # the same way.
    @item_counts = current_user.maker_inventory_items.group(:location_id).count
  end

  # A location's possible parents: every other location of this user's. Not its own descendants
  # either, which would make a cycle: Maker::Location refuses one (`parent_is_not_inside_this`), and
  # the page simply never offers it — they are left out here, walked in memory off one pluck.
  def load_parents
    rows = current_user.maker_locations.order(:name).pluck(:id, :name, :parent_id)
    children = rows.group_by(&:last)
    excluded = Set.new([ @location.id ])
    frontier = [ @location.id ]
    until frontier.empty?
      frontier = frontier.flat_map { |id| Array(children[id]).map(&:first) }.reject { |id| excluded.include?(id) }
      excluded.merge(frontier)
    end
    @parent_choices = rows.reject { |id, _, _| excluded.include?(id) }.map { |id, name, _| [ name, id ] }
  end

  # SCOPED THROUGH current_user, NEVER Maker::Location.find -- a foreign id must 404, not resolve
  # another user's row. Mutation-checked alongside SuppliersController#destroy.
  def find_location
    @location = current_user.maker_locations.find(params[:id])
  end

  def location_params
    params.require(:location).permit(:name, :parent_id, :description)
  end
end
