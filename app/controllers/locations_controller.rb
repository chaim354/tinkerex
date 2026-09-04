# Locations: the same reference-list shape as Suppliers/Shelves (§14d). A location can nest under
# another (Maker::Location#parent, self-referential), and both its children and any inventory item
# pointing at it are nullified on removal rather than locked or destroyed -- see that model's
# comment.
class LocationsController < ApplicationController
  def index
    @locations = current_user.maker_locations.includes(:parent).order(:name)
    # ONE GROUPED COUNT -- see SuppliersController#index for the argument; this page is budgeted
    # the same way.
    @item_counts = current_user.maker_inventory_items.group(:location_id).count
  end

  def create
    location = current_user.maker_locations.new(location_params)
    if location.save
      redirect_to locations_path, notice: "#{location.name} added."
    else
      redirect_to locations_path, alert: location.errors.full_messages.to_sentence
    end
  end

  # SCOPED THROUGH current_user, NEVER Maker::Location.find -- a foreign id must 404, not resolve
  # another user's row. Mutation-checked alongside SuppliersController#destroy.
  def destroy
    location = current_user.maker_locations.find(params[:id])
    location.destroy!
    redirect_to locations_path, notice: "#{location.name} removed."
  end

  private

  def location_params
    params.require(:location).permit(:name, :parent_id, :description)
  end
end
