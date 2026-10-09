# Redesign slice 5 — the Models fold-in — Implementation Plan

> **For agentic workers:** in this repo, execute with **`.claude/commands/execute-plan.md`** (CLAUDE.md
> §15: batched by file, parallel where independent, one capped quality review per task). It
> overrides the generic superpowers subagent loop. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Models stop being a second catalog beside the Library.
- A model's folder shows a compact **model strip** above its files: cover, status, details, print
  settings and "Log a print".
- **3D models** becomes a Library view at `/files/models`.
- `/models` and `/models/:id` redirect into the Library.
- **Shelves** move to Settings.

**Architecture:**
- **`Maker::ModelFolder`** (new, two functions) is the one answer to "which model does this folder
  show?" and "where does `/models/:id` send you?". `FilesController#index` uses it for the strip;
  `ModelsController#show` uses it for the redirect.
- **The strip** is a partial, `files/_model_strip`, rendered inside `.library-main` above the grid. It
  reuses the model page's print log as a strict-locals partial.
- **The 3D models view** is `ModelsController#index` moved to a small `Files::ModelsController`.
- **Shelves** move under the `settings` namespace.

**Tech Stack:** Rails 8, Hotwire, Minitest request and system tests.

**Spec:** `docs/superpowers/specs/2026-10-08-structural-redesign-design.md` §5.4, §9.1 (Routes), §9.3 and
§11 (slice 5). Slices 1–4 (#381–#384) are merged.

**Required reading for every task** (they bind these paths):
- `docs/invariants/model-intake.md`. Read it in full. Its rules are unchanged by this slice, and several
  bind the UI:
  - "a folder a project claims is the project's";
  - "deleting an auto model dismisses it";
  - "an emptied auto model is hidden, not dismissed";
  - "the sweep never calls `ensure_library_folder!`";
  - "a shelf is a PATH and a model a NODE ID";
  - "`Shelf.seed_once!` …".
- `docs/invariants/design-system.md` rules 3, 8, 11, 12, 13, `docs/invariants/files-preview.md` ("The
  inspector"), CLAUDE.md §14d.

The rules most likely to bite:
- **`?view=` is the Library's list/grid toggle, saved in the `files_view` cookie**, and
  `files_query_base` deliberately omits it. Do not add `models` to `FilesController::VIEWS`.
- **A tile is a selection item only if it is a file in the listing** (`with_selection`). Model tiles
  are plain links.
- **A cover cell needs a `thumbs` controller ancestor**, or carries its own the way
  `models/_hero_poster.html.erb` does. A cover node is a raw column that nothing validates, so render
  the cell only for a live node.
- **No emoji in the interface** (slice 1 deferred the 🧊 placeholders to this slice).
- **A component selector is defined only in `components.css`.** The strip's own classes go in
  `pages/files.css`, using tokens only.
- **Query budgets assert constancy in N. No `%>` inside an ERB comment. A `data-controller` name
  must resolve. No sideways scroll at 375px.**
- **Every new template must be rendered by a page in `template_hygiene_test.rb`'s `pages` hash.** Its
  coverage assertion fails otherwise.
- **Mutation-check every guard; restore with `git checkout --`, then `rm -rf tmp/cache/bootsnap*`.**

---

## Decisions this plan applies

From the spec:
- the model strip replaces the model page;
- 3D models is a Library view;
- `/models*` redirects;
- shelves become a Settings rule;
- the model-intake rules are unchanged.

Amendments found while planning, recorded in the spec by Task 4:

1. **The 3D models view lives at `/files/models`, not `/files?view=models`.** `?view=` already means
   list/grid and is saved in a cookie. Adding `models` to it would save "models" as the Library's
   view, so the next plain folder link would render the models view. Every control built from
   `files_query_base` (sort, dot-files, search, Rescan) would also drop it.
   - It also has its own filters (status, tag, title search, its own sort values), which collide with
     the Library's `q` and `sort`.
   - A path of its own avoids all three. It is a `Files::` controller, so it reads as a Library page.
   - The sidebar's 3D models place lights for it, and the phone tab bar lights Library.
2. **The strip keys on `folder_node_id`, not `auto_node_id`.**
   - An imported model's `Models/<slug>` sets only `folder_node_id`.
   - An auto folder model sets both to the folder.
   - A one-file auto model has no folder (its `auto_node_id` is a FILE on a shelf), so it gets no
     strip.
3. **There is no "manual" origin. The model page survives for every model that has no strip to land
   on:**
   - one-file models (about half of what the sweep creates);
   - imports whose `Models/<slug>` was never made or is in the trash;
   - a model whose folder a project now claims (a project's claim wins, so no strip shows there).

   `/models/:id` redirects only when `Maker::ModelFolder.landing_folder_id` names a folder that will
   show this model's strip. **It is a 302, not a 301**, because the answer changes when a folder is
   trashed or restored. `/models` itself is a permanent 301 to `/files/models`, keeping `q`,
   `status`, `tag` and `sort`.
4. **What the strip carries.**
   - Cover, title, status badge, and designer · license · source.
   - The print-settings summary when present, and notes in a `<details>`.
   - Edit, and Remove from catalog / Delete, with the model page's exact wording and branches.
   - The print log: "Log a print" and the history.

   The model page's 3D viewer, image gallery, instructions PDFs and file tree are not repeated. The
   folder's own listing, the inspector and the workspace already show those files.
5. **Logging or deleting a print redirects back** (`redirect_back_or_to model_path`), so from the
   strip you stay in the folder. `models#destroy` still lands on 3D models.
6. **Import stays at `/models/new`**, linked as the 3D models view's primary action. After an import
   the importer lands on `model_url`, which now redirects to the new `Models/<slug>` folder and its
   strip.
7. **Shelves move to `Settings::ShelvesController` at `/settings/shelves`.** The old
   `get "settings/shelves" → /models/shelves` redirect is deleted in the same change, which would
   otherwise be a redirect loop. `/models/shelves` 301s to `/settings/shelves`. Shelves light
   Settings. The 3D models view keeps one muted sentence pointing at them; they stop being
   navigation.
8. **The 🧊 placeholders become the 3D models icon** (`rail_icon(:models)`), and the
   `_print_log` partial takes strict locals so the strip and the page share it.

## Files

| file | change | task |
|---|---|---|
| `app/controllers/shelves_controller.rb` → `app/controllers/settings/shelves_controller.rb` | moved into `Settings::` | 1 |
| `app/views/shelves/index.html.erb` → `app/views/settings/shelves/index.html.erb` | moved; helpers and the back link | 1 |
| `config/routes.rb` (the shelves lines and the settings namespace) | routes | 1 |
| `app/views/settings/show.html.erb`, `app/views/models/index.html.erb` (its Shelves button), `app/helpers/shell_helper.rb` (`SECTIONS`) | links | 1 |
| shelves tests: `shelves_test.rb`, `settings_hub_test.rb`, `moved_reference_pages_test.rb`, `shell_layout_test.rb` L71–72, `template_hygiene_test.rb` "shelves", `accent_spend_test.rb`, `page_query_budget_test.rb` "shelves#index", `models_pages_test.rb` (the Shelves button) | updated | 1 |
| `app/services/maker/model_folder.rb` | new | 2 |
| `app/models/maker/print_run.rb` | `composer_choices` | 2 |
| `app/controllers/files_controller.rb` (`#index`) | `@folder_model` and the strip's data | 2 |
| `app/views/files/_model_strip.html.erb` | new | 2 |
| `app/views/files/index.html.erb` | render the strip | 2 |
| `app/views/models/_print_log.html.erb`, `app/views/models/show.html.erb` (its render call) | strict locals | 2 |
| `app/controllers/models/print_runs_controller.rb`, `app/controllers/models_controller.rb` (`#show`'s choices) | redirect back; shared choices | 2 |
| `app/assets/stylesheets/pages/files.css` | `.model-strip*` | 2 |
| `test/services/maker/model_folder_test.rb`, `test/integration/web/model_strip_test.rb` | new | 2 |
| `test/integration/web/print_runs_test.rb`, `page_query_budget_test.rb`, `template_hygiene_test.rb`, `accent_spend_test.rb` | updated | 2 |
| `app/controllers/files/models_controller.rb`, `app/views/files/models/index.html.erb` | new (moved from `ModelsController#index` / `models/index`) | 3 |
| `app/controllers/models_controller.rb` | `#index` 301s; `#show` 302s through `ModelFolder`; `#destroy` → 3D models | 3 |
| `config/routes.rb` (`get "files/models"` before `resources :files`; `models/shelves` redirect) | routes | 3 |
| `app/views/models/{show,edit,new}.html.erb`, `_card.html.erb`, `_hero_poster.html.erb` | crumbs, Cancel, icon | 3 |
| `app/helpers/shell_helper.rb` (`sidebar_current`, tab bar), `app/views/layouts/_rail.html.erb` | 3D models place | 3 |
| `app/controllers/search_controller.rb`, `tags_controller.rb`, `app/views/home/index.html.erb` | "See all" links | 3 |
| `app/views/models/index.html.erb` | deleted (moved) | 3 |
| model page tests (see Task 3's table), `test/integration/web/models_redirects_test.rb` (new) | updated / new | 3 |
| spec, `docs/invariants/{model-intake,design-system,files-preview}.md`, CLAUDE.md §14k stub | the record | 4 |

**Order: Task 1 → Task 2 → Task 3, sequentially.** They share `routes.rb`, `shell_helper.rb`,
`template_hygiene_test.rb`, `accent_spend_test.rb` and `page_query_budget_test.rb`. Task 3's
redirect tests also assert the strip from Task 2.
- **Task 4 (docs only) runs in parallel with Task 1.**
- Each implementer starts with `git reset --hard <previous task's commit on claude/redesign-slice-5>`,
  because a fresh worktree starts on `main`.

---

### Task 1: Shelves move to Settings

**Files:** Task 1's rows above.

- [ ] **Step 1: Move the controller and view**

```bash
mkdir -p app/views/settings/shelves
git mv app/controllers/shelves_controller.rb app/controllers/settings/shelves_controller.rb
git mv app/views/shelves/index.html.erb app/views/settings/shelves/index.html.erb
```

In the controller:
- Wrap the class in `module Settings` (match `Settings::TagsController`'s shape) and indent the body.
- Every `shelves_path` becomes `settings_shelves_path`.
- Rewrite the header comment to say why it lives here: shelves are the rule for what counts as a
  model, a setting, now that Models is a Library view. Note that this reverses the 2026-09-10 move.

In the view:
- `shelves_path` → `settings_shelves_path`, `shelf_path(...)` → `settings_shelf_path(...)`.
- The back link becomes `link_to "Back to settings", settings_path`.
- Leave the explainer and the live/missing hit counts: model-intake.md says they are "therefore not
  decoration".

- [ ] **Step 2: Routes**

In `config/routes.rb`:
- Delete `resources :shelves, only: %i[index create destroy], path: "models/shelves"` and
  `get "settings/shelves", to: redirect("/models/shelves")`.
- Replace their comment block with the new reasoning.
- Inside `namespace :settings do`, add:

```ruby
    # WHICH FOLDERS COUNT AS MODELS (structural redesign slice 5). Back under Settings, reversing the
    # 2026-09-10 move to /models/shelves: Models is now a Library view (/files/models), not a section,
    # so the section shelves serve is Settings — a rule, not navigation. The old path redirects
    # (declared above `resources :models`, where its static segment must precede the parent).
    resources :shelves, only: %i[index create destroy]
```

And where the shelves line was, above `resources :models` (the static segment must precede the parent,
per the existing ordering comment):

```ruby
  # /models/shelves WAS THE PAGE FROM 2026-09-10 TO SLICE 5 — a maker's bookmarks and anything that
  # linked it keep working. Declared before `resources :models`, or it matches models#show id=shelves.
  get "models/shelves", to: redirect("/settings/shelves")
```

**A redirect loop is impossible only because the old `settings/shelves → models/shelves` line is
gone.** `moved_reference_pages_test.rb` asserts both directions, so keep it that way.

- [ ] **Step 3: Links and lighting**

- `app/views/settings/show.html.erb` L9: `shelves_path` → `settings_shelves_path`.
- `app/views/models/index.html.erb` L12: delete the `link_to "Shelves", shelves_path, class: "btn"`.
  Shelves stop being navigation; Task 3 adds the muted pointer in the new view.
- `app/helpers/shell_helper.rb` `SECTIONS`: `"models" => %w[models shelves]` → `"models" => %w[models]`.
  `settings/shelves` lights Settings through the `"settings"` entry, because `rail_section` reads the
  first segment of the controller path.
- Update the comment beside `SECTIONS` if it names shelves.

- [ ] **Step 4: Tests**

| test | change |
|---|---|
| `test/integration/web/shelves_test.rb` | every `shelves_path` → `settings_shelves_path`, `shelf_path` → `settings_shelf_path`; redirect assertions follow |
| `test/integration/web/settings_hub_test.rb` L56–57 | `a.settings-name[href=?]`, `settings_shelves_path` |
| `test/integration/web/moved_reference_pages_test.rb` L25–58 | the page is `settings_shelves_path` (200); **`"/models/shelves" → "/settings/shelves"` is 301**; `"/settings/shelves"` itself renders 200 and is NOT a redirect; it lights **Settings** |
| `test/integration/web/shell_layout_test.rb` L71–72 | `get settings_shelves_path` lights "Settings"; keep a nested-controller family case by using another nested controller (`settings/tags` lights Settings) |
| `test/integration/web/template_hygiene_test.rb` | the `"shelves"` page entry → `settings_shelves_path` |
| `test/system/accent_spend_test.rb` | `"/models/shelves" => [ "Add shelf" ]` → `"/settings/shelves" => [ "Add shelf" ]`, path `settings_shelves_path` |
| `test/integration/web/page_query_budget_test.rb` "shelves#index" | path `settings_shelves_path` |
| `test/integration/web/models_pages_test.rb` L27 | delete the `a.btn[href=shelves_path]` "Shelves" assertion |

Grep `test/` for `shelves_path` and `shelf_path` and fix every hit. Also grep app/ for the old helpers.

- [ ] **Step 5: Run and mutation-check**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/shelves_test.rb test/integration/web/settings_hub_test.rb test/integration/web/moved_reference_pages_test.rb test/integration/web/shell_layout_test.rb test/integration/web/template_hygiene_test.rb test/integration/web/models_pages_test.rb test/integration/web/page_query_budget_test.rb`,
then `bin/rails test test/system/accent_spend_test.rb`. Expected: green.

Mutation: put the old `get "settings/shelves", to: redirect("/models/shelves")` line back above the
namespace. `moved_reference_pages_test` must go red, either as a redirect loop or as the page
redirecting instead of rendering. Restore it.

- [ ] **Step 6: Commit.** Subject: "Shelves are a Settings rule again: /settings/shelves, and the old
  Models path redirects". Use `git commit -F <file>`, and end the message with the Co-Authored-By line.

---

### Task 2: The model strip

**Files:** Task 2's rows above.

- [ ] **Step 1: Write the failing tests**

Create `test/services/maker/model_folder_test.rb`:

```ruby
require "test_helper"

module Maker
  # THE ONE ANSWER TO "WHICH 3D MODEL DOES THIS FOLDER SHOW?" AND "WHERE DOES /models/:id SEND YOU?"
  # (structural redesign §5.4, slice 5). Rows only, no port: every backend leg runs the same assertions.
  class ModelFolderTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "mf-#{SecureRandom.hex(4)}@example.com", password: "x" * 12, confirmed_at: Time.current)
      @dir = @user.nodes.create!(node_id: "d-bracket", name: "bracket", kind: "dir", mtime: 1, size: 0)
      @stl = @user.nodes.create!(node_id: "n-bracket", name: "bracket.stl", kind: "file", parent_node_id: "d-bracket",
                                 mtime: 1, size: 1, content_hash: "h", current_version_id: "v")
    end

    def model!(origin: "import", folder: "d-bracket", auto: nil, attach: true, dismissed: false)
      m = @user.maker_models.create!(title: "Bracket #{SecureRandom.hex(2)}", origin:, folder_node_id: folder,
                                     auto_node_id: auto, dismissed_at: (Time.current if dismissed))
      m.file_attachments.create!(user: @user, node_id: "n-bracket", role: "model") if attach
      m
    end

    test "an imported model's folder shows that model" do
      m = model!
      assert_equal m, ModelFolder.model_in(@user, "d-bracket")
    end

    test "an auto folder model shows, keyed on folder_node_id" do
      m = model!(origin: "auto", auto: "d-bracket")
      assert_equal m, ModelFolder.model_in(@user, "d-bracket")
    end

    test "a dismissed model and an emptied auto model show nothing" do
      model!(dismissed: true)
      model!(origin: "auto", auto: "d-bracket", attach: false)
      assert_nil ModelFolder.model_in(@user, "d-bracket")
    end

    test "a hidden stale row does not hide a live one in the same folder" do
      model!(origin: "auto", auto: "d-bracket", attach: false)   # older, emptied — hidden
      live = model!
      assert_equal live, ModelFolder.model_in(@user, "d-bracket")
    end

    test "another user's model in a same-named node id shows nothing" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", password: "x" * 12, confirmed_at: Time.current)
      other.maker_models.create!(title: "Theirs", folder_node_id: "d-bracket")
      assert_nil ModelFolder.model_in(@user, "d-bracket")
    end

    test "a folder model lands on its live folder" do
      m = model!
      assert_equal "d-bracket", ModelFolder.landing_folder_id(@user, m)
    end

    test "no landing for a one-file model, a trashed folder, a project's folder, or a folder showing another model" do
      one_file = model!(origin: "auto", folder: nil, auto: "n-bracket")
      assert_nil ModelFolder.landing_folder_id(@user, one_file)

      trashed = model!
      @dir.update!(deleted: true)
      assert_nil ModelFolder.landing_folder_id(@user, trashed)
      @dir.update!(deleted: false)

      claimed = model!
      @user.maker_projects.create!(name: "Shelf").update_column(:folder_node_id, "d-bracket")
      assert_nil ModelFolder.landing_folder_id(@user, claimed)
    end

    test "only the model the folder actually shows lands there" do
      shown = model!
      second = model!
      assert_equal "d-bracket", ModelFolder.landing_folder_id(@user, shown)
      assert_nil ModelFolder.landing_folder_id(@user, second)
    end
  end
end
```

Copy `User.create!` from a neighbouring service test if this suite's password rule differs.

Create `test/integration/web/model_strip_test.rb`:

```ruby
require "test_helper"

module Web
  # THE MODEL STRIP (structural redesign §5.4, slice 5): a catalogued model's folder shows its cover,
  # status, details and print log above the files, which is what the model page used to carry.
  class ModelStripTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "strip-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "d-bracket", name: "bracket", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "n-bracket", name: "bracket.stl", kind: "file", parent_node_id: "d-bracket",
                          mtime: 1, size: 1, content_hash: "h", current_version_id: "v")
      @model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-bracket",
                                          designer: "Ada", license: "CC-BY", source_url: "https://example.com/b",
                                          print_settings: { "layer_height" => "0.2mm", "nozzle" => "0.4" })
      @model.file_attachments.create!(user: @user, node_id: "n-bracket", role: "model")
    end

    test "a model's folder shows the strip above its files" do
      get files_path(folder: "d-bracket")
      assert_response :success
      assert_select ".library-main > .model-strip", count: 1
      assert_select ".model-strip h2", text: "Wall Bracket"
      assert_select ".model-strip .badge.mstatus-want_to_print", text: "Wanted"
      assert_select ".model-strip", text: /Ada/
      assert_select ".model-strip a[href=?]", "https://example.com/b"
      assert_select ".model-strip dl", text: /Layer height\s*0\.2mm/
      assert_select ".model-strip a.btn[href=?]", edit_model_path(@model), text: "Edit"
      assert_select ".model-strip form[action=?] button", model_path(@model), text: "Delete"
      assert_select ".model-strip details.composer > summary", text: "Log a print"
      assert_select ".model-strip form[action=?]", model_print_runs_path(@model)
      # The strip is not a selection item and spends no accent (Upload is the folder's one action).
      assert_select ".model-strip [data-selection-target]", count: 0
      assert_select ".model-strip .btn.primary", count: 0
    end

    test "an auto model's strip says Remove from catalog, never Delete" do
      @model.update!(origin: "auto", auto_node_id: "d-bracket")
      get files_path(folder: "d-bracket")
      assert_select ".model-strip form[action=?] button", model_path(@model), text: "Remove from catalog"
      assert_select ".model-strip button", text: "Delete", count: 0
    end

    test "no strip on a plain folder, a project's folder, or for a dismissed model" do
      @user.nodes.create!(node_id: "d-plain", name: "plain", kind: "dir", mtime: 1, size: 0)
      get files_path(folder: "d-plain")
      assert_select ".model-strip", count: 0

      @user.maker_projects.create!(name: "Shelf Unit").update_column(:folder_node_id, "d-bracket")
      get files_path(folder: "d-bracket")
      assert_select ".model-strip", count: 0
    end

    test "a dismissed model shows no strip" do
      @model.update!(dismissed_at: Time.current)
      get files_path(folder: "d-bracket")
      assert_select ".model-strip", count: 0
    end

    test "logging a print from the strip returns to the folder" do
      get files_path(folder: "d-bracket")
      post model_print_runs_path(@model),
           params: { print_run: { printed_on: Date.current, outcome: "success" } },
           headers: { "HTTP_REFERER" => files_url(folder: "d-bracket") }
      assert_redirected_to files_url(folder: "d-bracket")
      assert_equal "printed", @model.reload.print_status
    end
  end
end
```

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/model_folder_test.rb test/integration/web/model_strip_test.rb`

Expected: a `NameError` on `Maker::ModelFolder`, and the strip tests fail.

- [ ] **Step 2: `Maker::ModelFolder`**

Create `app/services/maker/model_folder.rb`:

```ruby
module Maker
  # THE ONE ANSWER TO "WHICH 3D MODEL DOES THIS FOLDER SHOW?" AND "WHERE DOES /models/:id SEND YOU?"
  # (structural redesign §5.4, slice 5). The Library's model strip and ModelsController#show's redirect
  # read this, so the two can never disagree about whether a model has a strip to land on.
  #
  # KEYED ON `folder_node_id`, NOT `auto_node_id`: an imported model's Models/<slug> sets only the
  # first, an auto folder model sets both to the folder, and a one-file auto model's `auto_node_id`
  # is a FILE on a shelf (docs/invariants/model-intake.md). `folder_node_id` has no index; the scan is
  # over this user's own models, the argument FilesController's @folder_project already makes.
  #
  # NEVER CALLS `ensure_library_folder!`: rendering a folder must not mint one (model-intake.md, "the
  # sweep never calls ensure_library_folder!" — and neither does a page).
  module ModelFolder
    module_function

    # The catalogued model whose strip the Library shows in this folder, or nil. An emptied auto model
    # is hidden exactly as the 3D models view hides it (model-intake.md: hidden, not dismissed), read
    # off the eager-loaded association rather than a `where.missing`. Several rows can name one folder
    # (a stale auto row beside an import, until `rake models:prune`), so the oldest VISIBLE one wins.
    # Does NOT check a project's claim: the Library already holds that answer (@folder_project).
    def model_in(user, folder_node_id)
      user.maker_models.catalogued.includes(:file_attachments)
          .where(folder_node_id:).order(:id)
          .detect { |model| !(model.auto? && model.file_attachments.empty?) }
    end

    # The folder /models/:id redirects to, or nil to keep the model page: the model's folder, when it
    # is live, no project claims it (a project's claim wins — model-intake.md), and it shows THIS
    # model's strip. Everything else — a one-file model, a trashed folder, an import whose folder was
    # never made — keeps the page.
    def landing_folder_id(user, model)
      id = model.folder_node_id
      return nil if id.blank?
      return nil unless user.nodes.present.exists?(node_id: id, kind: "dir")
      return nil if user.maker_projects.exists?(folder_node_id: id)

      model_in(user, id)&.id == model.id ? id : nil
    end
  end
end
```

- [ ] **Step 3: The print log takes strict locals; the composer's choices are shared**

`app/models/maker/print_run.rb`, add:

```ruby
  # The composer's datalists: every printer and material this user has logged, for "Log a print" on
  # the model page and the Library's model strip alike. Two distinct plucks, constant in N.
  def self.composer_choices(user)
    runs = user.maker_print_runs
    [ runs.where.not(printer: [ nil, "" ]).distinct.pluck(:printer),
      runs.where.not(material: [ nil, "" ]).distinct.pluck(:material) ]
  end
```

`ModelsController#show`: replace the two `@printers` / `@materials` lines with
`@printers, @materials = Maker::PrintRun.composer_choices(current_user)`.

`app/views/models/_print_log.html.erb`:
- Add `<%# locals: (model:, print_runs:, printers:, materials:) %>` as its first line.
- Replace `@model` → `model`, `@print_runs` → `print_runs`, `@printers` → `printers` and
  `@materials` → `materials`.
- The datalist ids `printer-options` / `material-options` stay; there is one composer per page.

`app/views/models/show.html.erb`: `render "print_log"` →
`render "models/print_log", model: @model, print_runs: @print_runs, printers: @printers, materials: @materials`.

`app/controllers/models/print_runs_controller.rb`: in `create` and `destroy`, every
`redirect_to model_path(model), …` becomes `redirect_back_or_to model_path(model), …` (same notice or
alert). Add a comment: "back, so a print logged from the Library's model strip stays in that folder."

- [ ] **Step 4: The controller**

`app/controllers/files_controller.rb` `#index`:
- In the flat branch, beside `@folder_project = nil`, add `@folder_model = nil`.
- In the folder branch, directly after `@folder_project = …`:

```ruby
      # THE FOLDER'S 3D MODEL, IF IT IS ONE (structural redesign §5.4, slice 5): the model strip above
      # the files. Maker::ModelFolder is the one definition (the redirect from /models/:id reads it
      # too). A project's claim wins, so a claimed folder never asks. Constant in N, beside
      # @folder_project's lookup and for the same reason.
      @folder_model = (@folder && @folder_project.nil?) ? Maker::ModelFolder.model_in(current_user, @folder.node_id) : nil
      load_model_strip(@folder_model) if @folder_model
```

Private:

```ruby
  # What the strip shows beyond the row itself: the cover (only when its node is live — the cover is a
  # raw column nothing validates, and a dead one would spin forever, the case models/_hero_poster
  # guards), the print log, and the composer's choices. Each is one query; none grows with the folder.
  def load_model_strip(model)
    cover = model.cover_node_id
    @strip_cover_live = cover.present? && current_user.nodes.present.exists?(node_id: cover, kind: "file")
    @strip_covers = Maker::Previews::ThumbnailMap.for(current_user, @strip_cover_live ? [ cover ] : [])
    @strip_print_runs = model.print_runs.reorder(printed_on: :desc, id: :desc).to_a
    @strip_printers, @strip_materials = Maker::PrintRun.composer_choices(current_user)
  end
```

- [ ] **Step 5: The partial**

Create `app/views/files/_model_strip.html.erb`:

```erb
<%# locals: (model:, cover_live:, covers:, print_runs:, printers:, materials:) %>
<%# THE MODEL STRIP (structural redesign §5.4, slice 5). A catalogued model's folder carries what the
    model page did: cover, status, details, print settings and the print log. The folder's own files,
    the inspector and the workspace show the rest, so the page's viewer, gallery and file tree are not
    repeated here.

    NOT A SELECTION ITEM AND NO ACCENT: Upload is the folder's one action (design-system.md rule 13),
    and nothing here goes through with_selection. Its cover cell carries its OWN thumbs controller,
    because the grid's is on a sibling, not an ancestor. %>
<section class="model-strip panel" aria-label="3D model">
  <div class="model-strip-head">
    <% if cover_live %>
      <span class="thumb file-cell model-strip-cover"
            data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>"
            data-thumbs-target="cell" data-node-id="<%= model.cover_node_id %>" data-ext="">
        <%= render "files/thumb", thumb: covers.thumb(model.cover_node_id), ext_label: "",
                   url: preview_src(covers.thumb(model.cover_node_id)) %>
      </span>
    <% else %>
      <span class="thumb model-strip-cover model-strip-cover--empty" aria-hidden="true"><%= rail_icon(:models) %></span>
    <% end %>
    <div class="model-strip-title">
      <span class="eyebrow">3D model</span>
      <h2><%= model.title %></h2>
      <span class="badge mstatus-<%= model.print_status %>"><%= model.print_status_label %></span>
      <% details = [ model.designer.presence, model.license.presence ].compact %>
      <% if details.any? || model.source_url.present? %>
        <p class="model-strip-meta muted">
          <%= details.join(" · ") %>
          <% if model.source_url.present? %>
            <%= " · " if details.any? %>
            <% if model.source_url.match?(%r{\Ahttps?://}i) %>
              <%= link_to "Source", model.source_url, target: "_blank", rel: "noopener" %>
            <% else %>
              <%= model.source_url %>
            <% end %>
          <% end %>
        </p>
      <% end %>
    </div>
    <div class="model-strip-actions">
      <%= link_to "Edit", edit_model_path(model), class: "btn small" %>
      <%# THE TWO DESTROY BRANCHES AND THEIR WORDING ARE models/show's, verbatim: an auto model is
          DISMISSED (the row survives so the sweep does not recreate it), an import is destroyed, and
          both keep the files (docs/invariants/model-intake.md). %>
      <% if model.auto? %>
        <%= button_to "Remove from catalog", model_path(model), method: :delete, class: "btn small danger",
                      form: { data: { turbo_confirm: "Remove #{model.title} from the catalog? " \
                                                     "The files stay, and it won't be re-added by the next scan." } } %>
      <% else %>
        <%= button_to "Delete", model_path(model), method: :delete, class: "btn small danger",
                      form: { data: { turbo_confirm: "Delete #{model.title}? (files are kept)" } } %>
      <% end %>
    </div>
  </div>
  <% if model.print_settings.present? %>
    <dl class="meta model-strip-settings">
      <% model.print_settings.each do |key, value| %>
        <dt><%= key.to_s.tr("_", " ").capitalize %></dt><dd><%= value %></dd>
      <% end %>
    </dl>
  <% end %>
  <% if model.notes.present? %>
    <details class="model-strip-notes">
      <summary>Notes</summary>
      <%= render_note(model.notes) %>
    </details>
  <% end %>
  <%= render "models/print_log", model:, print_runs:, printers:, materials: %>
</section>
```

Spell the `render` hash out in full. Memory: ERB hash shorthand at the end of a `render` line can
swallow the next tag. Keep it on one line ending with `%>`, or write the keys out (`model: model, …`).
Check that `render_note` is available to Files views (it is an ApplicationHelper method on the model
page; grep for it).

In `app/views/files/index.html.erb`, inside `<div class="library-main">` and before the `@truncated`
block:

```erb
    <% if @folder_model %>
      <%= render "files/model_strip", model: @folder_model, cover_live: @strip_cover_live, covers: @strip_covers,
                 print_runs: @strip_print_runs, printers: @strip_printers, materials: @strip_materials %>
    <% end %>
```

- [ ] **Step 6: Styles** (`app/assets/stylesheets/pages/files.css`, inside its layer, tokens only)

```css
  /* THE MODEL STRIP (files/_model_strip.html.erb): a model folder's header above its files. A panel,
     qualified rather than redeclared (design-system.md rule 3). The cover is a fixed small square so
     the strip stays a strip; it wraps at phone width rather than scrolling sideways. */
  .model-strip { margin-bottom: var(--space-4); }
  .model-strip-head { display: flex; flex-wrap: wrap; align-items: flex-start; gap: var(--space-3); }
  .model-strip-cover { flex: 0 0 72px; width: 72px; height: 72px; }
  .model-strip-cover--empty { display: grid; place-items: center; color: var(--fg-muted); }
  .model-strip-title { flex: 1 1 220px; min-width: 0; }
  .model-strip-title .eyebrow { display: block; font: 600 11px/16px var(--font-ui); letter-spacing: .08em; text-transform: uppercase; color: var(--fg-muted); }
  .model-strip-title h2 { margin: 0 0 var(--space-1); font-size: 16px; line-height: 22px; overflow-wrap: anywhere; }
  .model-strip-meta { margin: var(--space-1) 0 0; font-size: 13px; overflow-wrap: anywhere; }
  .model-strip-actions { display: flex; flex-wrap: wrap; gap: var(--space-2); }
  .model-strip-settings { margin-top: var(--space-3); grid-template-columns: max-content minmax(0, 1fr); }
  .model-strip-notes { margin-top: var(--space-3); }
  .model-strip .print-log { margin-top: var(--space-3); }
```

`.eyebrow` is styled only as `.inspector-head .eyebrow` (`pages/files.css` L23), which is why the strip
carries its own qualified rule above. `render_note` is `NotesHelper#render_note`, so every view has it.
If `.print-log`'s rules in `pages/models.css` assume the model page's side column, check them at 375px.

- [ ] **Step 7: Budgets, hygiene, accent**

`test/integration/web/page_query_budget_test.rb`, after the folder-view budget:

```ruby
    # THE MODEL STRIP (slice 5) MUST NOT GROW WITH THE MODEL: its attachments are eager-loaded and its
    # print log is one query, so a model folder with 15 files and 15 prints costs what one with 3 does.
    test "files#index on a model folder does not grow with attachments or print runs" do
      folder = @user.nodes.create!(node_id: "budget-model-dir", name: "bracket", kind: "dir", mtime: 1, size: 0)
      model = @user.maker_models.create!(title: "Budget Bracket", folder_node_id: folder.node_id)
      add = lambda do |prefix, count|
        count.times do |i|
          node!("#{prefix}#{i}", "#{prefix}#{i}.stl")
          @user.nodes.find_by!(node_id: "#{prefix}#{i}").update!(parent_node_id: folder.node_id)
          model.file_attachments.create!(user: @user, node_id: "#{prefix}#{i}", role: "model")
          model.print_runs.create!(user: @user, printed_on: Date.current, outcome: "success", printer: "P#{i}")
        end
      end
      assert_constant_queries(files_path(folder: folder.node_id), -> { add.call("ms", SMALL) },
                              -> { add.call("ml", LARGE - SMALL) }, "files#index (model folder)")
    end
```

`test/integration/web/template_hygiene_test.rb`:
- Add a page `"model folder" => files_path(folder: <a folder model's folder>)`, with its own fixture: a
  dir node and an import model with `folder_node_id` set, created beside the existing `@model`.
- Keep `@model` itself folderless, so `"model detail" => model_path(@model)` still renders the page
  after Task 3.

`test/system/accent_spend_test.rb`:
- Add a model folder to the fixture: a share folder made with `FileLayer.current.mkdir(@user, name:
  "bracket")`, plus `@user.maker_models.create!(title: "Wall Bracket", folder_node_id: …)`.
- Add a row `"/files (a model folder)" => [ "Upload" ]`, whose path is `files_path(folder: …)`. That
  pins the strip spending no accent.

`test/integration/web/print_runs_test.rb`: wherever it asserts `assert_redirected_to model_path(...)`
after a create or delete with no referer, `redirect_back_or_to` still lands there, so nothing changes.
Add one case with a referer that returns to it.

- [ ] **Step 8: Run and mutation-check**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/model_folder_test.rb test/integration/web/model_strip_test.rb test/integration/web/print_runs_test.rb test/integration/web/models_flow_test.rb test/integration/web/models_pages_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/template_hygiene_test.rb test/css_hygiene_test.rb test/stimulus_hygiene_test.rb`.
Then run the s3 leg on the two new files:
`env LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=ci-not-a-real-bucket LIBRARY_S3_REGION=us-east-1 LIBRARY_S3_ACCESS_KEY_ID=ci LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library bin/rails test <files>`.
Then the system tests: `bin/rails test test/system/accent_spend_test.rb test/system/shell_test.rb test/system/projects_models_pages_test.rb`.

| mutation | must redden |
|---|---|
| `.where(folder_node_id:)` → `.where(auto_node_id: folder_node_id)` in `model_in` | "an imported model's folder shows that model"; the strip test |
| drop `.catalogued` | "a dismissed model … shows nothing"; "a dismissed model shows no strip" |
| drop the `!(model.auto? && model.file_attachments.empty?)` filter (use `.first`) | "a dismissed model and an emptied auto model show nothing"; "a hidden stale row does not hide a live one" |
| drop `@folder_project.nil? &&` in `#index` | "no strip on … a project's folder" |
| drop the project `exists?` line in `landing_folder_id` | "no landing for … a project's folder" |
| `model_in(user, id)&.id == model.id ? id : nil` → `id` | "only the model the folder actually shows lands there" |
| `.includes(:file_attachments)` dropped from `model_in` | the model-folder query budget, if the strip derives a cover from attachments. If it stays green, the cover column is set in the fixture: unset it and re-run |
| `redirect_back_or_to` → `redirect_to model_path(model)` in print runs `create` | "logging a print from the strip returns to the folder" |

- [ ] **Step 9: Commit.** Subject: "A 3D model's folder shows its model strip: cover, status, details
  and the print log".

---

### Task 3: The 3D models view, the redirects, and the sidebar place

**Files:** Task 3's rows above.

- [ ] **Step 1: Write the failing redirect and view tests**

Create `test/integration/web/models_redirects_test.rb`:

```ruby
require "test_helper"

module Web
  # /models FOLDS INTO THE LIBRARY (structural redesign §5.4, slice 5): the index is a Library view at
  # /files/models, and a model page redirects to its folder whenever that folder will show its strip —
  # otherwise the page stays (Maker::ModelFolder.landing_folder_id is the one answer).
  class ModelsRedirectsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "mr-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "d-bracket", name: "bracket", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "n-bracket", name: "bracket.stl", kind: "file", parent_node_id: "d-bracket",
                          mtime: 1, size: 1, content_hash: "h", current_version_id: "v")
    end

    test "/models is a permanent redirect to the 3D models view, keeping its filters" do
      get models_path(q: "brack", status: "printed", tag: "shop", sort: "title", junk: "x")
      assert_response :moved_permanently
      assert_redirected_to files_models_path(q: "brack", status: "printed", tag: "shop", sort: "title")
    end

    test "a folder model's page redirects to its folder, temporarily, and the folder shows its strip" do
      model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-bracket")
      get model_path(model)
      assert_response :found
      assert_redirected_to files_path(folder: "d-bracket")
      follow_redirect!
      assert_select ".model-strip h2", text: "Wall Bracket"
    end

    test "a one-file model and a folderless import keep the model page" do
      one_file = @user.maker_models.create!(title: "Loose Clip", origin: "auto", auto_node_id: "n-bracket")
      one_file.file_attachments.create!(user: @user, node_id: "n-bracket", role: "model")
      get model_path(one_file)
      assert_response :success
      assert_select "h1", text: "Loose Clip"

      folderless = @user.maker_models.create!(title: "Orphan")
      get model_path(folderless)
      assert_response :success
    end

    test "a model whose folder is in the trash keeps the model page" do
      model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-bracket")
      @user.nodes.find_by!(node_id: "d-bracket").update!(deleted: true)
      get model_path(model)
      assert_response :success
    end

    test "the 3D models view lists catalogued models as cover tiles that open the model" do
      shown = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-bracket")
      @user.maker_models.create!(title: "Gone", dismissed_at: Time.current)
      get files_models_path
      assert_response :success
      assert_select "h1", text: "3D models"
      assert_select ".model-card[href=?]", model_path(shown), count: 1
      assert_select ".model-card", text: /Gone/, count: 0
      assert_select ".page-head a.btn.primary[href=?]", new_model_path, text: "Import model"
      assert_select "a[href=?]", settings_shelves_path
      # Model tiles are links, never selection items (a model is not a file in a listing).
      assert_select "[data-selection-target]", count: 0
    end

    test "the 3D models view filters by status, title and tag, and its controls stay on its own path" do
      @user.maker_models.create!(title: "Wall Bracket", print_status: "printed")
      @user.maker_models.create!(title: "Desk Clip")
      get files_models_path(status: "printed")
      assert_select ".model-card", count: 1
      get files_models_path(q: "desk")
      assert_select ".model-card", count: 1
      assert_select "form.models-toolbar[action=?]", files_models_path
    end

    test "the sidebar lights 3D models on the view, and the phone tab bar lights Library" do
      get files_models_path
      assert_select "aside.rail [aria-current='page']", count: 1, text: /3D models/
      assert_select "nav.tabbar [aria-current='page']", text: /Library/
    end
  end
end
```

Adapt the tab-bar selector to `layouts/_tabbar.html.erb`'s real markup; read
`shell_layout_test.rb` L234–239 for the idiom.

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/models_redirects_test.rb`

Expected: `NameError` / routing errors (`files_models_path` is undefined).

- [ ] **Step 2: Route and controller for the view**

`config/routes.rb`, **directly above** `resources :files, …`:

```ruby
  # THE 3D MODELS VIEW (structural redesign §5.4, slice 5): the old /models index as a Library view.
  # Its own path, NOT ?view=models: `view` is the list/grid toggle and lives in a cookie, so a
  # "models" value would be saved and every plain folder link would render this view. DECLARED BEFORE
  # `resources :files`, or /files/models matches files#show id=models.
  get "files/models", to: "files/models#index", as: :files_models
```

Create `app/controllers/files/models_controller.rb`:
- Move `ModelsController::SORTS` and the body of `ModelsController#index` here verbatim, with their
  comments.
- Change the class comment to say this is the Library's 3D models view, with `models_controller.rb`'s
  history pointer.

```ruby
module Files
  # THE LIBRARY'S 3D MODELS VIEW (structural redesign §5.4, slice 5) — the old /models index, moved
  # verbatim from ModelsController#index (which now 301s here). Every catalogued model as a cover tile;
  # a tile links to model_path, which lands on the model's folder whenever that folder shows its strip
  # (Maker::ModelFolder) — decided at click time, so rendering the grid needs no liveness query per tile.
  class ModelsController < ApplicationController
    SORTS = { … moved … }.freeze

    def index
      … moved verbatim …
    end
  end
end
```

`app/views/files/models/index.html.erb` is `git mv`'d from `app/views/models/index.html.erb`, then:
- **Title:** `content_for :title, "3D models — Tinkerex"`. The crumbs go in `content_for :crumbs`,
  with the Library breadcrumb markup `nav.breadcrumb`, `link_to "Files", files_path`, and
  `<span aria-current="page">3D models</span>`.
- **Page head:** `h1` "3D models". `.page-actions` keeps only
  `link_to "Import model", new_model_path, class: "btn primary"`; the Shelves button already went in
  Task 1.
- **Toolbar:** the form's `action` → `files_models_path`. Every chip and sort link `models_path(…)` →
  `files_models_path(…)`.
- **After the toolbar**, one muted line:
  `<p class="muted models-shelves-hint">Which folders count as models: <%= link_to "Settings → Shelves", settings_shelves_path %>.</p>`.
- The grid and `models/_card` stay as they are. Render it as `render "models/card", …`, since the
  partial's directory changed relative to the view.

`app/controllers/models_controller.rb`:
- Delete `SORTS` and the old `#index` body. `#index` becomes:

  ```ruby
    # /models IS THE LIBRARY'S 3D MODELS VIEW NOW (slice 5). Permanent, keeping the filters a bookmark
    # or a "See all" link carries; anything else in the query is dropped.
    def index
      redirect_to files_models_path(request.query_parameters.slice("q", "status", "tag", "sort")),
                  status: :moved_permanently
    end
  ```

- `#show` begins:

  ```ruby
      # A MODEL WITH A STRIP TO LAND ON GOES THERE (slice 5): its folder, where the Library's model strip
      # carries what this page did. Everything else stays — a one-file model, an import whose folder was
      # never made or is in the trash, a folder a project now claims. 302, never 301: the answer changes
      # when the folder is trashed or restored. Maker::ModelFolder is the one definition.
      if (folder_id = Maker::ModelFolder.landing_folder_id(current_user, @model))
        return redirect_to(files_path(folder: folder_id))
      end
  ```

- `#destroy`: both `redirect_to models_path` → `redirect_to files_models_path`. The `rescue_from`
  handlers' `models_path` → `files_models_path`.

- [ ] **Step 3: Pages that keep living at /models**

- `app/views/models/show.html.erb` crumbs: `link_to "Models", models_path` → `link_to "Files", files_path`
  then `link_to "3D models", files_models_path`, then the title.
- `app/views/models/edit.html.erb` and `new.html.erb`: the same crumb change. Cancel buttons that
  point at `models_path` → `files_models_path`.
- `app/views/models/_card.html.erb` and `_hero_poster.html.erb`: the 🧊 spans render
  `rail_icon(:models)` inside the same span. Keep `aria-hidden="true"`.

- [ ] **Step 4: The sidebar place and its lighting**

`app/views/layouts/_rail.html.erb`: the 3D models link's `models_path` → `files_models_path`.
The `sidebar_aria([ :models ])` stays.

`app/helpers/shell_helper.rb` `sidebar_current`, the `when "files"` arm:

```ruby
    when "files"
      # The Library's 3D models VIEW lights its own place, not Library (slice 5). Only one link is lit.
      if controller_path == "files/models"
        [ :models ]
      else
        pinned = sidebar_pins.map { |pin, _| pin.node_id }
        deepest = Array(@crumbs).map(&:node_id).reverse.find { |id| pinned.include?(id) }
        deepest ? [ :pin, deepest ] : [ :library ]
      end
```

In `tabbar_links`, the Library entry's lit test becomes `%i[library pin models].include?(current)`,
with a comment: "the 3D models view is a Library view; the bar has no place of its own for it".
Do the same on the `[ :models ]` page `ModelsController` serves, which is the same key.

- [ ] **Step 5: "See all" and Home**

- `app/controllers/search_controller.rb` L66–69: `models_path(q: @q)` → `files_models_path(q: @q)`.
- `app/controllers/tags_controller.rb` L15–16: `models_path(tag: @tag.name)` →
  `files_models_path(tag: @tag.name)`.
- `app/views/home/index.html.erb` L56: "See all" → `files_models_path`. The model links stay
  `model_path`, because the redirect lands them.
- `app/javascript/controllers/importer_controller.js` needs no change: `model_url` redirects to the new
  folder.

- [ ] **Step 6: Tests that move or change**

| test | change |
|---|---|
| `models_pages_test.rb` | index assertions → `files_models_path` (toolbar anatomy, Import model primary, `?q=` escaping, card badge); show-page assertions keep using a FOLDERLESS model |
| `models_flow_test.rb` | index tests → `files_models_path`. Show/edit/update tests: if a test's model has a live folder, it now redirects. Either make the fixture folderless (it is testing the page) or assert the redirect and the strip. Decide per test, and say which in the commit. |
| `models_catalog_test.rb` | `models_path` redirect targets → `files_models_path`; the index-hiding tests → the view; the one-file fallback keeps the page |
| `cohesion_vocabulary_test.rb` L34–56, L100–122 | `/models` → `files_models_path` |
| `file_cell_payload_test.rb` L59–67 | `"models#index"` surface → `files_models_path` |
| `maker_page_thumbnails_test.rb` L55–162 | `models#index` → `files_models_path` |
| `search_test.rb` L80, `tags_test.rb` | "See all" href → `files_models_path(...)` |
| `home_test.rb` L54–66 | unchanged (`model_path` links); add the "See all" href |
| `shell_layout_test.rb` L23–31, L136–137 | `files_models_path => "3D models"` lights one link; the top-bar title on the view is the breadcrumb "3D models" |
| `template_hygiene_test.rb` | `"models index" => models_path` → `"3D models" => files_models_path` |
| `page_query_budget_test.rb` "models#index" | path → `files_models_path`, label "files/models#index" |
| `accent_spend_test.rb` | `"/models" => [ "Import model" ]` → `"/files/models" => [ "Import model" ]`, path `files_models_path` |
| `test/system/shell_test.rb` L451 | `models_path` → `files_models_path` in the 375px sweep, plus the model folder from Task 2 |
| `test/system/o3dv_test.rb`, `projects_models_pages_test.rb` | they use folderless models, so they keep the page; confirm they pass |
| `auth_pages_test.rb` L113–122 | `new_model_path` unchanged |
| `cross_user_authorization_test.rb` L178–221 | `model_path` for another user's model must still be denied BEFORE any redirect. `set_model` 404s first; confirm it |

Grep `test/` and `app/` for `models_path` and fix every remaining hit. The only valid ones left are
`ModelsController#index`'s own route and tests asserting its redirect.

- [ ] **Step 7: Run and mutation-check**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/ test/services/maker/model_folder_test.rb`, then
the s3 leg for `models_redirects_test.rb` and `model_strip_test.rb`, then
`bin/rails test test/system/shell_test.rb test/system/accent_spend_test.rb test/system/o3dv_test.rb test/system/projects_models_pages_test.rb test/system/importer_test.rb`.

| mutation | must redden |
|---|---|
| `status: :moved_permanently` dropped from `#index` | "/models is a permanent redirect…" |
| `.slice("q", "status", "tag", "sort")` → all query parameters | the same test (`junk` survives) |
| the `landing_folder_id` redirect in `#show` → always `files_path(folder: @model.folder_node_id)` when the column is set | "a model whose folder is in the trash keeps the model page" |
| the `if controller_path == "files/models"` arm deleted | "the sidebar lights 3D models on the view" (Library lights instead) |
| `models` dropped from the tab bar's Library list | the same test's tab-bar assertion |
| the `get "files/models"` route moved below `resources :files` | every view test (files#show answers instead) |

- [ ] **Step 8: Commit.** Subject: "3D models is a Library view, and a model's page opens its folder".

---

### Task 4: Record the slice (docs only; runs in parallel with Task 1)

- **Spec:** append "**Amended 2026-10-09 (slice 5's plan):**" after slice 4's amendment, summarising the
  eight amendments in prose. Update the §3 map row ("`/models*` → 301 to Library views" becomes
  `/models` 301 → `/files/models`, and `/models/:id` 302 to its folder when it has a strip). Update
  §5.4 and the §9.1 Routes bullet the same way. Section numbers are unchanged.
- **`docs/invariants/model-intake.md`** (spec §9.3):
  - The model strip and the redirects replace the model page for any model with a folder to land on.
  - The "Delete button branches" rule (L39–45) now covers both `models/show` and
    `files/_model_strip`, which must keep the same branches and wording.
  - `models/show`'s files-panel rule (L112–128) applies only to the surviving page.
  - Add the rule that `Maker::ModelFolder` is the one answer to "which model does this folder show?"
    and "where does /models/:id go?", that it keys on `folder_node_id`, and why.
  - Shelves now live at `Settings::ShelvesController` / `/settings/shelves`.
- **`docs/invariants/design-system.md`** rule 8: the 3D models place lights for `files/models`, and the
  phone tab bar lights Library for it. Rule 12: no change unless a pinned class moved.
- **`docs/invariants/files-preview.md`** L519: update the `ModelsController#show` mention if it now
  reads wrongly, and add one sentence that the model strip is not a selection item.
- **CLAUDE.md §14k stub:** `app/controllers/shelves_controller.rb` → `app/controllers/settings/shelves_controller.rb`,
  and add `app/services/maker/model_folder.rb` and `app/views/files/_model_strip.html.erb` to the paths
  that send a reader to model-intake.md. Do not add lines; `docs_hygiene_test` holds a ceiling.
- Commit with the subject "Slice 5's record: Models folds into the Library".

### Task 5: Close out

- [ ] Run bare `bin/ci`. All gates must pass, with identical run counts on the three backend legs.
- [ ] `/finish-branch`: push, open a PR with what changed, the eight amendments, verification, and
  not-verified (no deploy; phones headless only; real data has 0 print runs, so the print log is
  exercised by tests only). Then `bin/log arc --from-pr <n>`. **Merging needs the user's go-ahead.**
