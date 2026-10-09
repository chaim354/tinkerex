# Redesign slice 4 — folder destinations — Implementation Plan

> **For agentic workers:** in this repo, execute with **`.claude/commands/execute-plan.md`** (CLAUDE.md
> §15: batched by file, parallel where independent, one capped quality review per task). It
> overrides the generic superpowers subagent loop. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** New files land in the folder the maker is looking at. The global "current project" is
retired. Upload moves into the top bar with a caption naming its destination. A tool page starts its
save where the maker came from, or where that tool last saved.

**Architecture:**
- **Tool pages.** `Tools::AddonsController#show` resolves its default save folder in four steps:
  `?in=`, then `?state=`'s own output folder, then the tool's last output (mapped up to its project's
  folder), then the library root. It hands that folder to the bundle through the same two ctx keys as
  today (`defaultFolder`, `defaultFolderLabel`), so the addons repo needs no code change.
- **The current project is deleted:** the concern, the controller, the preference, the rail card,
  the phone chip, "Set as current", the make-current checkbox and Home's current-project hero.
  `User` ignores its two columns until slice 7 drops them, and an architecture guard forbids the
  retired names in `app/`, `lib/` and `config/routes.rb`.
- **A small `FolderDestination` concern carries the page's folder.** The action that renders a
  folder sets it, and nothing else does. The top bar's Upload and the New ▾ menu both read it. Upload
  keeps the Files page's two flows exactly (`port_writable?` picks one) and adds the destination.
  - On a page with no folder, a new Stimulus controller, `upload-pick`, asks with the library's own
    folder chooser before the file picker opens.

**Tech Stack:** Rails 8, Turbo, Stimulus (importmap), Minitest request and system tests, Ripper for the
guard.

