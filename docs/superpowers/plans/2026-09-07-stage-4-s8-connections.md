# Stage 4, S4-8: connections and search — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S4-8 of `docs/superpowers/specs/2026-09-07-stage-4-bench-maker-design.md` (§5's S4-8 row). One new table, `maker_file_links`, holds two kinds of file↔file edge: **`derived_from`** (this SVG came out of that `.lbrn2`; this 3MF came out of that `.scad`) and **`photo_of`** (this picture shows that file). Both are **written automatically** — by S4-3's Save-to-library and by the OpenSCAD addon's save — and **settable by hand** on a file page. Both directions render in one **Connected** panel on the file page. Search grows a **Notes** group over note bodies and a **Folders** group. Stories 3.2, 3.3, 3.4, 3.5.

**Architecture:** `Maker::FileLink` keeps two **bare node-id strings with no foreign key** — the convention every maker table already keeps (`maker_file_attachments`, `maker_notes`, `maker_previews`) — and **liveness is answered at read time by `nodes.present`, never by the row**. `FilesController#show` reads both directions in ONE query (`from_node_id = :n OR to_node_id = :n`, both halves indexed) and resolves every partner in ONE `nodes.present` lookup; a partner that is a tombstone simply has no entry and the panel drops the row. `Maker::AttachmentReaper` destroys such a row once the node's undo window closes — the same instant-hide / delayed-destroy asymmetry `Maker::DeadNodes` argues for attachments. There is ONE door for both hand-set kinds (`Files::LinksController#create`), and **the direction is decided server-side from `kind`**, so a client cannot invert a link. Search gains two groups, each ONE capped query plus ONE count in `SearchController`'s existing idiom; README text is **not** searched, and the reason is measured, not assumed (Amendment 4).

**Tech Stack:** Rails 8, Hotwire (the existing `thumbs` and `filechooser` Stimulus controllers — **no new controller**), Minitest, one migration, `page_query_budget_test.rb`, `template_hygiene_test.rb`, `schema_map_test.rb`, `tenant_cleanup_test.rb`.

---

## Amendments (research decisions, 2026-09-07) — these override the brief and the overview where they differ

Each was forced by reading the code; each names what it read.

1. **A new table owes SIX derived guards here, not four — and the `maker_connections` orphan case is NOT one of them.** The overview names four (orphan guard, dead-node reaper, query budget, template sweep); the memory `new-table-guard-checklist` names four (schema map, tenant cleanup, template sweep, structural orphan). They overlap in one. The union that actually applies to `maker_file_links` is: (1) `SchemaMap::LAYOUT` + `EDGES` + a regenerated `docs/schema-map.html` (`test/schema_map_test.rb`); (2) `TenantCleanupTest::BUILDERS` + `BUILD_ORDER` + `User has_many … dependent:`; (3) `Maker::AttachmentReaper` sweeping **both** node columns; (4) `page_query_budget_test.rb`; (5) `template_hygiene_test.rb`; (6) `test/architecture_invariants_test.rb`'s index-prefix guard (satisfied by construction — see Amendment 3). **`test/models/structural_orphan_test.rb` needs NO case**, and this is read, not assumed: its `EDGES` filter (`test/models/structural_orphan_test.rb:28-32`) selects only `parent.end_with?(".id")`, which excludes `nodes.node_id`, and `user_id` edges are **derived** in `SchemaMap#edges` (`lib/schema_map.rb:243-257`) rather than authored, so they never reach `SchemaMap::EDGES` at all — which is why `maker_connections` has a case for `project_id` and none for `user_id`. Task A step 12 asserts that guard still passes with its derived count unchanged, so the claim is checked rather than believed.

2. **No `*_belongs_to_user` validation on either node column, at create time or otherwise.** The brief asked for one "per §14d's dangling-id lock warning"; reading the siblings says the opposite. `Maker::Note` (`app/models/maker/note.rb:13`), `Maker::FileAttachment` (`:336`), `Maker::Preview` (`:21`) and `Maker::ReleaseFile` (`:15`) all validate a node column for **presence only** and check ownership **at the door** (`NotesController#create`'s `current_user.nodes.present.exists?`). Adding one here would put ownership in two places and walk straight into §14d's lock: both columns are `null: false`, so a check that is not `on: :create` runs on every save and refuses the row the moment either node is tombstoned — the ordinary case this table is designed to survive — while `on: :create` would additionally make `TenantCleanupTest`'s builder need two real live nodes for a test that is about `dependent:`. **Ownership is checked at all three write doors instead**, each explicitly (Task B step 5, Task C steps 3 and 6), and the OpenSCAD writer's check is load-bearing because its input is user-supplied JSON.

3. **The indexes are `(user_id, from_node_id, to_node_id, kind)` UNIQUE plus `(user_id, to_node_id)`, and there is NO bare `user_id` index.** `test/architecture_invariants_test.rb:1135-1176` refuses an index whose column list is a strict prefix of another's on the same table, and `[user_id]` is a strict prefix of the unique index. `[user_id, to_node_id]` is not (its second column differs), so it is allowed — and it is needed, because the panel's `OR` has a `to_node_id` half the unique index cannot serve. This is exactly the shape `maker_file_attachments` already carries (`db/schema.rb:178-179`).

4. **README text is NOT searched, and story 3.5 lands as `rough`, not `works`.** `Maker::Readme.for` (`app/services/maker/readme.rb:63-84`) reads the bytes **through the port at request time** from in-memory `ProjectFolderListing::Row`s; there is no index and no stored text anywhere. Searching README text therefore costs, **per project**, one `Maker::ProjectFolderListing` construction (several queries each) plus one `FileLayer.current.read` — which on `chunk_remote`, the product's main deployment, is a WAN stream of up to `READ_LIMIT` (256 KB) per project per query. `page_query_budget_test.rb:746`'s `search#index` case grows projects and asserts **constancy in N**, so a per-project listing fails that guard *by construction*, and §14e's query-cost bullet plus §2's "the WAN is never in a read path paid per request" both point the same way. The honest answer is that README search needs an **index** (a stored, scan-maintained text column), which is a design, not a slice. Named in the close-out as remaining friction on 3.5, with the reason.

5. **`nodes.storage_path` is NOT searched either; a Folders group is what lands instead.** `storage_path` is written only by `FileLayer::Share` and `FileLayer::S3` (grep across `app/services/file_layer/`: every hit is in `share.rb` or `s3.rb`); `chunk_remote` mirrors a remote tree and never writes it. A `LIKE` over it is therefore **structurally empty on the main deployment** — one condition with two answers across backends (§14a) — and no test could pin it identically on the three legs. A **Folders** group (`kind: "dir"`, name `LIKE`, linking into `files_path(folder: …)`) is the only spelling of story 3.5's "folder paths found" that all three backends answer identically, costs one capped query plus one count like every other group, and does not flood the Files group the way folding a parent-name join into it would. **This is the one addition beyond the spec row's literal text** ("search over note bodies and README text"); it is small and reversible — if a reviewer prefers strict scope, drop Task D steps 6, 8 and the `:folder` arm and nothing else moves.

6. **`t.timestamps` (both columns), not `created_at` alone.** The spec's `(user_id, from_node_id, to_node_id, kind, created_at)` is a shorthand for what the row holds. Every sibling maker table carries both; nothing in the schema guards cares; and a table missing `updated_at` is a surprise waiting for the first person who writes `touch`. The row is still treated as immutable — created and destroyed, never edited.

7. **The OpenSCAD writer keys on `data["node_id"]`, and that convention was PROBED, not guessed.** `chaim354/tinkerex-addons`, `addons/openscad/editor.js:339-343` (`stateData`) writes `{ node_id: source.nodeId, source_name: source.title, params }` for a bring-your-own `.scad` and `{ generator: source.key, params }` for a bundled one; `addons/boxes/editor.js:359` and `addons/generators/generators.js:164` write `{ generator, params }` and **no node id at all**, so the key cannot collide with theirs. `Tools::AddonsController#parse_data` (`app/controllers/tools/addons_controller.rb:1092`) stores `data` unexamined, so this is the first server-side reader of any bundle key — which is why the value is **resolved against `current_user.nodes.present`** before a link is written (Amendment 2).

8. **The Save-to-library writer posts to the same door the hand control uses; it does not add a param to the upload doors.** S4-3's Task D leaves the new node id in the BROWSER (`chunk_upload.js`'s two doors both return `{ nodeId, notice }`, and `measure_controller.js#saveAll` binds it as `last`). Threading a `derived_from` through `FilesController#create` **and** `#finalize_upload` would put a link concern on two general upload doors that every other uploader also drives; one extra `fetch` to `POST /files/:id/links` reuses the door Task B builds anyway. The cost is stated rather than hidden: the link POST can fail independently of the save, so it is wrapped, logged and **never allowed to change the save's status sentence** — a file saved without its link is repairable with the hand control that sits on its own page.

9. **A `photo_of` link is refused unless the chosen file's role is `image`.** `Maker::FileAttachment.role_for` (`:307`) is the one vocabulary (§14a / `files-preview.md`); the picker is additionally filtered to the image extensions **derived from `ROLE_BY_EXT`**, never a second list — `lib/file_chooser.js:44-56` states in as many words that a picker filter is "a convenience for the human picking, never a restriction", so the server keeps the real refusal.

10. **The project page's Photos panel is NOT changed.** `Maker::ProjectPhotos.rows` stays the folder's image rows plus live entry photos (S4-1). A `photo_of` is a statement about a **file**, and the project page reaches it through that file's page; pulling `photo_of` photos into the project gallery would give one panel two definitions of "a project's photos" and would make the public page (which reuses the same method, §7) disagree with itself about what a visitor may see. Stated so it is not re-derived.

When a step below conflicts with an amendment, the amendment wins.

## Decisions on the open questions (orchestrator review, 2026-09-07) — these override the text below

1. **Keep the Folders group.** It is the one backend-neutral spelling of story 3.5's "folder paths";
   the close-out says README text stayed out on a measurement (one port read per project per search).
2. **The OpenSCAD save writes its `derived_from` link unasked**, and the panel's `×` withdraws it.
   That is the feature; the PR body says so. An opt-in would live in the bundle repo, not here.
3. **Boxes and generators write no link** — a catalog key is not a file. Not a second kind.
4. **The reaper destroys a link when either end is reaped.** No nullable breadcrumb column.
5. **`files#show` may backfill thumbnails through `ThumbnailMap.for`** like every other page that
   renders tiles; the PR body names it as a change in what viewing a file costs on an old library.
6. **The migration task also runs `bin/rails schema:map` and commits `docs/schema-map.html`** —
   `test/schema_map_test.rb` fails the full gate otherwise, and no per-task run reaches it (S4-2's gate).

When a step below conflicts with a decision here, the decision wins.

## Before you start

- Branch from `main` at `1c2b2b2` (S4-1 through S4-7 all merged; nothing else is in flight in this worktree). Never push to `main`. S4-3's Save-to-library (`chunk_upload.js`'s two doors returning `{ nodeId, notice }`, `measure_controller.js#saveAll`) is on `main`, so the writer this plan depends on exists. **The migration timestamp this plan names, `20260907130000`, is TAKEN** (S4-3's `add_library_scanned_at_to_users`), and S4-6 and S4-7 used `140000` and `160000` — use `20260907170000`. Since this plan was written S4-4 moved the public project page's body into `public/projects/_page.html.erb`, S4-5 made the file page's viewers shared partials under `app/views/files/viewers/` (the file page's body is `files/show.html.erb` rendering them), S4-6 added `discovered_at`/`opened_at`/the adoption door, and S4-7 made the project page a loop over `Maker::Project::PANELS` — a new project-page panel MUST be added to `PANELS`/`PANEL_LABELS`, or it renders for nobody (this plan adds none to the project page by amendment 10, but read that rule before touching `show.html.erb`). Line numbers quoted below were measured before those slices landed; anchor every edit on the quoted TEXT. Subagents in this stage run on Opus.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time; from a worktree `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci`. The three backend legs must report identical run counts.
- **Read first, in full:** CLAUDE.md **§14a** (bare node-id strings, the two tombstone kinds, why liveness is a read-time question), **§14d**'s `*_belongs_to_user`/`dependent:` bullet and its `form_with` `scope:` bullet (**assert the rendered field name**), **§14e**'s query-cost bullet, `docs/invariants/design-system.md` rules 3, 11 and 12 (a component selector lives in `components.css` alone; nothing scrolls sideways at 375px; class names are a contract), and `app/services/maker/dead_nodes.rb` in full (the revivability argument this table inherits verbatim).
- **The four-guard memory is really six here — read Amendment 1 before you start, and run those files directly before the full gate.** Each costs seconds; a miss costs ~10 minutes of `bin/ci`.
- **Fixtures.** A project folder in a request test is `project_folder_rows!(user, project)` (`test/test_helper.rb:171`), never `ensure_library_folder!` (a real mkdir; red on s3 and chunk_remote). A node that must carry a **content token** on all three legs needs BOTH `content_hash` and `current_version_id` — the idiom is `test/integration/web/template_hygiene_test.rb:280-284`'s `file!`. A bare `nodes.create!` has a nil `content_token` and `app/views/files/show.html.erb:115` short-circuits the whole preview tree on that.
- **Upload-control assertions branch on `capabilities.port_writable?`** (memory: `upload-form-assertions-must-branch-on-port-writable`). Nothing in this slice renders an upload form, but Task C touches `_measure.html.erb`, whose existing assertions do — leave them alone.
- `git add` a new file before a mutation check; restore with `git checkout -- <file>`; clear `tmp/cache/bootsnap*` after an equal-length restore; `git status --porcelain` before the next run.
- Helpers and facts you will rely on, each verified by reading:
  - `Maker::Note.joins(:rich_text_body)` emits `INNER JOIN action_text_rich_texts ON record_type = 'Maker::Note' AND name = 'body' AND record_id = maker_notes.id` — **probed via `bin/rails runner`, 2026-09-07**. `order(created_at: :desc)` on that relation qualifies to `"maker_notes"."created_at"` (no ambiguity), and `.count` works because no `select` values are set. **Do not hand-write the ON clause**: `has_rich_text :body` owns both conditions and a second spelling can drift from it.
  - `SearchController#add_group` (`app/controllers/search_controller.rb:74-78`) takes an AR **relation** and calls `.count` then `.limit(PER_GROUP)`. A relation carrying `select` values breaks `.count` (`select_for_count` joins them into `COUNT(a, b)`), so **never add a `select` to a scope you hand it**.
  - `thumb_cell_data(node_id, ext_label)` is `app/helpers/files_helper.rb:62`; `Maker::Previews::ThumbnailMap.for(user, node_ids)` is `app/services/maker/previews/thumbnail_map.rb:46` and **backfills on a GET, bounded at `BACKFILL_LIMIT = 100`** — that is its documented door contract, not a new liberty.
  - `app/views/projects/_photos.html.erb` is the shape to copy for a thumbnail grid outside a polling wrapper: its own `data-controller="thumbs"`, `thumb_cell_data` per cell, `render "files/thumb"`.
  - `library_children_path` / `library_folders_path` are the chooser's JSON endpoints (`config/routes.rb:130-131`); `LibraryBrowseController#children` already filters through `visible_entries`.
  - `Maker::FileAttachment.role_for(name)` is `:307`; the `image` role's extensions are `:61`.
  - `Library::RepoMetadata::DIR_NAME` is the `.git` marker; `Node.visible_entries(false)` is the display filter (`app/models/node.rb:73`).

