# F — Onboarding and in-app explanation: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repo `.claude/commands/execute-plan.md` governs batching: Tasks 1–4 touch disjoint files and run in parallel in their own worktrees; Task 5 is the orchestrator's.

**Goal:** A maker who is not the author understands, from the pages themselves, where files come from, what the app will do to a `Projects/` folder, why a tool is missing, and when the library cannot be reached — and can rename or move a file without leaving the browser. Design: `docs/superpowers/specs/2026-10-13-f-onboarding-design.md`.

**Facts (file:line on this branch, 2026-10-13):**
- Empty states: `app/views/home/index.html.erb:21`, `app/views/files/index.html.erb:267-278` (three emptinesses; only the last is the "new library" one), `app/views/projects/index.html.erb:72-75`.
- Capabilities in views: `capabilities.scannable?` / `capabilities.port_writable?` (`app/controllers/concerns/library_capabilities.rb:76`); `syncable?` exists on the same object (chunk_remote true).
- Thumbnail degrade: `app/services/maker/previews/thumbnail_map.rb:52-56` rescues `FileLayer::FetchError` to `{}`. There is no `ActiveSupport::CurrentAttributes` class in the app yet.
- Layout: `app/views/layouts/application.html.erb:39` and `:54` are the two `<main class="container …">` (no id). Flash stack: design-system rule 10 — only `.flash-stack > .flash` floats; an inline notice must not reuse `.flash`.
- Rail foot: `app/views/layouts/_rail.html.erb:101-108` (Settings `rail-btn`, Sign out `button_to`); icons are path strings in `ShellHelper::ICON_PATHS` (`app/helpers/shell_helper.rb:38-48`, e.g. `settings:`), drawn by `rail_icon` (`:196`).
- Routes: `resource :settings, only: :show` (`config/routes.rb:393`); files members at `:93-102` (`blob`, `geometry`, `inspector`, `history`, `restore/:oid`).
- Inspector actions: `app/views/files/inspector.html.erb:30-33` (Open / Download / Delete); file page: `app/views/files/show.html.erb:59-61`. `files#destroy` (`app/controllers/files_controller.rb:1001-1005`) is the shape: find by `node_id`, call the port/service, redirect with a notice. `FetchError` → `rescue_from` at `:144`; `UnsupportedOperation` → 422 mapped in the same controller.
- `Maker::MoveNode.call(user, node:, new_parent_node_id:, new_name: nil)` (`app/services/maker/move_node.rb:72`); raises `Maker::MoveNode::Collision` (`:49`) and an `ArgumentError` subclass for a bad leaf name (`:51-54`, `leaf!` at `:197`); `apply_move` reloads the row (`:232`). Read its header before touching it: it validates the parent and the leaf shape itself.
- Folder chooser as a form field: `app/views/shared/_folder_field.html.erb` + `filechooser_controller.js` (writes the chosen node_id into a hidden input; values `childrenUrl`, `createUrl`, `value`, `label`). `app/views/layouts/_topbar_upload.html.erb` shows a caller.
- Git working trees: `Library::WorkingTree.new(user).root_for(node)` answers the repo root a node sits in (`files_controller.rb:663`); `docs/invariants/git-editing.md`: bytes git owns never go through the port.
- Tools copy: `app/views/tools/home/index.html.erb:17-21` names `ADDON_SOURCE_URL`/`ADDON_SOURCE_PATH`; `app/services/maker/addons/registry.rb:51-55` builds "set <ENV_KEY>".
- Thumbs: `app/javascript/controllers/thumbs_controller.js:73-76` resolves `unsupported` and `failed` identically to `setIcon(cell)`.
- Design system (`docs/invariants/design-system.md`): component selectors live in `app/assets/stylesheets/components.css` and nowhere else; page-only layout lives in `pages/<page>.css` (the layout links `pages/home`, `pages/files`, `pages/tools` … explicitly at `application.html.erb:20`); no emoji; the accent is spent once per screen; class names the tests pin are a contract. `test/css_hygiene_test.rb`, `test/stimulus_hygiene_test.rb`, `test/no_emoji_test.rb`, `test/integration/web/template_hygiene_test.rb` guard all of it.

