# Suppliers: a flat reference list with an inline add and a Remove, in the shape of Shelves
# (session-authed web layer, §14d -- not the device-token v1 API, which has its own
# V1::Maker::SuppliersController and its own JSON shape). Removing a supplier never locks the rows
# that pointed at it: Maker::Supplier's own has_many associations (inventory_items, bom_lines) are
# `dependent: :nullify` -- see that model's comment for why nullify is the only safe choice.
class SuppliersController < ApplicationController
  def index
    @suppliers = current_user.maker_suppliers.order(:name)
    # ONE GROUPED COUNT, NOT A QUERY PER ROW -- the same argument Settings::ShelvesController#index
    # makes for its cards' rules. Mutation-checked (this task's step 3): swapping this for
    # `supplier.inventory_items.count` inside the view turns a flat 2-query page into one that
    # costs a query per supplier.
    @item_counts = current_user.maker_inventory_items.group(:supplier_id).count
  end

  def create
    supplier = current_user.maker_suppliers.new(supplier_params)
    if supplier.save
      redirect_to suppliers_path, notice: "#{supplier.name} added."
    else
      redirect_to suppliers_path, alert: supplier.errors.full_messages.to_sentence
    end
  end

  # SCOPED THROUGH current_user, NEVER Maker::Supplier.find -- a foreign id must 404, not resolve
  # another user's row. Mutation-checked (this task's step 3).
  def destroy
    supplier = current_user.maker_suppliers.find(params[:id])
    supplier.destroy!
    redirect_to suppliers_path, notice: "#{supplier.name} removed."
  end

  private

  def supplier_params
    params.require(:supplier).permit(:name, :url, :notes)
  end
end
