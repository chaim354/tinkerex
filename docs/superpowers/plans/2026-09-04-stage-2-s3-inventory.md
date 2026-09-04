# Stage 2, S2-3: inventory — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S2-3 of `docs/superpowers/specs/2026-09-04-stage-2-structure-design.md` (§6): a web UI for the inventory the v1 API already serves — `/inventory` (a table with search, category and low-stock chips, sort, a low-stock badge), `/inventory/:id` (the item's facts, an **Adjust** composer that posts through `Maker::InventoryTransaction.apply!`, the immutable ledger with the balance after each row), item create/edit/delete, and two settings pages, **Suppliers** and **Locations** (list + inline add + remove, like Shelves). Home's needs-attention list gains low-stock rows. No new tables; the ledger stays immutable (no update/destroy route exists); query counts constant in N.

**Architecture:** Three session-authed controllers (§14d) on the existing `Maker::InventoryItem`, `InventoryTransaction`, `Supplier`, `Location` models; every stock change goes through `InventoryTransaction.apply!` — never a write to `quantity_cached`. Views from the design system: `.table` (with `col-*` drops), `dl.meta`, `details.composer`, `.badge`, `.toolbar`/`.chip`, and the two page sheets already linked (`pages/inventory.css`, `pages/settings.css`).

**Tech Stack:** Rails 8, Hotwire, Minitest request tests, `page_query_budget_test.rb`.

---

## Before you start