**Conventions that bind every task:** tests run with `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test <files>`; the suite also runs on s3 and chunk_remote legs, so copy that branches on the backend must be asserted through `capabilities`, never a literal backend name; no `Object#stub` (Minitest 6) — copy the `replacing` helper from `test/integration/web/new_menu_test.rb:9` into a suite that must stub a singleton method; **every suite that includes `PublicFixture` calls `@root = use_fresh_share_library!` FIRST in `setup`** (it pins `FileLayer.current` to a Share adapter over a temp dir for that test on every leg, and `create_node!`/`make_dir!`/`make_file!` write real entries under `@root` — a bare `nodes.create!` leaves a NULL `storage_path` that no port verb can act on); form field names are asserted on the rendered HTML (§14d); mutation-check every guard (break it, run the named test, report the output, restore with `git checkout -- <file>` and `rm -rf tmp/cache/bootsnap*`); `bin/rubocop` on touched Ruby; commit per task, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`, no backticks or `!` in messages.

**File ownership (no two tasks touch one file):**

| task | files |
|---|---|
| 1 banner, skip link, failed preview | `app/models/current.rb` (new), `app/services/maker/previews/thumbnail_map.rb`, `app/views/layouts/application.html.erb`, `app/views/layouts/_library_unreachable.html.erb` (new), `app/assets/stylesheets/components.css`, `app/javascript/controllers/thumbs_controller.js`, `app/assets/stylesheets/pages/files.css`, `test/integration/web/library_unreachable_test.rb` (new), `test/integration/web/skip_link_test.rb` (new) |
| 2 empty states, getting started, intake explained | `app/views/shared/_where_files_come_from.html.erb` (new), `app/views/home/index.html.erb`, `app/views/files/index.html.erb`, `app/views/projects/index.html.erb`, `app/assets/stylesheets/pages/home.css`, `test/integration/web/where_files_come_from_test.rb` (new) |
| 3 help page, rail link, tools copy | `config/routes.rb` (one line), `app/controllers/help_controller.rb` (new), `app/views/help/show.html.erb` (new), `app/views/layouts/_rail.html.erb`, `app/helpers/shell_helper.rb` (one `ICON_PATHS` entry), `app/views/tools/home/index.html.erb`, `app/services/maker/addons/registry.rb`, their existing tests, `test/integration/web/help_page_test.rb` (new) |
| 4 rename and move | `config/routes.rb` (two member lines — coordinate: Task 3 adds `get "help"` at the top level, Task 4 adds inside the files `member do`; both are one-line insertions at different places and merge cleanly), `app/controllers/files_controller.rb`, `app/views/files/inspector.html.erb`, `app/views/files/show.html.erb`, `app/views/files/_rename_move.html.erb` (new), `test/integration/web/files_rename_move_test.rb` (new) |

---

### Task 1: The library says when it cannot be reached; a skip link; a failed preview says so

- [ ] **Step 1: Tests first**

`test/integration/web/library_unreachable_test.rb`:

```ruby
require "test_helper"