## File structure

| path | responsibility | task |
|---|---|---|
| new `db/migrate/20260907130000_create_maker_file_links.rb`, `db/schema.rb`, new `app/models/maker/file_link.rb`, `app/models/user.rb`, `lib/schema_map.rb`, `docs/schema-map.html` (regenerated), `app/services/maker/attachment_reaper.rb`, `config/recurring.yml`; new `test/models/maker/file_link_test.rb`, `test/models/tenant_cleanup_test.rb`, `test/services/maker/attachment_reaper_test.rb` | the table, the model, the reaper, and the guards a new table owes | **A** |
| `app/controllers/search_controller.rb`, `app/views/shared/_result_group.html.erb`; `test/integration/web/search_test.rb` | search finds notes, and folders by name | **D** |
| `app/controllers/files_controller.rb` (`#show` only), new `app/controllers/files/links_controller.rb`, `config/routes.rb`, `app/views/files/show.html.erb`, new `app/views/files/_connections.html.erb`, `app/views/shared/_folder_field.html.erb`, `app/javascript/controllers/filechooser_controller.js`, `app/models/maker/file_attachment.rb` (`IMAGE_EXTS`), `app/assets/stylesheets/pages/files.css`; `test/integration/web/file_page_test.rb`, new `test/integration/web/file_links_test.rb` | the Connected panel and its two hand doors | **B** |
| `app/controllers/tools/addons_controller.rb`, `app/views/files/_measure.html.erb`, `app/javascript/controllers/measure_controller.js`; `test/controllers/tools/addons_controller_test.rb`, `test/system/measure_export_test.rb` | the two automatic writers | **C** |
| `test/integration/web/page_query_budget_test.rb`, `test/integration/web/template_hygiene_test.rb`, `test/system/shell_test.rb` | the three shared sweeps, both features' fixtures in one pass | **E** |
| `docs/user-stories.md` (re-tag 3.2–3.5 + the coverage table), `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md` (S4-8 row → landed), `docs/invariants/files-preview.md` | close-out | **F** |

**Dependencies.** **A and D are disjoint — dispatch them in parallel.** B needs A (`Maker::FileLink`). C needs A and B (it posts to B's door and writes B's model). **E owns all three shared guard files for BOTH features**, which is why it is its own task rather than split across B and D: batching by file is what keeps two tasks from editing `page_query_budget_test.rb` at once, and E is the only writer of the three. E starts when B, C and D have committed. F closes out.

---

### Task A: the table, the model, the reaper, and the guards a new table owes

**Files:**
- Create: `db/migrate/20260907130000_create_maker_file_links.rb`, `app/models/maker/file_link.rb`, `test/models/maker/file_link_test.rb`
- Modify: `db/schema.rb`, `app/models/user.rb`, `lib/schema_map.rb`, `docs/schema-map.html`, `app/services/maker/attachment_reaper.rb`, `config/recurring.yml`
- Test: `test/models/maker/file_link_test.rb` (new), `test/models/tenant_cleanup_test.rb`, `test/services/maker/attachment_reaper_test.rb`

- [ ] **Step 1: the failing model test.** Create `test/models/maker/file_link_test.rb`:

```ruby
require "test_helper"

module Maker
  # Stage 4, S4-8: one file's tie to another. The model's whole job is to hold two BARE node-id
  # strings honestly — no foreign key, no liveness, no ownership check (Maker::Note and
  # Maker::FileAttachment set that convention and the plan's Amendment 2 argues it). What it does
  # own is the kind vocabulary, the self-link refusal, and the pair's uniqueness.
  class FileLinkTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "link-#{SecureRandom.hex(4)}@example.com")
    end

    def link(from: "n-export", to: "n-source", kind: "derived_from", user: @user)
      user.maker_file_links.new(from_node_id: from, to_node_id: to, kind:)
    end

    test "both kinds are valid and nothing else is" do
      assert_equal %w[derived_from photo_of], Maker::FileLink::KINDS
      Maker::FileLink::KINDS.each { |k| assert link(kind: k).valid?, "#{k} should be a kind" }
      refute link(kind: "inspired_by").valid?
      refute link(kind: "").valid?
    end

    # A NODE THIS USER DOES NOT OWN, AND A NODE THAT DOES NOT EXIST, ARE BOTH VALID ROWS — on
    # purpose. Ownership is the DOOR's question (Files::LinksController, Tools::AddonsController,
    # the measure save), and liveness is the READER's (nodes.present at render time). Putting
    # either here would refuse a row whose file was tombstoned an hour ago, which is exactly the
    # state Maker::AttachmentReaper exists to clean up on a schedule instead.
    test "a node that is absent, tombstoned or another user's is still a valid row" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: "n-theirs", name: "theirs.stl", kind: "file")
      assert link(from: "never-existed", to: "n-theirs").valid?
    end

    test "a file cannot be derived from itself" do
      row = link(from: "n-same", to: "n-same")
      refute row.valid?
      assert_includes row.errors.full_messages.join, "same file"
    end

    # ONE PAIR PER KIND, ENFORCED BY THE INDEX AND NOT BY A VALIDATION. A `validates :uniqueness`
    # would be a second SELECT on every write and would still lose a race; the doors treat
    # RecordNotUnique as "this request's intent is already satisfied" (the argument
    # Projects::EntryPhotosController#create already carries for maker_file_attachments).
    test "the same pair and kind cannot be stored twice, while the other kind and the reverse can" do
      link.save!
      assert_raises(ActiveRecord::RecordNotUnique) { link.save! }
      assert link(kind: "photo_of").save, "a different kind on the same pair is a different fact"
      assert link(from: "n-source", to: "n-export").save, "the reverse pair is a different fact"
    end

    test "another user may hold the identical pair" do
      link.save!
      other = User.create!(email: "twin-#{SecureRandom.hex(4)}@example.com")
      assert link(user: other).save
    end

    # `touching` IS WHAT MAKES THE FILE PAGE ONE QUERY INSTEAD OF TWO (FilesController#show).
    test "touching finds a node at either end and nothing else" do
      a = link(from: "n-a", to: "n-b").tap(&:save!)
      b = link(from: "n-b", to: "n-c").tap(&:save!)
      link(from: "n-x", to: "n-y").save!
      assert_equal [ a, b ].map(&:id).sort, @user.maker_file_links.touching("n-b").pluck(:id).sort
    end

    test "destroying the user takes its links" do
      link.save!
      assert_difference "Maker::FileLink.count", -1 do
        @user.destroy!
      end
    end
  end
end
```

- [ ] **Step 2: run it, expect FAIL.** `bin/rails test test/models/maker/file_link_test.rb` → every case errors with `NameError: uninitialized constant Maker::FileLink`.

- [ ] **Step 3: the migration.** Create `db/migrate/20260907130000_create_maker_file_links.rb`:

```ruby
class CreateMakerFileLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_file_links do |t|
      t.integer :user_id, null: false
      # BARE NODE-ID STRINGS, NO FOREIGN KEY — the convention every maker table keeps (§14a).
      # `nodes.node_id` is a per-user string, a tombstone outlives its file, and a restore returns
      # the SAME id, which is the whole reason attachments, BOM lines and tags are keyed on it.
      t.string  :from_node_id, null: false
      t.string  :to_node_id,   null: false
      t.string  :kind,         null: false
      t.timestamps
    end

    # ONE PAIR PER KIND. Also the panel's `from` half: (user_id, from_node_id, …) is its leading
    # prefix, so `from_node_id = ?` seeks it.
    add_index :maker_file_links, %i[user_id from_node_id to_node_id kind],
              unique: true, name: "index_maker_file_links_uniqueness"
    # THE OTHER HALF OF FilesController#show's ONE query. Its OR asks about both columns and the
    # unique index above cannot serve `to_node_id` — its second column is `from_node_id`. Exactly
    # the pair maker_file_attachments carries for the same reason.
    #
    # AND DELIBERATELY NO BARE `user_id` INDEX: it would be a strict PREFIX of the unique index,
    # which test/architecture_invariants_test.rb refuses — every seek it answers, the wider one
    # answers too, and it would cost a btree write on every insert and delete for nothing.
    add_index :maker_file_links, %i[user_id to_node_id]
  end
end
```

- [ ] **Step 4: the model.** Create `app/models/maker/file_link.rb`:

```ruby
module Maker
  # ONE FILE'S TIE TO ANOTHER (stage 4, S4-8; stories 3.2 and 3.3). Two kinds, and which way each
  # points is spelled ONCE here so no door can invert one:
  #
  #   derived_from — FROM the derived file (an SVG export, a generated 3MF) TO its source (the
  #                  .lbrn2, the .scad). "This came from …" sits on the derived file's page.
  #   photo_of     — FROM the photograph TO the file it depicts. "Photos of this file" sits on the
  #                  depicted file's page.
  #
  # BOTH COLUMNS ARE BARE node_id STRINGS WITH NO FOREIGN KEY, and LIVENESS IS ANSWERED AT READ
  # TIME by `nodes.present`, never by the row (§14a). A link whose partner is a tombstone is
  # dropped by the page immediately and destroyed by Maker::AttachmentReaper once that node's undo
  # window closes — hiding is instant because hiding is reversible, destroying waits because it is
  # not (Maker::DeadNodes owns that rule and this table is its third subject).
  #
  # NO OWNERSHIP VALIDATION ON EITHER NODE, AND THAT IS THE SIBLINGS' RULE RATHER THAN AN OMISSION.
  # Maker::Note, Maker::FileAttachment, Maker::Preview and Maker::ReleaseFile all validate a node
  # column for PRESENCE only and ask `current_user.nodes.present.exists?` at the door. Adding one
  # here would put ownership in two places, and — both columns being `null: false` — an unguarded
  # check would run on EVERY save and refuse the row the moment either file was tombstoned, which
  # is the ordinary state this table is built to survive (§14d's dangling-id lock, one table over).
  class FileLink < ApplicationRecord
    self.table_name = "maker_file_links"

    KINDS = %w[derived_from photo_of].freeze

    belongs_to :user

    validates :from_node_id, :to_node_id, presence: true
    validates :kind, inclusion: { in: KINDS }
    validate  :not_a_self_link

    # BOTH DIRECTIONS IN ONE PREDICATE, because the file page needs both and asking twice is two
    # queries for one panel. Both halves are indexed (see the migration).
    scope :touching, ->(node_id) { where("from_node_id = :n OR to_node_id = :n", n: node_id) }

    private

    # A FILE DERIVED FROM ITSELF IS A MISCLICK, NOT A FACT — and the unique index cannot refuse it,
    # since one such row is unique on all four columns. A validation rather than a door check
    # because otherwise all three write doors would each need their own copy.
    def not_a_self_link
      return if from_node_id.blank? || from_node_id != to_node_id

      errors.add(:to_node_id, "can't be the same file")
    end
  end
end
```

- [ ] **Step 5: the association.** In `app/models/user.rb`, beside `has_many :maker_notes` (`:100`):

```ruby
  # Stage 4, S4-8. `:destroy` rather than `:delete_all` to match every sibling here; the model
  # carries no callbacks, so the two are equivalent in effect and the cheaper one buys nothing at
  # these row counts. TenantCleanupTest is what proves the line exists at all.
  has_many :maker_file_links, class_name: "Maker::FileLink", dependent: :destroy
```

- [ ] **Step 6: migrate dev and test, commit the schema.**

```bash
bin/rails db:migrate
RAILS_ENV=test bin/rails db:migrate
git diff --stat db/schema.rb   # expect: maker_file_links added, version bumped to 2026_09_07_130000
```

