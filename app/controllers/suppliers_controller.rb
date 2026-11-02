# Suppliers: a flat reference list with an inline add, a page to rename one and keep notes on it,
# and a Remove (session-authed web layer, §14d -- not the device-token v1 API, which has its own
# V1::Maker::SuppliersController and its own JSON shape). Removing a supplier never locks the rows
# that pointed at it: Maker::Supplier's own has_many associations (inventory_items, bom_lines) are
# `dependent: :nullify` -- see that model's comment for why nullify is the only safe choice.
#
# A REFUSAL RE-RENDERS WITH ITS ERRORS AND WHAT WAS TYPED (UX audit 2026-11-01, B3): the add form on
# the list, the edit form on its page, 422 either way. Both used to redirect with an alert, which
# dropped the input.
class SuppliersController < ApplicationController
  before_action :find_supplier, only: %i[edit update destroy]

  def index
    load_index
    # The add form's empty values: a bare record, NOT `current_user.maker_suppliers.new`, which would
    # sit in the association's loaded target for the rest of the request.
    @supplier = Maker::Supplier.new
  end

  def create
    @supplier = current_user.maker_suppliers.new(supplier_params)
    if @supplier.save
      redirect_to suppliers_path, notice: "Added #{@supplier.name}."
    else
      load_index
      render :index, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @supplier.update(supplier_params)
      redirect_to suppliers_path, notice: "Saved #{@supplier.name}."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @supplier.destroy!
    redirect_to suppliers_path, notice: "Removed #{@supplier.name}."
  end

  private

  def load_index
    @suppliers = current_user.maker_suppliers.order(:name)
    # ONE GROUPED COUNT, NOT A QUERY PER ROW -- the same argument Settings::ShelvesController#index
    # makes for its cards' rules. Mutation-checked (this task's step 3): swapping this for
    # `supplier.inventory_items.count` inside the view turns a flat 2-query page into one that
    # costs a query per supplier.
    @item_counts = current_user.maker_inventory_items.group(:supplier_id).count
  end

  # SCOPED THROUGH current_user, NEVER Maker::Supplier.find -- a foreign id must 404, not resolve
  # another user's row. Mutation-checked (this task's step 3).
  def find_supplier
    @supplier = current_user.maker_suppliers.find(params[:id])
  end

  def supplier_params
    params.require(:supplier).permit(:name, :url, :notes)
  end
end
