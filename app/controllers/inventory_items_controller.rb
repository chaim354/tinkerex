# Inventory on the web (stage 2, S2-3). Session-authed (§14d), on the same models and the same one
# door the v1 API uses: EVERY stock change is Maker::InventoryTransaction.apply!, and
# quantity_cached is never assigned here. The ledger is immutable — this controller has no
# transaction update or destroy, and config/routes.rb draws none.
class InventoryItemsController < ApplicationController
  QUERY_MAX = 80
  LEDGER_CAP = 200
  SORTS = {
    "name" => "LOWER(maker_inventory_items.name)",
    "quantity" => "maker_inventory_items.quantity_cached",
    "category" => "LOWER(maker_inventory_items.category)",
    "updated" => "maker_inventory_items.updated_at"
  }.freeze

  before_action :find_item, only: %i[show edit update destroy adjust]

  # The "−8" / "+50" sign used both in the flash and in the ledger's Delta column — a real minus
  # sign (U+2212), matching the ledger, not a hyphen. helper_method so the view can call it too:
  # ONE place decides the glyph, not one in the controller's flash string and a second in the view.
  helper_method :signed

  def index
    items = current_user.maker_inventory_items.includes(:location, :supplier)
    @q = params[:q].to_s.strip.first(QUERY_MAX)
    if @q.present?
      like = "%#{Maker::InventoryItem.sanitize_sql_like(@q.downcase)}%"
      items = items.where("LOWER(name) LIKE ? ESCAPE '\\' OR LOWER(part_number) LIKE ? ESCAPE '\\'", like, like)
    end
    # `?tag=` (stage 2, S2-5): same tagged_with idiom as ModelsController/ProjectsController.
    @tag = params[:tag].presence
    items = items.tagged_with(@tag) if @tag
    @category = params[:category].presence
    items = items.where(category: @category) if @category
    @low = params[:low] == "1"
    items = items.low_stock if @low
    @sort = SORTS.key?(params[:sort]) ? params[:sort] : "name"
    @dir = params[:dir] == "desc" ? "desc" : "asc"
    @items = items.order(Arel.sql("#{SORTS[@sort]} #{@dir}"), :id).to_a
    @categories = current_user.maker_inventory_items.where.not(category: [ nil, "" ]).distinct.order(:category).pluck(:category)
    # Tags in use across the user's items, for the filter chips in the toolbar's span.chips --
    # ONE query. Mirrors ProjectsController#index's @project_tags.
    @item_tags = current_user.maker_tags.joins(:taggings)
                             .where(maker_taggings: { taggable_type: "Maker::InventoryItem" })
                             .distinct.order(:name).pluck(:name)
    @low_count = current_user.maker_inventory_items.low_stock.count
  end

  def show
    ledger_scope = @item.transactions.reorder(created_at: :desc, id: :desc)
    @ledger_total = ledger_scope.count
    @ledger = ledger_scope.includes(:project).limit(LEDGER_CAP).to_a
    # THE BALANCE AFTER EACH ROW, walking back from the cached balance: the newest row's balance is
    # the balance now; each older row's is the next-newer's minus that newer delta. In Ruby, no
    # per-row query — @ledger is already loaded above.
    running = @item.quantity_cached
    @balances = @ledger.each_with_object({}) { |t, h| h[t.id] = running; running -= t.delta }
    @projects = current_project_choices
  end

  def new
    @item = current_user.maker_inventory_items.new(unit: "each")
  end

  def edit
  end

  # `initial_quantity` is a FORM-ONLY field, never assigned to the model (it is not in
  # `item_params`'s permit list) — an initial balance is posted through the SAME ledger door as
  # every other stock change, never written to quantity_cached directly.
  def create
    @item = current_user.maker_inventory_items.new(item_params)
    if @item.save
      post_initial_quantity!(@item)
      redirect_to inventory_item_path(@item), notice: "Added #{@item.name}."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @item.update(item_params)
      redirect_to inventory_item_path(@item), notice: "Saved #{@item.name}."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # `release_bom_lines` (Maker::InventoryItem, CLAUDE.md §14d) hands any BOM line pointing at this
  # item a free-text `part_name` BEFORE the pointer is dropped; `dependent: :delete_all` on
  # `transactions` removes the ledger row-level (never record-level — the ledger's before_destroy
  # would raise on anything else, see that association's comment).
  def destroy
    name = @item.name
    @item.destroy!
    redirect_to inventory_items_path, notice: "Deleted #{name}."
  end

  # POST /inventory/:id/adjust — the ledger's one door from the web, mirroring the v1 API's own
  # adjust action (V1::Maker::InventoryItemsController#adjust) field-for-field.
  def adjust
    delta = parse_delta(params.require(:transaction)[:delta])
    return redirect_to(inventory_item_path(@item), alert: "Enter a non-zero amount.") if delta.nil?

    reason = params[:transaction][:reason].presence || "adjusted"
    unless Maker::InventoryTransaction::REASONS.include?(reason)
      return redirect_to(inventory_item_path(@item), alert: "Pick a reason.")
    end

    # A FOREIGN PROJECT ID IS DROPPED, NOT REFUSED — find_by (not find) against the user's own
    # projects, same shape as ProjectsController's own tenancy scoping. The adjustment still
    # posts; it just carries no project, which is a safe silent narrowing (nobody's data leaks and
    # nothing 500s) rather than a rejection of an otherwise-valid stock change.
    project_id = params[:transaction][:project_id]
    project = current_user.maker_projects.find_by(id: project_id) if project_id.present?

    Maker::InventoryTransaction.apply!(item: @item, user: current_user, delta:, reason:,
                                        project_id: project&.id, note: params[:transaction][:note].presence)
    redirect_to inventory_item_path(@item), notice: "Posted #{signed(delta)} #{@item.unit} (#{reason})."
  end

  private

  # THE COLUMN IS decimal(12,3). BigDecimal() happily parses "Infinity", "-Infinity", "NaN" and
  # "1e400", and none of them is zero?, so a zero-check alone let them through to apply! — measured
  # in review: an Infinity row stores as Infinity while the cached balance stays put, so the
  # model's quantity_cached == SUM(delta) invariant breaks silently, rebuild_quantity_cached! then
  # writes Infinity, and the ledger being immutable, only deleting the item recovers; a NaN reaches
  # the DB as NULL and 500s. Non-finite and out-of-column amounts answer nil here, the same
  # "Enter a non-zero amount" refusal a non-number gets, at BOTH doors (adjust, initial quantity).
  MAX_DELTA = BigDecimal("999999999.999")

  def parse_delta(raw)
    delta = BigDecimal(raw.to_s)
    return nil unless delta.finite? && !delta.zero? && delta.abs <= MAX_DELTA
    delta
  rescue ArgumentError, TypeError
    nil
  end

  def post_initial_quantity!(item)
    raw = params.dig(:inventory_item, :initial_quantity)
    return if raw.blank?

    delta = parse_delta(raw)
    return if delta.nil?

    Maker::InventoryTransaction.apply!(item:, user: current_user, delta:, reason: "initial")
  end

  # 404 for a foreign or nonexistent id, never another user's data — current_user-scoped find,
  # the same pattern every other web controller in this app uses (§14d).
  def find_item
    @item = current_user.maker_inventory_items.find(params[:id])
  end

  # The v1 API's own permit list (V1::Maker::InventoryItemsController#item_params) is the web
  # form's field list too — one vocabulary for what an inventory item's facts are.
  # `quantity_cached` is deliberately ABSENT: the balance is never assigned directly, only ever
  # moved by Maker::InventoryTransaction.apply!.
  def item_params
    params.require(:inventory_item).permit(
      :name, :part_number, :category, :unit, :min_quantity, :unit_cost,
      :location_id, :supplier_id, :notes, :tag_list
    )
  end

  def signed(delta)
    n = ActiveSupport::NumberHelper.number_to_rounded(delta.abs, precision: 3, strip_insignificant_zeros: true)
    (delta.negative? ? "−" : "+") + n
  end
end