- [ ] **Step 7: run the model test, expect PASS.** `bin/rails test test/models/maker/file_link_test.rb` → 7 runs, 0 failures.

- [ ] **Step 8: the schema map (guard 1).** In `lib/schema_map.rb`, add `maker_file_links` to the **"Files ↔ maker"** column (`:73-76` — it is a row about files, keyed on `nodes.node_id`, and names no project), and add two edges beside `maker_notes.node_id` (`:135`):

```ruby
    # Stage 4, S4-8. TWO edges from one table, because a link is a statement about a PAIR: both
    # ends are `nodes.node_id`, both are bare strings, and neither is enforced by anything. Drawn
    # for the same reason maker_notes.node_id and maker_file_attachments.node_id are — this map
    # exists to show the app-level references no constraint would ever notice.
    [ "maker_file_links.from_node_id", "nodes.node_id", "app", "links from" ],
    [ "maker_file_links.to_node_id",   "nodes.node_id", "app", "links to" ],
```

Then regenerate the checked-in page:

```bash
bin/rails schema:map
bin/rails test test/schema_map_test.rb   # expect 0 failures
```

- [ ] **Step 9: tenant cleanup (guard 2).** In `test/models/tenant_cleanup_test.rb`, add a builder beside `maker_notes` (`:61`) and the table to `BUILD_ORDER` (`:132-141`, in the same line as `maker_notes`):

```ruby
    "maker_file_links" => ->(u) {
      u.maker_file_links.create!(from_node_id: SecureRandom.uuid, to_node_id: SecureRandom.uuid,
                                 kind: "derived_from")
    },
```

Random ids and no `nodes` rows, exactly as the `maker_notes` builder does one line up: this test is about `dependent:`, not about the library, and the model deliberately refuses neither (Amendment 2).

- [ ] **Step 10: the reaper (guard 3).** In `app/services/maker/attachment_reaper.rb`, extend `reap!`. Add to the class comment, after the "NOT gated on any capability" line:

```ruby
  # SINCE STAGE 4, S4-8 IT SWEEPS `maker_file_links` TOO, and from BOTH of its node columns. A link
  # is a statement about a PAIR, so it stops being true the moment ONE end is gone for good —
  # waiting for the second would leave a "Derived from: (missing)" row on the surviving file's page
  # forever, which is the same "⚠️ (file unavailable)" tile this sweep was written to end. The
  # grace window is Maker::DeadNodes' and is therefore identical for all three subjects: a
  # tombstone is one undo away from returning with the same node_id, and the link is keyed on it.
```

and inside `reap!`:

```ruby
      attachments = user.maker_file_attachments.to_a
      links       = user.maker_file_links.to_a
      covered     = user.maker_projects.where.not(cover_node_id: [ nil, "" ]).to_a +
                    user.maker_models.where.not(cover_node_id: [ nil, "" ]).to_a
      return 0 if attachments.empty? && covered.empty? && links.empty?

      nodes  = Maker::DeadNodes.index(user, attachments.map(&:node_id) +
                                            covered.map { |p| p[:cover_node_id] } +
                                            links.flat_map { |l| [ l.from_node_id, l.to_node_id ] })
      cutoff = grace.ago

      doomed = attachments.select { |a| Maker::DeadNodes.reapable?(nodes[a.node_id], cutoff) }
      stale_covers = covered.select { |p| Maker::DeadNodes.reapable?(nodes[p[:cover_node_id]], cutoff) }
      # EITHER END, NOT BOTH — see the class comment. `||`, and the mutation check for it is
      # turning it into `&&`.
      dead_links = links.select { |l|
        Maker::DeadNodes.reapable?(nodes[l.from_node_id], cutoff) ||
          Maker::DeadNodes.reapable?(nodes[l.to_node_id], cutoff)
      }
      return doomed.size + stale_covers.size + dead_links.size if dry_run

      doomed.each(&:destroy!)
      stale_covers.each { |p| p.update_column(:cover_node_id, nil) }
      dead_links.each(&:destroy!)
      doomed.size + stale_covers.size + dead_links.size
```

Leave the existing comments on `covered`, `stale_covers` and `update_column` exactly where they are.

- [ ] **Step 11: the reaper's tests.** Append to `test/services/maker/attachment_reaper_test.rb` (its `node(node_id, deleted:, updated_at:)` helper at `:17` is what you need):

```ruby
    # ---- file links (stage 4, S4-8) ------------------------------------------------------

    def link(from, to, kind: "derived_from")
      @user.maker_file_links.create!(from_node_id: from, to_node_id: to, kind:)
    end

    test "a link is reaped when EITHER end is gone for good, and not while both are live" do
      node("live-a"); node("live-b")
      link("live-a", "live-b")
      assert_equal 0, Maker::AttachmentReaper.reap_all!, "a link between two live files is never touched"

      node("live-c")
      link("live-c", "never-existed")
      assert_equal 1, Maker::AttachmentReaper.reap_all!
      assert_equal 1, @user.maker_file_links.count

      link("never-existed-either", "live-c")
      assert_equal 1, Maker::AttachmentReaper.reap_all!, "the FROM end counts as much as the TO end"
      assert_equal 1, @user.maker_file_links.count
    end

    test "a link to a fresh tombstone is spared and one past the window is reaped" do
      node("live-d")
      node("tomb", deleted: true, updated_at: 2.days.ago)
      link("live-d", "tomb")
      assert_equal 0, Maker::AttachmentReaper.reap_all!, "an undo would bring the file back with the same id"

      @user.nodes.find_by!(node_id: "tomb").update_column(:updated_at, 31.days.ago)
      assert_equal 1, Maker::AttachmentReaper.reap_all!
      assert_equal 0, @user.maker_file_links.count
    end

    test "dry_run counts links without destroying them" do
      link("gone-1", "gone-2")
      assert_equal 1, Maker::AttachmentReaper.reap_all!(dry_run: true)
      assert_equal 1, @user.maker_file_links.count
    end

    test "another user's links are never reaped by this user's sweep" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com")
      other.maker_file_links.create!(from_node_id: "x", to_node_id: "y", kind: "photo_of")
      assert_equal 0, Maker::AttachmentReaper.reap!(@user)
      assert_equal 1, other.maker_file_links.count
    end
```

Also extend `config/recurring.yml`'s `attachment_reaper` comment (the block after `dead_node_preview_reaper`) with one sentence: *"Since stage 4, S4-8 it also sweeps `maker_file_links`, whose two node columns can each go dead independently."*

- [ ] **Step 12: run the guards, expect PASS — including the one that needs NO change.**

```bash
bin/rails test test/schema_map_test.rb test/models/tenant_cleanup_test.rb \
               test/models/structural_orphan_test.rb test/services/maker/attachment_reaper_test.rb \
               test/architecture_invariants_test.rb
```
→ 0 failures. **Report `structural_orphan_test.rb`'s own numbers**: its `EDGES.size >= 12` assertion must still hold at the same count as before this branch (`maker_file_links` contributes no structural edge — Amendment 1), and `architecture_invariants_test.rb`'s prefix guard must report `PREFIX_PAIRS=0`. If either moved, stop: the table's index shape or its edges are wrong, not the guard.

- [ ] **Step 13: mutation checks. Report all five outputs.**
  - (i) In the migration, change the unique index to non-unique, `bin/rails db:migrate:redo` on the test DB → `file_link_test.rb`'s "the same pair and kind cannot be stored twice" FAILS (`ActiveRecord::RecordNotUnique expected but nothing was raised`). Restore and re-migrate.
  - (ii) In the migration, add `add_index :maker_file_links, :user_id` → `architecture_invariants_test.rb` FAILS with `PREFIX_PAIRS=1 … index_maker_file_links_on_user_id ["user_id"] is a strict prefix of index_maker_file_links_uniqueness`. Restore.
  - (iii) Delete the `has_many :maker_file_links` line from `app/models/user.rb` → `tenant_cleanup_test.rb` FAILS naming `maker_file_links` in the surviving-rows message, and `file_link_test.rb`'s six `@user.maker_file_links` cases error. Restore.
  - (iv) In `attachment_reaper.rb`, change `dead_links`' `||` to `&&` → "a link is reaped when EITHER end is gone" FAILS at the second assertion (`Expected: 1, Actual: 0`). Restore.
  - (v) In `lib/schema_map.rb`, remove `maker_file_links` from `LAYOUT` → `schema_map_test.rb` FAILS with `maker_file_links is not in SchemaMap::LAYOUT — decide which column it belongs in`. Restore; re-run `bin/rails schema:map` and confirm `docs/schema-map.html` is byte-identical to the committed one.

- [ ] **Step 14: commit.**

```bash
git add db/migrate/20260907130000_create_maker_file_links.rb db/schema.rb app/models/maker/file_link.rb \
        app/models/user.rb lib/schema_map.rb docs/schema-map.html \
        app/services/maker/attachment_reaper.rb config/recurring.yml \
        test/models/maker/file_link_test.rb test/models/tenant_cleanup_test.rb \
        test/services/maker/attachment_reaper_test.rb
git commit -m "A file can record where it came from, and a dead end takes the link with it"
```

---

### Task D: search finds notes, and folders by name

Disjoint from A, B and C — **dispatch in parallel with A.**

**Files:**
- Modify: `app/controllers/search_controller.rb`, `app/views/shared/_result_group.html.erb`
- Test: `test/integration/web/search_test.rb`

- [ ] **Step 1: the failing tests.** Append inside `Web::SearchTest` (`test/integration/web/search_test.rb`):

```ruby
    # A NOTE IS THE ONE THING A MAKER WRITES THAT THE APP KEEPS AND COULD NOT FIND (story 3.5).
    # The body is Action Text, so the match is over `action_text_rich_texts.body` reached through
    # the `rich_text_body` association `has_rich_text :body` declares — the association carries
    # `record_type` and `name = 'body'` itself, so there is no hand-written ON clause to drift.
    test "a note body is searchable and its row links to the file the note is on" do
      node = @user.nodes.create!(node_id: "n-noted", name: "shade.stl", kind: "file")
      @user.maker_notes.create!(node_id: node.node_id, body: "<div>Cut this one on the LAMP jig.</div>")
      @user.maker_notes.create!(node_id: node.node_id, body: "<div>Nothing to do with it.</div>")

      get search_path(q: "lamp")
      assert_response :success
      assert_select ".result-group--note", count: 1
      assert_select ".result-group--note a[href=?]", file_path(node.node_id), text: "shade.stl"
      # THE SNIPPET IS PLAIN TEXT, NOT THE STORED HTML. `to_plain_text` is what keeps `<div>` out
      # of a results row — a raw body would render the tags as escaped noise on every hit.
      assert_select ".result-group--note .result-sub", text: /Cut this one on the LAMP jig\./
      assert_select ".result-group--note .result-sub", text: /Nothing to do with it/, count: 0
    end

    # A NOTE WHOSE FILE IS GONE HAS NOWHERE TO LINK. `.present` is the same filter every other
    # file-facing surface applies; without it the row renders a link to a dead /files/:id.
    test "a note on a tombstoned or absent file does not surface" do
      dead = @user.nodes.create!(node_id: "n-dead", name: "lamp-old.stl", kind: "file", deleted: true)
      @user.maker_notes.create!(node_id: dead.node_id, body: "<div>lamp notes</div>")
      @user.maker_notes.create!(node_id: "never-existed", body: "<div>lamp notes</div>")

      get search_path(q: "lamp")
      assert_select ".result-group--note", count: 0
    end

    # FOLDERS, BY NAME — the only spelling of "find my folder path" all three backends can answer.
    # `nodes.storage_path` is written by the Share and S3 adapters ONLY, so a LIKE over it is
    # structurally empty on chunk_remote (the plan's Amendment 5).
    test "a folder is a result of its own, linking into the Files page's folder view" do
      dir = @user.nodes.create!(node_id: "d-lamps", name: "lamps", kind: "dir")
      @user.nodes.create!(node_id: "d-hidden", name: ".lamps", kind: "dir")
      @user.nodes.create!(node_id: "d-gone", name: "lamps-old", kind: "dir", deleted: true)

      get search_path(q: "lamp")
      assert_select ".result-group--folder", count: 1
      assert_select ".result-group--folder a[href=?]", files_path(folder: dir.node_id), text: "lamps"
      assert_select ".result-group--folder a", text: ".lamps", count: 0
      assert_select ".result-group--folder a", text: "lamps-old", count: 0
    end

    # THE SAME ESCAPE RULE AS EVERY OTHER GROUP. SQLite has no default escape character, so
    # `sanitize_sql_like` alone is inert there and `%` would be a wildcard on self-host.
    test "the two new groups escape LIKE metacharacters too" do
      node = @user.nodes.create!(node_id: "n-pct", name: "pct.stl", kind: "file")
      @user.maker_notes.create!(node_id: node.node_id, body: "<div>done at 100% power</div>")
      @user.maker_notes.create!(node_id: node.node_id, body: "<div>100-decoy</div>")
      @user.nodes.create!(node_id: "d-pct", name: "100% jobs", kind: "dir")
      @user.nodes.create!(node_id: "d-decoy", name: "100-decoy", kind: "dir")

      get search_path(q: "100%")
      assert_select ".result-group--note .result-sub", text: /100% power/
      assert_select ".result-group--note .result-sub", text: /100-decoy/, count: 0
      assert_select ".result-group--folder a", text: "100% jobs"
      assert_select ".result-group--folder a", text: "100-decoy", count: 0
    end

    test "tenancy: another user's note and folder never appear" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      node = other.nodes.create!(node_id: "n-theirs", name: "lamp.stl", kind: "file")
      other.maker_notes.create!(node_id: node.node_id, body: "<div>their lamp note</div>")
      other.nodes.create!(node_id: "d-theirs", name: "lamps", kind: "dir")

      get search_path(q: "lamp")
      assert_select ".result-group--note", count: 0
      assert_select ".result-group--folder", count: 0
    end
```