module Web
  # When the port raises FetchError, list pages keep rendering from the catalog with thumbnails
  # degraded (ThumbnailMap rescues to {}) — and said NOTHING about it. Current.library_unreachable
  # is set exactly where that rescue happens; the layout renders one banner when it is set, and
  # never probes the port itself (a page that did not touch the port says nothing).
  class LibraryUnreachableTest < ActionDispatch::IntegrationTest
    include PublicFixture # make_owner!, sign_in_as, make_file!, make_dir!

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      sign_in_as(@user)
      dir = create_node!(@user, node_id: SecureRandom.uuid, name: "laser", kind: "dir")
      make_file!(@user, "part.stl", dir)
    end

    test "a page whose thumbnails could not be fetched carries the banner" do
      replacing(FileLayer.current, :stat_all, ->(*) { raise FileLayer::FetchError, "share unmounted" }) do
        get files_path
      end
      assert_response :success
      assert_select ".library-unreachable", 1
      assert_match(/can't be reached/i, response.body)
    end

    test "a page that reached the library carries no banner" do
      get files_path
      assert_response :success
      assert_select ".library-unreachable", 0
    end

    test "the flag does not leak into the next request" do
      replacing(FileLayer.current, :stat_all, ->(*) { raise FileLayer::FetchError, "share unmounted" }) do
        get files_path
      end
      get files_path
      assert_select ".library-unreachable", 0
    end
  end
end
```

Check how `PublicFixture` and `replacing` are actually spelled in `test/support/` before relying on them; adapt the setup to the fixture helpers that exist (the point is one live file so `ThumbnailMap.for` calls `stat_all`). If `replacing` cannot stub a singleton's method, define a tiny port-wrapping stub the way `test/integration/web/page_nodes_test.rb`'s FetchError test does — read it first and mirror it.

`test/integration/web/skip_link_test.rb`:

```ruby
require "test_helper"

module Web
  class SkipLinkTest < ActionDispatch::IntegrationTest
    include PublicFixture

    test "the shell starts with a skip link that targets the main landmark" do
      sign_in_as(make_owner!(handle: "ada"))
      get root_path
      assert_select "body > a.skip-link[href='#main']", 1
      assert_select "main#main", 1
    end

    test "the signed-out shell has it too" do
      get new_user_session_path
      assert_select "a.skip-link[href='#main']", 1
      assert_select "main#main", 1
    end
  end
end
```

- [ ] **Step 2: Implement**

`app/models/current.rb`:

```ruby
# Request-scoped flags (ActiveSupport::CurrentAttributes resets them per request and per job).
#
# library_unreachable: set ONLY where a FileLayer::FetchError was rescued into degraded output
# (Maker::Previews::ThumbnailMap.for), read by layouts/_library_unreachable. The banner never
# probes the port: a page that did not touch the port says nothing, so no request pays a network
# round trip for the sentence (CLAUDE.md §14d).
class Current < ActiveSupport::CurrentAttributes
  attribute :library_unreachable
end
```

`thumbnail_map.rb:54-56` — in the rescue: `Current.library_unreachable = true` before `{}` (keep the comment above it; add one line saying the layout reads the flag).

`app/views/layouts/_library_unreachable.html.erb`:

```erb
<%# Rendered by the layout when Current.library_unreachable is set (app/models/current.rb). Names
    the likely cause per backend without probing anything: the flag was set by a port call that
    already failed on this request. Not a .flash: design-system rule 10 — only the flash stack
    floats; this sits inline above the page. %>
<% cause = if capabilities.scannable? && !capabilities.presignable?
             "the library folder may be unmounted"
           elsif capabilities.presignable?
             "the storage bucket isn't answering"
           else
             "the sync server may be down"
           end %>
<div class="library-unreachable" role="status">
  <strong>Your library can't be reached right now</strong> — <%= cause %>. Files are shown from the
  catalog; opening, uploading and downloading will fail until it is back.
</div>
```

(`capabilities` is a controller helper from `LibraryCapabilities`; confirm it is `helper_method`-exposed — `files/index.html.erb:42` uses it in a view, so it is.) Layout: render the partial right after the flash stack inside the signed-in shell, guarded by `<% if Current.library_unreachable %>`, and add `id="main"` to BOTH `<main>` elements, and `<a href="#main" class="skip-link">Skip to content</a>` as the first child of `<body>`.

`components.css` — append, under a `/* ── shell: skip link and the unreachable-library banner ── */` heading:

```css
.skip-link { position: absolute; left: 1rem; top: -3rem; padding: .5rem .75rem; background: var(--surface); color: var(--ink); border: 1px solid var(--line); border-radius: .5rem; z-index: 100; }
.skip-link:focus { top: 1rem; }
.library-unreachable { margin: 0 0 1rem; padding: .75rem 1rem; border: 1px solid var(--line); border-left: 4px solid var(--warn, var(--accent)); border-radius: .5rem; background: var(--surface); }
```

Use the token names `components.css` already uses (grep `var(--` there and copy the real names; `--warn` may not exist — then use the existing muted/ink pair, never a literal colour; design-system rule 4).

Failed previews: in `thumbs_controller.js:73-76`, split the branch: `failed` → `this.setIcon(cell); cell.classList.add("thumb-failed"); cell.title = "Preview couldn't be rendered"`; `unsupported` stays as is. In `pages/files.css` add `.thumb-failed::after` drawing a small corner mark with existing tokens (no emoji, no image). `test/stimulus_hygiene_test.rb` must stay green (no new controller).

- [ ] **Step 3: Run** the two new tests plus `test/integration/web/page_nodes_test.rb test/css_hygiene_test.rb test/stimulus_hygiene_test.rb test/no_emoji_test.rb test/integration/web/template_hygiene_test.rb test/integration/web/shell_test.rb` (if that last one is a system test, skip it here). Expected PASS.

- [ ] **Step 4: Mutation-check** — remove the `Current.library_unreachable = true` line: the first unreachable test RED; restore. Remove `id="main"` from one `<main>`: the skip-link test RED; restore.

- [ ] **Step 5: Commit** — "An unreachable library is said on the page, the shell has a skip link, and a failed preview says so".

---

### Task 2: The empty states say where files come from, and intake is explained first

- [ ] **Step 1: Test first** — `test/integration/web/where_files_come_from_test.rb`:

```ruby
require "test_helper"

module Web
  # A brand-new library used to say "No files yet. Upload one." and nothing about the folder on
  # the server, the desktop app, or what a Projects/ folder turns into. The copy branches on the
  # port's capabilities so it is right on every backend leg, and the assertions do too.
  class WhereFilesComeFromTest < ActionDispatch::IntegrationTest
    include PublicFixture

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      sign_in_as(@user)
    end

    def caps = FileLayer.current.capabilities

    test "Home's getting-started panel names every way a file arrives on this backend" do
      get root_path
      assert_select ".getting-started", 1
      assert_match(/Upload/, response.body)
      assert_match(/every 15 minutes/i, response.body) if caps.scannable?
      assert_match(/desktop app/i, response.body) if caps.syncable?
      assert_match(/Projects\//, response.body)
      assert_select "a[href=?]", help_path
    end

    test "the panel is gone once a file exists" do
      dir = create_node!(@user, node_id: SecureRandom.uuid, name: "laser", kind: "dir")
      make_file!(@user, "part.stl", dir)
      get root_path
      assert_select ".getting-started", 0
    end

    test "the Files page's new-library state says the same" do
      get files_path
      assert_match(/every 15 minutes/i, response.body) if caps.scannable?
      assert_match(/desktop app/i, response.body) if caps.syncable?
      assert_match(/Upload/, response.body)
    end

    test "the Projects page says what a Projects folder becomes before anything is moved" do
      get projects_path
      assert_match(/becomes a project/i, response.body)
      assert_match(/filed/i, response.body)
      assert_select "a[href=?]", settings_filing_rules_path
    end
  end
end
```

`help_path` is Task 3's route; until the branches merge, assert the link by its literal `"/help"` so this task's test runs green alone.

- [ ] **Step 2: Implement**

`app/views/shared/_where_files_come_from.html.erb` — a `<ul class="file-sources">` with one `<li>` per way, branching on `capabilities`:
- always: "**Upload**, in the top bar, puts files in the folder you're looking at."
- `capabilities.scannable?`: "**The library folder on this server** is the library. Files you put there — from a NAS share, another program, a copy — appear here within 15 minutes, or right away with *Rescan library* under ⋯ on the Files page." (For s3 — `capabilities.presignable?` — say "the storage bucket" instead of "folder".)
- `capabilities.syncable?`: "**The desktop app** syncs a folder on your computer with this library."
Then one sentence, always: "A folder under <code>Projects/</code> becomes a project; files dropped at a project's root are filed into type folders by the next sweep (<%= link_to "Filing", settings_filing_rules_path %>)."

Home: replace the `No files yet…` paragraph with a `<section class="panel getting-started">` — heading "Getting started", the partial, and three short numbered steps (files in; `Projects/`; Tools, linking `tools_path`), plus "Help explains all of this" linking `/help`. Only when `@recent_files.empty?` (which is exactly "no live file", `home_controller.rb:12-13`). Styles in `pages/home.css`, tokens only.

Files: replace the last emptiness (`:277`) with a `<div class="empty">` containing the partial. Also, at the top of a project folder (`@folder_project.present?`), one muted line: "Loose files at this folder's root are filed into type folders by the next sweep (every 15 minutes)." — find where the folder head renders (`files/index.html.erb` near the breadcrumb/`@folder_project` use at `:42`) and put it beside the existing project note if one exists.

Projects: replace the `No projects yet…` branch (keep the archived one) with: "No projects yet. A folder you create under <code>Projects/</code> — on the server, from the desktop app, or with New ▸ Folder — becomes a project here within 15 minutes; files dropped at its root are filed into type folders (see <%= link_to "Filing", settings_filing_rules_path %>). Or create one now." keeping whatever "create" control the page already offers.

- [ ] **Step 3: Run** the new test plus `test/integration/web/home_test.rb`-style existing suites that assert the old sentences (`grep -rn "No files yet\|No projects yet" test/` and update those assertions to the new copy — each must still assert something true). Then `no_emoji`, `template_hygiene`, `css_hygiene`.

- [ ] **Step 4: Mutation-check** — drop the `Projects/` sentence from the partial: the Home and Projects tests RED; restore.

- [ ] **Step 5: Commit** — "The empty library says where files come from, and what a Projects folder becomes, before anything is moved".

---

### Task 3: A Help page, a Help button in the rail, and no operator vocabulary on the Tools page

- [ ] **Step 1: Test first** — `test/integration/web/help_page_test.rb`:

```ruby
require "test_helper"

module Web
  class HelpPageTest < ActionDispatch::IntegrationTest
    include PublicFixture

    test "signed out, help redirects to sign-in like every other page" do
      get "/help"
      assert_redirected_to new_user_session_path
    end

    test "signed in, the help page explains the library, projects, tools and accounts" do
      sign_in_as(make_owner!(handle: "ada"))
      get "/help"
      assert_response :success
      %w[library Projects/ Filing Rescan Trash Tools owner sign-ups].each do |word|
        assert_match(/#{Regexp.escape(word)}/i, response.body, "help page should mention #{word}")
      end
      assert_select "a[href=?]", settings_filing_rules_path
      assert_select "a[href=?]", tools_path
    end

    test "the rail offers Help beside Settings" do
      sign_in_as(make_owner!(handle: "ada"))
      get root_path
      assert_select "a.rail-btn[href='/help'][aria-label='Help']", 1
    end

    test "the Tools page speaks to the maker, not the operator" do
      sign_in_as(make_owner!(handle: "ada"))
      get tools_path
      assert_response :success
      body_without_details = response.body.gsub(%r{<details.*?</details>}m, "")
      assert_no_match(/ADDON_SOURCE_URL|ADDON_SOURCE_PATH|_SIDECAR_URL/, body_without_details,
                      "environment-variable names belong behind the operator's <details>, not in the maker's copy")
    end
  end
end
```

- [ ] **Step 2: Implement**

`config/routes.rb` — beside `resource :settings`: `get "help", to: "help#show", as: :help`.

`app/controllers/help_controller.rb`: `class HelpController < ApplicationController; def show; end; end` (session-authed by `ApplicationController`'s `authenticate_user!`).

`app/views/help/show.html.erb` — `content_for :title, "Help — Tinkerex"`, a `.page-head` h1 "Help", then sections (use `.settings-list`/`.page-head`/`.prose`-style classes that already exist in `components.css`; add nothing to the stylesheet unless a class is missing, and then only in `components.css`):
1. **Your library** — the folder/bucket/sync-server sentence per backend (reuse Task 2's partial if it has merged; otherwise write the three sentences inline and leave a comment to swap in `shared/_where_files_come_from` later), the 15-minute scan and Rescan, upload, versions (chunk_remote only: `capabilities.versioned?`), Trash and Restore (restore the folder before its files).
2. **Projects** — a `Projects/` folder becomes a project; loose root files are filed by the sweep into type folders per the Filing rules (link); archiving; publishing a project (handle, public or unlisted) and what visitors see.
3. **3D models and shelves** — a shelf is a path; a model is what a folder under one shows (`docs/invariants/model-intake.md` in one paragraph).
4. **Tools** — add-ons; some need a service the person running the server installs; the generators tool needs none.
5. **Your account** — the first account is the owner; sign-ups are closed unless the person running the server opens them; mail; what to do if you forget your password when the server has no mail (ask the person running it; the console door is `bin/rails tinkerex:password` — say it once, for that person).
6. **For the person running this server** — a `<details>` with `docs/INSTALL.md`, the environment variables that matter for tools (`ADDON_SOURCE_URL` / `ADDON_SOURCE_PATH`, `<NAME>_SIDECAR_URL`), and the source repository link `https://github.com/chaim354/tinkerex`.

`_rail.html.erb:101` — before the Settings link, a `link_to help_path, class: "rail-btn rail-help", title: "Help", "aria-label": "Help"` with `rail_icon(:help)` and `<span>Help</span>`; `shell_helper.rb` `ICON_PATHS` gains `help: "M8 1.5a6.5 6.5 0 1 1 0 13 6.5 6.5 0 0 1 0-13z M6.2 6.2a1.9 1.9 0 1 1 2.7 1.7c-.6.3-.9.7-.9 1.3v.4 M8 11.4v.1"` (a circled question mark; adjust so it reads at 16px).

`tools/home/index.html.erb:17-21` — replace the `else` branch with: `<p class="muted">No tools are installed on this server. The person running it can add them — <%= link_to "Help", help_path %> says how.</p>` and a `<details class="muted"><summary>For the person running this server</summary>Set <code>ADDON_SOURCE_URL</code> … (the current sentence)</details>`.

`registry.rb:51-55` — `unavailable_reason`: `"Needs the #{missing} service, which this server doesn't run"`; move the env-key mention into the existing comment. Update `test/services/maker/addons/registry_test.rb` (or wherever `set ADDON_SERVICE` is asserted: `grep -rn "SIDECAR_URL\|ADDON_SERVICE" test/`) to the new sentence, keeping the assertion that the card is `available? == false`.

- [ ] **Step 3: Run** the new test, the registry/tools suites you touched, `stimulus_hygiene`, `no_emoji`, `template_hygiene`, `css_hygiene`, and `test/integration/web/shell_test.rb` if it is an integration test (the rail foot is measured in a system test too; do not run system tests here).

- [ ] **Step 4: Mutation-check** — put `ADDON_SOURCE_URL` back into the maker's paragraph: the Tools test RED; restore. Remove the rail link: its test RED; restore.

- [ ] **Step 5: Commit** — "A Help page, a Help button in the rail, and the Tools page speaks to the maker".

---

### Task 4: Rename and Move to folder, from the inspector and the file page

- [ ] **Step 1: Read first** — `app/services/maker/move_node.rb` whole (what it validates, what it raises, how `new_name` and `new_parent_node_id` combine), `docs/invariants/git-editing.md` (bytes git owns never go through the port — a node inside a working tree must not be renamed through the port), `app/views/shared/_folder_field.html.erb` (the form-field chooser), `files_controller.rb:120-160` (the rescue map), and `test/integration/web/files_selection_test.rb` for how the suite drives file pages on all three legs (fixtures that create nodes through the port vs `nodes.create!` — a rename on share/s3 needs a REAL file under `LIBRARY_PATH`; `PublicFixture#make_file!` or the Files upload path creates one — check which helper writes through the port).

- [ ] **Step 2: Tests first** — `test/integration/web/files_rename_move_test.rb`:

```ruby
require "test_helper"

module Web
  # Rename and Move to folder from the browser (user stories 1.3 and 4.7 were `rough` for the lack
  # of them). Both are Maker::MoveNode behind two member routes; a collision and a bad name answer
  # the page, not a 500; a node inside a git working tree offers neither (git-editing.md).
  class FilesRenameMoveTest < ActionDispatch::IntegrationTest
    include PublicFixture

    setup do
      @root = use_fresh_share_library!   # pins a real Share port over a temp dir on EVERY leg
      @user = make_owner!(handle: "ada")
      sign_in_as(@user)
      @dir = create_node!(@user, node_id: SecureRandom.uuid, name: "laser", kind: "dir")
      @docs = make_dir!(@user, "docs", @dir)
      @file = make_file!(@user, "part.stl", @dir)
    end

    test "the inspector and the file page offer Rename and Move with the field names the controller reads" do
      get inspector_file_path(@file.node_id)
      assert_select "form[action=?] input[name='name']", rename_file_path(@file.node_id)
      assert_select "form[action=?] input[name='parent_node_id']", move_file_path(@file.node_id)
      get file_path(@file.node_id)
      assert_select "form[action=?] input[name='name']", rename_file_path(@file.node_id)
    end

    test "rename changes the name and lands back on the file" do
      patch rename_file_path(@file.node_id), params: { name: "bracket.stl" }
      assert_redirected_to file_path(@file.node_id)
      assert_equal "bracket.stl", @user.nodes.find_by!(node_id: @file.node_id).name
    end

    test "a rename onto an existing name is refused with a sentence, not a 500" do
      make_file!(@user, "taken.stl", @dir)
      patch rename_file_path(@file.node_id), params: { name: "taken.stl" }
      assert_response :redirect
      follow_redirect!
      assert_match(/already/i, flash[:alert].to_s)
      assert_equal "part.stl", @user.nodes.find_by!(node_id: @file.node_id).name
    end

    test "a name that is not a single path segment is refused" do
      patch rename_file_path(@file.node_id), params: { name: "../escape.stl" }
      assert_response :redirect
      assert_match(/name/i, flash[:alert].to_s)
    end

    test "move changes the parent" do
      patch move_file_path(@file.node_id), params: { parent_node_id: @docs.node_id }
      assert_redirected_to file_path(@file.node_id)
      assert_equal @docs.node_id, @user.nodes.find_by!(node_id: @file.node_id).parent
    end

    test "a node inside a git working tree offers neither" do
      # Build a working tree the way test/support/git_repo_fixture.rb does, put a file in it, and
      # assert the inspector renders no rename/move form for it (and the PATCH is refused).
    end
  end
end
```

Fill the fixture lines from what Step 1 found; the file must exist through the port on share/s3 or `MoveNode` raises `NotFound`.

- [ ] **Step 3: Implement**

Routes (inside `member do`): `patch "rename"` and `patch "move"`.

`files_controller.rb` — two actions modelled on `destroy`:

```ruby
  # RENAME AND MOVE, FROM THE BROWSER (F). Both are Maker::MoveNode, which validates the leaf name
  # and the parent and raises Collision for a taken name — the one condition a user hits
  # routinely, answered as a sentence on the page they came from. A node inside a git working
  # tree is refused here as well as hidden in the view: bytes git owns never go through the port
  # (docs/invariants/git-editing.md). FetchError and UnsupportedOperation keep this controller's
  # existing mappings (503 / 422), so a share that is unmounted or an s3 directory move answers
  # the way every other port failure here does.
  def rename
    node = current_user.nodes.present.find_by!(node_id: params[:id])
    return redirect_back_or_to(file_path(node.node_id), alert: "Files inside a repository are renamed in git, not here.") if in_working_tree?(node)

    Maker::MoveNode.call(current_user, node:, new_parent_node_id: node.parent, new_name: params.require(:name))
    redirect_to file_path(node.node_id), notice: "Renamed to #{params[:name]}."
  rescue Maker::MoveNode::Collision
    redirect_back_or_to file_path(node.node_id), alert: "Something named #{params[:name]} is already there."
  rescue Maker::MoveNode::InvalidName => e   # use the real class name from move_node.rb:51-54
    redirect_back_or_to file_path(node.node_id), alert: "That name isn't allowed: #{e.message}"
  end

  def move
    node = current_user.nodes.present.find_by!(node_id: params[:id])
    return redirect_back_or_to(file_path(node.node_id), alert: "Files inside a repository are moved in git, not here.") if in_working_tree?(node)

    Maker::MoveNode.call(current_user, node:, new_parent_node_id: params.require(:parent_node_id).presence)
    redirect_to file_path(node.node_id), notice: "Moved #{node.name}."
  rescue Maker::MoveNode::Collision
    redirect_back_or_to file_path(node.node_id), alert: "Something named #{node.name} is already in that folder."
  end

  def in_working_tree?(node) = Library::WorkingTree.new(current_user).root_for(node).present?
```

(`root_for` is what `files#update` uses at `:663`; confirm its exact name and return, and that `MoveNode` wants `parent: nil` for the library root the way the chooser's `ROOT_LABEL` implies.)

`app/views/files/_rename_move.html.erb` — two small forms, rendered by both `inspector.html.erb` (after the Delete button) and `show.html.erb` (beside Download/Delete), and NOT rendered when `in_working_tree?` — expose that as `@in_working_tree` set by the `show`/`inspector` actions (or a helper). Rename: `form_with url: rename_file_path(node.node_id), method: :patch` with a text field named `name` prefilled with the node's name and a "Rename" submit. Move: `form_with url: move_file_path(node.node_id), method: :patch` rendering `shared/_folder_field` (read its locals: it needs the hidden input's name — make it `parent_node_id` — plus `children_url`/`create_url` as `_topbar_upload` passes them) and a "Move" submit. Use existing `.menu-form` / `.field` / `.btn small` classes; the accent is already spent on the page, so these are plain buttons.

- [ ] **Step 4: Run** the new test, `test/integration/web/files_selection_test.rb`, `test/integration/web/inspector_test.rb`, and `template_hygiene`; then the same new test under the s3 leg env if `.kamal`-free s3 stubs are available locally (`ci.yml`'s `test-s3-backend` env lists the five `LIBRARY_S3_*` stub knobs) — if not, say so in the report; the orchestrator's `bin/ci` runs all three legs.

- [ ] **Step 5: Mutation-check** — remove the `rescue Maker::MoveNode::Collision` from `rename`: the collision test RED (500); restore. Remove the working-tree guard: the working-tree test RED; restore.

- [ ] **Step 6: Commit** — "Rename and Move to folder from the inspector and the file page".

---

### Task 5 (orchestrator): merge, gates, docs, PR

1. Merge the four branches; run `bin/ci` (three identical run counts).
2. `docs/user-stories.md`: re-tag 1.3 (rename/move) and 4.7 (file into a project — only if Task 4's Move covers it) from `rough` with the new evidence; keep the table in step.
3. `docs/AUDIT-2026-10-12-readiness.md` §2.3: mark items 1, 2, 3 (help), 4 (rename/move, failed previews, banner), 7 (skip link) fixed by F.
4. CLAUDE.md §14d: one line for `Current.library_unreachable` (never probes), within the ceiling.
5. `/finish-branch`, `bin/log arc --from-pr <n>`.
