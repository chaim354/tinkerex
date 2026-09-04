# Stage 2, S2-5: tags and search — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S2-5 of `docs/superpowers/specs/2026-09-04-stage-2-structure-design.md` (§8). **Tags** become a web feature wherever the data already allows: projects and inventory items gain the same polymorphic `Maker::Tag` models carry, with a comma-separated editor on their forms, tag chips on their pages, and `?tag=` filter chips on their indexes; `/tags/:name` lists everything wearing a tag, grouped by kind. **Search** grows from files to everything: `/search?q=` renders five results per kind (files, projects, models, inventory, tags) with "See all" links into each index's own search; the top bar posts there, and the Files page keeps its own search in its toolbar. No new tables; query counts constant in N.

**Architecture:** `Maker::Taggable` (a concern) holds what `Maker::Model` implements today — `taggings`/`tags`, `tag_list`, `tag_list=`, the deferred `apply_pending_tag_list`, a `tagged_with(name)` scope — and is included by Model, Project and InventoryItem. `TagsController#show` and `SearchController#index` are read-only, session-authed (§14d), and render one shared result-group partial. Search uses the Files idiom (`LOWER(col) LIKE ? ESCAPE '\'`, `sanitize_sql_like`, `QUERY_MAX = 80`), one query per kind plus one count per kind, each capped at five.

**Tech Stack:** Rails 8, Hotwire (GET forms), Minitest request tests, `page_query_budget_test.rb`.

---

## Before you start