- [ ] **Step 2: run, expect FAIL.** `bin/rails test test/integration/web/search_test.rb -n "/note|folder/"` → 6 runs, 6 failures on the missing `.result-group--note` / `.result-group--folder`.

- [ ] **Step 3: `add_group` answers with the group it added.** In `app/controllers/search_controller.rb`, change the last two lines of `add_group` (`:76-78`) and extend its comment:

```ruby
  # RETURNS THE GROUP, OR nil WHEN THERE WERE NO MATCHES. The Notes group needs one more query
  # after the cap is applied (the file names for the five rows it will actually render), and that
  # query must see the CAPPED set, not the whole match set — so the caller needs the hash back.
  # Every other caller ignores the return value, exactly as before.
  def add_group(title, kind, scope, more_path)
    total = scope.count
    return if total.zero?

    group = { title:, kind:, records: scope.limit(PER_GROUP).to_a, total:, more_path: }
    @groups << group
    group
  end
```

- [ ] **Step 4: the Folders group.** In `#index`, immediately after the Files group's `add_group` (`:35`):

```ruby
    # Folders: the DIRECTORY rows the Files group deliberately excludes, as their own kind. This is
    # story 3.5's "folder paths" half, in the only spelling all three backends can answer:
    # `nodes.storage_path` — the obvious one — is written by FileLayer::Share and FileLayer::S3
    # ONLY (chunk_remote mirrors a remote tree and never writes it), so a LIKE over it would be
    # structurally empty on the product's main deployment: one condition with two answers across
    # backends, which §14a forbids and which no test leg could pin identically. A folder row links
    # into the Files page's own folder view, which is the thing the maker was looking for.
    #
    # `visible_entries(false)`: the same display filter the Files group applies, so a dot-dir, the
    # `.git` marker and a build-output directory are as absent here as they are on a folder page.
    folders = current_user.nodes.present.where(kind: "dir")
                          .visible_entries(false)
                          .where("LOWER(name) LIKE ? ESCAPE '\\'", like)
    # No "See all": the Files index has no folder-only listing to send a remainder to.
    add_group("Folders", :folder, folders.order(:name), nil)
```

- [ ] **Step 5: the Notes group.** After the Models group (`:47`):

```ruby
    # Notes: the note BODY, which is the one thing a maker writes that this app keeps and could not
    # find (story 3.5). It lives in `action_text_rich_texts`, reached through the `rich_text_body`
    # association `has_rich_text :body` already declares — `joins(:rich_text_body)` emits both
    # `record_type = 'Maker::Note'` and `name = 'body'` itself (probed), so a hand-written ON clause
    # here would be a second spelling that can drift from the association.
    #
    # ONLY NOTES ON A LIVE FILE, because the row's whole content is a link to that file's page. The
    # `.present` subquery is one statement and adapter-agnostic; a boolean literal inside a JOIN
    # condition is not.
    #
    # README TEXT IS DELIBERATELY NOT HERE, and the reason is a measurement rather than a
    # preference: Maker::Readme reads a README through the PORT at request time from an in-memory
    # ProjectFolderListing, so searching them costs one listing plus one port read PER PROJECT —
    # on chunk_remote a WAN stream each. page_query_budget_test.rb's search#index case grows
    # projects and asserts constancy in N, so that shape fails a guard by construction. README
    # search needs a stored, scan-maintained index; that is a design, not a group (spec §9's
    # shape). Story 3.5 records it as remaining friction.
    notes = current_user.maker_notes
                        .joins(:rich_text_body)
                        .where(node_id: current_user.nodes.present.select(:node_id))
                        .where("LOWER(action_text_rich_texts.body) LIKE ? ESCAPE '\\'", like)
                        .includes(:rich_text_body)
                        .order(created_at: :desc)
    if (group = add_group("Notes", :note, notes, nil))
      # THE FILE NAMES FOR THE ROWS THAT WILL ACTUALLY RENDER — one query over at most PER_GROUP
      # ids, after the cap. Doing it in the scope instead would need a `select`, and a relation
      # carrying select values breaks `add_group`'s own `.count` (`COUNT(a, b)` is not SQL).
      group[:node_names] = current_user.nodes.where(node_id: group[:records].map(&:node_id))
                                       .pluck(:node_id, :name).to_h
    end
```

- [ ] **Step 6: the two render arms.** In `app/views/shared/_result_group.html.erb`, extend the Locals block (`kind` gains `:folder | :note`, and a new optional local) and add two `when` arms after `:file`:

```erb
  <% when :folder %>
    <%#
      A FOLDER IS A DESTINATION, NOT A FILE, so it links into the Files page's folder view rather
      than to a /files/:id page it does not have. No extension label: `.result-sub` says what it
      is instead, since a bare name in a list of files would read as a file with no type.
    %>
    <%= link_to record.name, files_path(folder: record.node_id) %>
    <span class="result-sub">Folder</span>
  <% when :note %>
    <%#
      THE ROW IS THE FILE THE NOTE IS ON, because that is where the note is readable — a note has
      no page of its own. `node_names` is this group's own local, built by SearchController#index
      over the CAPPED rows; a missing key cannot happen (the scope filters to live nodes) but the
      fallback is there rather than a nil link text.

      `to_plain_text`, NOT the stored body: an Action Text body is HTML, and rendering it raw here
      would escape `<div>` into every result row.
    %>
    <% names = local_assigns.fetch(:node_names, {}) %>
    <%= link_to names[record.node_id] || "this file", file_path(record.node_id) %>
    <span class="result-sub"><%= truncate(record.body.to_plain_text, length: 80) %></span>
```

- [ ] **Step 7: run, expect PASS.** `bin/rails test test/integration/web/search_test.rb` → 17 runs, 0 failures (11 existing + 6 new).

- [ ] **Step 8: mutation checks. Report all four outputs.**
  - (i) Drop `.where(node_id: current_user.nodes.present.select(:node_id))` → "a note on a tombstoned or absent file does not surface" FAILS (`expected .result-group--note count 0, found 1`).
  - (ii) Change the notes clause's `ESCAPE '\\'` to no ESCAPE clause → "the two new groups escape LIKE metacharacters" FAILS on the `100-decoy` assertion (SQLite reads the sanitizer's backslash literally, so `100%` matches everything starting `100`).
  - (iii) Change `record.body.to_plain_text` to `record.body` → the snippet assertion FAILS on the escaped `&lt;div&gt;` prefix in `.result-sub`.
  - (iv) Drop `.visible_entries(false)` from `folders` → "a folder is a result of its own" FAILS on `.lamps` appearing.
  Restore each; re-run; PASS.

- [ ] **Step 9: commit.**

```bash
git add app/controllers/search_controller.rb app/views/shared/_result_group.html.erb \
        test/integration/web/search_test.rb
git commit -m "Search finds what you wrote in a note, and the folder you were looking for"
```

---

### Task B: the file page's Connected panel and its two hand doors

Starts when A has committed.

**Files:**
- Create: `app/controllers/files/links_controller.rb`, `app/views/files/_connections.html.erb`, `test/integration/web/file_links_test.rb`
- Modify: `app/controllers/files_controller.rb` (`#show` only), `config/routes.rb`, `app/views/files/show.html.erb`, `app/views/shared/_folder_field.html.erb`, `app/javascript/controllers/filechooser_controller.js`, `app/models/maker/file_attachment.rb`, `app/assets/stylesheets/pages/files.css`
- Test: `test/integration/web/file_page_test.rb`, `test/integration/web/file_links_test.rb` (new)

- [ ] **Step 1: the failing page test.** Append inside `Web::FilePageTest` (`test/integration/web/file_page_test.rb`). Note that `@node` (`:16`) is a bare row with a nil `content_token`; these cases do not touch the preview tree, so it is fine here.

```ruby
    # ---- the Connected panel (stage 4, S4-8) --------------------------------------------

    def file!(id, name)
      @user.nodes.create!(node_id: id, name:, kind: "file", mtime: 1_000_000_000, size: 10)
    end

    def link!(from, to, kind)
      @user.maker_file_links.create!(from_node_id: from, to_node_id: to, kind:)
    end

    test "with no links the panel is absent entirely, and both hand doors are not" do
      get file_path(@node.node_id)
      assert_select "section.connections-panel", count: 1, &:present?
      assert_select ".connections-panel .connection-row", count: 0
      # THE DOORS ARE THE POINT OF AN EMPTY PANEL. A file with no lineage is exactly the file whose
      # page has to offer "This came from …"; hiding the panel until a link exists would make the
      # first link unreachable from the app.
      assert_select ".connections-panel details.composer > summary", text: "This came from…"
      assert_select ".connections-panel details.composer > summary", text: "Add a photo of this"
    end

    test "both directions of derived_from render, each naming the other file" do
      source = file!("n-src-lbrn", "coaster.lbrn2")
      export = file!("n-out-svg", "coaster-parts.svg")
      link!(export.node_id, source.node_id, "derived_from")

      get file_path(export.node_id)
      assert_select ".connections-derived-from a[href=?]", file_path(source.node_id), text: "coaster.lbrn2"

      get file_path(source.node_id)
      assert_select ".connections-derived a[href=?]", file_path(export.node_id), text: "coaster-parts.svg"
    end

    test "a photo renders on the file it shows, and the file renders on the photo" do
      subject = file!("n-lid", "lid.stl")
      photo = file!("n-shot", "cut.png")
      link!(photo.node_id, subject.node_id, "photo_of")

      get file_path(subject.node_id)
      assert_select ".connections-photos a[href=?]", file_path(photo.node_id)
      assert_select ".connections-photos [data-thumbs-target='cell'][data-node-id=?]", photo.node_id

      get file_path(photo.node_id)
      assert_select ".connections-depicts a[href=?]", file_path(subject.node_id), text: "lid.stl"
    end

    # LIVENESS IS THE READER'S QUESTION (§14a). The row survives until Maker::AttachmentReaper's
    # window closes; the page must stop showing it the moment the file is gone.
    test "a link whose other end is a tombstone or absent is dropped from the render" do
      subject = file!("n-live", "live.stl")
      dead = @user.nodes.create!(node_id: "n-tomb", name: "gone.stl", kind: "file",
                                 mtime: 1_000_000_000, size: 1, deleted: true)
      link!(subject.node_id, dead.node_id, "derived_from")
      link!(subject.node_id, "never-existed", "derived_from")

      get file_path(subject.node_id)
      assert_select ".connections-panel .connection-row", count: 0
      assert_equal 2, @user.maker_file_links.count, "the rows survive; only the render drops them"
    end

    # §14d: a form_with with no model:/scope: has a blank object_name. These fields are FLAT and
    # must stay flat — Files::LinksController reads params[:kind] and params[:other_node_id], and a
    # nested-hash test could not see the difference. Assert the RENDERED field name.
    test "the hand doors post flat field names to this file's links endpoint" do
      get file_path(@node.node_id)
      assert_select "form.link-form[action=?]", file_links_path(@node.node_id), count: 2
      assert_select "form.link-form input[type=hidden][name='kind'][value='derived_from']"
      assert_select "form.link-form input[type=hidden][name='kind'][value='photo_of']"
      assert_select "form.link-form input[type=hidden][name='other_node_id']", count: 2
    end

    # The picker is the EXISTING chooser in file mode (shared/_folder_field), filtered for the
    # photo door from ROLE_BY_EXT and not from a second list.
    test "the photo door's picker is filtered to the image vocabulary" do
      get file_path(@node.node_id)
      assert_select ".folder-field[data-filechooser-mode-value='file']", count: 2
      assert_select ".folder-field[data-filechooser-extensions-value=?]",
                    Maker::FileAttachment::IMAGE_EXTS.to_json, count: 1
    end
```

- [ ] **Step 2: run, expect FAIL.** `bin/rails test test/integration/web/file_page_test.rb` → 9 runs, 6 failures on the missing panel.

- [ ] **Step 3: the image vocabulary, derived.** In `app/models/maker/file_attachment.rb`, directly after `ROLE_BY_EXT`'s closing `.freeze` (`:~130`):

```ruby
    # WHICH EXTENSIONS ARE PICTURES, DERIVED FROM THE ONE VOCABULARY (stage 4, S4-8). Read by the
    # `photo_of` door's file picker so a maker is offered pictures and not their whole library.
    # Derived rather than written out for the reason §14d gives about every extension list in this
    # app: a second copy is a second thing to forget when a format is added, and this one would
    # silently offer nothing new.
    IMAGE_EXTS = ROLE_BY_EXT.filter_map { |ext, role| ext if role == "image" }.freeze
```

- [ ] **Step 4: the routes.** In `config/routes.rb`, directly after the per-file notes block (`:133-135`):

```ruby
  # --- Per-file links (stage 4, S4-8; keyed by node_id, session auth) ---
  # THE SAME SHAPE THE NOTES ROUTES ABOVE TAKE, for the same reason: the subject of a create is a
  # node_id, which is a string the library owns, while the subject of a destroy is a row id.
  post "files/:node_id/links", to: "files/links#create", as: :file_links
  resources :file_links, only: %i[destroy], controller: "files/links"
```

- [ ] **Step 5: the door.** Create `app/controllers/files/links_controller.rb`:

```ruby
module Files
  # The two hand-set file links (stage 4, S4-8): "This came from …" and "Add a photo of this".
  # Session-authed and current_user-scoped, like NotesController, which this is modelled on.
  #
  # ONE ACTION FOR BOTH KINDS, AND THE DIRECTION IS DECIDED HERE. The URL's node is the SUBJECT —
  # the page you are standing on — and `kind` says which end of the pair that is: a `derived_from`
  # subject is the DERIVED file, a `photo_of` subject is the file being DEPICTED. Letting the form
  # post `from`/`to` directly would let one control write a link the other control's page then
  # renders backwards, and no server-side test could tell an inverted link from a correct one.
  #
  # OWNERSHIP IS THIS DOOR'S QUESTION, NOT THE MODEL'S (Maker::FileLink's own comment): both nodes
  # are resolved through `current_user.nodes.present` before anything is written, and a node
  # belonging to someone else simply is not found.
  class LinksController < ApplicationController
    # POST /files/:node_id/links { kind, other_node_id }
    def create
      subject = current_user.nodes.present.find_by(node_id: params.require(:node_id))
      return refuse(files_path, "That file isn't in your library.") if subject.nil?

      kind = params[:kind].to_s
      return refuse(file_path(subject.node_id), "That isn't a kind of link.") unless
        Maker::FileLink::KINDS.include?(kind)

      other = current_user.nodes.present.find_by(node_id: params[:other_node_id].to_s, kind: "file")
      return refuse(file_path(subject.node_id), "Pick a file in your library.") if other.nil?
      # THE PICKER'S FILTER IS A CONVENIENCE; THIS IS THE REFUSAL. lib/file_chooser.js says so in as
      # many words about `extensions` — it is a courtesy to the human picking and never a
      # restriction — so the vocabulary question is asked again here, through the one definition.
      return refuse(file_path(subject.node_id), "Only an image can be a photo of a file.") if
        kind == "photo_of" && Maker::FileAttachment.role_for(other.name) != "image"

      from, to = kind == "photo_of" ? [ other.node_id, subject.node_id ]
                                    : [ subject.node_id, other.node_id ]
      link = current_user.maker_file_links.new(from_node_id: from, to_node_id: to, kind:)
      return refuse(file_path(subject.node_id), link.errors.full_messages.to_sentence) unless link.save

      respond_to do |f|
        f.html { redirect_to file_path(subject.node_id), notice: "Linked #{other.name}." }
        f.json { render json: { id: link.id }, status: :created }
      end
    rescue ActiveRecord::RecordNotUnique
      # ALREADY LINKED IS THIS REQUEST'S INTENT ALREADY SATISFIED, not an error to surface — the
      # argument Projects::EntryPhotosController#create carries for maker_file_attachments'
      # unique index, and the reason there is no `validates :uniqueness` on the model (a second
      # SELECT on every write that would still lose the race a double-click creates).
      respond_to do |f|
        f.html { redirect_to file_path(params[:node_id]), notice: "Already linked." }
        f.json { head :ok }
      end
    end

    # DELETE /file_links/:id
    def destroy
      link = current_user.maker_file_links.find(params[:id])
      # BACK TO THE PAGE THE REMOVE BUTTON WAS ON, which is either end of the pair. `back_target_path`
      # is not reachable here (the button posts, so there is no meaningful referer chain for it);
      # the subject travels as a param the view already knows.
      node_id = current_user.nodes.present.exists?(node_id: params[:from]) ? params[:from] : link.from_node_id
      link.destroy!
      redirect_to file_path(node_id), notice: "Link removed."
    end

    private

    def refuse(path, message)
      respond_to do |f|
        f.html { redirect_to path, alert: message }
        f.json { render json: { error: message }, status: :unprocessable_entity }
      end
    end
  end
end
```

- [ ] **Step 6: the controller's reads.** In `app/controllers/files_controller.rb#show`, directly after `@new_note = …` (`:517`):

```ruby
    # THE CONNECTED PANEL, BOTH DIRECTIONS IN ONE QUERY (stage 4, S4-8). `touching` is
    # `from_node_id = :n OR to_node_id = :n`; asking twice would be two queries for one panel, and
    # both halves are indexed (the unique index leads on from_node_id, a second index covers
    # to_node_id).
    links = current_user.maker_file_links.touching(@node.node_id).order(:created_at).to_a
    # LIVENESS IS ANSWERED HERE AND NEVER BY THE ROW (§14a). ONE `nodes.present` lookup over every
    # other end; a link whose partner is a tombstone has no entry and the four filter_maps drop it.
    # Maker::AttachmentReaper destroys those rows once the partner's undo window closes — hiding is
    # instant because hiding is reversible, destroying waits because it is not (Maker::DeadNodes).
    partners = current_user.nodes.present
                           .where(node_id: links.flat_map { |l| [ l.from_node_id, l.to_node_id ] }.uniq)
                           .index_by(&:node_id)
    # FOUR LISTS, ONE PER SENTENCE THE PANEL SAYS — resolved here rather than in the template,
    # because the direction rule (Maker::FileLink's KINDS comment) has one home and a view that
    # re-derived it could disagree with the door that wrote the row.
    @derived_from = pick_links(links, partners, "derived_from", :from) # this file's sources
    @derived      = pick_links(links, partners, "derived_from", :to)   # what came out of this file
    @photos       = pick_links(links, partners, "photo_of",     :to)   # pictures OF this file
    @depicts      = pick_links(links, partners, "photo_of",     :from) # what this picture shows
    # ONE ThumbnailMap FOR THE PHOTO CELLS, the shape projects/_photos already uses. `for`
    # backfills on a GET, bounded at BACKFILL_LIMIT — its documented door contract, not a new
    # liberty — and this list is at most the number of photos of one file.
    @link_thumbs = Maker::Previews::ThumbnailMap.for(current_user, @photos.map(&:node_id))
```

and, in the private section beside `name_key`:

```ruby
  # The live partner nodes of `links` for one kind, where `@node` is the named END of the pair.
  # `end_` is :from when @node is the link's from_node_id (so the partner is its `to`), and :to
  # when it is the to_node_id. Nothing here queries — `partners` is the one lookup #show made.
  def pick_links(links, partners, kind, end_)
    mine, theirs = end_ == :from ? %i[from_node_id to_node_id] : %i[to_node_id from_node_id]
    links.filter_map { |l|
      partners[l.public_send(theirs)] && [ l, partners[l.public_send(theirs)] ] if
        l.kind == kind && l.public_send(mine) == @node.node_id
    }
  end
```

Each list is therefore `[[link, node], …]` — the view needs the link's `id` for the Remove button and the node for the name and href.

Note `@photos.map(&:node_id)` above must become `@photos.map { |_l, n| n.node_id }`; write it that way.

- [ ] **Step 7: the partial.** Create `app/views/files/_connections.html.erb`:

```erb
<%#
  WHERE THIS FILE CAME FROM AND WHAT CAME OUT OF IT (stage 4, S4-8; stories 3.2 and 3.3). Four
  lists off ONE query in FilesController#show, each already reduced to live partners — a link whose
  other end is a tombstone is not rendered here and is destroyed later by Maker::AttachmentReaper
  (§14a: liveness is a read-time question, never a property of the row).

  THE PANEL RENDERS EVEN WITH NOTHING IN IT, unlike projects/_photos. A file with no lineage is
  exactly the file whose page has to offer "This came from …"; the two doors ARE the panel's
  content in that state, and hiding them until a link exists would make the first link unreachable
  from the app.

  `section.connections-panel`, not `section.panel` — the file page's own sections (.notes-panel,
  .history-panel) are page classes, and `.panel` is a COMPONENT whose selector belongs to
  components.css alone (design-system.md rule 3).
%>
<section class="connections-panel">
  <h2>Connected</h2>

  <% if @derived_from.any? %>
    <div class="connection-group connections-derived-from">
      <h3 class="muted">This came from</h3>
      <% @derived_from.each do |link, node| %>
        <div class="connection-row">
          <%= link_to node.name, file_path(node.node_id) %>
          <%= button_to "×", file_link_path(link), method: :delete,
                params: { from: @node.node_id }, class: "chip-x",
                form: { data: { turbo_confirm: "Unlink #{node.name}?" } },
                "aria-label": "Unlink #{node.name}" %>
        </div>
      <% end %>
    </div>
  <% end %>

  <% if @derived.any? %>
    <div class="connection-group connections-derived">
      <h3 class="muted">Made from this</h3>
      <% @derived.each do |link, node| %>
        <div class="connection-row">
          <%= link_to node.name, file_path(node.node_id) %>
          <%= button_to "×", file_link_path(link), method: :delete,
                params: { from: @node.node_id }, class: "chip-x",
                form: { data: { turbo_confirm: "Unlink #{node.name}?" } },
                "aria-label": "Unlink #{node.name}" %>
        </div>
      <% end %>
    </div>
  <% end %>

  <% if @photos.any? %>
    <%# Its own `thumbs` controller, the same reason projects/_photos carries one: this grid sits
        outside any polling wrapper, and its cells are the only ones on this page. %>
    <div class="connection-group connections-photos" data-controller="thumbs"
         data-thumbs-url-value="<%= thumbnails_files_path %>">
      <h3 class="muted">Photos of this file</h3>
      <% @photos.each do |link, node| %>
        <div class="connection-row">
          <%= link_to file_path(node.node_id), class: "photo-cell file-cell", title: node.name,
                      data: thumb_cell_data(node.node_id, "IMG") do %>
            <%= render "files/thumb", thumb: @link_thumbs.thumb(node.node_id), ext_label: "IMG" %>
          <% end %>
          <%= button_to "×", file_link_path(link), method: :delete,
                params: { from: @node.node_id }, class: "chip-x",
                form: { data: { turbo_confirm: "Remove this photo link?" } },
                "aria-label": "Remove the link to #{node.name}" %>
        </div>
      <% end %>
    </div>
  <% end %>

  <% if @depicts.any? %>
    <div class="connection-group connections-depicts">
      <h3 class="muted">This is a photo of</h3>
      <% @depicts.each do |link, node| %>
        <div class="connection-row">
          <%= link_to node.name, file_path(node.node_id) %>
          <%= button_to "×", file_link_path(link), method: :delete,
                params: { from: @node.node_id }, class: "chip-x",
                form: { data: { turbo_confirm: "Unlink #{node.name}?" } },
                "aria-label": "Unlink #{node.name}" %>
        </div>
      <% end %>
    </div>
  <% end %>

  <%#
    THE TWO DOORS. Both post to the same endpoint with a different `kind`, and the DIRECTION is
    Files::LinksController's to decide — see its class comment.

    `form_with url:` WITH NO model:/scope: HAS A BLANK object_name, which is safe for the flat
    fields below and would NOT be for a fields_for (§14d: it interpolates brackets and Rack parses
    the result to a literal "[x]" key). Keep these flat, and keep file_page_test.rb's assertion on
    the rendered field names.
  %>
  <details class="composer">
    <summary class="btn small">This came from…</summary>
    <%= form_with url: file_links_path(@node.node_id), method: :post, class: "link-form",
                  data: { turbo: false } do |f| %>
      <%= f.hidden_field :kind, value: "derived_from" %>
      <%= render "shared/folder_field", name: "other_node_id", mode: "file",
                 children_url: library_children_path, create_url: library_folders_path,
                 root_label: "Choose the source file…" %>
      <%= f.submit "Link", class: "btn small" %>
    <% end %>
  </details>

  <details class="composer">
    <summary class="btn small">Add a photo of this</summary>
    <%= form_with url: file_links_path(@node.node_id), method: :post, class: "link-form",
                  data: { turbo: false } do |f| %>
      <%= f.hidden_field :kind, value: "photo_of" %>
      <%= render "shared/folder_field", name: "other_node_id", mode: "file",
                 extensions: Maker::FileAttachment::IMAGE_EXTS,
                 children_url: library_children_path, create_url: library_folders_path,
                 root_label: "Choose a photo…" %>
      <%= f.submit "Add photo", class: "btn small" %>
    <% end %>
  </details>
</section>
```

Render it from `app/views/files/show.html.erb` immediately **before** the notes panel (`:382`), so a file's records read outward-in — what it is connected to, then what you wrote about it:

```erb
<%= render "files/connections" %>
```

- [ ] **Step 8: the picker's extension filter.** `lib/file_chooser.js` has supported `extensions` since it was written (`:36`, `:223-224`, `normalizeExtensions` at `:406`); only the Stimulus wrapper and the partial lack the plumbing. In `app/javascript/controllers/filechooser_controller.js`, add to `static values`:

```js
    // WHICH FILES THE PICKER OFFERS, forwarded to lib/file_chooser.js, which has always accepted it
    // (the addon SDK's `pickFile` passes one). Stimulus parses an Array value from JSON, so the
    // partial writes `[...].to_json`. Absent means no filtering, which is every existing caller.
    extensions: Array,
```

and in `#open`'s `new FileChooser({…})`:

```js
      extensions: this.hasExtensionsValue && this.extensionsValue.length ? this.extensionsValue : null,
```

In `app/views/shared/_folder_field.html.erb`, add the local and the data attribute (documenting it in the Locals block):

```erb
    extensions:   optional Array of extensions the picker offers ("svg" or ".SVG"; default: all)
```
```ruby
  extensions   = local_assigns.fetch(:extensions, nil)
```
```ruby
        filechooser_extensions_value: extensions&.to_json,
```

`tag.span` drops a nil data value, so every existing caller renders byte-identically.