- Branch `claude/stage-2-inventory` from `main` at `1e59b37` (PR #312 merged), scaffold commit `23e6988` already on it: the routes (`resources :inventory_items, path: "inventory"` + `post :adjust, on: :member`; `resources :suppliers` / `:locations`, `only: %i[index create destroy]`, under `settings/`), the rail's Inventory item (`ShellHelper::SECTIONS["inventory"] = %w[inventory_items suppliers locations]`, seven tab-bar links), and both page sheets with their rules, linked and guarded. **Do not add routes or rail entries; they exist.**
- Worktree `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/auto-model-folder-files-bug-112353`. Never push to `main`. Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time.
- Read `docs/invariants/design-system.md` (§14m). Read CLAUDE.md §14d's bullets on `form_with` **`scope:`** (a namespaced model derives `maker_inventory_item[...]`; the controller requires `:inventory_item` — assert the rendered field name) and on the `*_belongs_to_user` validations + `release_bom_lines` (why an item's destroy hands its BOM lines a `part_name`, and why Supplier/Location nullify).
- The model facts: `InventoryItem::UNITS`, `low_stock` scope (`quantity_cached <= min_quantity`), `has_many :transactions` ordered asc with `dependent: :delete_all` (the ledger's `before_update`/`before_destroy` raise `ReadOnlyRecord`), `InventoryTransaction::REASONS = %w[consumed restocked adjusted initial]`, `InventoryTransaction.apply!(item:, user:, delta:, reason:, project_id:, note:)` (atomic: ledger row + cached balance; `project_id` is a soft reference the MODEL does not scope, so the controller must), `Supplier#url`, `Location#parent` (self-referential, `parent_belongs_to_user`). The v1 API's `item_params` permit list is the web form's field list: `name part_number category unit min_quantity unit_cost location_id supplier_id notes`.
- Search: the Files idiom — `LOWER(col) LIKE ? ESCAPE '\'` with `sanitize_sql_like` (on SQLite `sanitize_sql_like` is inert without the `ESCAPE` clause), capped at `QUERY_MAX = 80` chars.
- `git checkout -- <file>` restores to HEAD and cannot restore a new file: `git add` before a mutation check. Commit with a pathspec (`git commit -m ... -- <paths>`); another agent shares the index.

## File structure

| path | responsibility | task |
|---|---|---|
| `app/controllers/inventory_items_controller.rb`, `app/helpers/inventory_helper.rb` | index/show/new/create/edit/update/destroy/adjust; the sort header | A |
| `app/views/inventory_items/{index,show,new,edit,_form}.html.erb` | the pages | A |
| `app/controllers/home_controller.rb`, `app/views/home/index.html.erb` | low-stock attention rows | A |
| `test/integration/web/inventory_test.rb`, `home_test.rb`, `shell_layout_test.rb` (sections loop), `page_query_budget_test.rb` (index, show, home seed) | the pages and their budgets | A |
| `app/controllers/suppliers_controller.rb`, `locations_controller.rb`, `app/views/suppliers/index.html.erb`, `app/views/locations/index.html.erb` | the settings pages | B |
| `test/integration/web/settings_reference_test.rb` | their tests | B |
| `app/assets/stylesheets/pages/inventory.css`, `pages/settings.css` | already written; extend inside the layer if a page needs a rule | A / B |
| `test/system/shell_test.rb` (sweep gains the four pages), budget tests for suppliers/locations | close-out | C |

**Dependencies:** A and B are disjoint and run in parallel. C follows both.

---

### Task A: the inventory pages

- [ ] **Step 1: tests first** — `test/integration/web/inventory_test.rb` (sign in as `home_test.rb` does; helpers `item!(name, **attrs)` creating `@user.maker_inventory_items`, `post!(item, delta, reason:, project_id: nil)` using `InventoryTransaction.apply!`):
  - **index lists items with their facts and links each row** — three items with a location and a supplier; `assert_select "table.table.inventory-table tbody tr", 3`; `td.col-name a[href=?]` `inventory_item_path(item)`; `.col-onhand` text `/12 each/`; `.col-location` `/Bin A1/`; `.col-supplier` `/McMaster/`; the rows carry `data-node`? no — keep it plain.
  - **low stock is a badge, a chip and a scope** — one item at 12 with min 50 → its row has `tr.low-stock` and `.badge.low-stock`; `GET inventory_items_path(low: 1)` lists only it; the chip `a.filter.chip.active[href=?]` `inventory_items_path(low: 1)` reads `/Low stock \(1\)/`.
  - **search matches name or part number, case-insensitively, with `%` escaped** — `q: "m3"` matches `M3×8 screw`; `q: "91290"` matches its part number; `q: "100%"` matches only an item literally named `100% cotton`, not everything.
  - **category chips come from the user's own categories** — items in `Fasteners` and `Electronics` → two chips (plus All and Low stock); `category: "Fasteners"` filters; a category chip is `a.filter.chip` with `active` on the current one.
  - **sort** — `sort: "quantity", dir: "asc"` orders by `quantity_cached`; the header `th.sorted a` carries the arrow and `aria-sort`; default is name asc.
  - **the item page shows the strip, the composer and the ledger with balances** — item at 0; post `+50 initial`, `-30 consumed` (project P), `-8 consumed` → `dl.meta` has `dt` Part #, Category, On hand (`/12 each · min 50/`), Unit cost, Location, Supplier; `details.composer.adjust[open]` with `select[name='transaction[reason]']` listing `InventoryTransaction::REASONS`, `select[name='transaction[project_id]']` with the project, `input[name='transaction[delta]']`, `input[name='transaction[note]']`; `table.table.ledger tbody tr` count 3, newest first: first row delta `−8` (`.delta-out`), balance `12`; second `−30`, balance `20`, project link `a[href=?]` `project_path(project)`; third `+50` (`.delta-in`), balance `50`, reason `initial`.
  - **the ledger is capped** — `InventoryItemsController::LEDGER_CAP + 1` transactions (use `insert_all` on `maker_inventory_transactions` with `user_id`, `inventory_item_id`, `delta`, `reason`, `created_at`; then `item.rebuild_quantity_cached!`) → `LEDGER_CAP` rows and `.ledger-truncated` text `/Showing 200 of 201/`.
  - **Adjust posts through apply!** — `post adjust_inventory_item_path(item), params: { transaction: { delta: "-8", reason: "consumed", project_id: project.id, note: "base" } }` → redirect to the item, flash `/Posted −8 each \(consumed\)/`, `item.reload.quantity_cached == 4`, the newest ledger row has `project_id`, `note`; **a zero delta is refused** (`delta: "0"` → redirect with alert `/Enter a non-zero/`, no row); **a non-number is refused**; **a foreign project is dropped** (another user's project id → row saved with `project_id: nil`, flash still posts); **a reason outside REASONS is refused** (422 or alert; no row).
  - **the ledger has no edit or delete door** — `assert_raises(ActionController::RoutingError) { patch "/inventory/#{item.id}/transactions/1" }` and the same for `delete`; the item page has no `form[action*='transactions']`.
  - **new → create with an initial quantity writes an `initial` transaction, never the column** — `post inventory_items_path, params: { inventory_item: { name: "PETG black", unit: "kg", min_quantity: "1", initial_quantity: "2.5", category: "Filament" } }` → item created, `quantity_cached == 2.5`, one transaction `reason: "initial", delta: 2.5`; with a blank initial quantity, no transaction. **Assert the rendered field name**: `GET new_inventory_item_path` → `input[name='inventory_item[name]']`, `select[name='inventory_item[unit]']` with `UNITS`, `select[name='inventory_item[location_id]']`, `select[name='inventory_item[supplier_id]']`, `input[name='inventory_item[initial_quantity]']`; on edit, no initial-quantity field.
  - **edit → update** changes facts and never quantity (`inventory_item[quantity_cached]` is not permitted: post it and assert unchanged).
  - **a foreign location or supplier is refused** (another user's ids → 422, the form re-renders with the model's error).
  - **destroy releases BOM lines** — a `Maker::Bom` on a project with a line pointing at the item (`bom.lines.create!(user:, inventory_item: item, quantity: 2)`) → `delete inventory_item_path(item)` → redirect to the index with a flash; the line survives with `part_name == item.name` and `inventory_item_id nil`; the ledger rows are gone (`delete_all`).
  - **a foreign item 404s** on show/edit/adjust/destroy.
  - In `home_test.rb`: **low-stock items land in attention** — an item at 12/min 50 → `.home-attention .attention-row` text `/M3×8 screw: 12 each left, minimum 50/` with `a.btn[href=?]` `inventory_item_path(item)` text `Restock`; capped at `HomeController::ATTENTION_STOCK` (5); an item at min exactly (50/50) counts as low (the scope is `<=`).
  - In `shell_layout_test.rb`: the sections loop gains `inventory_items_path => "Inventory"`; on `GET suppliers_path` the Inventory link is active (B's controller — run this after B commits, or leave that one assertion to Task C: say which).
  - In `page_query_budget_test.rb`: `inventory#index` (grow items, each with its own location and supplier), `inventory#show` (grow transactions, each with its own project), and the `home#index` seed grows low-stock items.

- [ ] **Step 2: the controller** — `InventoryItemsController < ApplicationController`:

```ruby
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

  def index
    items = current_user.maker_inventory_items.includes(:location, :supplier)
    @q = params[:q].to_s.strip.first(QUERY_MAX)
    if @q.present?
      like = "%#{Maker::InventoryItem.sanitize_sql_like(@q.downcase)}%"
      items = items.where("LOWER(name) LIKE ? ESCAPE '\\' OR LOWER(part_number) LIKE ? ESCAPE '\\'", like, like)
    end
    @category = params[:category].presence
    items = items.where(category: @category) if @category
    @low = params[:low] == "1"
    items = items.low_stock if @low
    @sort = SORTS.key?(params[:sort]) ? params[:sort] : "name"
    @dir = params[:dir] == "desc" ? "desc" : "asc"
    @items = items.order(Arel.sql("#{SORTS[@sort]} #{@dir}"), :id).to_a
    @categories = current_user.maker_inventory_items.where.not(category: [ nil, "" ]).distinct.order(:category).pluck(:category)
    @low_count = current_user.maker_inventory_items.low_stock.count
  end

  def show
    ledger_scope = @item.transactions.reorder(created_at: :desc, id: :desc)
    @ledger_total = ledger_scope.count
    @ledger = ledger_scope.includes(:project).limit(LEDGER_CAP).to_a   # add `belongs_to :project, optional: true` to the model if absent — check first
    # THE BALANCE AFTER EACH ROW, walking back from the cached balance: newest row's balance is the
    # balance now; each older row's is the next-newer's minus that newer delta. In Ruby, no query.
    running = @item.quantity_cached
    @balances = @ledger.each_with_object({}) { |t, h| h[t.id] = running; running -= t.delta }
    @projects = current_project_choices
  end
  ...
  def adjust
    delta = BigDecimal(params.require(:transaction)[:delta].to_s) rescue nil
    return redirect_to(inventory_item_path(@item), alert: "Enter a non-zero amount.") if delta.nil? || delta.zero?
    reason = params[:transaction][:reason].presence || "adjusted"
    return redirect_to(inventory_item_path(@item), alert: "Pick a reason.") unless Maker::InventoryTransaction::REASONS.include?(reason)
    project = current_user.maker_projects.find_by(id: params[:transaction][:project_id]) if params[:transaction][:project_id].present?
    Maker::InventoryTransaction.apply!(item: @item, user: current_user, delta:, reason:, project_id: project&.id,
                                       note: params[:transaction][:note].presence)
    redirect_to inventory_item_path(@item), notice: "Posted #{signed(delta)} #{@item.unit} (#{reason})."
  end
```

`create`: build from `item_params` (the API's permit list), save, then if `params.dig(:inventory_item, :initial_quantity).present?` and non-zero, `apply!(item:, user:, delta:, reason: "initial")`; redirect to the item. `update`: `item_params` only. `destroy`: `@item.destroy!` then redirect to the index with `"Deleted #{name}."`. `find_item`: `current_user.maker_inventory_items.find(params[:id])` (404 for a foreign id via `ActiveRecord::RecordNotFound`). `signed(delta)` renders `−8` / `+50` (a real minus sign, U+2212, matching the ledger).

Check `Maker::InventoryTransaction` for a `project` association; if it has only the soft `project_id`, add `belongs_to :project, class_name: "Maker::Project", optional: true` **without** a validation (the column is a soft reference by design — read the model's test "project_id is a soft reference") so `includes(:project)` works and a deleted project renders as "—".

`app/helpers/inventory_helper.rb`: `inventory_sort_header(label, key, col:)` — the same shape as `FilesHelper#sort_header` but linking to `inventory_items_path(q: @q, category: @category, low: (@low ? 1 : nil), sort: key, dir: next_dir)`.

- [ ] **Step 3: the views.** `index.html.erb`: `page-head` (h1 Inventory, `link_to "New item", new_inventory_item_path, class: "btn primary"`); `form.toolbar.inventory-toolbar` (GET; `input[type=search][name=q]` placeholder "Name or part number"; `span.chips` with All / `Low stock (n)` / one chip per category — `a.filter.chip` + `active`; the hidden sort/dir carried; a `select[name=sort]` with `onchange="this.form.requestSubmit()"` like models/index; `span.toolbar-count` "N items"); the table `table.table.inventory-table` with `thead` from `inventory_sort_header` for Name/Category/On hand(quantity)/Updated and plain `th` for Part #, Min, Location, Supplier — `col-name col-part col-category col-onhand col-min col-location col-supplier` classes on th AND td; each row `tr` with `class: ("low-stock" if item.quantity_cached <= item.min_quantity)`; on-hand cell `td.num.col-onhand` "12 each" (format quantities with `number_with_precision(q, precision: 3, strip_insignificant_zeros: true)`); empty state `p.empty.muted` "No inventory yet. Add your first item." `show.html.erb`: crumbs (`content_for :crumbs`: Inventory / name), `page-head.page-title` h1 + `.badge.low-stock` when low; actions Edit (`btn small`), Delete (`button_to ... method: :delete, class: "btn small danger", form: { data: { turbo_confirm: } }`); `dl.meta`; `p.item-notes` when notes; `details.composer.adjust` **open**, summary "Adjust stock", `form_with url: adjust_inventory_item_path(@item), scope: :transaction, method: :post` with `.adjust-fields` (delta `number_field step: "any"`, reason select, project select with a blank option, note text field, submit `btn primary adjust-submit` "Post"); `table.table.ledger` (When `col-when` | Delta `num` | Balance `num` | Reason | Project `col-project` | Note `col-note`), delta cells `span.delta-in`/`.delta-out` with `+`/`−` signs, balance from `@balances[t.id]`, project as a link or "—"; `p.muted.ledger-truncated` when `@ledger_total > @ledger.size` ("Showing 200 of 201 entries."). `_form.html.erb`: `form_with model: @item, scope: :inventory_item, url:` (new → `inventory_items_path`, edit → `inventory_item_path(@item)`) with `label.field` wrappers as `projects/_form` uses; on new only, `initial_quantity` (number, step any) with a hint "Posts an initial transaction; the balance is never edited directly."; location and supplier selects from `current_user.maker_locations.order(:name)` / `maker_suppliers.order(:name)` with a blank option; a `.form-actions` row with submit and Cancel. Error rendering like `projects/_form`.

  Home: `HomeController::ATTENTION_STOCK = 5`; `@low_stock = current_user.maker_inventory_items.low_stock.order(:name).limit(ATTENTION_STOCK).to_a`; `home/index.html.erb`'s attention section renders `attention-row attention-row--warn` rows after the failed prints: "<name>: <qty> <unit> left, minimum <min>." + `link_to "Restock", inventory_item_path(item), class: "btn small"`; the section is empty only when both lists are. Add `.attention-row--warn .attention-mark { background: var(--accent); }` to `pages/home.css`.

- [ ] **Step 4: run** the four test files + `template_hygiene_test.rb` + `css_hygiene_test.rb` + `stimulus_hygiene_test.rb` + `bin/ci style`. Add every new page to `template_hygiene_test.rb`'s coverage map if its guard asks (it did for S2-1 and S2-2).

- [ ] **Step 5: mutation-check** (stage first; verbatim output; restore): (a) write `quantity_cached` directly in `adjust` instead of `apply!` → the ledger-row assertion in the adjust test fails; (b) drop `ESCAPE '\\'` → the `100%` search test fails; (c) drop `.includes(:project)` on the ledger → `inventory#show` budget fails; (d) let a foreign project through (`params[:transaction][:project_id]` unscoped) → the foreign-project test fails; (e) drop `low_stock` from the Home query → the attention test fails.

- [ ] **Step 6: commit** with a pathspec: `Inventory on the web: the table, the item page, Adjust through the ledger's one door`.

---

### Task B: Suppliers and Locations

- [ ] **Tests first** — `test/integration/web/settings_reference_test.rb` (sign in like `shelves_test.rb`): suppliers index lists the user's suppliers A→Z with `a[href]` for a `url`, the item count per supplier ("4 items"), and a Remove `button` per row; `post suppliers_path, params: { supplier: { name: "McMaster", url: "https://mcmaster.com" } }` → created, redirect back, flash; a blank name re-renders/redirects with the model's error; `delete supplier_path(s)` → gone, its items' `supplier_id` nullified (create one item first and assert), flash; a foreign supplier 404s. Locations: rows show the parent ("Drawer B1 · in Cabinet B"), create with `parent_id`, a foreign `parent_id` is refused (422/alert), remove nullifies children and items. Both pages: `h1`, the rail's Inventory link active (`aside.rail a.rail-link[aria-current='page'][href=?]` `inventory_items_path`), a Back link to `inventory_items_path`. **Assert the rendered form field names** (`input[name='supplier[name]']`, `select[name='location[parent_id]']`).
- [ ] **Controllers** — `SuppliersController` / `LocationsController < ApplicationController`, `index` (`current_user.maker_suppliers.order(:name)` + ONE grouped count `current_user.maker_inventory_items.group(:supplier_id).count`; locations `includes(:parent)` + the same count by `location_id`), `create` (`params.require(:supplier).permit(:name, :url, :notes)` / `params.require(:location).permit(:name, :parent_id, :description)`, `current_user.maker_*.new`, save → redirect with notice, else redirect with `alert: model.errors.full_messages.to_sentence`), `destroy` (`find` → `destroy!` → redirect with notice). A foreign `parent_id` fails the model's `parent_belongs_to_user`; surface its message.
- [ ] **Views** — `suppliers/index.html.erb` and `locations/index.html.erb` in the Shelves shape with the settings classes already in `pages/settings.css`: `page-head` (h1, `link_to "Inventory", inventory_items_path, class: "btn ghost small"`), a one-line `p.muted` purpose sentence, `ul.settings-list` rows (`span.settings-name`, `a.settings-fact` for the url / `span.settings-fact` for the parent and the item count, `button_to "Remove", ..., method: :delete, class: "linkbtn danger small settings-remove", form: { data: { turbo_confirm: } }`), `form.settings-add` (`form_with url: suppliers_path, scope: :supplier` — a bare `url:` form with `fields_for` would emit `[supplier][name]` (§14d) — so use `scope:` and plain `f.text_field`), submit `btn primary` "Add supplier" / "Add location". Locations' add form has a `select[name='location[parent_id]']` of the user's locations with a blank option. `content_for :title`.
- [ ] **Run** the test file + `template_hygiene_test.rb` (add the two pages to its map if it asks) + `bin/ci style`; **mutations**: (a) unscope the supplier lookup in `destroy` (`Maker::Supplier.find`) → the foreign-404 test fails; (b) count items per supplier with a query per row → Task C's budget test would catch it; for now report the query count of the index with 3 vs 6 suppliers using the `count_queries` idiom from `page_query_budget_test.rb` and assert it in your test file's own helper. Commit with a pathspec: `Suppliers and Locations: reference lists with an inline add, like Shelves`.

---

### Task C: close-out (the orchestrator)

- [ ] Budget tests for `suppliers#index` and `locations#index` in `page_query_budget_test.rb`; the phone sweep in `test/system/shell_test.rb` gains `inventory_items_path`, `inventory_item_path(item)`, `suppliers_path`, `locations_path` (with an item, a supplier and a location created in its setup); look at the four pages on the dev server; `bin/ci`; `/finish-branch`; `bin/log arc --from-pr <n>`.