**Spec:** `docs/superpowers/specs/2026-10-08-structural-redesign-design.md` §4.2, §7, §8, §9.1 and §11
(slice 4). Slices 1 (#381), 2 (#382) and 3 (#383) are merged.

**Required reading for every task** (they bind these paths):
- `docs/invariants/addons.md` (Task 1)
- `docs/invariants/project-intake.md` (Tasks 1 and 2)
- `docs/invariants/design-system.md` (Tasks 2 and 3)
- `docs/invariants/files-preview.md` (Task 3)
- CLAUDE.md §14a (the `port_writable` bullet) and §14d

The rules most likely to bite here:
- **`port_writable` is not "accepts uploads".** It picks the flow. A test asserting one flow's markup
  is red on the other leg, so every upload assertion branches on
  `FileLayer.current.capabilities.port_writable?` (memory: this has bitten twice).
- **The nine legacy `data-addon-*` attributes and both shapes of `defaultFolder` stay**, for the
  life of `api_version: "1"`. The raw mount ctx's `defaultFolder` is a STRING. Never add a
  `host.defaultFolder` accessor.
- **`?state=` is a hint and answers nil**, and `?in=` is a hint in the same way: a stale, foreign or
  non-String value falls through to the next step and never errors.
- **A project-folder fixture must be port-free.** `ensure_library_folder!` in a test is a real
  `mkdir`, red on s3 and chunk_remote. Use `project_folder_rows!` (test_helper.rb:181).
- **No `%>` inside an ERB comment.**
- **A `data-controller` name must resolve** (`test/stimulus_hygiene_test.rb`).
- **Every colour is a token**, and `shell.css` carries no colour literals.
- **No sideways scroll at 375px.**
- **Query budgets assert constancy in N.**
- **Mutation-check every guard; clear `tmp/cache/bootsnap*` after restoring.**

---

## Decisions this plan applies

From the spec:
- New files land in the folder you're in (§2 decision 6, §8).
- The current project is retired (§9.1).
- Tool output reaches a project only through intake (§7).
- Upload sits in the top bar (§4.2).

**The cross-repo check (§9.1) is done, and it passes.**
- No code in `chaim354/tinkerex-addons` (`main` @ `b0e6c0f`) reads `.current-project select`,
  `current_project`, `project_id` or any host DOM. The only host values its bundles read are the raw
  ctx keys `ctx.defaultFolder` and `ctx.defaultFolderLabel`, in three copies of `folder_field.js`.
- So this repo keeps those keys and changes only what fills them. No new host contract is needed,
  and the addons repo needs a README correction (Task 4) and no code.

Amendments found while planning, recorded in the spec by Task 4:

1. **No host "destination bar" on tool pages.** Spec §7 asked for "Saves to … · Change" above every
   tool.
   - All three bundles already render their own "Save into" field (`mountFolderField`), seeded from
     the host's `defaultFolder` and sent back as `folderNodeId` on save.
   - A host bar would be a second chooser that can disagree with the bundle's. Its Change could only
     take effect by reloading with `?in=`, which throws away unsaved tool settings (the boxes params).
   - So the host's job is the **default**: the bundle's own field shows it and changes it.
2. **The tool's default is resolved in four steps, not three.**
   - Step 1: `?in=` names a live folder of the user's. New ▸ <tool> sets it to the folder you're in.
   - Step 2: `?state=` names one of this tool's saved states, and the default is the folder that
     state's output lives in now. This is how "Reopen from a file sets the file's folder" (§7) is
     met: every reopen link already carries `state=`, so no link changes.
     `#resolve_placements`' owned arm then replaces the file in place there.
   - Step 3: the folder of the tool's most recent live output, **mapped up to its owning project's
     folder** when it sits inside one. The eager intake nudge files `Projects/<slug>/x.svg` into
     `design/`. A same-name save into `design/` gets `#refuse_taken_names!`'s terminal 422, while the
     project root reaches `#resolve_placements`' 409 "Save as revision 2" offer.
     `box_revisions_test`'s join test pins that offer through this step.
   - Step 4: the library root.
3. **Home's current-project hero goes in this slice, with the concept it shows.** Recent is still
   slice 6. Until then Home keeps its other sections, and its Upload is the top bar's, which asks for
   a folder.
4. **The project hub's Files-panel upload moves to the top bar.** That keeps one door per destination
   and two accent controls on the hub, the two decision 3 allows. An upload into the project folder
   attaches through intake (`FilesController#create` / `#finalize_upload` both run
   `intake_project_folder`). `Projects::UploadsController` stays for the build-log entries' own
   uploads.
5. **The top-bar Upload keeps the Files flows' outcomes unchanged.** On share/s3 one file redirects to
   its page and a batch redirects back. On chunk_remote the page reloads. Nothing here changes a
   redirect.
6. **Upload is `.btn.primary` on the Library and the project hub, `.btn` everywhere else.**
   - Home keeps "New project" as its primary until slice 6 makes it Recent.
   - A tool page's primary is its own Save.
   - The workspace's top-bar Upload is quiet.
7. **At phone width Upload sits beside New.** The spec's single "+" is deferred to slice 7's cleanup.
   The caption hides below 1100px, where the button's `title` carries it.
8. **The New ▾ menu creates in the same destination as Upload**, which is now the validated folder on
   every page that shows one. Until now it used the raw `params[:folder]`, on the Files index only.
   The menu's tool entries carry `in=` that folder.
9. **`users.current_project_id` and `users.remember_current_project` are `ignored_columns`** until
   slice 7 drops them, so no code can read either by accident.

## Files

| file | change | task |
|---|---|---|
| `app/controllers/tools/addons_controller.rb` | `#show` resolves the default in four steps; the attach-to-current-project call and its comments go | 1 |
| `app/controllers/tools/home_controller.rb`, `app/views/tools/home/new_menu.html.erb` | the New menu's tool links carry `in=` | 1 |
| `test/controllers/tools/addon_destination_test.rb` | new | 1 |
| `test/system/addon_bundle_test.rb`, `test/system/box_revisions_test.rb` | seed with `?in=` / step 3 instead of the current-project select | 1 |
| `test/controllers/tools/addons_controller_test.rb` | comment rewording only (L636–639, L1053–1061) | 1 |
| `test/integration/web/page_query_budget_test.rb` | a tools#show budget | 1 |
| `app/controllers/concerns/current_project.rb`, `app/controllers/current_project_controller.rb`, `app/controllers/settings/preferences_controller.rb`, `app/views/home/_project_hero.html.erb` | deleted | 2 |
| `config/routes.rb` | the two routes go | 2 |
| `app/controllers/application_controller.rb`, `home_controller.rb`, `projects_controller.rb`, `inventory_items_controller.rb` | the current project's readers go | 2 |
| `app/views/layouts/_rail.html.erb`, `_topbar.html.erb` (the phone chip only), `application.html.erb` (comment), `app/views/settings/show.html.erb`, `projects/_form.html.erb`, `projects/show.html.erb`, `home/index.html.erb`, `files/index.html.erb` (the current-project branch, caption and menu switch) | the current project's UI goes | 2 |
| `app/assets/stylesheets/shell.css`, `components.css`, `pages/home.css` | the card, chip, badge and hero rules go | 2 |
| `app/models/user.rb` | `ignored_columns` | 2 |
| comment-only: `move_conflicts.rb`, `csp_reports_controller.rb`, `public/base_controller.rb`, `projects/attachments_controller.rb`, `projects/uploads_controller.rb`, `maker/attach_to_project.rb`, `shell_helper.rb`, `files/_attach.html.erb`, `projects/_upload_control.html.erb`, `tools/base_controller.rb` | reworded | 2 |
| tests listed in Task 2's table, `test/architecture_invariants_test.rb` (new guard), `test/test_helper.rb` | deleted, rewritten or trimmed | 2 |
| `app/controllers/concerns/folder_destination.rb` | new | 3 |
| `app/controllers/application_controller.rb` | include `LibraryCapabilities` and `FolderDestination` | 3 |
| `app/controllers/files_controller.rb`, `projects_controller.rb`, `tools/addons_controller.rb` | set the destination | 3 |
| `app/helpers/new_menu_helper.rb` | reads the destination | 3 |
| `app/views/layouts/_topbar.html.erb`, new `app/views/layouts/_topbar_upload.html.erb` | Upload in the bar; the tools frame carries `in=` | 3 |
| `app/javascript/controllers/upload_pick_controller.js` | new | 3 |
| `app/assets/stylesheets/shell.css` | `.topbar-upload*` | 3 |
| `app/views/files/index.html.erb`, `app/views/projects/_attachments.html.erb` | their page-level uploaders go | 3 |
| `test/integration/web/topbar_upload_test.rb`, `test/system/topbar_upload_test.rb` | new | 3 |
| `test/integration/web/files_toolbar_test.rb`, `new_menu_test.rb`, `test/system/accent_spend_test.rb`, `upload_batch_test.rb` and the other upload pins in Task 3's table | rewritten | 3 |
| spec, `docs/invariants/{design-system,project-intake,addons}.md`, `docs/addon-api-v1.md`, CLAUDE.md §11 | the record | 4 |
| `chaim354/tinkerex-addons` `README.md` | a docs PR in the sibling repo | 4 |

**Order: Task 1 → Task 2 → Task 3, sequentially.**
- Task 2 deletes the concern that `Tools::AddonsController` calls until Task 1 lands.
- Task 3 edits the same lines of `files/index.html.erb`, `_topbar.html.erb` and
  `application_controller.rb` that Task 2 clears.
- Run each task in its own worktree based on the previous task's commit, then cherry-pick it onto
  `claude/redesign-slice-4`.

---

### Task 1: The tool's default destination

**Files:**
- Modify: `app/controllers/tools/addons_controller.rb` (`#show` ~L192–204; `#create` L538 and comments
  L171–172, L541–547, L553–554; new private methods after `#addon_states` ~L598)
- Modify: `app/controllers/tools/home_controller.rb` (`#new_menu` ~L19–22),
  `app/views/tools/home/new_menu.html.erb`
- Create: `test/controllers/tools/addon_destination_test.rb`
- Modify: `test/system/addon_bundle_test.rb` (L218–262), `test/system/box_revisions_test.rb` (L152–268),
  `test/controllers/tools/addons_controller_test.rb` (comments only),
  `test/integration/web/page_query_budget_test.rb`

- [ ] **Step 1: Write the failing request tests**

Create `test/controllers/tools/addon_destination_test.rb`:

```ruby
require "test_helper"
require_relative "../../support/fake_addon_source"

module Tools
  # WHERE A TOOL'S SAVE STARTS (structural redesign spec §7, as slice 4's plan amended it): the four
  # steps of Tools::AddonsController#tool_destination_node_id, read off the two attributes the shipped
  # bundles seed their "Save into" field from (`data-addon-default-folder-value` /
  # `-label-value`). Rows are created directly and no port call is made, so every backend leg runs
  # the same assertions.
  class AddonDestinationTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    MANIFEST = {
      "key" => "destkit", "title" => "Dest Kit", "icon" => "✏️", "description" => "Destinations",
      "api_version" => "1", "entry" => "dest.js"
    }.freeze

    setup do
      @prior_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST ], assets: { "destkit/dest.js" => "export default { mount() {} }" }
      )
      @user = User.create!(email: "dest-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    teardown do
      Maker::Addons::Source.reset!
      Rails.cache = @prior_cache
      FileLayer.reset!
    end

    def dir(id, name, parent = nil, deleted: false)
      @user.nodes.create!(node_id: id, name:, kind: "dir", parent_node_id: parent, deleted:, mtime: 1, size: 0)
    end

    def file(id, name, parent, deleted: false)
      @user.nodes.create!(node_id: id, name:, kind: "file", parent_node_id: parent, deleted:,
                          mtime: 1, size: 1, content_hash: "h-#{id}", current_version_id: "v-#{id}")
    end

    # A saved state whose output is `node_id`, touched at `at` — `updated_at` is what orders "most
    # recent", so tests set it explicitly rather than trusting creation order (memory: a sort fixture
    # must disagree with the default order, or the mutation reads green).
    def saved(node_id, at:, key: "destkit")
      state = @user.maker_addon_states.create!(addon_key: key, name: "box #{node_id}", data: {})
      state.files.create!(node_id:, role: "output")
      state.update_columns(updated_at: at)
      state
    end

    def assert_default(node_id, label)
      assert_response :success
      assert_select "[data-controller='addon'][data-addon-default-folder-value=?]", node_id.to_s
      assert_select "[data-controller='addon'][data-addon-default-folder-label-value=?]", label
    end

    test "with nothing saved, a tool starts at the library root" do
      get tools_addon_path("destkit")
      assert_default "", "/ (library root)"
    end

    test "?in= naming a live folder of the user's wins over everything else" do
      dir("d-jigs", "jigs")
      dir("d-cad", "cad")
      file("n-old", "old.svg", "d-cad")
      saved("n-old", at: 1.hour.ago)
      get tools_addon_path("destkit", in: "d-jigs")
      assert_default "d-jigs", "/jigs"
    end

    test "a stale, foreign, file or non-String ?in= falls through to the next step" do
      dir("d-cad", "cad")
      file("n-old", "old.svg", "d-cad")
      saved("n-old", at: 1.hour.ago)
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.nodes.create!(node_id: "d-theirs", name: "theirs", kind: "dir", mtime: 1, size: 0)

      [ "gone", "d-theirs", "n-old" ].each do |stale|
        get tools_addon_path("destkit", in: stale)
        assert_default "d-cad", "/cad"
      end
      get "#{tools_addon_path('destkit')}?in[]=d-cad&in[]=gone"
      assert_default "d-cad", "/cad"
    end

    test "with no ?in=, the tool starts where its most recent live output is" do
      dir("d-new", "new")
      dir("d-old", "old")
      # Created FIRST but touched LAST, so creation order and recency disagree.
      file("n-new", "new.svg", "d-new")
      saved("n-new", at: 1.minute.ago)
      file("n-old", "old.svg", "d-old")
      saved("n-old", at: 2.days.ago)
      get tools_addon_path("destkit")
      assert_default "d-new", "/new"
    end

    test "a trashed output, or one whose folder is gone, is skipped for the next live one" do
      dir("d-live", "live")
      dir("d-dead", "dead", deleted: true)
      file("n-live", "live.svg", "d-live")
      saved("n-live", at: 3.days.ago)
      file("n-trashed", "trashed.svg", "d-live", deleted: true)
      saved("n-trashed", at: 1.minute.ago)
      file("n-orphan", "orphan.svg", "d-dead")
      saved("n-orphan", at: 2.minutes.ago)
      get tools_addon_path("destkit")
      assert_default "d-live", "/live"
    end

    # THE ROOT IS AN ANSWER, NOT A MISS: a newest output at the root must not fall through to an older
    # output's folder. This is the LEFT JOIN and the `empty?`-not-`any?` in #destination_from_outputs.
    test "a newest output at the library root keeps the tool at the root" do
      dir("d-old", "old")
      file("n-old", "old.svg", "d-old")
      saved("n-old", at: 2.days.ago)
      file("n-root", "root.svg", nil)
      saved("n-root", at: 1.minute.ago)
      get tools_addon_path("destkit")
      assert_default "", "/ (library root)"
    end

    test "an output the intake sweep filed into a project's category folder starts at the project folder" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project_folder_rows!(@user, project)
      dir("d-design", "design", folder.node_id)
      file("n-lamp", "lamp.svg", "d-design")
      saved("n-lamp", at: 1.minute.ago)
      get tools_addon_path("destkit")
      assert_default folder.node_id, "/Projects/desk-lamp"
    end

    test "only this tool's own outputs count" do
      dir("d-mine", "mine")
      dir("d-other", "other")
      file("n-mine", "mine.svg", "d-mine")
      saved("n-mine", at: 2.days.ago)
      file("n-other", "other.svg", "d-other")
      saved("n-other", at: 1.minute.ago, key: "someone-else")
      get tools_addon_path("destkit")
      assert_default "d-mine", "/mine"
    end

    # STEP 2 — a reopened file starts in ITS folder, even when another box is newer, and WITHOUT the
    # project mapping: a revision replaces its own output in place wherever that output lives.
    test "?state= starts where that state's own output lives" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project_folder_rows!(@user, project)
      dir("d-design", "design", folder.node_id)
      dir("d-new", "new")
      file("n-lamp", "lamp.svg", "d-design")
      reopened = saved("n-lamp", at: 3.days.ago)
      file("n-new", "new.svg", "d-new")
      saved("n-new", at: 1.minute.ago)
      get tools_addon_path("destkit", state: reopened.id)
      assert_default "d-design", "/Projects/desk-lamp/design"
    end

    test "a ?state= that resolves to nothing falls through to the newest output" do
      dir("d-new", "new")
      file("n-new", "new.svg", "d-new")
      saved("n-new", at: 1.minute.ago)
      get tools_addon_path("destkit", state: 999_999)
      assert_default "d-new", "/new"
    end

    # The ctx blob carries the same answer as the legacy attribute (addons.md: both shapes, one render).
    test "the ctx blob's defaultFolder agrees with the attribute" do
      dir("d-jigs", "jigs")
      get tools_addon_path("destkit", in: "d-jigs")
      ctx = JSON.parse(css_select("[data-controller='addon']").first["data-addon-ctx-value"])
      assert_equal({ "nodeId" => "d-jigs", "label" => "/jigs" }, ctx["defaultFolder"])
    end

    test "the New menu's tool links carry the folder they were opened from" do
      get tools_new_menu_path(in: "d-jigs")
      assert_select "turbo-frame#new-menu-tools a.menu-item[href=?]", tools_addon_path("destkit", in: "d-jigs")
      get "#{tools_new_menu_path}?in[]=x"
      assert_select "turbo-frame#new-menu-tools a.menu-item[href=?]", tools_addon_path("destkit")
    end
  end
end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/controllers/tools/addon_destination_test.rb`

Expected: the root-default test passes. The `?in=`, recency, project, `?state=` and New-menu tests fail
(the default is the root, or a `NameError` on `current_project_folder_node_id` once Task 2 has landed).

- [ ] **Step 3: Implement the four steps in `Tools::AddonsController`**

In `#show`, replace `@default_parent_node_id = current_project_folder_node_id` with:

```ruby
      @default_parent_node_id = tool_destination_node_id
```

Add these private methods directly after `def addon_states`:

```ruby
    # WHERE A SAVE STARTS (structural redesign spec §7, as slice 4's plan amended it). The bundle shows
    # this folder in its OWN "Save into" field and the user changes it there; this decides only where
    # that field begins. Four steps, first answer wins:
    #
    #   1. `?in=` naming a live folder of this user's (New ▸ <tool> from a folder sets it).
    #   2. `?state=` naming one of this tool's saved states: the folder ITS output lives in now. Every
    #      reopen link ("Edit in Boxes") already carries `state=`, so a revision starts where its file
    #      is and #resolve_placements' owned arm replaces it in place there.
    #   3. The folder of this tool's most recent live output, MAPPED UP to its owning project's folder
    #      when it sits inside one. The eager intake nudge files `Projects/<slug>/x.svg` into
    #      `design/`; a same-name save into `design/` is #refuse_taken_names!'s terminal 422, where the
    #      project root reaches #resolve_placements' 409 "save as revision 2" offer —
    #      test/system/box_revisions_test.rb's join test reaches that offer through this step.
    #   4. nil, the library root.
    #
    # NEVER SESSION OR USER STATE: this replaced the global current project, whose names
    # test/architecture_invariants_test.rb now forbids.
    def tool_destination_node_id
      return @tool_destination_node_id if defined?(@tool_destination_node_id)

      @tool_destination_node_id = destination_from_param || destination_from_outputs
    end

    # Step 1. A String only, for #find_addon_state's reason: `?in[]=a&in[]=b` arrives as an Array, and
    # `find_by(node_id: [...])` is an IN lookup answering whichever row the planner meets first.
    def destination_from_param
      id = params[:in]
      return nil unless id.is_a?(String) && id.present?

      current_user.nodes.present.find_by(node_id: id, kind: "dir")&.node_id
    end

    # Steps 2–4. `empty?`, NEVER `any?`: `[nil]` is the answer "its output is at the library root",
    # and `[nil].any?` is false — the spelling that turns the root into a fall-through to some older
    # output's folder.
    def destination_from_outputs
      if (state = find_addon_state(params[:state]))
        rows = latest_output_folder(addon_states.where(id: state.id))
        return rows.first unless rows.empty?
      end

      rows = latest_output_folder(addon_states)
      return nil if rows.empty? || rows.first.nil?

      owning_project_folder(rows.first) || rows.first
    end

    # `[]` when no live output exists, `[nil]` when the newest one sits at the library root, `[id]`
    # otherwise. `pluck` + `limit(1)` rather than `pick`, because `pick` answers nil for BOTH "no row"
    # and "a row whose folder is the root", and the caller must tell them apart.
    #
    # ONE STATEMENT. `[user_id, addon_key]` drives the states, `[addon_state_id, node_id]` the files,
    # `[user_id, node_id]` both node lookups. The folder is a LEFT join so an output at the root is
    # still a row, and a dead folder disqualifies its output rather than answering a tombstone's id.
    # `maker_addon_states.updated_at` orders it because every save touches the state (create, or
    # `revision + 1`), where `maker_addon_files.updated_at` survives an unchanged upsert.
    def latest_output_folder(states)
      states
        .joins("INNER JOIN maker_addon_files ON maker_addon_files.addon_state_id = maker_addon_states.id")
        .joins("INNER JOIN nodes outputs ON outputs.user_id = maker_addon_states.user_id " \
               "AND outputs.node_id = maker_addon_files.node_id")
        .joins("LEFT JOIN nodes folders ON folders.user_id = outputs.user_id " \
               "AND folders.node_id = outputs.parent_node_id")
        .where("outputs.deleted = ? AND outputs.kind = ?", false, "file")
        .where("outputs.parent_node_id IS NULL OR (folders.deleted = ? AND folders.kind = ?)", false, "dir")
        .order(Arel.sql("maker_addon_states.updated_at DESC, maker_addon_states.id DESC, " \
                        "maker_addon_files.position ASC, maker_addon_files.id ASC"))
        .limit(1)
        .pluck(Arel.sql("outputs.parent_node_id"))
    end

    # The nearest folder at-or-above `folder_id` that a project claims, or nil. The walk is the
    # request's own Maker::LibraryTree (#show already builds it for the picker), so it costs one
    # pluck of the claimed folder ids and no query per level.
    def owning_project_folder(folder_id)
      chain = library_tree.ancestors_of(folder_id)
      return nil if chain.nil?

      claimed = current_user.maker_projects.where.not(folder_node_id: nil).pluck(:folder_node_id).to_set
      chain.compact.find { |id| claimed.include?(id) }
    end
```

`find_addon_state` (L633) is safe to hand `params[:state]` raw. It returns nil unless the argument is
a String or an Integer, so a missing or array `?state=` costs nothing and falls through.

- [ ] **Step 4: Delete the attach-to-current-project call**

In `#create`, delete the line `attach_addon_files_to_current_project(addon_files)` (L538).

Reword the three comments that name it:
- L171–172: say that `#intake_project_folder` rescues `StandardError`, and drop the attach clause.
- L541–547: the save dialog now defaults by the four steps in `#tool_destination_node_id`, not to the
  current project's folder.
- L553–554: drop "AFTER attach_addon_files_to_current_project". The ordering rule is now
  `record_source_links` before `intake_project_folder`.

`test/controllers/tools/addons_controller_test.rb` L636–639 and L1053–1061 are comments that say the
dialog defaults to the current project. Reword them to "the dialog defaults by
`#tool_destination_node_id`". No assertion changes there.

- [ ] **Step 5: The New menu carries `in=`**

`app/controllers/tools/home_controller.rb`, in `#new_menu` before `render`:

```ruby
      # The folder the menu was opened from (layouts/_topbar.html.erb's frame src), echoed into each
      # tool link as `?in=`. A String only; the tool page validates it (Tools::AddonsController#
      # destination_from_param), so a bad value costs a link to the tool's own default.
      @in = params[:in].presence if params[:in].is_a?(String)
```

`app/views/tools/home/new_menu.html.erb`, the link:

```erb
      <%= link_to "#{addon.title}…", tools_addon_path(addon.key, in: @in), class: "menu-item" %>
```

(`in: nil` is dropped from the URL, so with no folder the href is unchanged.)

- [ ] **Step 6: Rewrite the two system tests that seeded through the current-project select**

`test/system/addon_bundle_test.rb`, in "the chooser resumes from the folder it was seeded with, in both
halves":
- Delete the `visit tools_path` / `select "Lamp", from: "project_id"` /
  `assert_selector ".current-project select"` block, and replace its comment with: "`?in=` IS WHAT MAKES
  THE DEFAULT FOLDER NON-ROOT (Tools::AddonsController#tool_destination_node_id, step 1)."
- Change the visit to `visit "/tools/fixture?in=#{folder.node_id}&fname=seeded.svg"`.
- Keep `project.ensure_library_folder!(user)` as it is: this file already uses a real share library
  for the save it asserts.

`test/system/box_revisions_test.rb`:
- Replace `use_current_project` with:

  ```ruby
    # A project whose library folder a save starts in — which is what puts the save on the one path
    # that reaches a 409 rather than the terminal 422 (see the join test). Returns the folder's
    # node_id for `?in=`.
    def project_folder(name = "Lamp")
      @user.maker_projects.create!(name:).ensure_library_folder!(@user).node_id
    end
  ```

- `create_box(name, x: nil)` gains `folder: nil` and visits `tools_addon_path("boxes", in: folder)`.
  Never name the keyword `in`, which is a reserved word and cannot be read back as a local.
- **The join test**:
  - It begins `lamp = project_folder` and calls `create_box("Shelf box", x: "111", folder: lamp)`.
  - Keep the SECOND `visit tools_addon_path("boxes")` exactly as it is, with **no** `in:`, and add
    this comment above it: "NO `in=`: the blank generator starts where this tool last saved, mapped
    up to the project folder (step 3), and that is the only reason this save reaches the 409."
  - Without step 3's project mapping this test gets the 422 and fails. That is its mutation check
    (Step 8).
- **"save, tweak, save again in one mount"**: begins `lamp = project_folder` and visits
  `tools_addon_path("boxes", in: lamp)`.
- Update the L159 comment: "the mainline for anyone saving into a project folder, which a tool starts
  in when its last output was filed there".

- [ ] **Step 7: A query budget for the tool page**

In `test/integration/web/page_query_budget_test.rb` (it already requires `fake_addon_source` and
resets the stub in teardown), add:

```ruby
    # STEP 3 OF Tools::AddonsController#tool_destination_node_id IS ONE STATEMENT, and the project
    # mapping walks the request's own LibraryTree — so the page's cost must not grow with how many
    # boxes this user has saved, nor with how deep their folders sit.
    test "tools#show's default folder does not grow with saved states" do
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ { "key" => "fixture", "title" => "Fixture", "icon" => "🧪",
                       "description" => "A fixture addon", "api_version" => "1", "entry" => "f.js" } ],
        assets: { "fixture/f.js" => "export default { mount() {} }" }
      )
      project = @user.maker_projects.create!(name: "Budget Lamp")
      folder = project_folder_rows!(@user, project)
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          dir = @user.nodes.create!(node_id: "#{id}-dir", name: "d-#{id}", kind: "dir",
                                    parent_node_id: folder.node_id, mtime: 1, size: 0)
          @user.nodes.create!(node_id: id, name: "#{id}.svg", kind: "file", parent_node_id: dir.node_id,
                              mtime: 1, size: 1, content_hash: "h-#{id}", current_version_id: "v-#{id}")
          state = @user.maker_addon_states.create!(addon_key: "fixture", name: "box #{id}", data: {})
          state.files.create!(node_id: id, role: "output")
        end
      end
      assert_constant_queries(tools_addon_path("fixture"), -> { add.call("s", 2) }, -> { add.call("l", 8) },
                              "tools#show")
    end
```

- [ ] **Step 8: Run, then mutation-check**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/controllers/tools/ test/integration/web/page_query_budget_test.rb`
then `bin/rails test test/system/addon_bundle_test.rb test/system/box_revisions_test.rb`.
Expected: green.

Each mutation must turn red, and each must be restored afterwards. After each restore, run
`rm -rf tmp/cache/bootsnap*`.

| mutation | must redden |
|---|---|
| `rows.empty?` → `rows.any?` in step 2's `return` (with `unless` → `if`) and step 3's `rows.empty? \|\|` → `!rows.any? \|\|` | "a newest output at the library root keeps the tool at the root" |
| `LEFT JOIN nodes folders` → `INNER JOIN nodes folders` | the same root test |
| `owning_project_folder(rows.first) \|\|` deleted | "…starts at the project folder", and box_revisions' join test (it now gets the 422) |
| `is_a?(String) &&` deleted from `#destination_from_param` | the `?in[]=` arm |
| `.where(id: state.id)` deleted (step 2 queries all states) | "?state= starts where that state's own output lives" |
| `"outputs.deleted = ? AND"` dropped | "a trashed output … is skipped" |

- [ ] **Step 9: Commit**

```bash
git add app/controllers/tools/ app/views/tools/home/new_menu.html.erb test/controllers/tools/ \
        test/system/addon_bundle_test.rb test/system/box_revisions_test.rb \
        test/integration/web/page_query_budget_test.rb
git commit -F <message file>
```

Subject: "A tool starts its save where you came from, or where it last saved — not in the current
project". Commit with `-F`, because backticks in zsh `-m` run as commands.

---

### Task 2: Retire the current project

**Files:** every row marked Task 2 in the Files table. The line numbers below are against `main` @
`9d7f3584`. Re-find each by its quoted text before editing.

- [ ] **Step 1: Write the guard first, and watch it fail**

Add to `test/architecture_invariants_test.rb`, near the other Ripper-based guards (`sync_references`,
~L119):

```ruby
  # THE CURRENT PROJECT IS RETIRED (structural redesign spec §9.1, slice 4) AND NOTHING MAY READ A
  # DESTINATION FROM SESSION OR USER STATE AGAIN (spec §10). New files land in the folder the maker
  # is looking at — FolderDestination, set by the action that renders that folder — and a destination
  # read from a session key or a user column is the design this replaced: it needed three rounds of
  # fixes because the place a file landed was not the place the maker was looking.
  #
  # Ripper over app/ + lib/ + config/routes.rb, and over every ERB template COMPILED to Ruby first
  # (Erubi drops `<%# %>` comments, so prose about the old design never trips it). Tokens, not text:
  # `:on_ident` catches a method, a local and a `session[:current_project_id]` key; `:on_const` the
  # concern and controller. The columns themselves are also `ignored_columns` on User, so a read
  # raises; this catches the NAMES, which is what a revival starts with.
  RETIRED_DESTINATION_NAMES = %w[
    current_project current_project_id current_project_folder_node_id current_project_choices
    current_project_notice remember_current_project remember_current_project? make_current
    attach_addon_files_to_current_project CurrentProject CurrentProjectController
  ].freeze

  test "nothing reads a destination from session or user state: the current project's names are gone" do
    rb = Dir[ROOT.join("app/**/*.rb"), ROOT.join("lib/**/*.rb"), ROOT.join("config/routes.rb")]
    erb = Dir[ROOT.join("app/views/**/*.erb")]
    refute_empty rb, "the Ruby scan found no files — the guard would pass over nothing"
    refute_empty erb, "the template scan found no files — the guard would pass over nothing"

    hits = (rb.map { |f| [ f, File.read(f) ] } +
            erb.map { |f| [ f, ActionView::Template::Handlers::ERB::Erubi.new(File.read(f)).src ] })
      .flat_map do |file, source|
        rel = Pathname.new(file).relative_path_from(ROOT)
        Ripper.lex(source).filter_map do |(pos, type, str, _)|
          "#{rel}:#{pos.first} #{str}" if %i[on_ident on_const].include?(type) && RETIRED_DESTINATION_NAMES.include?(str)
        end
      end
    assert_empty hits, "the retired current project is referenced again"
  end
```

**ERB line numbers in the failure are lines of the compiled source, not of the template.** The
failure names the file, and that is enough to find the reference. If `ROOT` is named differently in
this file, use its constant.

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/architecture_invariants_test.rb -n "/current project's names/"`

Expected: FAIL, listing every reference in the files below.

- [ ] **Step 2: Delete the machinery**

Delete these four files outright:
- `app/controllers/concerns/current_project.rb`
- `app/controllers/current_project_controller.rb`
- `app/controllers/settings/preferences_controller.rb`
- `app/views/home/_project_hero.html.erb`

Then delete these lines and blocks:
- `config/routes.rb`: the comment plus `resource :current_project, only: %i[update destroy],
  controller: "current_project"` (~L274–278), and `resource :preferences, only: :update` inside
  `namespace :settings` (~L408).
- `app/controllers/application_controller.rb`: `include CurrentProject` (L40).
- `app/controllers/home_controller.rb`:
  - the whole `@project = current_project` / `if @project … end` block (L26–47);
  - `HERO_TASKS`;
  - the header comment's "the current project, then" and the sentence about its tasks;
  - the `include LibraryCapabilities` comment that says it is for the hero. Keep the include until
    Task 3 moves it.
- `app/views/home/index.html.erb`: `<%= render "project_hero" %>`.
- `app/controllers/projects_controller.rb`:
  - the line `make_current(@project) if params[:project][:make_current] == "1"` (~L468);
  - in `#created_notice`, everything after the lead sentence (L598–605), so the method returns
    `lead`;
  - `def make_current` (L608–610).
  - **Also remove `:make_current` from the strong-params permit list if it is there.**
- `app/views/projects/_form.html.erb`: the make-current checkbox block (L141–163).
- `app/views/projects/show.html.erb`: the current-project badge, Clear and "Set as current" (L48–58).
- `app/views/settings/show.html.erb`: the whole "Current project" `<li>` (L36–60).
- `app/views/layouts/_rail.html.erb`: the current-project card (L12–25). Reword the header comment
  (L1–6) so it no longer names the card or the tests that pinned it.
- `app/views/layouts/_topbar.html.erb`: the phone chip and its comment (L14–28).
- `app/views/files/index.html.erb`:
  - L27–37: reword the comment to "THE PAGE HEAD HOLDS THE ONE PRIMARY ACTION (spec §8): Upload, in
    whichever of its two flows this deployment has." Delete the `project_upload` line.
  - L48: `menu_items` loses `current_project.present? ||`.
  - L53–58: the `if project_upload` branch goes. The `elsif capabilities.port_writable?` becomes
    `if`, and its comment and the chunk branch stay. **Task 3 moves this block to the top bar. Task 2
    only removes the current-project arm.**
  - L160–168: the `upload-alt` menu switch.
  - L190–192: the "Uploads go to …" caption.
- `app/controllers/files_controller.rb`: the `@current_project_folder_node_id` assignment and its
  comment (L333–339).
- `app/controllers/inventory_items_controller.rb` L57: `@projects = current_user.maker_projects.where.not(status: "archived").order(:name).pluck(:name, :id)`,
  inlined from the deleted helper. The ledger's project `<select>` still needs it.
- `app/controllers/tools/addons_controller.rb`: nothing left after Task 1. Verify with the guard.
- CSS:
  - `shell.css`: delete L33–42 (`.current-project*`) and L130, L181–183 (`.topbar-project*`). Drop
    the `.current-project` selector from L85 and L161, keeping those rules. Reword the L1 comment.
  - `components.css`: delete L372 `.badge.current-project-badge`.
  - `pages/home.css`: delete the `.home-hero*` rules (L5–12).
- `app/models/user.rb`:

  ```ruby
    # RETIRED WITH THE CURRENT PROJECT (structural redesign spec §9.1, slice 4) and dropped by slice 7's
    # migration. Ignored rather than dropped now so a deploy's old and new code never disagree about a
    # column mid-rollout; ignored rather than left readable so no code reaches for either by accident
    # (test/architecture_invariants_test.rb forbids the names as well).
    self.ignored_columns += %w[current_project_id remember_current_project]
  ```

  Also drop `current_project` from the L175 handle-segment comment's examples.

- [ ] **Step 3: Reword the comments that cite it**

Each of these is prose only:

| file | change |
|---|---|
| `concerns/move_conflicts.rb` L8–10 | repoint the precedent to "ProjectsController#show's folder ensure: a view must not create a project folder" |
| `concerns/move_conflicts.rb` L57–58 | delete the `CurrentProject` writer from the list |
| `csp_reports_controller.rb` L12–13 | drop "CurrentProject" |
| `public/base_controller.rb` L3 | drop "CurrentProject" |
| `public/base_controller.rb` L17–19 | keep "an honest preview of what a visitor sees" as the reason |
| `layouts/application.html.erb` L29–32 | as `public/base_controller.rb` L17–19 |
| `projects/attachments_controller.rb` L44–50 | "one attach path never reaches this action: the model importer". The addon one is gone. |
| `projects/uploads_controller.rb` L80 | drop the Files-page current-project uploader. Build-log entries are this controller's callers now. |
| `maker/attach_to_project.rb` L121–126 | remove the entry, so "six others" becomes "five others" |
| `maker/attach_to_project.rb` L171–177 | past tense: "was reachable while a current project attached tool output regardless of folder (retired in slice 4)" |
| `shell_helper.rb` L15 | `%w[projects current_project]` → `%w[projects]` |
| `shell_helper.rb` L64 | drop "current-project switcher" |
| `files/_attach.html.erb` L29–36 | the explicit id stays; the clash it avoided is history |
| `projects/_upload_control.html.erb` L6–11, L17–22 | its callers are now the project panel (until Task 3) and the build-log entries |
| `tools/base_controller.rb` L4–6 | drop the current project |
| `docs/invariants/project-intake.md` L342–345 | past tense, as `attach_to_project.rb` L171–177 |
| `docs/invariants/project-intake.md` L413–416 | "the save dialog starts where the tool last saved, mapped up to its project folder" |

- [ ] **Step 4: Tests: delete, rewrite or trim**

The explorer's classification, applied:

| test file | action |
|---|---|
| `test/controllers/current_project_controller_test.rb` | delete the file |
| `test/integration/web/current_project_persistence_test.rb` | delete the file |
| `test/integration/web/current_project_set_from_project_test.rb` | delete the file |
| `test/integration/web/current_project_topbar_test.rb` | delete the file |
| `test/integration/web/current_project_files_upload_test.rb` | Delete the tests at L25, L32, L37 and L48. Move L58 (drop its `patch current_project_path` line) and L73 into `test/integration/web/project_upload_attach_test.rb`; they test `Projects::UploadsController`'s `redirect_url`. Then delete the file. |
| `test/integration/web/files_toolbar_test.rb` | delete L83 "a current project turns the head's upload…"; Task 3 writes its replacement; reword the comments at L175 and L187 |
| `test/integration/web/files_type_filter_test.rb` | delete L577 "the upload-alternative links keep the filter…" |
| `test/integration/web/home_test.rb` | delete L30, L64, L155; in L19 drop the L23 `.home-hero` assertion; in L112 drop the `patch` and the `/No current project/` assertion, keep "not in recent"; reword the L4 comment |
| `test/integration/web/page_query_budget_test.rb` | in "home#index does not grow…" drop the `patch current_project_path` and the hero seeding; keep the constancy assertion; reword the L528 comment |
| `test/integration/web/project_page_test.rb` | L52: drop the L54 "Set as current" assertion, rename to "the head's actions are buttons, with Archive quiet" |
| `test/integration/web/projects_flow_test.rb` | delete L396, L419, L435, L490; L406 keeps only "Its folder is Projects/smart-lamp" (drop `make_current: "1"` and the current-project asserts) and is renamed "creating a project names its folder" |
| `test/integration/web/settings_hub_test.rb` | L40: count 8 → 7, drop "Current project" from the names, drop the `remember_current_project` assertions |
| `test/integration/web/shell_layout_test.rb` | delete L87 and L150; reword the L4 comment |
| `test/integration/web/attach_from_files_test.rb` | L65: rename to "the attach label points at the attach select"; reword L60–64 |
| `test/system/home_test.rb` | delete L25 and L51 (Task 3's system test replaces the upload); reword L3–7 |
| `test/system/shell_test.rb` | L371–379: drop the rail select and the `.home-hero h2` wait, assert `main h1` instead; L571–572: drop both assertions (L570's `nav.tabbar` stays) |
| `test/system/accent_spend_test.rb` | delete the tail from `@user.update!(current_project_id: …)` to the end of the test; reword the L37 header sentence (Task 3 rewrites the table) |
| `test/test_helper.rb` | delete `current_project_id_for` (L351–360); reword the L255/L265 comments |
| `test/services/maker/attach_to_project_test.rb` L344, `test/services/maker/project_intake_test.rb` L255/L698 | reword the comments |

- [ ] **Step 5: Run everything that moved**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test` (the share leg), then
`bin/rails test test/system/home_test.rb test/system/shell_test.rb test/system/accent_spend_test.rb`.

Expected: green, the guard included. `grep -rn "current_project\|CurrentProject\|remember_current" app lib config`
prints only `db/schema.rb` and old `db/migrate/` files. Migrations are never rewritten (CLAUDE.md §10).

- [ ] **Step 6: Mutation-check the guard**

Run each of these, check it is red, and restore it. Clear bootsnap after each restore.
1. Add `current_user.current_project_id` to any controller action. The guard must go red, and the
   suite must also raise `NoMethodError` from `ignored_columns`.
2. Add `<%= current_project %>` to `app/views/settings/show.html.erb`. Red.
3. Add `<%# current_project %>` (a comment) to the same file. **Green.** This proves the guard does
   not fire on prose.
4. Make the template glob `app/views/**/*.nope`. Red on `refute_empty`.

- [ ] **Step 7: Commit**

Subject: "The current project is retired: nothing decides where a file lands from session or user
state". Body:
- what went;
- that intake now attaches tool output by folder;
- the columns are ignored until slice 7;
- the guard and its four mutations.

---

### Task 3: Upload in the top bar, into the folder you're in

**Files:** every row marked Task 3 in the Files table.

- [ ] **Step 1: Write the failing request tests**

Create `test/integration/web/topbar_upload_test.rb`:

```ruby
require "test_helper"

module Web
  # THE TOP BAR'S UPLOAD (structural redesign spec §4.2 and §8, slice 4): it uploads into the folder the
  # page shows and says which, and on a page that shows no folder it asks with the folder chooser
  # instead of guessing. Both flows carry the destination, so every assertion branches on the flow
  # this leg renders (`port_writable?`): asserting the form alone is red on chunk_remote.
  class TopbarUploadTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "up-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "d-cad", name: "cad", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-jigs", name: "jigs", kind: "dir", parent_node_id: "d-cad", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "n-plate", name: "plate.dxf", kind: "file", parent_node_id: "d-jigs",
                          mtime: 1_000_000_000, size: 10, content_hash: "h-plate", current_version_id: "v-plate")
    end

    def assert_destination(node_id)
      if FileLayer.current.capabilities.port_writable?
        assert_select "header.topbar .topbar-upload form.uploader[action=?] input[type=hidden][name='parent_node_id'][value=?]",
                      files_path, node_id
      else
        assert_select "header.topbar .topbar-upload section.uploader[data-controller='uploader'][data-uploader-parent-node-id-value=?]",
                      node_id
      end
    end

    def assert_caption(text)
      assert_select "header.topbar .topbar-upload-caption", text: "Saves to #{text}"
    end

    test "on a folder, Upload carries that folder, is the page's primary, and names it" do
      get files_path(folder: "d-jigs")
      assert_response :success
      assert_destination "d-jigs"
      assert_select "header.topbar .topbar-upload label.upload-btn.primary span", text: "Upload"
      assert_caption "cad/jigs"
      # The page head's own uploader moved here; one Upload, not two.
      assert_select "main .uploader", count: 0
    end

    test "at the top of the Library it saves to the library root" do
      get files_path
      assert_destination ""
      assert_caption "the library root"
    end

    # The validated folder, never the raw param: a stale ?folder= renders the root's listing, so it
    # must not leave the stale id in the form.
    test "a stale ?folder= uploads to the root it shows, and New creates there too" do
      get files_path(folder: "gone")
      assert_destination ""
      assert_select "header.topbar form[action=?] input[name='parent_node_id'][value=?]", library_folders_path, ""
    end

    test "the workspace saves beside its file, quietly" do
      get file_path("n-plate")
      assert_destination "d-jigs"
      assert_select "header.topbar .topbar-upload label.upload-btn:not(.primary)"
      assert_caption "cad/jigs"
    end

    test "the project hub saves to the project's folder and its Files panel has no second uploader" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project_folder_rows!(@user, project)
      get project_path(project)
      assert_destination folder.node_id
      assert_select "header.topbar .topbar-upload label.upload-btn.primary"
      assert_caption "Projects/desk-lamp"
      assert_select ".attachments-panel .uploader", count: 0
    end

    test "a page with no folder asks with the chooser, quietly, and names nothing yet" do
      get settings_path
      assert_select "header.topbar .topbar-upload[data-controller='upload-pick'][data-upload-pick-children-url-value=?][data-upload-pick-create-url-value=?]",
                    library_children_path, library_folders_path
      assert_destination ""
      assert_select "header.topbar .topbar-upload label.upload-btn:not(.primary)[data-action=?]", "click->upload-pick#pick"
      assert_select "header.topbar .topbar-upload-caption[hidden]"
    end

    test "New creates where Upload saves, and its tools open there" do
      get file_path("n-plate")
      assert_select "header.topbar form[action=?] input[name='parent_node_id'][value=?]", library_folders_path, "d-jigs"
      assert_select "header.topbar a.menu-item[href=?]", new_files_text_file_path(parent_node_id: "d-jigs")
      assert_select "header.topbar turbo-frame#new-menu-tools[src=?]", tools_new_menu_path(in: "d-jigs")
    end
  end
end
```

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/topbar_upload_test.rb`

Expected: every test fails (there is no `.topbar-upload`).

- [ ] **Step 2: The `FolderDestination` concern**

Create `app/controllers/concerns/folder_destination.rb`:

```ruby
# WHERE THE TOP BAR'S UPLOAD AND NEW ▾ MENU PUT WHAT THEY MAKE (structural redesign spec §8, slice 4):
# the folder the maker is looking at, set by the action that renders that folder and by nothing else.
#
# It replaced the global current project, and how it replaced it is the point: NOTHING HERE READS
# SESSION OR USER STATE. A page that shows a folder names it (FilesController#index and #show,
# ProjectsController#show, Tools::AddonsController#show); a page that shows none leaves this nil, and
# Upload asks with the folder chooser (upload_pick_controller.js). test/architecture_invariants_test.rb
# forbids the retired names.
module FolderDestination
  extend ActiveSupport::Concern

  # `path` is root-relative with no leading slash ("Projects/shop-stool") and "" at the library root —
  # Maker::LibraryTree#path_for's spelling. `primary` is whether Upload is this screen's accent action
  # (docs/invariants/design-system.md rule 13): the Library and the project hub, nowhere else.
  Destination = Data.define(:node_id, :path, :primary) do
    def caption = path.presence || "the library root"
  end

  included do
    helper_method :folder_destination
  end

  private

  def folder_destination = @folder_destination

  def use_folder_destination(node_id, path:, primary: false)
    @folder_destination = Destination.new(node_id:, path: path.to_s, primary:)
  end
end
```

In `app/controllers/application_controller.rb`, where `include CurrentProject` was, add:

```ruby
  # The top bar renders on every signed-in page and needs both: which upload flow this deployment
  # drives (`capabilities.port_writable?`) and which folder it uploads into.
  include LibraryCapabilities
  include FolderDestination
```

This is the first time Settings, Search, Inventory and Trash read `FileLayer.current`. That adds no
new failure mode in production. The adapter is memoized per process, and `LibraryBackendCheck`
already refuses to boot a deployment whose backend cannot be constructed (CLAUDE.md §14a's boot-guard
bullet). Tests already need `LIBRARY_PATH` for the same reason.

Remove the now-redundant `include LibraryCapabilities` lines from `FilesController`,
`ProjectsController`, `HomeController` and `ModelsController`, along with their "the helper comes from
here" comments. Their `require_capability!` class calls keep working, because the method is inherited.

- [ ] **Step 3: Set the destination where a folder is rendered**

`app/controllers/files_controller.rb`:
- In `#index`, after the flat/tree `if … else … end` that sets `@folder` and `@crumbs`:

  ```ruby
      # The top bar's Upload and New create here (FolderDestination). The VALIDATED folder: a stale
      # ?folder= renders the root's listing and must upload to the root it shows. Flat mode has no
      # folder, so it is the root too.
      use_folder_destination(@folder&.node_id, path: Array(@crumbs).map(&:name).join("/"), primary: true)
  ```

- In `#show`, after `@crumbs = folder_crumbs(parent)`:

  ```ruby
      use_folder_destination(parent&.node_id, path: @crumbs.map(&:name).join("/"))
  ```

`app/controllers/projects_controller.rb` `#show`:
- After `@listing = Maker::ProjectFolderListing.new(current_user, @project)`:

  ```ruby
      # Upload targets the project's folder (spec §6). A folder in the trash or unreachable this render
      # gives no destination, and the top bar asks with the chooser rather than guess the root.
      use_folder_destination(@listing.folder_id, path: @listing.path, primary: true) if @listing.available?
  ```

- The `@upload_parent_node_id = begin … end` block keeps its `ensure_library_folder!` call and its
  ordering comment, because the listing reads what it writes. Drop the assignment, since nothing reads
  the ivar once the panel's uploader is gone:

  ```ruby
      begin
        @project.ensure_library_folder!(current_user)
      rescue StandardError
        nil
      end
  ```

`app/controllers/tools/addons_controller.rb` `#show`, after `@default_folder_label`:

```ruby
      # The top bar's Upload starts where this tool's save starts, so the two agree on the page.
      use_folder_destination(@default_parent_node_id, path: library_tree.path_for(@default_parent_node_id).to_s)
```

(`path_for` returns `""` for the root and `nil` for a broken chain; `.to_s` folds the second into the
root caption.)

`app/helpers/new_menu_helper.rb`: replace the method body and update the header comment to say slice 4
generalised it:

```ruby
  def new_menu_folder_node_id = folder_destination&.node_id
```

- [ ] **Step 4: The top-bar partial**

Create `app/views/layouts/_topbar_upload.html.erb`:

```erb
<%# THE TOP BAR'S UPLOAD (structural redesign spec §4.2 and §8, slice 4). It uploads into the folder
    the page shows (FolderDestination, set by that page's action) and says which. The two flows are
    the Files page's own, unchanged: `port_writable?` picks WHICH DOOR the bytes go in (CLAUDE.md
    §14a — it is not "can this deployment upload"), and both carry the destination as the
    `parent_node_id` the doors already accept.

    A PAGE WITH NO FOLDER (Home, Tools, Settings, Search) asks with the library's folder chooser
    before the file picker opens (upload_pick_controller.js), and never guesses one.

    `primary` only where Upload IS the screen's one action (design-system.md rule 13): the Library and
    the project hub. The caption hides below 1100px, so the button's title carries it there. %>
<% dest = folder_destination %>
<% parent_value = dest ? dest.node_id.to_s : "" %>
<% btn_class = dest&.primary ? "upload-btn primary" : "upload-btn" %>
<% pick = dest.nil? %>
<%= tag.div class: "topbar-upload",
            data: (pick ? { controller: "upload-pick",
                            upload_pick_children_url_value: library_children_path,
                            upload_pick_create_url_value: library_folders_path } : {}) do %>
  <% if capabilities.port_writable? %>
    <%= form_with url: files_path, method: :post, class: "uploader",
                  data: { turbo: false }, html: { multipart: true } do |f| %>
      <%= hidden_field_tag :parent_node_id, parent_value, id: nil,
                           data: (pick ? { upload_pick_target: "parent" } : {}) %>
      <%= tag.label class: btn_class, title: (dest ? "Saves to #{dest.caption}" : "Choose a folder, then files"),
                    data: (pick ? { action: "click->upload-pick#pick" } : {}) do %>
        <%# `include_hidden: false` IS LOAD-BEARING — files/index.html.erb's old uploader records why:
            the companion empty `file[]` input put a bare "" at the head of params[:file]. %>
        <%= f.file_field :file, multiple: true, include_hidden: false, id: "topbar_upload_file",
                         onchange: "this.form.requestSubmit()", hidden: true,
                         data: (pick ? { upload_pick_target: "input" } : {}) %>
        <span>Upload</span>
      <% end %>
    <% end %>
  <% else %>
    <%# Chunk: the browser hashes, we presign the missing chunks, the browser PUTs them (§15). %>
    <section class="uploader"
             data-controller="uploader"
             data-uploader-begin-url-value="<%= begin_upload_files_path %>"
             data-uploader-finalize-url-value="<%= finalize_upload_files_path %>"
             data-uploader-parent-node-id-value="<%= parent_value %>"
             <%= "data-upload-pick-target=uploader" if pick %>>
      <%= tag.label class: btn_class, title: (dest ? "Saves to #{dest.caption}" : "Choose a folder, then files"),
                    data: (pick ? { action: "click->upload-pick#pick" } : {}) do %>
        <input type="file" multiple id="topbar_upload_file" data-uploader-target="input"
               data-action="uploader#upload" hidden<%= ' data-upload-pick-target="input"'.html_safe if pick %>>
        <span>Upload</span>
      <% end %>
      <span class="upload-status" data-uploader-target="status"></span>
    </section>
  <% end %>
  <% if dest %>
    <span class="topbar-upload-caption">Saves to <strong><%= dest.caption %></strong></span>
  <% else %>
    <span class="topbar-upload-caption" data-upload-pick-target="caption" hidden></span>
  <% end %>
<% end %>
```

Write the chunk section's `data-upload-pick-target` the way the surrounding markup is written. Either
the `<%= … if pick %>` form above or a `tag.section` builder is fine. **Assert the rendered attribute in
Step 1's test**, not the template.

In `app/views/layouts/_topbar.html.erb`:
- Render it after the New ▾ `</details>`: `<%= render "layouts/topbar_upload" %>`.
- Change the tools frame's `src` to `tools_new_menu_path(in: new_menu_folder_node_id)`.
- Update the `NEW ▾` comment: "Upload sits beside it (layouts/_topbar_upload.html.erb), and both
  create in FolderDestination's folder."

`test/integration/web/new_menu_test.rb` L60–61 pins the plain src. Change it to
`tools_new_menu_path(in: nil)`, which is the same string on a page with no folder. Add one assertion on
a folder page that the src carries `in=`.

- [ ] **Step 5: The chooser step**

Create `app/javascript/controllers/upload_pick_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"
import { chooseFolder } from "lib/file_chooser"

// THE TOP BAR'S UPLOAD ON A PAGE THAT SHOWS NO FOLDER (structural redesign spec §4.2 and §8, slice 4).
// Home, Tools, Settings and Search have no "folder you're in", so the first click asks for one with the
// library's own chooser, writes it where the upload flow reads its destination, and only then opens
// the file picker. It never guesses: a cancelled chooser uploads nothing.
//
// TWO FLOWS, TWO PLACES TO WRITE (layouts/_topbar_upload.html.erb): the share/s3 form's hidden
// `parent_node_id` (the `parent` target) or the chunk uploader's `data-uploader-parent-node-id-value`
// (the `uploader` target), which uploader_controller.js reads at upload time.
//
// THE FILE PICKER OPENS FROM THE CHOOSER'S OWN CLICK. `input.click()` needs a user activation, and the
// chooser resolves inside its Choose button's click handler, so the activation is still live here.
export default class extends Controller {
  static targets = [ "input", "parent", "uploader", "caption" ]
  static values = { childrenUrl: String, createUrl: String }

  async pick(event) {
    // The programmatic click below bubbles back through this label; let it through, and let every
    // click after a folder is chosen open the picker directly.
    if (this.chosen || event.target === this.inputTarget) return
    event.preventDefault()

    const selection = await chooseFolder({ childrenUrl: this.childrenUrlValue, createUrl: this.createUrlValue })
    if (!selection) return

    const nodeId = selection.nodeId || ""
    if (this.hasParentTarget) this.parentTarget.value = nodeId
    if (this.hasUploaderTarget) this.uploaderTarget.setAttribute("data-uploader-parent-node-id-value", nodeId)
    if (this.hasCaptionTarget) {
      const strong = document.createElement("strong")
      strong.textContent = selection.path
      this.captionTarget.replaceChildren("Saves to ", strong)
      this.captionTarget.hidden = false
    }
    this.chosen = true
    this.inputTarget.click()
  }
}
```

`stimulus_hygiene_test.rb` derives `upload-pick` from the filename. Run it.

- [ ] **Step 6: Styles**

In `app/assets/stylesheets/shell.css`, inside the shell layer, after `.topbar-new`:

```css
  /* THE TOP BAR'S UPLOAD (layouts/_topbar_upload.html.erb): the button, then where it saves. The
     caption is the answer to "where will this go", so it is ink, not muted; below 1100px it hides and
     the button's title carries it. */
  .topbar-upload { display: flex; align-items: center; gap: var(--space-2); min-width: 0; }
  .topbar-upload .uploader { gap: var(--space-2); }
  .topbar-upload-caption { max-width: 240px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; color: var(--fg-muted); }
  .topbar-upload-caption strong { color: var(--fg); font-weight: 600; }
```

Add `.topbar-upload-caption { display: none; }` inside the existing `@media (max-width: 1099px)` block,
or open one in the shell layer if there isn't one.

**There is no global `[hidden]` rule in this app.** Every author `display` beats the UA's
`[hidden] { display: none }`, which is why `components.css` writes `.tab-pane[hidden]` and
`.flash[hidden]` by hand. So add the same guard here, beside the caption's rules:

```css
  /* An author `display` beats the UA's `[hidden]`; the no-folder caption is rendered hidden until the
     chooser fills it (upload_pick_controller.js). Same shape as components.css's `.tab-pane[hidden]`. */
  .topbar-upload-caption[hidden] { display: none; }
```

- [ ] **Step 7: Remove the page-level uploaders**

- `app/views/files/index.html.erb`: delete the whole `if capabilities.port_writable? … else … end`
  upload block from `.page-actions` (Task 2 left only the two plain arms). Reword the page-head comment
  to say Upload is in the top bar (layouts/_topbar_upload.html.erb). `.page-actions` keeps New text
  file and the overflow menu. **Keep the "New text file" link's `parent_node_id: @folder&.node_id`**:
  it is the same folder, and this slice does not touch it.
- `app/views/projects/_attachments.html.erb`: delete `<%= render "upload_control", primary: true, … %>`
  from `.panel-actions`. Reword the L60–62 comment's "the upload control below" to "the top bar's
  Upload".
- `app/views/projects/_upload_control.html.erb`: update the call-site count in its header. Its one
  caller is now `projects/_log_entry.html.erb`.

- [ ] **Step 8: Rewrite the upload pins**

| test | change |
|---|---|
| `files_toolbar_test.rb` L36 "upload is the primary action in the page head…" | Rewrite as "the Files page head no longer holds an uploader; Upload is the top bar's": `main .uploader` count 0. Keep the `rescan`/`New text file` assertions if any. `topbar_upload_test.rb` owns the rest. |
| `upload_batch_test.rb` L49, L65 | scope to `header.topbar form.uploader …` |
| `home_test.rb` (integration) L49–57, if it survived Task 2 | gone with the hero; nothing to do |
| `test/system/uploader_test.rb` | unchanged: `/files` still has exactly one `input[type=file]` (the top bar's) and uploads to the root. It skips unless `ChunkRemoteJourney.configured?` on chunk_remote, so the system gate skips it. Read it to confirm the unlocated `attach_file` still finds exactly one input. |
| `test/system/accent_spend_test.rb` | see below |
| `accent_spend_test.rb`'s helper `accent_controls` | It builds its selector as `'main ' + s` (~L141). Prefix each control selector with both `header.topbar ` and `main `, so the top-bar Upload is counted on every page in document order (the bar comes first). Keep the `assert_selector "main"` precondition. |

The new expectation table for `accent_spend_test.rb`:

```ruby
    expected = {
      "/" => [ "New project" ],                 # Home's Upload is quiet until slice 6 makes it Recent
      "/files" => [ "Upload" ],                 # the top bar's, now the Library's one action
      "/models" => [ "Import model" ],
      "/projects" => [ "New project" ],
      "/inventory" => [ "New item" ],
      # The two decision 3 names: the folder this project keeps its files in (now the top bar's
      # Upload, into that folder) and the switch that makes the whole thing public.
      "/projects/desk-lamp" => [ "Upload", "Save publishing" ],
      "/settings" => [], "/tools" => [], "/search" => [],
      "/inventory/suppliers" => [ "Add supplier" ],
      "/inventory/locations" => [ "Add location" ],
      "/models/shelves" => [ "Add shelf" ]
    }
```

Keep the existing comments that still hold. Update the mutation notes in the header:
- Mutation 3 is now "dropping `primary: true` from `ProjectsController#show`'s `use_folder_destination`".
- Mutation 1's per-log-entry runaway still reproduces through `projects/_log_entry`.

- [ ] **Step 9: System tests**

Create `test/system/topbar_upload_test.rb`:

```ruby
require "application_system_test_case"

# THE TOP BAR'S UPLOAD IN A BROWSER (structural redesign spec §4.2, §8; slice 4). A request test sees
# the destination in the markup; only a browser sees the file actually land there, and only a browser
# can drive the chooser step on a page with no folder. Share only (use_fresh_share_library!): the
# chunk flow's browser test is uploader_test.rb.
class TopbarUploadSystemTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("topbar-upload@example.com")
    @cad = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "cad")
    @sample = Rails.root.join("tmp", "topbar-upload-#{SecureRandom.hex(4)}.txt")
    File.write(@sample, "hello")
  end

  teardown do
    FileUtils.rm_f(@sample)
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "on a folder, Upload puts the file in that folder" do
    visit files_path(folder: @cad.node_id)
    assert_selector "header.topbar .topbar-upload-caption", text: "Saves to cad"
    attach_file("topbar_upload_file", @sample.to_s, make_visible: true)
    assert_text File.basename(@sample)
    assert_equal @cad.node_id, @user.nodes.present.find_by!(name: File.basename(@sample)).parent_node_id
    assert_no_console_errors
  end

  test "on Home, Upload asks for a folder first and then saves there" do
    visit root_path
    find("header.topbar .topbar-upload label.upload-btn").click
    assert_selector ".filechooser-overlay"
    find(".filechooser-row", text: "cad").click
    click_on "Choose"
    assert_selector "header.topbar .topbar-upload-caption", text: "Saves to /cad"
    assert_equal @cad.node_id, find("header.topbar input[name='parent_node_id']", visible: :all).value

    attach_file("topbar_upload_file", @sample.to_s, make_visible: true)
    assert_text File.basename(@sample)
    assert_equal @cad.node_id, @user.nodes.present.find_by!(name: File.basename(@sample)).parent_node_id
    assert_no_console_errors
  end

  test "cancelling the chooser uploads nothing and leaves the caption empty" do
    visit root_path
    find("header.topbar .topbar-upload label.upload-btn").click
    assert_selector ".filechooser-overlay"
    find(".filechooser-overlay").send_keys(:escape)
    assert_no_selector ".filechooser-overlay"
    assert_selector "header.topbar .topbar-upload-caption", visible: :hidden
    assert_equal "", find("header.topbar input[name='parent_node_id']", visible: :all).value
  end
end
```

Checked while planning:
- `FileLayer::Share#mkdir(user, parent_node_id:, name:)` returns the folder's `stat` info, which
  carries `node_id`.
- `lib/file_chooser.js` closes on Escape through `close()`, which settles `null`, the same answer as
  Cancel (L149–152).
- A one-file share upload redirects to the file page, which shows the name. That is what
  `assert_text` waits on.

Also check `test/system/shell_test.rb`'s 375px sweep. It visits Home, the Library, a workspace, a
project hub and a tool page, and it must stay green with New and Upload both in the bar.
`test/system/new_menu_test.rb`'s phone test measures the open New menu. Upload now sits to its right,
so if New's menu opens off the left edge, give `.topbar-new` the menu's right-anchoring fix there. Do
not move Upload before New.

- [ ] **Step 10: Run, mutation-check, commit**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/ test/stimulus_hygiene_test.rb test/css_hygiene_test.rb`, then
`bin/rails test test/system/topbar_upload_test.rb test/system/accent_spend_test.rb test/system/shell_test.rb test/system/new_menu_test.rb test/system/uploader_test.rb`.

Mutations, each red, each restored:

| mutation | must redden |
|---|---|
| `@folder&.node_id` → `params[:folder]` in `#index`'s `use_folder_destination` | "a stale ?folder= uploads to the root it shows…" |
| `new_menu_folder_node_id` back to the raw-`params[:folder]` body | the same test (its New assertion), and "New creates where Upload saves" on the workspace |
| `primary: true` dropped from `ProjectsController#show` | the hub test, and accent_spend's `/projects/desk-lamp` row |
| the `parent_node_id` hidden field removed from the partial | "on a folder, Upload puts the file in that folder" (system) |
| `this.inputTarget.click()` removed from `upload_pick_controller.js` | (none can redden: Capybara's `attach_file` sets the input directly) |
| `this.parentTarget.value = nodeId` removed | "on Home, Upload asks for a folder first" |
| the `.attachments-panel` uploader restored | the hub test's `count: 0` |

The `inputTarget.click()` row is the honest limit of a headless browser. State it in the commit body
and the PR's "not verified" list. A human clicking Upload on Home is the only check that the file
picker opens after Choose.

Subject: "Upload sits in the top bar and saves into the folder you're looking at".

---

### Task 4: Record the slice

**Files:**
- `docs/superpowers/specs/2026-10-08-structural-redesign-design.md`: append "**Amended 2026-10-09
  (slice 4's plan):**" after slice 3's amendment, summarising this plan's nine numbered amendments in
  prose. Also update the §9.1 cross-repo bullet to record its result, that nothing in
  `tinkerex-addons` reads it.
- `docs/invariants/design-system.md`:
  - Rule 12: remove `.current-project select` and `form[action=current_project_path]
    select[name=project_id]` from the pinned list.
  - Rule 13: "`--accent` fills the one primary action. On the Library and a project hub that is the
    top bar's Upload, which says where it saves." Remove the "Set as current" sentence, since nothing
    secondary is allowed the accent now.
  - Rule 8 (the shell): add "The top bar's Upload and New ▾ create in `FolderDestination`'s folder,
    set by the action that renders a folder. A page with none asks with the chooser."
- `docs/invariants/addons.md`:
  - **WHERE A SAVE STARTS:** `Tools::AddonsController#tool_destination_node_id`'s four steps, and why
    step 3 maps up to the project folder (the 422 vs 409).
  - **`?in=` is a hint like `?state=`:** a String only, validated as a live folder of the user's, and
    falling through on any miss.
  - **`defaultFolder`'s VALUE changed and its two shapes did not**, so no bundle needed to move. Place
    this beside the existing rule about the two shapes (~L355).
- `docs/invariants/project-intake.md`: "Intake is the only way tool output reaches a project" (spec
  §9.3), since `attach_addon_files_to_current_project` is gone.
- `docs/addon-api-v1.md`:
  - L638–640: "If the destination is a project's folder, the host files the output into a category
    subfolder and attaches it to that project."
  - L655–657: "The host seeds both from where this tool's save starts: the folder it was opened from,
    the reopened file's folder, or where it last saved."
- `CLAUDE.md` §11: remove "current-project" from the maker web layer's feature list.
- **The sibling repo `chaim354/tinkerex-addons`:**
  - `README.md` L121: no change; the key names stand.
  - `README.md` L163: `defaultFolder`'s description becomes "The folder id to preselect: the folder
    the tool was opened from, the reopened file's folder, or where this tool last saved."
  - Branch `claude/default-folder-docs` there, commit, push, and open a PR. It is docs-only, so its
    `bin/check-fixture-drift` is unaffected.

- [ ] Commit the docs in this repo with the subject "Slice 4's record: folder destinations replace the
  current project".

### Task 5: Close out

- [ ] Run bare `bin/ci`. All seven gates must pass, and the three backend legs must report identical
  run counts. Expect the counts to drop from slice 3's 4318, because tests were deleted. They must
  drop by the same number on all three legs.
- [ ] Open a manual-test checklist in the PR body for the one thing no test drives: on Home, click
  Upload → choose a folder → **the file picker opens**.
- [ ] `/finish-branch`: push, then `gh pr create`. The body covers:
  - what changed for a maker;
  - the nine amendments;
  - the cross-repo result and the sibling README PR's link;
  - the verification table;
  - not verified: the file picker after Choose, phone checks headless only, no deploy.
- [ ] `bin/log arc --from-pr <n>`, and report the PR. **Merging needs the user's go-ahead.** At merge,
  run `bin/log close <arc>`.