- [ ] **Step 9: the styles.** Append to `app/assets/stylesheets/pages/files.css`, after the `.chip-x:hover` block (`:~54`) so the reused `.chip-x` sits beside its other tenants:

```css
  /* --- Connected files (stage 4, S4-8), on files/show. `.connections-panel` follows
     `.notes-panel` above: a PAGE class, because `.panel` is a component and components.css owns
     that selector alone (design-system.md rule 3). The rows WRAP rather than squashing, which is
     rule 11's requirement at 375px — a long library name plus a Remove button has no business
     pushing the page sideways. */
  .connections-panel { margin-top: 28px; border-top: 1px solid var(--line); padding-top: 16px; }
  .connections-panel h2 { font-size: 16px; margin: 0 0 12px; }
  .connections-panel h3 { font-size: 13px; font-weight: 500; margin: 0 0 6px; }
  .connection-group { margin-bottom: 14px; }
  .connections-photos .connection-group,
  .connections-photos { display: block; }
  .connection-row { display: flex; align-items: center; gap: 6px; flex-wrap: wrap;
    overflow-wrap: anywhere; margin-bottom: 4px; }
  .connections-photos .connection-row { display: inline-flex; vertical-align: top; margin-right: 8px; }
  .connections-photos .photo-cell { display: block; width: 96px; }
  .connections-panel details.composer { margin-top: 10px; }
```

- [ ] **Step 10: the door's own tests.** Create `test/integration/web/file_links_test.rb`:

```ruby
require "test_helper"

module Web
  # Files::LinksController (stage 4, S4-8): one door, two kinds, and the DIRECTION decided by the
  # server from `kind` rather than posted by the form — which is the property that makes an
  # inverted link unreachable rather than merely unlikely.
  class FileLinksTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "fl-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @subject = file!("n-subject", "lid.stl")
      @source  = file!("n-source", "lid.lbrn2")
      @photo   = file!("n-photo", "cut.png")
    end

    def file!(id, name)
      @user.nodes.create!(node_id: id, name:, kind: "file", mtime: 1_000_000_000, size: 10)
    end

    test "derived_from points FROM the page you are on TO the file you picked" do
      post file_links_path(@subject.node_id),
           params: { kind: "derived_from", other_node_id: @source.node_id }
      assert_redirected_to file_path(@subject.node_id)
      link = @user.maker_file_links.sole
      assert_equal [ @subject.node_id, @source.node_id, "derived_from" ],
                   [ link.from_node_id, link.to_node_id, link.kind ]
    end

    # THE REVERSAL IS THE WHOLE REASON THE DOOR TAKES `kind` AND NOT `from`/`to`: a photo_of's
    # subject is the file being DEPICTED, so the picked image is the link's FROM.
    test "photo_of points FROM the picked image TO the page you are on" do
      post file_links_path(@subject.node_id),
           params: { kind: "photo_of", other_node_id: @photo.node_id }
      link = @user.maker_file_links.sole
      assert_equal [ @photo.node_id, @subject.node_id, "photo_of" ],
                   [ link.from_node_id, link.to_node_id, link.kind ]
    end

    test "a photo_of whose target is not an image is refused by name, not silently accepted" do
      assert_no_difference "Maker::FileLink.count" do
        post file_links_path(@subject.node_id),
             params: { kind: "photo_of", other_node_id: @source.node_id }
      end
      assert_equal "Only an image can be a photo of a file.", flash[:alert]
    end

    test "an unknown kind, a directory, a tombstone and another user's file are all refused" do
      dir = @user.nodes.create!(node_id: "d-x", name: "x", kind: "dir")
      @user.nodes.create!(node_id: "n-tomb", name: "t.stl", kind: "file", deleted: true)
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: "n-theirs", name: "theirs.stl", kind: "file")

      assert_no_difference "Maker::FileLink.count" do
        post file_links_path(@subject.node_id), params: { kind: "inspired_by", other_node_id: @source.node_id }
        post file_links_path(@subject.node_id), params: { kind: "derived_from", other_node_id: dir.node_id }
        post file_links_path(@subject.node_id), params: { kind: "derived_from", other_node_id: "n-tomb" }
        post file_links_path(@subject.node_id), params: { kind: "derived_from", other_node_id: "n-theirs" }
        post file_links_path("n-theirs"), params: { kind: "derived_from", other_node_id: @source.node_id }
      end
    end

    test "linking the same pair twice succeeds without raising" do
      2.times do
        post file_links_path(@subject.node_id),
             params: { kind: "derived_from", other_node_id: @source.node_id }
        assert_response :redirect
      end
      assert_equal 1, @user.maker_file_links.count
    end

    test "a file cannot be linked to itself" do
      assert_no_difference "Maker::FileLink.count" do
        post file_links_path(@subject.node_id),
             params: { kind: "derived_from", other_node_id: @subject.node_id }
      end
      assert_match(/same file/, flash[:alert])
    end

    test "the JSON door answers 201 with the row's id, and 422 with a sentence" do
      post file_links_path(@subject.node_id), as: :json,
           params: { kind: "derived_from", other_node_id: @source.node_id }
      assert_response :created
      assert_equal @user.maker_file_links.sole.id, response.parsed_body["id"]

      post file_links_path(@subject.node_id), as: :json,
           params: { kind: "derived_from", other_node_id: "nope" }
      assert_response :unprocessable_entity
      assert_equal "Pick a file in your library.", response.parsed_body["error"]
    end

    test "destroy removes the link and returns to the page the button was on" do
      link = @user.maker_file_links.create!(from_node_id: @subject.node_id,
                                            to_node_id: @source.node_id, kind: "derived_from")
      delete file_link_path(link), params: { from: @source.node_id }
      assert_redirected_to file_path(@source.node_id)
      assert_equal 0, @user.maker_file_links.count
    end

    test "another user's link cannot be destroyed" do
      other = User.create!(email: "o2-#{SecureRandom.hex(4)}@example.com")
      link = other.maker_file_links.create!(from_node_id: "a", to_node_id: "b", kind: "photo_of")
      assert_raises(ActiveRecord::RecordNotFound) { delete file_link_path(link) }
    end

    test "both actions require a session" do
      delete destroy_user_session_path
      assert_no_difference "Maker::FileLink.count" do
        post file_links_path(@subject.node_id), params: { kind: "derived_from", other_node_id: @source.node_id }
      end
      assert_redirected_to new_user_session_path
    end
  end
end
```

- [ ] **Step 11: run, expect PASS.**

```bash
bin/rails test test/integration/web/file_page_test.rb test/integration/web/file_links_test.rb \
               test/stimulus_hygiene_test.rb test/css_hygiene_test.rb \
               test/integration/web/notes_test.rb test/system/file_chooser_test.rb
```
→ 0 failures. `stimulus_hygiene_test.rb` is in the list because Step 8 touches a Stimulus controller (no new identifier, so it must stay green rather than change); `css_hygiene_test.rb` because Step 9 appends to a page sheet and must not redeclare a component selector; `file_chooser_test.rb` because Step 8 touches the shared chooser.

- [ ] **Step 12: mutation checks. Report all six outputs.**
  - (i) In `LinksController#create`, drop the `photo_of` swap (always `[subject, other]`) → `file_links_test.rb`'s "photo_of points FROM the picked image" FAILS on the pair.
  - (ii) In `FilesController#show`, change `current_user.nodes.present` to `current_user.nodes` for `partners` → `file_page_test.rb`'s "a link whose other end is a tombstone" FAILS (`.connection-row` count 1, expected 0).
  - (iii) Drop the `photo_of` role refusal → "a photo_of whose target is not an image is refused" FAILS (a link is created).
  - (iv) In `_connections.html.erb`, change the `photo_of` door's hidden field to `derived_from` → "the hand doors post flat field names" FAILS on the `photo_of` value assertion.
  - (v) In `_folder_field.html.erb`, drop `filechooser_extensions_value` → "the photo door's picker is filtered to the image vocabulary" FAILS (`count 1` → `0`).
  - (vi) In `pages/files.css`, rename `.connections-panel` to `.panel` → `css_hygiene_test.rb` FAILS with `pages/files.css redeclares component selector(s) [".panel"]`. Restore each (clear `tmp/cache/bootsnap*` after the equal-length ones); PASS.

- [ ] **Step 13: commit.**

```bash
git add app/controllers/files_controller.rb app/controllers/files/links_controller.rb config/routes.rb \
        app/views/files/show.html.erb app/views/files/_connections.html.erb \
        app/views/shared/_folder_field.html.erb app/javascript/controllers/filechooser_controller.js \
        app/models/maker/file_attachment.rb app/assets/stylesheets/pages/files.css \
        test/integration/web/file_page_test.rb test/integration/web/file_links_test.rb
git commit -m "A file page says where the file came from, what came out of it and what it looks like"
```

---

### Task C: the two automatic writers

Starts when A and B have committed (it writes A's model through B's door).

**Files:**
- Modify: `app/controllers/tools/addons_controller.rb`, `app/views/files/_measure.html.erb`, `app/javascript/controllers/measure_controller.js`
- Test: `test/controllers/tools/addons_controller_test.rb`, `test/system/measure_export_test.rb`

- [ ] **Step 1: the failing addon-save test.** Append to `test/controllers/tools/addons_controller_test.rb` (find its existing save-door class and its fixture helpers first; the case below needs a signed-in `@user` and the `fixture` addon source the file already stubs — reuse them rather than building a second stub):

```ruby
    # LINEAGE FROM A GENERATOR (stage 4, S4-8; story 3.2). A bundle's `data` is opaque JSON this
    # app stores unexamined, with ONE documented convention: the openscad bundle writes the node id
    # of the .scad the maker picked as `data["node_id"]` (chaim354/tinkerex-addons,
    # addons/openscad/editor.js#stateData — probed 2026-09-07). The boxes and generators bundles
    # write `{generator, params}` and no node id, so the key cannot collide with theirs.
    test "a save whose data names a source file links every output to it" do
      source = @user.nodes.create!(node_id: "n-scad", name: "washer.scad", kind: "file",
                                   mtime: 1_000_000_000, size: 20)

      post tools_addon_files_path("fixture"), params: {
        name: "washer", data: { node_id: source.node_id, source_name: "washer.scad" }.to_json,
        files: [ { name: "washer.3mf", content_type: "model/3mf", body: "PK\x03\x04" } ].to_json
      }

      output = @user.maker_addon_states.last.files.sole
      link = @user.maker_file_links.sole
      assert_equal [ output.node_id, source.node_id, "derived_from" ],
                   [ link.from_node_id, link.to_node_id, link.kind ]
    end

    # THE VALUE IS USER-SUPPLIED JSON AND IS RESOLVED, NEVER TRUSTED. A bundle that starts writing
    # `node_id` to mean something else therefore writes NO links rather than wrong ones.
    test "a data node_id that is not this user's live file writes no link" do
      other = User.create!(email: "x-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: "n-theirs", name: "theirs.scad", kind: "file")
      @user.nodes.create!(node_id: "n-tomb", name: "old.scad", kind: "file", deleted: true)
      @user.nodes.create!(node_id: "d-dir", name: "dir", kind: "dir")

      [ "n-theirs", "n-tomb", "d-dir", "never-existed", "" ].each_with_index do |id, i|
        post tools_addon_files_path("fixture"), params: {
          name: "w#{i}", data: { node_id: id }.to_json,
          files: [ { name: "w#{i}.3mf", content_type: "model/3mf", body: "PK\x03\x04" } ].to_json
        }
      end
      assert_equal 0, @user.maker_file_links.count
    end

    # A BOXES SAVE CARRIES `generator`, NOT `node_id`, AND MUST BE UNAFFECTED.
    test "a save whose data names a bundled generator writes no link" do
      post tools_addon_files_path("fixture"), params: {
        name: "box", data: { generator: "hex_cell_holder", params: { n: 3 } }.to_json,
        files: [ { name: "box.svg", content_type: "image/svg+xml", body: "<svg/>" } ].to_json
      }
      assert_equal 0, @user.maker_file_links.count
    end

    # A REVISION REWRITES THE SAME NODE (LibraryOutput#upsert_file!), so the second save meets its
    # own link. Already the fact it states; nothing to do, and nothing to raise.
    test "re-saving the same design does not raise on its own link" do
      source = @user.nodes.create!(node_id: "n-scad2", name: "plate.scad", kind: "file",
                                   mtime: 1_000_000_000, size: 20)
      2.times do
        post tools_addon_files_path("fixture"), params: {
          name: "plate", state_id: @user.maker_addon_states.last&.id, data: { node_id: source.node_id }.to_json,
          files: [ { name: "plate.3mf", content_type: "model/3mf", body: "PK\x03\x04" } ].to_json,
          replace: "1"
        }
        assert_response :redirect
      end
      assert_equal 1, @user.maker_file_links.count
    end
```

**Read the file's existing save cases before writing these** — the wire shape (`files` as JSON vs multipart parts, the `replace`/`onReplace` 409 flow) is `parse_files`' business and this file already exercises it; copy whichever spelling its own save tests use rather than the sketch above.

- [ ] **Step 2: run, expect FAIL.** The four cases fail on `Maker::FileLink.count` being 0 where 1 is expected (and the last on a `RecordNotUnique` if the guard is written naively).

- [ ] **Step 3: the OpenSCAD writer.** In `app/controllers/tools/addons_controller.rb#create`, after `attach_addon_files_to_current_project(addon_files)` (`:539`) and **before** the eager nudge:

```ruby
      record_source_links(state, addon_files)
```

and in the private section, beside `owned_destinations`:

```ruby
    # THE LINEAGE OF A GENERATED FILE (stage 4, S4-8; story 3.2). Until now a tool's output knew
    # which SAVED ITEM produced it (maker_addon_files) and nothing knew which of the maker's OWN
    # files it was generated from — so a .scad and its 3MF sat in the library as strangers.
    #
    # ONE DOCUMENTED CONVENTION, PROBED RATHER THAN ASSUMED. `data` is opaque JSON this app stores
    # unexamined (#parse_data), and the openscad bundle writes the node id of the .scad the maker
    # picked as `data["node_id"]`, beside `source_name` (chaim354/tinkerex-addons,
    # addons/openscad/editor.js#stateData, 2026-09-07). The boxes and generators bundles write
    # `{generator, params}` and no node id at all, so this key cannot collide with theirs. This is
    # the FIRST server-side reader of any bundle key — §14c's compatibility promise is why it reads
    # one key and refuses nothing.
    #
    # THE VALUE IS RESOLVED, NEVER TRUSTED: it arrives as user-supplied JSON, so a link is written
    # only when it names a LIVE FILE THIS USER OWNS. One query. A bundle that starts spelling
    # `node_id` differently therefore writes no links rather than wrong ones — the safe direction
    # for a fact a page will present as true.
    def record_source_links(state, addon_files)
      source_id = state.data.is_a?(Hash) ? state.data["node_id"].to_s : ""
      return if source_id.blank?
      return unless current_user.nodes.present.exists?(node_id: source_id, kind: "file")

      addon_files.each do |f|
        next if f.node_id == source_id

        current_user.maker_file_links.create!(from_node_id: f.node_id, to_node_id: source_id,
                                              kind: "derived_from")
      rescue ActiveRecord::RecordNotUnique
        # A REVISION REWRITES THE SAME NODE (LibraryOutput#upsert_file!), so the second save of one
        # design meets its own link. The row already states the fact; there is nothing to add and
        # nothing to report. Rescued per file rather than around the loop so one collision does not
        # skip the outputs after it.
      end
    end
```

- [ ] **Step 4: run, expect PASS.** `bin/rails test test/controllers/tools/addons_controller_test.rb` → 0 failures.

- [ ] **Step 5: the Measure save's failing claim.** Append to `test/integration/web/file_page_test.rb` (Task B owns that file; if it has moved under you, re-anchor on its last test rather than a line number):

```ruby
    test "the Measure view carries the source node and the links endpoint for its save" do
      node = @user.nodes.create!(node_id: "n-plate2", name: "plate.lbrn2", kind: "file",
                                 mtime: 1_000_000_000, size: 90,
                                 content_hash: "h-plate2", current_version_id: "v-plate2")
      get file_path(node.node_id)
      assert_select ".measure-view[data-measure-source-node-id-value=?]", node.node_id
      assert_select ".measure-view[data-measure-link-url-value=?]", file_links_path("__ID__")
    end
```

- [ ] **Step 6: the two values.** In `app/views/files/_measure.html.erb`, inside the value block S4-3 added:

```erb
     <%#
       LINEAGE FOR A SAVE (stage 4, S4-8; story 3.2). Everything Measure saves is DERIVED from this
       file, so the save records that as it lands — the maker who opens the export a month later is
       one click from the .lbrn2 it came out of.

       `__ID__` IS A TEMPLATE THE SERVER WRITES, the same idiom projects/_repo_browser.html.erb
       uses for a file row's href: the new node's id does not exist until the upload answers, and
       this module must not learn a route. lib/file_chooser.js documents the convention.
     %>
     data-measure-source-node-id-value="<%= @node.node_id %>"
     data-measure-link-url-value="<%= file_links_path("__ID__") %>"
```

- [ ] **Step 7: the writer.** In `app/javascript/controllers/measure_controller.js`, add the two values to `static values` (`sourceNodeId: String, linkUrl: String`) and change `saveAll` to collect the ids and record them:

```js
  async saveAll(files, button) {
    const previous = button.textContent
    button.disabled = true
    button.textContent = "Saving…"
    try {
      let last = null
      const saved = []
      for (const file of files) {
        last = await this.uploadOne(new File([ file.body ], file.name, { type: "image/svg+xml" }))
        saved.push(last.nodeId)
      }
      // THE LINEAGE, WRITTEN BY THE SAVE THAT CREATED IT (stage 4, S4-8). A second request rather
      // than a parameter on the upload doors: those doors serve every uploader in the app, and one
      // extra POST to the endpoint the file page's own "This came from…" control already uses is
      // smaller than a link concern on two general write paths.
      //
      // IT CANNOT FAIL THE SAVE. The bytes are already on the share; a link that did not land is
      // repairable with the hand control on that very file's page, so this logs and says nothing.
      // Reporting it would tell a maker their save failed when it did not.
      await this.recordSources(saved)
      this.setStatus(last?.notice || `Saved ${files.length === 1 ? files[0].name : `${files.length} sheets`}.`)
    } catch (e) {
      console.warn("[measure] save refused:", e)
      this.setStatus(e.message)
    } finally {
      button.disabled = false
      button.textContent = previous
    }
  }

  async recordSources(nodeIds) {
    if (!this.hasSourceNodeIdValue || !this.hasLinkUrlValue) return
    for (const id of nodeIds) {
      try {
        await postJSON(this.linkUrlValue.replace("__ID__", encodeURIComponent(id)),
                       { kind: "derived_from", other_node_id: this.sourceNodeIdValue })
      } catch (e) {
        console.warn("[measure] could not record where this came from:", e)
      }
    }
  }
```

`postJSON` is already exported from `lib/chunk_upload` (it is what `uploadChunkFile` uses); add it to that import line rather than writing a second `fetch` with its own CSRF handling.

- [ ] **Step 8: the browser test.** Append to `test/system/measure_export_test.rb` (its setup stands up a real share library holding `sample.lbrn2`, so the save really lands and really becomes a node):

```ruby
  # THE ROUND TRIP REMEMBERING ITSELF (story 3.2): the export knows the file it came out of, and
  # the source's page lists it back. Both directions off ONE row, which is the point of the table.
  test "a saved export records where it came from, and both pages say so" do
    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10
    find(".measure-stage circle.measure-contour").click
    assert_text "1 part"

    find("[data-measure-target='saveSvgButton']").click
    assert_text "sample-parts.svg", wait: 15

    export = @user.nodes.present.find_by!(name: "sample-parts.svg")
    link = @user.maker_file_links.sole
    assert_equal [ export.node_id, @sample_id, "derived_from" ],
                 [ link.from_node_id, link.to_node_id, link.kind ]

    visit file_path(export.node_id)
    assert_selector ".connections-derived-from a", text: "sample.lbrn2"
    visit file_path(@sample_id)
    assert_selector ".connections-derived a", text: "sample-parts.svg"
    assert_no_console_errors
  end
```

- [ ] **Step 9: run, expect PASS.**

```bash
bin/rails test test/integration/web/file_page_test.rb test/controllers/tools/addons_controller_test.rb
bin/rails test test/system/measure_export_test.rb test/system/measure_print_test.rb
```
→ 0 failures.

- [ ] **Step 10: mutation checks. Report all four outputs.**
  - (i) In `record_source_links`, drop the `current_user.nodes.present.exists?` guard → "a data node_id that is not this user's live file writes no link" FAILS (`Expected: 0, Actual: 5`).
  - (ii) In `record_source_links`, swap `from_node_id` and `to_node_id` → "a save whose data names a source file links every output to it" FAILS on the triple.
  - (iii) In `measure_controller.js#recordSources`, delete the `postJSON` call → the browser test FAILS at `@user.maker_file_links.sole` (`ActiveRecord::RecordNotFound`).
  - (iv) In `_measure.html.erb`, drop `data-measure-source-node-id-value` → `file_page_test.rb`'s "the Measure view carries the source node" FAILS, **and the browser test still passes** — report both, because that pair is what shows the request-level claim is the one carrying the attribute's weight. Restore; PASS.

- [ ] **Step 11: commit.**

```bash
git add app/controllers/tools/addons_controller.rb app/views/files/_measure.html.erb \
        app/javascript/controllers/measure_controller.js \
        test/controllers/tools/addons_controller_test.rb test/integration/web/file_page_test.rb \
        test/system/measure_export_test.rb
git commit -m "A generated file records the file it was generated from, without being asked"
```

---

### Task E: the three shared sweeps

Starts when B, C and D have all committed. **This task is the only writer of these three files**, which is why both features' fixtures land here in one pass rather than being split across two tasks that would collide (`.claude/commands/execute-plan.md`: batch by file).

**Files:** `test/integration/web/page_query_budget_test.rb`, `test/integration/web/template_hygiene_test.rb`, `test/system/shell_test.rb`

- [ ] **Step 1: the query budget for the file page.** Append to `Web::PageQueryBudgetTest` beside the existing `files#show` case (`:642`):

```ruby
    # THE CONNECTED PANEL IS TWO QUERIES FOR ANY NUMBER OF LINKS — one `touching` read and one
    # `nodes.present` lookup over every partner — plus one ThumbnailMap for the photo cells.
    # Written per-row (a `nodes.find_by` inside the view's loop, which is the obvious spelling)
    # this is invisible on a two-link fixture and a page-load per photo on a real one.
    test "files#show does not grow with the number of connected files" do
      subject = node!("cn-subject", "lid.stl")
      path = file_path(subject.node_id)
      add = lambda do |prefix, count|
        count.times do |i|
          src = node!("#{prefix}s#{i}", "#{prefix}s#{i}.lbrn2")
          pic = node!("#{prefix}p#{i}", "#{prefix}p#{i}.png")
          @user.maker_file_links.create!(from_node_id: subject.node_id, to_node_id: src.node_id,
                                        kind: "derived_from")
          @user.maker_file_links.create!(from_node_id: pic.node_id, to_node_id: subject.node_id,
                                        kind: "photo_of")
        end
      end
      assert_constant_queries(path, -> { add.call("cs", SMALL) }, -> { add.call("cl", LARGE - SMALL) },
                              "files#show (connections)")
    end
```

`node!` (`:85`) is what gives each row both content columns, which is what makes the ThumbnailMap's preview query actually run — without it the map short-circuits and this budget would be measuring a path that never executes (the header comment there says so).

- [ ] **Step 2: the query budget for search.** Extend the existing `search#index` case's `add` lambda (`:747-757`) with the two new kinds, and extend its comment from "FIVE kinds" to seven:

```ruby
          # Stage 4, S4-8: a note on a live file, and a folder — the two groups added there. The
          # notes group is the one with a second query after its cap (the file names for the rows
          # it renders), so growing it is what would show a per-row name lookup.
          noted = @user.nodes.create!(node_id: "search-n-#{id}", name: "lamp-noted-#{id}.stl", kind: "file")
          @user.maker_notes.create!(node_id: noted.node_id, body: "<div>lamp note #{id}</div>")
          @user.nodes.create!(node_id: "search-d-#{id}", name: "lamps #{id}", kind: "dir")
```

- [ ] **Step 3: run the budgets, expect PASS.** `bin/rails test test/integration/web/page_query_budget_test.rb` → 0 failures. **Report the two numbers each new case prints on failure** by running the mutation in step 7(i) first if you want to see them.

- [ ] **Step 4: the template sweep's fixtures.** In `test/integration/web/template_hygiene_test.rb`'s `setup`, after the S4-2 `update_columns` block (`:~270`):

```ruby
      # STAGE 4, S4-8: THE CONNECTED PANEL'S FOUR POPULATED BRANCHES, or files/_connections renders
      # only its two doors and the lists' markup is never swept. `n-stl` is the page the `pages` map
      # visits as "file detail (3d)", so it must sit at BOTH ends of a derived_from and be the
      # subject of a photo_of; `n-photo` is where the fourth branch ("This is a photo of") renders,
      # and it is visited below.
      @user.maker_file_links.create!(from_node_id: "n-stl", to_node_id: "n-bak", kind: "derived_from")
      @user.maker_file_links.create!(from_node_id: "n-generated", to_node_id: "n-stl", kind: "derived_from")
      @user.maker_file_links.create!(from_node_id: "n-photo", to_node_id: "n-stl", kind: "photo_of")
      # A NOTE MATCHING THE SWEEP'S OWN QUERY ("lamp"), so the search page renders the Notes arm of
      # shared/_result_group. The Folders arm needs no fixture: `project_folder_rows!` above already
      # minted a `desk-lamp` directory, which the same query matches.
      @user.maker_notes.create!(node_id: "n-stl", body: "<div>Cut on the lamp jig.</div>")
```

and add one page to the `pages` map (`:312-320`), beside the other `file detail` entries:

```ruby
        # STAGE 4, S4-8: the photo's OWN page, which is the only place _connections' fourth branch
        # ("This is a photo of") renders — n-stl above covers the other three.
        "file detail (photo)" => file_path("n-photo"),
```

- [ ] **Step 5: run the sweep, expect PASS.** `bin/rails test test/integration/web/template_hygiene_test.rb` → 2 runs, 0 failures. Its coverage assertion is per TEMPLATE, so `files/_connections.html.erb` must now appear in `rendered`; confirm by temporarily removing the `render "files/connections"` line and checking the assertion names it (that is mutation (ii) below).

- [ ] **Step 6: the phone sweep.** In `test/system/shell_test.rb`'s "no page scrolls sideways at phone width", after the BOM-line fixtures (`:~133`):