- Branch `claude/stage-2-tags-search` from `main` at `89c060a` (PR #314 merged); the routes are committed: `search_path(q:)` → `SearchController#index`, `tag_path(name)` → `TagsController#show` (`tags/:name`, any segment without a slash). Worktree `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/auto-model-folder-files-bug-112353`. Never push to `main`.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time; commit with a pathspec (another agent shares the index).
- Read `docs/invariants/design-system.md` (§14m) and `docs/invariants/files-preview.md` (a file row in search results is a plain name link, never a poll cell). CLAUDE.md §14d's `form_with scope:` bullet binds every form here. `Maker::Tag` normalizes `name` (strip, downcase) and is unique per user; `Maker::Tagging` is polymorphic on `taggable` with a unique `(tag, taggable)`.
- The Files page's search idiom is `FilesController#index` (`resolve_query`, the `LOWER(name) LIKE ? ESCAPE '\'` clause with its comment); `Node.present`, `visible_entries(false)`, `outside_repo_metadata`.
- **Fixtures**: a project folder is `project_folder_rows!`; nodes are `@user.nodes.create!(node_id:, name:, kind: "file")`; never `ensure_library_folder!` in a request test.
- `git checkout -- <file>` cannot restore a new file: `git add` before a mutation check.

## File structure

| path | responsibility | task |
|---|---|---|
| `app/models/concerns/maker/taggable.rb` (new), `app/models/maker/model.rb` (include it, drop the moved code), `project.rb`, `inventory_item.rb` (include) | the shared tag behaviour | A |
| `app/controllers/tags_controller.rb`, `app/views/tags/show.html.erb`, `app/views/shared/_result_group.html.erb` (the grouped list both pages render), `app/helpers/tags_helper.rb` (`tag_chips`) | the tag page and the chips | A |
| `app/views/projects/_form.html.erb`, `app/views/inventory_items/_form.html.erb` (`tag_list` field), `app/controllers/projects_controller.rb` (`:tag_list` permitted; `index` filters `?tag=`), `app/controllers/inventory_items_controller.rb` (same), `app/views/projects/index.html.erb`, `app/views/inventory_items/index.html.erb` (filter chips), `app/views/projects/show.html.erb`, `app/views/inventory_items/show.html.erb` (the object's chips) | tags on the surfaces | A |
| `app/assets/stylesheets/components.css` (`.tag-chips`, `.tag-chip`) | the chip component | A |
| `test/models/maker/taggable_test.rb` (new), `test/integration/web/tags_test.rb` (new), `project_page_test.rb`/`inventory_test.rb` (chips + editor), `page_query_budget_test.rb` (`tags#show`; `projects#index` and `inventory#index` seeds grow tags), `template_hygiene_test.rb` | A's tests | A |
| `app/controllers/search_controller.rb`, `app/views/search/index.html.erb`, `app/assets/stylesheets/pages/search.css` (new, linked in the layout + `css_hygiene_test.rb`) | the results page | B |
| `app/views/layouts/_topbar.html.erb` (posts to `search_path`, placeholder "Search everything"), `app/views/files/index.html.erb` / `_ext_filter.html.erb` (the Files toolbar gains a visible `q` input) | where search lives | B |
| `test/integration/web/search_test.rb` (new), `shell_layout_test.rb` (the top bar pin), `files_toolbar_test.rb` / `files_search_test.rb` (the toolbar input), `test/system/shell_test.rb` (sweep gains `search_path(q:)` and `tag_path`) | B's tests | B |

**Dependencies:** A and B are disjoint except `shared/_result_group.html.erb`, which A writes and B renders; B writes everything, then waits for A's commit (`git log -1 -- app/views/shared/_result_group.html.erb`) before running. C (the orchestrator) adds the `search#index` budget test.

---

### Task A: tags everywhere they already are in the data

- [ ] **Step 1: the concern.** `app/models/concerns/maker/taggable.rb`:

```ruby
module Maker
  # What a taggable thing shares (stage 2, S2-5): the polymorphic edge onto Maker::Tag, the
  # comma-separated `tag_list` the forms edit, and the deferred apply that makes it safe on a new,
  # unsaved record. Lifted from Maker::Model verbatim, where models/_form has used it since the
  # catalog shipped; Project and InventoryItem include it now. A tag name is whatever Maker::Tag
  # normalizes (stripped, downcased), unique per user, find-or-created on write.
  module Taggable
    extend ActiveSupport::Concern

    included do
      has_many :taggings, as: :taggable, class_name: "Maker::Tagging", dependent: :destroy
      has_many :tags, through: :taggings, class_name: "Maker::Tag"
      after_save :apply_pending_tag_list

      # Rows wearing the tag NAMED here (normalized the way Tag stores it); a name nobody uses is
      # an empty set, not an error. ONE join, no subquery per row.
      scope :tagged_with, ->(name) {
        joins(:tags).where(maker_tags: { name: name.to_s.strip.downcase })
      }
    end

    def tag_list = tags.map(&:name).sort.join(", ")
    def tag_list=(str) = @tag_list_pending = str

    private

    def apply_pending_tag_list
      return unless defined?(@tag_list_pending)
      names = @tag_list_pending.to_s.split(",").map { |n| n.strip.downcase }.reject(&:blank?).uniq
      wanted = names.map { |n| user.maker_tags.find_or_create_by!(name: n) }
      transaction do
        taggings.where.not(tag_id: wanted.map(&:id)).destroy_all
        wanted.each { |t| taggings.find_or_create_by!(user: user, tag: t) }
      end
      remove_instance_variable(:@tag_list_pending)
    end
  end
end
```

`Maker::Model`: `include Maker::Taggable`, delete the moved associations, callback, `tag_list`, `tag_list=`, `apply_pending_tag_list` (keep any comment that explains history by pointing at the concern). `Maker::Project` and `Maker::InventoryItem`: `include Maker::Taggable`. `ModelsController#index`'s existing `params[:tag]` join can become `tagged_with(params[:tag])` — same SQL. Test `test/models/maker/taggable_test.rb`: on a Project and an InventoryItem — `tag_list=` on a NEW record applies after save; replaces the set; normalizes ("  Laser , LASER, firmware ") to two tags; a tag shared by a model and a project is ONE `maker_tags` row; `tagged_with("laser")` finds the project and not another; destroying the project destroys its taggings and not the tag. Run `test/models/maker/model_test.rb` (whatever pins `tag_list` there) to prove the lift changed nothing.

- [ ] **Step 2: the chips and the editor.** `TagsHelper#tag_chips(record)` → `tag.div(class: "tag-chips") { record.tags.sort_by(&:name).map { |t| link_to t.name, tag_path(t.name), class: "tag-chip" } }` (empty string when none — use `safe_join`). Components: `.tag-chips { display: flex; flex-wrap: wrap; gap: 6px }`, `.tag-chip { the .chip look at 11px mono, lowercase, with the accent on hover }` in `components.css` beside `.chip` (add both to `COMPONENT_SELECTORS` if the guard lists selectors explicitly — read `test/css_hygiene_test.rb`). Forms: `projects/_form` and `inventory_items/_form` gain `<label class="field">Tags <%= f.text_field :tag_list, placeholder: "laser, firmware" %></label>` with a `.hint` "Comma-separated"; permit `:tag_list` in both controllers. Pages: `projects/show.html.erb` renders `tag_chips(@project)` under the description; `inventory_items/show.html.erb` adds `<dt>Tags</dt><dd>` with the chips when any. Indexes: `ProjectsController#index` applies `tagged_with(params[:tag])` when present (BEFORE the archived partition) and sets `@tag`; `@project_tags = current_user.maker_tags.joins(:taggings).where(maker_taggings: { taggable_type: "Maker::Project" }).distinct.order(:name).pluck(:name)` (ONE query); the view renders a `.toolbar.projects-toolbar` with `a.filter.chip` per tag (+ "All") only when `@project_tags.any?`, keeping `archived` in the chip hrefs. `InventoryItemsController#index`: the same with `Maker::InventoryItem`, the chips joining the existing toolbar's `span.chips` after the category chips, `tag` carried by the sort header and the other chips (read `InventoryHelper#inventory_sort_header`).

- [ ] **Step 3: the tag page.** `TagsController#show`: `@tag = current_user.maker_tags.find_by!(name: params[:name].to_s.strip.downcase)` (404 otherwise); `@groups` = `[ ["Projects", current_user.maker_projects.tagged_with(@tag.name).order(:name).to_a], ["Models", current_user.maker_models.tagged_with(@tag.name).order(:title).to_a], ["Inventory", current_user.maker_inventory_items.tagged_with(@tag.name).order(:name).to_a] ]` — three queries, each capped at `TagsController::GROUP_CAP = 100` with a count when capped (the desktop client's `Maker::Item` rows are NOT listed — the web has no item page; say so in a comment). View: crumbs `Tags / <name>`, `page-head` (h1 the tag as a chip + "N things"), then `render "shared/result_group", title:, records:, kind:` per non-empty group.

  **`shared/_result_group.html.erb` — the contract B renders too.** Locals: `title` (String), `kind` (`:project | :model | :inventory_item | :file | :tag`), `records` (Array), `total` (Integer, may exceed `records.size`), `more_path` (String or nil), `more_label` (default "See all"). Renders `section.result-group.result-group--<kind>` → `h2` (title + `span.muted` count) → `ul.result-list` → `li.result-row` per record with, by kind: project → `link_to name, project_path` + `span.result-sub` description truncated 80; model → `link_to title, model_path` + status badge (`.badge.mstatus-<status>`); inventory_item → `link_to name, inventory_item_path` + `span.result-sub` "12 each · Bin A1"; file → `link_to node.name, file_path(node.node_id)` + `span.result-sub` the ext label (upcased, ≤4) — a PLAIN link, no `thumb_cell_data`; tag → `link_to name, tag_path(name), class: "tag-chip"`. After the list, `p.result-more` with `link_to more_label, more_path` when `more_path && total > records.size` ("See all 12"). Empty `records` → render nothing.

- [ ] **Step 4: tests** — `tags_test.rb`: the page groups by kind with counts and links; a name is normalized (`/tags/LASER` finds `laser`); an unknown tag 404s; another user's tag 404s; a dotted name (`v2.1`) routes. `project_page_test.rb`: chips under the description linking to `tag_path`; the form's `input[name='project[tag_list]']`; PATCH with `tag_list: "laser, firmware"` → two tags, chips render; the projects index shows filter chips and `?tag=laser` narrows (an untagged project absent). `inventory_test.rb`: the same three on items (`input[name='inventory_item[tag_list]']`, `?tag=` narrowing, chips in the meta strip). Budgets: `tags#show` (grow all three kinds under one tag); the `projects#index` and `inventory#index` seeds tag every record with its own tag so the chip query is measured. `template_hygiene_test.rb` gains `"tags/show" => tag_path("laser")` with a tagged fixture.

- [ ] **Step 5: mutation-check** (stage first; verbatim; restore): (a) `tagged_with` ignoring the name (`joins(:tags)` alone) → the narrowing tests fail; (b) `TagsController#show` finding across users (`Maker::Tag.find_by!`) → the foreign-tag test fails; (c) `apply_pending_tag_list` skipping the `where.not … destroy_all` → the replace test fails; (d) the chip query per project in the view (`project.tags` on each card) → the `projects#index` budget fails.

- [ ] **Step 6: commit** with a pathspec: `Tags on projects and inventory: one Taggable concern, chips, an editor, a page per tag`.

---

### Task B: search everything, from the top bar

- [ ] **Step 1: tests first** — `test/integration/web/search_test.rb`:
  - `GET search_path(q: "lamp")` → `h1` "Search", the query echoed in `input[name=q][value=lamp]`; groups `.result-group--file`, `--project`, `--model`, `--inventory_item`, `--tag` each present only when it has rows; a file `lamp-base.stl` (a live, visible file node) → a row linking `file_path`; a project "Desk Lamp" (name match) and a project whose DESCRIPTION mentions lamp → both; a model "lamp-shade"; an item "12 V lamp brick" (name) and one whose PART NUMBER matches; a tag `lamp` → a `.tag-chip[href=?]` `tag_path("lamp")`.
  - **five per group with See all**: seven matching files → 5 rows, `.result-more a[href=?]` `files_path(q: "lamp")` text `/See all 7/`; same for models → `models_path(q:)`, inventory → `inventory_items_path(q:)`, projects → `projects_path(q:)` (add `q` to `ProjectsController#index`: `LOWER(name) LIKE`, ONE line, and a test in this file that `projects_path(q: "lamp")` narrows).
  - **the query is escaped and capped** — `q: "100%"` matches only a file literally named `100%.stl`; `_` is literal; a 200-char query is truncated to `SearchController::QUERY_MAX` (80) and does not error.
  - **hidden and deleted files do not surface** — a tombstoned node and a `.DS_Store` are absent.
  - **an empty query renders the prompt** — no groups, `p.search-prompt`.
  - **tenancy** — another user's project, item and tag never appear.
  - `shell_layout_test.rb:~106`: the top bar's form posts to `search_path` with placeholder "Search everything" (update the pin and its comment). `files_toolbar_test.rb`: the Files toolbar gains `input[type=search][name=q]` inside `.toolbar.files-toolbar` (and `_ext_filter`'s hidden `q` goes away, since the visible input carries it — read `files_search_test.rb`; every `files_path(q:)` assertion there still holds). System: `test/system/shell_test.rb`'s sweep gains `search_path(q: "lamp")` and `tag_path("lamp")` (tag a project in its setup — run ONLY after Task A's commit exists, since `tag_list=` is A's).

- [ ] **Step 2: the controller** — `SearchController < ApplicationController`:

```ruby
# One search over everything the web app shows (stage 2, S2-5). Read-only, session-authed. Each
# kind is ONE capped query plus ONE count, in the Files idiom (LOWER … LIKE … ESCAPE, escaped
# with sanitize_sql_like — without the ESCAPE clause SQLite reads the escape as a literal).
class SearchController < ApplicationController
  QUERY_MAX = 80
  PER_GROUP = 5

  def index
    @q = params[:q].to_s.strip.first(QUERY_MAX)
    @groups = []
    return if @q.blank?

    like = "%#{Node.sanitize_sql_like(@q.downcase)}%"
    files = current_user.nodes.present.where(kind: "file").visible_entries(false).where("LOWER(name) LIKE ? ESCAPE '\\'", like)
    add_group("Files", :file, files.order(:name), files_path(q: @q))
    projects = current_user.maker_projects.where("LOWER(name) LIKE ? ESCAPE '\\' OR LOWER(description) LIKE ? ESCAPE '\\'", like, like)
    add_group("Projects", :project, projects.order(:name), projects_path(q: @q))
    models = current_user.maker_models.catalogued.where("LOWER(title) LIKE ? ESCAPE '\\'", like)   # check the scope name
    add_group("Models", :model, models.order(:title), models_path(q: @q))
    items = current_user.maker_inventory_items.where("LOWER(name) LIKE ? ESCAPE '\\' OR LOWER(part_number) LIKE ? ESCAPE '\\'", like, like)
    add_group("Inventory", :inventory_item, items.order(:name), inventory_items_path(q: @q))
    tags = current_user.maker_tags.where("name LIKE ? ESCAPE '\\'", like)
    add_group("Tags", :tag, tags.order(:name), nil)
  end

  private

  def add_group(title, kind, scope, more_path)
    total = scope.count
    return if total.zero?
    @groups << { title:, kind:, records: scope.limit(PER_GROUP).to_a, total:, more_path: }
  end
end
```

(A `description` column is `text`; `LOWER()` on it is fine on both adapters. Project search must NOT include archived? Include them, they are the user's — but the "See all" projects index hides archived by default; acceptable, say so in a comment.)

- [ ] **Step 3: the views.** `search/index.html.erb`: `content_for :title`; `page-head` (h1 "Search"); a `form.toolbar.search-toolbar` (GET `search_path`, `input[type=search][name=q]` autofocus, a submit `btn`); `p.search-prompt.muted` "Search files, projects, models, inventory and tags." when `@q` blank; `p.empty.muted` "Nothing matches “…”." when `@q` present and `@groups` empty; else `render "shared/result_group", **group` per group (Task A's partial; its contract is in Task A Step 3). `_topbar.html.erb`: `form_with url: search_path` … placeholder and aria-label "Search everything"; the `⌘K` hint stays. Files: `files/index.html.erb`'s `.toolbar.files-toolbar` gains `input[type=search][name=q][value=@q]` placeholder "Search files" at the start of the toolbar's form (read the toolbar's structure and `files_toolbar_test.rb` first — the count, the view toggle, the sort and the ext picker keep their places); remove `_ext_filter`'s hidden `q` if the visible input is in the same form (otherwise keep it). `pages/search.css` (link it after `pages/settings` in the layout and in `css_hygiene_test.rb`'s two lists): `.search-toolbar input[type=search] { flex: 1; max-width: 480px }`, `.result-group { margin-bottom: 20px }`, `.result-group h2 { font-size: 14px; margin-bottom: 6px }`, `.result-list { list-style: none; margin: 0; padding: 0 }`, `.result-row { display: flex; align-items: baseline; gap: 10px; padding: 6px 0; border-bottom: 1px solid var(--line) }`, `.result-sub { font: 11px/1.4 var(--font-mono); color: var(--fg-muted) }`, `.result-more { font-size: 12px; margin-top: 6px }` — all inside `@layer pages`.

- [ ] **Step 4: run** (after A's commit): `search_test.rb`, `shell_layout_test.rb`, `files_toolbar_test.rb`, `files_search_test.rb`, `template_hygiene_test.rb` (add `"search" => search_path(q: "lamp")`), `css_hygiene_test.rb`, `stimulus_hygiene_test.rb`, `bin/ci style`; then the one system file.

- [ ] **Step 5: mutation-check**: (a) drop `ESCAPE '\\'` from the files clause → the `100%` test fails; (b) unscope one kind (`Maker::Project.where`) → the tenancy test fails; (c) `PER_GROUP + 1` → the five-per-group test fails; (d) drop `.present` from the files scope → the tombstone test fails.

- [ ] **Step 6: commit** with a pathspec: `Search everything from the top bar: one results page grouped by kind, the Files page keeps its own`.

---

### Task C: close-out (the orchestrator)

- [ ] `search#index` budget test (grow every kind); look at `/search?q=lamp` and a tag page on the dev server; `bin/ci`; `/finish-branch`; `bin/log arc --from-pr <n>`.