```ruby
    # STAGE 4, S4-8: the Connected panel populated on the page the sweep already visits, and a note
    # matching the sweep's own search query — or the overflow check measures the EMPTY branch of
    # both new surfaces and says nothing about the two layouts this slice adds. `long` is the file
    # with the deliberately long name, which is exactly what a `.connection-row` has to wrap.
    photo = create_node!(@user, node_id: SecureRandom.uuid, kind: "file",
                         name: "workshop bench photo, second attempt.png")
    @user.maker_file_links.create!(from_node_id: long.node_id, to_node_id: kicad.node_id,
                                   kind: "derived_from")
    @user.maker_file_links.create!(from_node_id: photo.node_id, to_node_id: long.node_id,
                                   kind: "photo_of")
    @user.maker_notes.create!(node_id: long.node_id, body: "<div>Second lamp attempt, 40% power.</div>")
```

and inside the sweep loop, beside the existing per-page markers:

```ruby
        if path == file_path(long.node_id)
          # STAGE 4, S4-8: both list branches AND the photo grid are on this page, or the overflow
          # check above measured a panel holding only its two closed composers.
          assert_selector ".connections-derived-from a"
          assert_selector ".connections-photos .photo-cell"
        end
        if path == search_path(q: "lamp")
          assert_selector ".result-group--note .result-sub"
          assert_selector ".result-group--folder a"
        end
```

Read the loop's existing `launched_gerber` / `opened_repo` flag idiom first: those exist because a gated branch can go silently unrun. These two are unconditional assertions inside the loop rather than flags, because the paths are literals in the same list — but if you find yourself gating on anything, add the flag.

- [ ] **Step 7: run the phone sweep, expect PASS.** `bin/rails test test/system/shell_test.rb` → 0 failures.

- [ ] **Step 8: mutation checks. Report all three outputs.**
  - (i) In `files/_connections.html.erb`, replace `partners`-based rendering with a per-row lookup — change the `@photos` loop's `node.name` to `current_user.nodes.find_by(node_id: node.node_id).name` (a deliberate N+1) → `page_query_budget_test.rb`'s "files#show does not grow with the number of connected files" FAILS naming two different counts.
  - (ii) Remove `<%= render "files/connections" %>` from `files/show.html.erb` → `template_hygiene_test.rb`'s coverage assertion FAILS with `files/_connections.html.erb` in the uncovered list.
  - (iii) In `pages/files.css`, remove `flex-wrap: wrap` and `overflow-wrap: anywhere` from `.connection-row` → `shell_test.rb`'s "no page scrolls sideways at phone width" FAILS on `file_path(long.node_id)`. **If it does NOT fail, say so and report the measured `scrollWidth`** — that means the long name is not long enough to overflow at 375px and the fixture, not the rule, needs strengthening (design-system.md rule 11 is the claim being made).

- [ ] **Step 9: commit.**

```bash
git add test/integration/web/page_query_budget_test.rb test/integration/web/template_hygiene_test.rb \
        test/system/shell_test.rb
git commit -m "The budgets, the template sweep and the phone sweep all see the new panel and the new groups"
```

---

### Task F: close-out

- [ ] **Step 1: re-tag the stories** in `docs/user-stories.md`, T3's table. Change only these four rows:
  - **3.2 lineage** → `rough`. New evidence: `maker_file_links` holds a `derived_from` edge, written automatically by Measure's Save-to-library and by an OpenSCAD save whose `data` names the `.scad` it read, and settable by hand from "This came from…" on any file page; both directions render in the Connected panel (S4-8). Remaining friction, stated so it is not read as done: the boxes and generators bundles record a **generator key**, not a node id, so a box's SVG still has no source file to point at; and nothing back-fills the three real lineages that already exist by NAME (`.gbrjob` → layers, zip → members, README links) — those stay computed per request.
  - **3.3 photos** → `rough`. New evidence: `photo_of` attaches a picture to a **file** from that file's own page, and the picture's page says what it shows (S4-8), beside the build-log entry attachment it already had. Remaining: a print run still has no node column, so a photo cannot attach to a print (`maker_print_runs`, out of this stage).
  - **3.4 README links** → unchanged, `rough`, with S4-1's evidence. Say why in the row: S4-8 adds a stored file↔file edge and does **not** touch the computed README link resolution, which is `Maker::Readme`'s and renders on the project page and the repo card as before.
  - **3.5 search** → `rough` (from `missing`). New evidence: a Notes group over `action_text_rich_texts.body`, joined through `maker_notes` and scoped to live files, and a Folders group by name (S4-8). Remaining, both with their reason: **README text is not searched** — it is read through the port at request time with no index, so a per-project read fails `page_query_budget_test.rb`'s constancy-in-N assertion by construction and would put the WAN in a search request on chunk_remote; and **`nodes.storage_path` is not searched** — it is written by the Share and S3 adapters only, so a path LIKE is structurally empty on the main deployment. Both need a stored index, which is a design rather than a group.
  - Update the Coverage table: T3 becomes 7 stories / 1 `works` / 4 `rough` / 1 `missing` / 1 `built-unused`; the **all** row moves to 8 / 28 / 12 / 2. **Recompute from the rows rather than from these numbers** — S4-2 and S4-3 are re-tagging the same file, and the last writer must count what is actually there. Add a line under the table: `Re-measured after S4-8 (2026-09-07): 3.2, 3.3 and 3.5 moved out of missing; 3.4 unchanged and says why.`

- [ ] **Step 2: the overview.** In `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md`, mark the S4-8 row landed with the PR number, and correct the Territory section where this plan diverged from it: the orphan guard needs **no** case for this table (Amendment 1 — say which guards it does owe); README text search is **not** delivered and the reason; a Folders group is delivered in its place; and the OpenSCAD writer keys on the probed `data["node_id"]` convention. Also correct the `Maker::FileLink` shared-interface block: it says "the orphan guard's `maker_connections` case is the model to copy", which is wrong for this table's shape — replace it with the six obligations.

- [ ] **Step 3: the invariants file.** In `docs/invariants/files-preview.md`, add one paragraph to the file-page section:

> **A FILE'S CONNECTIONS ARE ROWS, NOT A COMPUTATION (stage 4, S4-8).** `maker_file_links` holds two kinds — `derived_from` (from the derived file to its source) and `photo_of` (from the picture to the file it shows) — as **bare node-id strings with no foreign key**, and **liveness is answered at read time by `nodes.present`, never by the row**: `FilesController#show` drops a link whose partner is a tombstone, and `Maker::AttachmentReaper` destroys it once that node's undo window closes, from **either** column. That is deliberately unlike the three lineages this page already computes by NAME per request (`.gbrjob` → its layers, a Gerber zip → its members, a README's links), which stay computed because they are properties of the bytes rather than statements a maker made. The direction of a link is decided in `Files::LinksController` from `kind`, never posted, so no door can write one backwards.

Nothing here belongs in CLAUDE.md: all of it binds inside the file page and its table, which is what the area files are for.

- [ ] **Step 4: the docs gate.** `bin/rails test test/docs_hygiene_test.rb` → PASS.

- [ ] **Step 5: the gates.**

```bash
TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci
```

Green on every gate `bin/ci --list-ci` names. **Report the three legs' run counts side by side** — `test` (share), `test-s3`, `test-chunk-remote` — and confirm they are identical. A ±2 assertion / ±1 skip flap is the known nondeterminism (`tinkerex#131`); a structural difference means a test depends on the ambient `LIBRARY_BACKEND` and is a real bug in this slice. The two places that could produce one here: `test/system/measure_export_test.rb` pins share in its own setup (leg-independent by construction — confirm the new case inherits that setup and does not reach `FileLayer.current` itself), and `page_query_budget_test.rb` asserts **constancy**, never a literal, so its new case must not gain a hard-coded count.

- [ ] **Step 6: commit, push, PR, record.**

```bash
git commit -m "S4-8 close-out: the stories re-tagged, the overview corrected, the invariants updated"
```
then `/finish-branch`, then `bin/log arc --from-pr <n>`. The PR body states what was verified (the three legs with their counts, every mutation check with its output) and what was not (the open questions below, plus the two named non-deliveries: README text and path search).

---

## Self-review against the spec (§5's S4-8 row and §7)

| spec item | task |
|---|---|
| `maker_file_links(user_id, from_node_id, to_node_id, kind, created_at)`, unique `(user, from, to, kind)` | A steps 3, 6 (`t.timestamps` — Amendment 6) |
| `kind ∈ %w[derived_from photo_of]`, no FK on node columns, liveness at read time | A step 4; B step 6 |
| a `user_id` index only if the prefix guard permits | A step 3 — **no bare `user_id` index**, it is a strict prefix (Amendment 3); mutation (ii) proves the guard fires |
| model validations at create time only, per §14d's lock warning | A step 4 + **Amendment 2**: no ownership validation at all, per the four siblings' rule; ownership is checked at all three doors instead |
| `User has_many :maker_file_links` | A step 5 |
| the four derived guards | A steps 8–12 — **six**, and why (Amendment 1); the orphan guard is verified to owe nothing |
| `derived_from` written by Save-to-library | C steps 6–8 (a POST to the same door the hand control uses — Amendment 8) |
| `derived_from` written by the OpenSCAD save | C step 3 (`data["node_id"]`, probed — Amendment 7; resolved, never trusted) |
| `derived_from` set by hand, "This came from…", with a Remove | B steps 5, 7 |
| `photo_of` from attaching a photo on a file page | B steps 5, 7, 8 (the existing chooser in file mode, filtered from `ROLE_BY_EXT`) |
| both directions shown on the file pages | B steps 6, 7 (four lists: sources, derived, photos, depicts) |
| live nodes only; a dead node's row dropped and reaped later | B step 6 (`nodes.present` at read); A step 10 (the reaper, from **both** columns) |
| the project Photos panel unchanged | **Amendment 10**, argued rather than left implicit |
| search over note bodies | D step 5 |
| search over README text | **not delivered — Amendment 4**, with the measurement; story 3.5 stays `rough` and says so |
| a Paths group | **not delivered — Amendment 5**; a Folders group lands instead, backend-neutral |
| every new LIKE carries `ESCAPE '\'` | D steps 4, 5; mutation (ii) |
| `files#show` gains links at constant cost | E step 1 (constancy, never a literal) |
| `search#index` constant in N | E step 2 |
| the template sweep renders the populated branches | E steps 4, 5; mutation (ii) |
| `stimulus_hygiene` unaffected | B step 11 — no new controller; the `filechooser` change adds a value, not an identifier |
| the phone sweep visits a file page with the panel populated | E step 6 |
| migration in dev and test, `db/schema.rb` committed | A step 6 |
| every guard mutation-checked with its output reported | A 13 (5), B 12 (6), C 10 (4), D 8 (4), E 8 (3) — **22 in total** |
| close-out re-tags the stories and marks the overview row | F |

## Open questions the implementer must not decide alone

1. **The Folders group is the one addition beyond the spec row's literal text.** The row says "search over note bodies and README text"; story 3.5 says "notes, README text and folder paths". README text is out on a measurement, so without Folders the slice moves one of the story's three asks. Folders is small (one capped query, one count, one `case` arm, two tests) and is the only backend-neutral spelling of the third ask. **If a reviewer prefers strict spec scope, drop Task D steps 4, 6 (the `:folder` arm) and 8(iv) plus the one test — nothing else moves** — and say so in the close-out rather than leaving story 3.5 claiming a half it did not get.
2. **Whether an addon save should link its output to a source at all when the maker did not ask.** `record_source_links` writes a `derived_from` on every OpenSCAD save that names a picked `.scad`. That is the feature, and it is what makes the table useful on day one without any hand work — but it is also the app writing a fact into the maker's library unasked (spec §2 decision 3's spirit), and the only way to withdraw it is the panel's `×`. The alternative is an opt-in the bundle would have to render, which cannot ship from this repo (the bundle is `chaim354/tinkerex-addons`). Raise it rather than quietly changing the default in either direction.
3. **Whether `record_source_links` should also fire for the boxes and generators bundles.** They record `data["generator"]` — a **catalog key**, not a node id — so there is no library file to point at and this slice writes nothing for them. The maker's mental model may well be that a box "came from" the generator; expressing that needs a second kind, or a link whose other end is not a node, and neither belongs in a table whose whole shape is `node_id → node_id`. Named so it is not solved by widening this table on a hunch.
4. **Whether the reaper's "either end" rule should instead null one column.** A link whose source file was deleted forever is currently destroyed, so the derived file's page loses the sentence entirely rather than saying "derived from a file that is gone". Destroying matches every other subject of this sweep and keeps the table free of half-facts; the alternative preserves a breadcrumb at the cost of a nullable column and a render branch. **Do not change it mid-implementation** — Task A step 11's tests pin the current rule, and reversing it later is one migration.
5. **`Maker::Previews::ThumbnailMap.for` on `files#show` makes that GET write** (bounded preview rows and enqueues, `BACKFILL_LIMIT = 100`). That is the map's documented door contract and every project/model page already does it, but `files#show` did not until now, and it is a real change in what viewing a file costs on a library indexed before previews shipped. Reported rather than decided: if it is judged unacceptable, the fix is `from_info` with `backfill: false` and a page that never self-heals its photo thumbnails, not a smaller cap.

**Stated limits, decided rather than open** — do not reopen them mid-implementation, but do report them in the PR body: a link is between two files and there is no third kind; the Connected panel renders even when empty, because its two doors are the only way to make the first link; the OpenSCAD writer reads exactly one bundle key and writes nothing when it resolves to anything but this user's live file; and the `photo_of` picker's extension filter is a convenience, with `Files::LinksController` holding the real refusal (`lib/file_chooser.js:44-56` makes the same distinction for the addon SDK).
