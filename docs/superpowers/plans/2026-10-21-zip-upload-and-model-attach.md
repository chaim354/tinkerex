# Zip upload unpacks models + attach a model to a project — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The top-bar Upload unpacks a `.zip` holding model files into a folder where it was uploaded, and a model can be attached to projects from either end, with a Models panel of cards on the project page.

**Architecture:** Zip: the browser reads the zip with JSZip (`lib/zip_bundle.js`, shared with the Import page), asks a new folders-only endpoint (`Files::UnpacksController`) for a folder map, and uploads each entry through the existing per-file doors; no zip byte reaches Rails. Attach: the existing bundle write (`Maker::AttachToProject`) gains a model-level entry, a read-only `Maker::ProjectModels` derives a project's models on each render, and two small controllers carry attach/detach and the picker. No new table.

**Tech Stack:** Rails 8, Stimulus, importmap, JSZip 3.10.1, Minitest + Capybara/Selenium system tests.

**Specs:** `docs/superpowers/specs/2026-10-20-zip-upload-unpacks-models-design.md`, `docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md`.

**Worktree:** `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/zip-upload-model-attach`, branch `claude/zip-upload-and-model-attach`.

---

## Rules for every implementer (read first)

1. **Running tests.** A bare `bin/rails test` errors without a library path. Run focused files as:
   `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test <files>`.
   System tests: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test <test/system/file.rb>`.
   **Never run the full suite** — the parent session runs it once at the end (parallel full runs share
   one SQLite test DB and collide). A transient `SQLite3::BusyException` from another agent's focused
   run is not your bug: re-run once.
2. **Ruby scripts that edit files:** `LANG=en_US.UTF-8 ruby -Eutf-8:utf-8`. Prefer the Edit tool.
3. **Git:** `git add <explicit paths>` only (never `-A`, never stash). Commit with a pathspec:
   `git commit -F <msgfile> -- <your paths>` — never a bare `git commit`. Write the message to a file
   (zsh runs backticks inside `-m "..."`). End every message with
   `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
4. **`git checkout -- <file>` cannot restore a file your task created.** Before a mutation check on a
   new file, `cp` it to the scratchpad and restore from there with the Edit tool or `cp` back.
   Clear `tmp/cache/bootsnap*` after restoring a mutated Ruby file (`rm -rf tmp/cache/bootsnap*`).
5. **Comment style:** this codebase writes a header comment on every class/partial explaining WHY,
   with a leading CAPITALISED claim. Match it; the code blocks below already carry their comments.
6. **System tests must be mutation-checked** (test/system/README.md): break the behaviour, watch the
   test go red, restore, and record what you broke in a comment in the test file.
7. Selenium cannot read files under `~/Desktop` (macOS TCC). System tests build fixtures in
   `Dir.mktmpdir`, never under the repo.

## Waves (what can run in parallel)

| Wave | Tasks | Why together |
|---|---|---|
| A | 1, 2, 4 | disjoint files |
| B | 3, 5 | 3 needs 1+2; 5 needs 4; disjoint files (only Task 5 touches `config/routes.rb` in this wave) |
| C | 6, 7 | both need 4+5; disjoint files |
| D | 8 (parent session) | full CI, PR, merge, deploy |

## File map

| File | Task | Responsibility |
|---|---|---|
| `app/controllers/files/unpacks_controller.rb` (new) | 1 | folders for an unpack; catalog nudge |
| `config/routes.rb` | 1, 5 | `files/unpack_folder`, `files/unpacked`; model↔project routes, picker |
| `test/integration/web/files_unpack_test.rb` (new) | 1 | endpoint tests |
| `CLAUDE.md` | 1 | "FOUR web doors mint a leaf name" → FIVE |
| `app/javascript/lib/zip_bundle.js` (new) | 2 | read a zip into entries (clutter, wrapper, dedupe) |
| `app/javascript/lib/zip_unpack.js` (new) | 2 | split a selection, unpack, upload the rest, report |
| `config/importmap.rb` | 2 | pin the two libs |
| `app/javascript/controllers/importer_controller.js` | 2 | use `zip_bundle.js` |
| `app/models/maker/file_attachment.rb` | 3 | `MODEL_EXTS` |
| `app/views/layouts/_topbar_upload.html.erb` | 3 | wire both flows |
| `app/javascript/controllers/zip_upload_controller.js` (new) | 3 | share/s3 form takeover for model zips |
| `app/javascript/controllers/uploader_controller.js` | 3 | chunk flow zip branch |
| `test/integration/web/topbar_zip_markup_test.rb` (new) | 3 | markup on both flows |
| `test/system/topbar_zip_upload_test.rb` (new) | 3 | browser: unpack, non-model zip, project root |
| `test/system/uploader_test.rb` | 3 | chunk-flow zip test (skips off chunk_remote) |
| `app/services/maker/attach_to_project.rb` | 4 | `attach_model`, `owners_by_node` |
| `app/services/maker/project_models.rb` (new) | 4 | a project's models, derived |
| `test/services/maker/attach_model_test.rb` (new) | 4 | |
| `test/services/maker/project_models_test.rb` (new) | 4 | |
| `app/controllers/models/projects_controller.rb` (new) | 5 | attach / detach |
| `app/controllers/projects/models_controller.rb` (new) | 5 | the Add-model picker |
| `app/views/projects/models/new.html.erb` (new) | 5 | picker page |
| `test/integration/web/attach_model_to_project_test.rb` (new) | 5 | |
| `app/models/maker/project.rb` | 6 | `models` panel key + label |
| `app/controllers/projects_controller.rb` | 6 | `@project_models`, Linked exclusion, thumbs |
| `app/views/projects/_models.html.erb` (new) | 6 | the panel |
| `app/assets/stylesheets/pages/projects.css` | 6 | card + Detach layout |
| `test/integration/web/project_models_panel_test.rb` (new) | 6 | |
| `app/services/maker/model_project_choices.rb` (new) | 7 | a model's projects row |
| `app/views/models/_projects.html.erb` (new) | 7 | the row |
| `app/views/files/_model_strip.html.erb`, `app/views/files/index.html.erb`, `app/controllers/files_controller.rb` | 7 | strip renders the row |
| `app/views/models/show.html.erb`, `app/controllers/models_controller.rb` | 7 | model page renders the row |
| `test/services/maker/model_project_choices_test.rb` (new), `test/integration/web/model_projects_row_test.rb` (new) | 7 | |

---

### Task 1: The unpack endpoints (`Files::UnpacksController`)

**Files:**
- Create: `app/controllers/files/unpacks_controller.rb`
- Modify: `config/routes.rb` (the `namespace :files do … end` block holding `resources :text_files`)
- Modify: `CLAUDE.md` (the "FOUR web doors mint a leaf name" sentence in §14c)
- Test: `test/integration/web/files_unpack_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/files_unpack_test.rb`:

```ruby
require "test_helper"

module Web
  # THE FOLDERS-ONLY HALF OF A MODEL ZIP UNPACKED BY THE TOP BAR (Files::UnpacksController). The
  # browser half — JSZip, the per-file uploads — is test/system/topbar_zip_upload_test.rb's. PINNED
  # TO A FRESH SHARE LIBRARY: these make real folders through the port, which on the s3 leg is a
  # Forbidden from the stub bucket and on chunk_remote a per-email library provisioning; what is
  # under test is where the folders go and what is refused, not which backend holds them
  # (Maker::LibraryFolder is the one backend-neutral door and has its own tests).
  class FilesUnpackTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      @root = use_fresh_share_library!
      @user = sign_in_web!(User.create!(email: "unpack-#{SecureRandom.hex(4)}@example.com",
                                        password: WEB_PASSWORD, confirmed_at: Time.current))
    end

    def unpack(**body)
      post files_unpack_folder_path(format: :json), params: body.to_json,
                                                    headers: { "CONTENT_TYPE" => "application/json" }
      JSON.parse(response.body)
    end

    def mkdir(name, parent = nil)
      FileLayer.current.mkdir(@user, parent_node_id: parent&.node_id, name:)
    end

    def node(id) = @user.nodes.find_by!(node_id: id)

    test "a folder gets a new folder named after the zip, with every requested subfolder" do
      cad = mkdir("cad")
      body = unpack(parent_node_id: cad.node_id, name: "dragon", dirs: [ "parts/tail", "docs" ],
                    first_model_name: "body.stl")

      assert_response :created
      folder = node(body["folder_node_id"])
      assert_equal [ "dragon", cad.node_id ], [ folder.name, folder.parent_node_id ]
      assert_equal files_path(folder: folder.node_id), body["folder_url"]
      tail = node(body.dig("folder_map", "parts/tail"))
      assert_equal "tail", tail.name
      assert_equal [ "parts", folder.node_id ], [ node(tail.parent_node_id).name, node(tail.parent_node_id).parent_node_id ]
      assert_equal folder.node_id, node(body.dig("folder_map", "docs")).parent_node_id
      assert_equal body["folder_node_id"], body.dig("folder_map", "")
      assert @root.join("cad", "dragon", "parts", "tail").directory?, "the folders are real on the share"
    end

    test "at a project's own folder the zip unpacks where filing puts a model" do
      project = @user.maker_projects.create!(name: "Stargate")
      folder = mkdir("stargate", mkdir("Projects"))
      project.update_column(:folder_node_id, folder.node_id)

      body = unpack(parent_node_id: folder.node_id, name: "iris", dirs: [], first_model_name: "gate.stl")

      assert_response :created
      made = node(body["folder_node_id"])
      assert_equal "iris", made.name
      assert_equal [ "models", folder.node_id ], [ node(made.parent_node_id).name, node(made.parent_node_id).parent_node_id ]
    end

    test "a project's subfolder is used as it is" do
      project = @user.maker_projects.create!(name: "Lamp")
      folder = mkdir("lamp", mkdir("Projects"))
      project.update_column(:folder_node_id, folder.node_id)
      parts = mkdir("parts", folder)

      body = unpack(parent_node_id: parts.node_id, name: "shade", dirs: [], first_model_name: "shade.stl")

      assert_equal parts.node_id, node(body["folder_node_id"]).parent_node_id
    end

    test "a taken name gets the next free number, case-folded, files counting too" do
      cad = mkdir("cad")
      mkdir("Dragon", cad)
      # A FILE, materialised on disk under cad/ by create_node! (it reads @root).
      create_node!(@user, node_id: "n-dragon-2", name: "dragon 2", kind: "file", parent_node_id: cad.node_id,
                          mtime: 1, size: 1)

      body = unpack(parent_node_id: cad.node_id, name: "dragon", dirs: [])

      assert_response :created
      assert_equal "dragon 3", node(body["folder_node_id"]).name
    end

    test "the library root is a destination" do
      body = unpack(name: "benchy", dirs: [])

      assert_response :created
      assert_nil node(body["folder_node_id"]).parent_node_id
    end

    test "an invalid or reserved folder name is refused and makes nothing" do
      assert_no_difference -> { @user.nodes.count } do
        unpack(name: "..", dirs: [])
        assert_response :unprocessable_entity
        unpack(name: ".trash", dirs: [])
        assert_response :unprocessable_entity
      end
    end

    test "a subfolder with a bad segment is left out, so its files fall back to the root" do
      body = unpack(name: "kit", dirs: [ "ok", "../escape", ".hidden/x" ])

      assert_response :created
      assert_equal [ "", "ok" ], body["folder_map"].keys.sort
    end

    test "another user's folder is a 404 and makes nothing" do
      other = User.create!(email: "unpack-other-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      theirs = FileLayer.current.mkdir(other, parent_node_id: nil, name: "theirs")

      assert_no_difference -> { @user.nodes.count } do
        unpack(parent_node_id: theirs.node_id, name: "x", dirs: [])
      end
      assert_response :not_found
    end

    test "finish nudges the model catalog for this user" do
      cad = mkdir("cad")

      assert_enqueued_with(job: Maker::ModelIntakeJob, args: [ { user_id: @user.id } ]) do
        post files_unpacked_path(format: :json), params: { folder_node_id: cad.node_id }.to_json,
                                                 headers: { "CONTENT_TYPE" => "application/json" }
      end
      assert_response :accepted
    end

    test "finish on a folder that is not this user's is a 404 and enqueues nothing" do
      assert_no_enqueued_jobs(only: Maker::ModelIntakeJob) do
        post files_unpacked_path(format: :json), params: { folder_node_id: "nope" }.to_json,
                                                 headers: { "CONTENT_TYPE" => "application/json" }
      end
      assert_response :not_found
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/files_unpack_test.rb`
Expected: errors — `undefined local variable or method 'files_unpack_folder_path'`.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, the block currently reads:

```ruby
  namespace :files do
    resources :text_files, only: %i[new create]
  end
```

Replace it with:

```ruby
  namespace :files do
    resources :text_files, only: %i[new create]
    # A MODEL ZIP UNPACKED BY THE TOP BAR'S UPLOAD (2026-10-21; docs/superpowers/specs/
    # 2026-10-20-zip-upload-unpacks-models-design.md). The browser unzips and uploads each entry
    # through the ordinary doors; these two only make the folders and nudge the catalog, so no zip
    # byte reaches Rails (§15). Two segments, POST only — nothing in `resources :files` matches them.
    post "unpack_folder", to: "unpacks#create", as: :unpack_folder
    post "unpacked",      to: "unpacks#finish", as: :unpacked
  end
```

- [ ] **Step 4: Write the controller**

Create `app/controllers/files/unpacks_controller.rb`:

```ruby
module Files
  # THE FOLDERS A MODEL ZIP UNPACKS INTO, AND THE CATALOG NUDGE AFTER (2026-10-21; spec
  # docs/superpowers/specs/2026-10-20-zip-upload-unpacks-models-design.md).
  #
  # THE SERVER MAKES FOLDERS AND THE BROWSER MOVES BYTES — Maker::GerberArchive's "the server lists,
  # the browser extracts", applied to writing. The top bar's Upload reads a selected zip with JSZip
  # (lib/zip_bundle.js); when it holds a model-role file the page asks #create for a folder map,
  # uploads each entry through the ordinary per-file doors (FilesController#create on share/s3,
  # #begin_upload/#finalize_upload on chunk_remote), then posts #finish once. No zip byte reaches
  # Rails (§15).
  #
  # ModelsController#ensure_folders is the Import page's twin, and the two differ on purpose: that
  # one builds `Models/<slug>/` for a catalogue row it has just made; this one builds wherever the
  # Upload button said it saves to and makes no row — Maker::ModelIntake's shelves catalogue the
  # folder like any other model folder.
  class UnpacksController < ApplicationController
    # POST /files/unpack_folder (JSON) { parent_node_id, name, dirs: [...], first_model_name }
    #   -> 201 { folder_node_id, folder_url, folder_map: { "" => id, "sub/dir" => id } }
    def create
      parent = parent_dir
      return render(json: { error: "not_found" }, status: :not_found) if parent == :missing

      # THE FIFTH WEB DOOR THAT MINTS A LEAF NAME, and it asks the same two questions in the same
      # breath as the other four (CLAUDE.md §14c): syntax, then the library's own namespace.
      name = params.require(:name).to_s
      unless leaf_ok?(name)
        return render(json: { error: "#{name.inspect} is not a valid folder name" },
                      status: :unprocessable_entity)
      end

      dest = destination(parent, params[:first_model_name].to_s)
      folder = Maker::LibraryFolder.create_child!(current_user, parent_node_id: dest&.node_id,
                                                  name: free_name(dest, name))
      render json: { folder_node_id: folder.node_id, folder_url: files_path(folder: folder.node_id),
                     folder_map: folder_map(folder) }, status: :created
    rescue FileLayer::FetchError
      render json: { error: "fetch_error" }, status: :service_unavailable
    rescue FileLayer::NotFound, FileLayer::UnsupportedOperation => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # POST /files/unpacked (JSON) { folder_node_id } -> 202
    #
    # ENQUEUES, NEVER SWEEPS: nothing sweeps inside a web request (Maker::ModelIntake::MAX_MODELS
    # says why there is no in-request cap), and the job's own limits_concurrency discards a second
    # nudge while one is queued. Without it the model card waits for the next 15-minute sweep.
    def finish
      folder = current_user.nodes.present.find_by(node_id: params.require(:folder_node_id).to_s, kind: "dir")
      return render(json: { error: "not_found" }, status: :not_found) unless folder

      Maker::ModelIntakeJob.perform_later(user_id: current_user.id)
      head :accepted
    end

    private

    # nil is the library root; :missing is an id that is not one of this user's live folders —
    # another user's included, which is a 404 and never a hint that the id exists.
    def parent_dir
      id = params[:parent_node_id].presence
      return nil if id.nil?

      current_user.nodes.present.find_by(node_id: id.to_s, kind: "dir") || :missing
    end

    def leaf_ok?(name)
      Maker::MoveNode.valid_leaf_name?(name) && !Library::ReservedNames.reserved?(name)
    end

    # AT A PROJECT'S OWN FOLDER THE ZIP GOES WHERE FILING WOULD PUT ITS FIRST MODEL — `models/` for
    # every user today (Maker::ProjectFolders.folder_for reads the per-user filing rules). The
    # project root is the sweep's inbox (§14f), and intake moves FILES only, so a folder left there
    # would never be filed. A project's SUBFOLDER is where the maker chose, and is used as it is.
    def destination(parent, first_model_name)
      return parent if parent.nil? || !current_user.maker_projects.exists?(folder_node_id: parent.node_id)

      sub = Maker::ProjectFolders.folder_for(current_user, first_model_name.presence || "model.stl")
      Maker::LibraryFolder.create_child!(current_user, parent_node_id: parent.node_id, name: sub)
    end

    # A TAKEN NAME GETS A NUMBER, and "taken" is any live child — a FILE called `dragon` blocks a
    # folder called `dragon` on every backend (LibraryBrowseController#create_folder says why).
    # CASE-FOLDED, because a share on macOS or over SMB is case-insensitive: `Dragon` and `dragon`
    # are one name there, and the mkdir would land on the existing folder.
    def free_name(dest, name)
      taken = current_user.nodes.present.where(parent_node_id: dest&.node_id).pluck(:name).map(&:downcase).to_set
      return name unless taken.include?(name.downcase)

      (2..).each do |i|
        candidate = "#{name} #{i}"
        return candidate unless taken.include?(candidate.downcase)
      end
    end

    # { "" => folder, "sub/dir" => its node } for every requested dir. A dir with any segment that
    # could not be a folder name is LEFT OUT, so its files fall back to the root — the importer's
    # rule (ModelsController#ensure_folders) — rather than failing the unpack.
    def folder_map(folder)
      map = { "" => folder.node_id }
      Array(params[:dirs]).grep(String).reject(&:blank?).uniq.each do |rel|
        segs = rel.split("/").reject(&:blank?)
        next if segs.empty? || !segs.all? { |s| leaf_ok?(s) }

        leaf = segs.reduce(folder) do |dir, seg|
          Maker::LibraryFolder.create_child!(current_user, parent_node_id: dir.node_id, name: seg)
        end
        map[rel] = leaf.node_id
      end
      map
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/files_unpack_test.rb`
Expected: `10 runs, … 0 failures, 0 errors`.

- [ ] **Step 6: Mutation-check the two rules a regression would hide behind**

1. In `destination`, change the first line to `return parent` (always). Run the file → the
   "project's own folder" test must go RED. Restore.
2. In `free_name`, drop the `.map(&:downcase)` and compare raw names. Run → the "taken name" test must
   go RED (on a case-insensitive tmp dir it may raise instead — red either way). Restore.
Run `rm -rf tmp/cache/bootsnap*` after restoring, then re-run the file green.

- [ ] **Step 7: Update CLAUDE.md's door count**

In `CLAUDE.md` (search for `FOUR web doors`), the sentence reads:
`**FOUR web doors mint a leaf name and all four ask two questions in the same breath**:`
and the list ends `` `FilesController#rename` (F, 2026-10-13). ``

Change `FOUR` to `FIVE` and `all four` to `all five`, and append `` `Files::UnpacksController#create` (a model zip's folder, 2026-10-21)`` to the list (edit within existing lines — `test/docs_hygiene_test.rb` caps the file's line count; do not add lines). Then run:
`LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/docs_hygiene_test.rb` → green.

- [ ] **Step 8: Rubocop and commit**

Run: `bin/rubocop app/controllers/files/unpacks_controller.rb test/integration/web/files_unpack_test.rb config/routes.rb` → no offenses.

```bash
git add app/controllers/files/unpacks_controller.rb config/routes.rb CLAUDE.md test/integration/web/files_unpack_test.rb
git commit -F <msgfile> -- app/controllers/files/unpacks_controller.rb config/routes.rb CLAUDE.md test/integration/web/files_unpack_test.rb
```
Message: `Unpack endpoints: a model zip's folders, made where Upload saves, and a catalog nudge`.

---

### Task 2: The zip reader and the unpack runner (JS libs) + the Import page on the shared reader

**Files:**
- Create: `app/javascript/lib/zip_bundle.js`
- Create: `app/javascript/lib/zip_unpack.js`
- Modify: `config/importmap.rb`
- Modify: `app/javascript/controllers/importer_controller.js`
- Test: `test/system/importer_test.rb` (existing — must stay green; one new test)

- [ ] **Step 1: Create `app/javascript/lib/zip_bundle.js`**

```js
import JSZip from "jszip"

// A ZIP'S CONTENTS AS THE LIBRARY SHOULD RECEIVE THEM, read in the browser (§15: no zip byte
// reaches Rails). ONE READER for the two pages that unpack a zip — the Import page
// (importer_controller.js) and the top bar's Upload (lib/zip_unpack.js) — so they cannot disagree
// about what a zip holds.
//
// Three cleanups, in this order:
//   1. CLUTTER IS DROPPED: any path segment starting with "." (macOS's `__MACOSX/._x`, `.DS_Store`,
//      a `.git/` someone zipped) and the `__MACOSX` directory itself. A dot-segment could not
//      become a folder anyway (Library::ReservedNames), so its files would land loose at the root.
//   2. ONE WRAPPER FOLDER IS REMOVED: when every entry sits under the same single top-level
//      directory, that level goes, so `widget.zip` holding `widget/…` does not unpack as
//      `widget/widget/…`.
//   3. DUPLICATES ARE DROPPED by `dir/name`, keeping the first — a duplicated entry would upload to
//      the same path twice, and share/s3 refuse the second as a clobber.
const isClutter = (path) => path.split("/").some((seg) => seg.startsWith(".") || seg === "__MACOSX")

// The extension, lower-cased and without the dot ("" for none) — Maker::FileAttachment.role_for's
// own reading (`File.extname(name).downcase.delete(".")`), so a page asking "is this a model?" and
// the server asking the same question read the same three letters.
export const extOf = (name) => {
  const dot = name.lastIndexOf(".")
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : ""
}

export const isZip = (file) => file.name.toLowerCase().endsWith(".zip")

// Read `file` (a File or Blob) into [{ name, dir, blob }] — `dir` is "" at the zip's (unwrapped)
// root and "a/b" below it, `blob` a File carrying the entry's own name. Throws whatever JSZip throws
// for a file that is not a readable zip; the callers decide what that means.
export async function readZipBundle(file) {
  const zip = await JSZip.loadAsync(file)
  const found = []
  for (const entry of Object.values(zip.files)) {
    if (entry.dir || isClutter(entry.name)) continue
    const parts = entry.name.split("/").filter(Boolean)
    const name = parts.pop()
    if (!name) continue
    found.push({ parts, name, entry })
  }

  const tops = new Set(found.map((f) => (f.parts.length > 0 ? f.parts[0] : null)))
  const wrapped = found.length > 0 && tops.size === 1 && !tops.has(null)

  const seen = new Set()
  const entries = []
  for (const f of found) {
    const dir = (wrapped ? f.parts.slice(1) : f.parts).join("/")
    const key = `${dir}/${f.name}`
    if (seen.has(key)) continue
    seen.add(key)
    const blob = await f.entry.async("blob")
    entries.push({ name: f.name, dir, blob: new File([blob], f.name) })
  }
  return entries
}
```

- [ ] **Step 2: Create `app/javascript/lib/zip_unpack.js`**

```js
import { postJSON } from "lib/chunk_upload"
import { extOf, isZip, readZipBundle } from "lib/zip_bundle"

// THE TOP BAR'S UPLOAD WHEN THE SELECTION HOLDS A MODEL ZIP (2026-10-21; spec
// docs/superpowers/specs/2026-10-20-zip-upload-unpacks-models-design.md). Shared by both upload
// flows — zip_upload_controller.js (share/s3) and uploader_controller.js (chunk_remote) — which
// differ only in the per-file door, passed in as `upload(file, parentNodeId)` resolving to
// { nodeId } or throwing.

export { isZip }

// Sort a selection into MODEL ZIPS (unpacked) and everything else (uploaded as it is). Each .zip is
// read once. "Model" is the server's vocabulary — `modelExts` is Maker::FileAttachment::MODEL_EXTS,
// rendered into the page — never a list kept here. A zip JSZip cannot open is "everything else": it
// uploads as a file, exactly as it did before this existed, and its name is reported.
export async function splitSelection(files, modelExts) {
  const zips = []
  const rest = []
  const unreadable = []
  for (const file of files) {
    if (!isZip(file)) { rest.push(file); continue }
    let entries
    try {
      entries = await readZipBundle(file)
    } catch (e) {
      console.warn(`could not open ${file.name}:`, e)
      unreadable.push(file.name)
      rest.push(file)
      continue
    }
    const firstModel = entries.find((e) => modelExts.includes(extOf(e.name)))
    if (firstModel) zips.push({ file, entries, firstModel })
    else rest.push(file)
  }
  return { zips, rest, unreadable }
}

// Unpack ONE model zip: the folder map from the server, every entry through `upload`, then the
// catalog nudge. A failed entry is recorded and passed over — the importer's rule: one refused
// name must not lose the other seventeen. THROWS only when the folder itself could not be made.
async function unpackZip({ file, entries, firstModel }, { parentNodeId, unpackUrl, unpackedUrl, upload, setStatus }) {
  const made = await postJSON(unpackUrl, {
    parent_node_id: parentNodeId || null,
    name: file.name.replace(/\.zip$/i, ""),
    dirs: [...new Set(entries.map((e) => e.dir).filter(Boolean))],
    first_model_name: firstModel.name
  })
  const failed = []
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i]
    setStatus(`Unpacking ${file.name} — ${i + 1}/${entries.length}`)
    try {
      await upload(entry.blob, made.folder_map[entry.dir] ?? made.folder_map[""])
    } catch (e) {
      console.warn(`skipped ${entry.dir ? `${entry.dir}/` : ""}${entry.name}:`, e)
      failed.push(entry.name)
    }
  }
  const landed = entries.length - failed.length
  // BEST-EFFORT: the 15-minute sweep catalogues the folder anyway, so a lost nudge only delays the
  // model card. Never thrown — the files are already in the library by now.
  if (landed > 0) {
    try {
      await postJSON(unpackedUrl, { folder_node_id: made.folder_node_id })
    } catch (e) {
      console.warn("catalog nudge failed:", e)
    }
  }
  return { folderUrl: made.folder_url, landed, failed }
}

// Unpack every model zip in `split`, then upload the rest one at a time — SEQUENTIAL, for
// uploader_controller.js's reason: parallel uploads race the port's clobber check. `landing` is the
// one folder to open, set only when the selection was ONE model zip and nothing else — the only
// case with a single obvious place to go.
export async function uploadSplit(split, { parentNodeId, unpackUrl, unpackedUrl, upload, setStatus }) {
  const unpacked = []
  const failed = []
  for (const zip of split.zips) {
    try {
      const r = await unpackZip(zip, { parentNodeId, unpackUrl, unpackedUrl, upload, setStatus })
      if (r.landed > 0) {
        unpacked.push({ name: zip.file.name, folderUrl: r.folderUrl })
        failed.push(...r.failed.map((name) => `${name} (in ${zip.file.name})`))
      } else {
        failed.push(`${zip.file.name} (nothing could be unpacked)`)
      }
    } catch (e) {
      console.error(e)
      failed.push(`${zip.file.name} (${e.message})`)
    }
  }

  let uploaded = 0
  for (let i = 0; i < split.rest.length; i++) {
    const file = split.rest[i]
    setStatus(`Uploading ${file.name}…${split.rest.length > 1 ? ` (${i + 1} of ${split.rest.length})` : ""}`)
    try {
      await upload(file, parentNodeId)
      uploaded += 1
    } catch (e) {
      console.error(e)
      failed.push(`${file.name} (${e.message})`)
    }
  }

  const landing = split.zips.length === 1 && split.rest.length === 0 && unpacked.length === 1
    ? unpacked[0].folderUrl : null
  return { unpacked, uploaded, failed, unreadable: split.unreadable, landing }
}

// The end of a run, the same for both flows. ANYTHING THAT WENT WRONG STAYS ON SCREEN — a reload
// would wipe the one line that says what failed. A clean run navigates: to the unpacked folder, or
// a reload of this page so the new files show.
export function reportAndLand(out, setStatus) {
  if (out.unpacked.length === 0 && out.uploaded === 0) {
    setStatus(`Upload failed: ${out.failed.join(", ")}`)
    return
  }
  if (out.failed.length > 0 || out.unreadable.length > 0) {
    const parts = []
    if (out.unpacked.length > 0) parts.push(`unpacked ${out.unpacked.map((u) => u.name).join(", ")}`)
    if (out.uploaded > 0) parts.push(`uploaded ${out.uploaded} ${out.uploaded === 1 ? "file" : "files"}`)
    if (out.unreadable.length > 0) parts.push(`couldn't open ${out.unreadable.join(", ")}, so uploaded it as is`)
    if (out.failed.length > 0) parts.push(`failed: ${out.failed.join(", ")}`)
    const line = parts.join("; ")
    setStatus(`${line.charAt(0).toUpperCase()}${line.slice(1)}. Reload to see them.`)
    return
  }
  setStatus("Done.")
  if (out.landing) window.location.href = out.landing
  else window.location.reload()
}
```

- [ ] **Step 3: Pin both libs**

In `config/importmap.rb`, after `pin "lib/file_chooser", to: "lib/file_chooser.js"`, add:

```ruby
pin "lib/zip_bundle", to: "lib/zip_bundle.js"
pin "lib/zip_unpack", to: "lib/zip_unpack.js"
```

- [ ] **Step 4: Point the Import page at the shared reader**

In `app/javascript/controllers/importer_controller.js`:

Replace the first three lines' imports:
```js
import { Controller } from "@hotwired/stimulus"
import JSZip from "jszip"
import { uploadChunkFile, uploadPortFile } from "lib/chunk_upload"
```
with:
```js
import { Controller } from "@hotwired/stimulus"
import { uploadChunkFile, uploadPortFile } from "lib/chunk_upload"
import { isZip, readZipBundle } from "lib/zip_bundle"
```

Replace the header comment's first sentence block:
```js
// Import a downloaded model bundle from ONE selection. Unzips any .zip in the browser, classifies
// entries by extension, then creates the Model (+ folder map) and uploads every entry through the
// existing per-backend flow, attaching each. No zip bytes ever reach Rails; §15/§10 untouched.
```
with:
```js
// Import a downloaded model bundle from ONE selection. Unzips any .zip in the browser through
// lib/zip_bundle.js — the reader the top bar's Upload shares, so the two cannot disagree about what
// a zip holds (clutter, a wrapper folder, duplicates) — classifies entries by extension, then
// creates the Model (+ folder map) and uploads every entry through the existing per-backend flow,
// attaching each. No zip bytes ever reach Rails; §15/§10 untouched.
```

In `choose()`, replace:
```js
        if (f.name.toLowerCase().endsWith(".zip")) {
          const zip = await JSZip.loadAsync(f)
          for (const entry of Object.values(zip.files)) {
            if (entry.dir) continue
            const blob = await entry.async("blob")
            const parts = entry.name.split("/")
            const name = parts.pop()
            if (!name || name.startsWith(".")) continue
            this.files.push({ name, dir: parts.join("/"), blob: new File([blob], name), role: roleFor(name) })
          }
        } else {
```
with:
```js
        if (isZip(f)) {
          for (const entry of await readZipBundle(f)) this.files.push({ ...entry, role: roleFor(entry.name) })
        } else {
```

In `deriveTitle()`, replace
`const zip = [...this.inputTarget.files].find((f) => f.name.toLowerCase().endsWith(".zip"))`
with
`const zip = [...this.inputTarget.files].find(isZip)`.

The cross-selection de-dupe block in `choose()` stays: it also covers a loose PDF dropped beside a
zip that contains the same PDF, which `readZipBundle` cannot see.

- [ ] **Step 5: Add a wrapper-folder test to the Import page's system test**

In `test/system/importer_test.rb`, add after the existing test (inside the class, before `private`):

```ruby
  # THE WRAPPER FOLDER IS DROPPED (lib/zip_bundle.js, shared with the top bar since 2026-10-21): a
  # zip whose every entry sits under one top-level directory imports without that level, so the
  # model's folder does not hold a single folder of the same name. MUTATION-CHECKED: forcing
  # `wrapped = false` in zip_bundle.js reddens the parent assertion below (the STL lands one level
  # deeper, under `widget/`).
  test "a zip wrapped in one folder imports without the wrapper" do
    zip = Tempfile.new([ "widget", ".zip" ])
    zip.close
    Zip::File.open(zip.path, create: true) do |z|
      z.get_output_stream("widget/widget.stl")       { |io| io.write("solid w\nendsolid\n") }
      z.get_output_stream("widget/parts/knob.stl")   { |io| io.write("solid k\nendsolid\n") }
      z.get_output_stream("__MACOSX/widget/._x.stl") { |io| io.write("junk") }
    end

    visit new_model_path
    fill_in "Title", with: "Widget"
    attach_file(zip.path)
    assert_selector "[data-importer-target='summary']", text: "2 model files · 0 images · 0 PDF"
    click_on "Create model"

    model = nil
    assert_eventually("the model was never created") do
      model = @user.maker_models.find_by(title: "Widget")
      model.present? && model.file_attachments.reload.count == 2
    end
    # By the model's folder ID, never by name: unwrapped or not, the parent would be CALLED `widget`.
    widget = @user.nodes.find_by!(node_id: model.file_attachments.map(&:node_id), name: "widget.stl")
    assert_equal model.reload.folder_node_id, widget.parent_node_id
    knob = @user.nodes.find_by!(node_id: model.file_attachments.map(&:node_id), name: "knob.stl")
    assert_equal "parts", @user.nodes.find_by!(node_id: knob.parent_node_id).name
    assert_no_console_errors
  ensure
    zip&.close!
  end
```

- [ ] **Step 6: Run the Import page's system tests**

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/importer_test.rb`
Expected: `2 runs, 0 failures, 0 errors`.

Then perform the mutation recorded in the new test's comment (`const wrapped = false` in
`zip_bundle.js`), run, confirm the new test goes RED, restore (`cp` from your scratchpad copy — the
file is new and untracked), re-run green.

- [ ] **Step 7: Commit**

```bash
git add app/javascript/lib/zip_bundle.js app/javascript/lib/zip_unpack.js config/importmap.rb app/javascript/controllers/importer_controller.js test/system/importer_test.rb
git commit -F <msgfile> -- app/javascript/lib/zip_bundle.js app/javascript/lib/zip_unpack.js config/importmap.rb app/javascript/controllers/importer_controller.js test/system/importer_test.rb
```
Message: `One zip reader for the Import page and Upload; the unpack runner`.

---

### Task 3: The top bar unpacks a model zip (both flows)

Depends on Tasks 1 and 2.

**Files:**
- Modify: `app/models/maker/file_attachment.rb` (beside `IMAGE_EXTS`)
- Modify: `app/views/layouts/_topbar_upload.html.erb`
- Create: `app/javascript/controllers/zip_upload_controller.js`
- Modify: `app/javascript/controllers/uploader_controller.js`
- Test: `test/integration/web/topbar_zip_markup_test.rb` (new), `test/system/topbar_zip_upload_test.rb` (new), `test/system/uploader_test.rb`

- [ ] **Step 1: `MODEL_EXTS`**

In `app/models/maker/file_attachment.rb`, directly after the line
`IMAGE_EXTS = ROLE_BY_EXT.filter_map { |ext, role| ext if role == "image" }.freeze`, add:

```ruby

    # WHAT THE TOP BAR'S UPLOAD CALLS A MODEL when it decides whether a zip unpacks (2026-10-21,
    # lib/zip_unpack.js) — DERIVED, like IMAGE_EXTS above, so a model extension added to ROLE_BY_EXT
    # makes a zip holding it unpack with no second edit. The importer's own five-entry MODEL_EXT
    # (importer_controller.js) is display-only and is not this.
    MODEL_EXTS = ROLE_BY_EXT.filter_map { |ext, role| ext if role == "model" }.freeze
```

- [ ] **Step 2: Write the failing markup test**

Create `test/integration/web/topbar_zip_markup_test.rb`:

```ruby
require "test_helper"

module Web
  # THE TOP BAR'S UPLOAD CARRIES THE UNPACK DOORS ON EITHER FLOW (2026-10-21). Two wire shapes behind
  # one button (layouts/_topbar_upload.html.erb): the share/s3 multipart form with the zip-upload
  # controller, the chunk_remote uploader section with three more values. BRANCHED ON
  # port_writable? because a form-shaped assertion is red only on the chunk_remote leg — the trap
  # files_toolbar_test.rb's idiom exists for. Runs on the ambient backend; node rows only.
  class TopbarZipMarkupTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "tzm-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
    end

    teardown { FileLayer.reset! }

    test "the top bar's Upload carries the unpack doors and the model extensions" do
      get files_path
      assert_response :success
      exts = Maker::FileAttachment::MODEL_EXTS.to_json

      if FileLayer.current.capabilities.port_writable?
        assert_select "header.topbar form[data-controller~='zip-upload']" \
                      "[data-zip-upload-unpack-url-value=?][data-zip-upload-unpacked-url-value=?]" \
                      "[data-zip-upload-create-url-value=?][data-zip-upload-model-exts-value=?]",
                      files_unpack_folder_path, files_unpacked_path, files_path, exts
        assert_select "header.topbar input#topbar_upload_file[data-action~='change->zip-upload#change']"
        assert_select "header.topbar input#topbar_upload_file[onchange]", count: 0
        assert_select "header.topbar input[name='parent_node_id'][data-zip-upload-target='parent']"
      else
        assert_select "header.topbar section[data-controller~='uploader']" \
                      "[data-uploader-unpack-url-value=?][data-uploader-unpacked-url-value=?]" \
                      "[data-uploader-model-exts-value=?]",
                      files_unpack_folder_path, files_unpacked_path, exts
      end
    end

    test "MODEL_EXTS is every extension the vocabulary files as a model" do
      assert_includes Maker::FileAttachment::MODEL_EXTS, "stl"
      assert_includes Maker::FileAttachment::MODEL_EXTS, "3mf"
      assert_includes Maker::FileAttachment::MODEL_EXTS, "step"
      refute_includes Maker::FileAttachment::MODEL_EXTS, "zip"
      assert(Maker::FileAttachment::MODEL_EXTS.all? { |e| Maker::FileAttachment.role_for("x.#{e}") == "model" })
    end
  end
end
```

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/topbar_zip_markup_test.rb`
Expected: the first test FAILS (no `zip-upload` controller on the form).

- [ ] **Step 3: Wire the view**

In `app/views/layouts/_topbar_upload.html.erb`:

(a) Replace the share/s3 form block — from `<%= form_with url: files_path, method: :post, class: "uploader",`
through its matching `<% end %>` (the one right before `<% else %>`) — with:

```erb
    <%# THE ZIP-UPLOAD CONTROLLER (2026-10-21) submits this form exactly as the inline `onchange` it
        replaced did, for every selection without a model zip; a selection holding one is unpacked
        in the browser instead (zip_upload_controller.js, lib/zip_unpack.js). %>
    <%= form_with url: files_path, method: :post, class: "uploader",
                  data: { turbo: false, controller: "zip-upload",
                          zip_upload_create_url_value: files_path,
                          zip_upload_unpack_url_value: files_unpack_folder_path,
                          zip_upload_unpacked_url_value: files_unpacked_path,
                          zip_upload_model_exts_value: Maker::FileAttachment::MODEL_EXTS },
                  html: { multipart: true } do |f| %>
      <%= hidden_field_tag :parent_node_id, parent_value, id: nil,
                           data: { zip_upload_target: "parent", upload_pick_target: ("parent" if pick) } %>
      <%= tag.label class: btn_class, title: btn_title,
                    data: (pick ? { action: "click->upload-pick#pick" } : {}) do %>
        <%# `include_hidden: false` IS LOAD-BEARING. `f.file_field` with `multiple: true` renders a
            companion `<input name="file[]" type="hidden" value="">` so an empty selection still
            submits the key, which put a bare "" at the head of `params[:file]`, and the server
            called `original_filename` on a String and 500'd. Nothing needs that marker here: the
            field's own change handler is the only thing that submits this form, so it never fires
            with an empty selection. Found by uploading four real files through the real form; the
            Rack::Test suites POSTed a Ruby array and never sent the marker at all, which is §14d's
            "assert the rendered field name" with a different attribute (upload_batch_test.rb). %>
        <%= f.file_field :file, multiple: true, include_hidden: false, id: "topbar_upload_file", hidden: true,
                         data: { zip_upload_target: "input", action: "change->zip-upload#change",
                                 upload_pick_target: ("input" if pick) } %>
        <span>Upload</span>
      <% end %>
      <span class="upload-status" data-zip-upload-target="status"></span>
    <% end %>
```

(b) In the chunk branch's `tag.section` data hash, add three values after
`uploader_parent_node_id_value: parent_value,`:

```erb
                            uploader_unpack_url_value: files_unpack_folder_path,
                            uploader_unpacked_url_value: files_unpacked_path,
                            uploader_model_exts_value: Maker::FileAttachment::MODEL_EXTS,
```

(c) In the partial's opening comment, after the paragraph that starts `ONE BUTTON, TWO FLOWS`, add:

```erb
    A ZIP HOLDING A MODEL FILE UNPACKS (2026-10-21; docs/superpowers/specs/
    2026-10-20-zip-upload-unpacks-models-design.md): both flows carry the two unpack doors and the
    server's model extensions, and lib/zip_unpack.js does the rest in the browser.
```

- [ ] **Step 4: Create `app/javascript/controllers/zip_upload_controller.js`**

```js
import { Controller } from "@hotwired/stimulus"
import { uploadPortFile } from "lib/chunk_upload"
import { isZip, reportAndLand, splitSelection, uploadSplit } from "lib/zip_unpack"

// THE SHARE/S3 TOP-BAR UPLOAD (layouts/_topbar_upload.html.erb), WHICH UNPACKS A MODEL ZIP
// (2026-10-21; spec docs/superpowers/specs/2026-10-20-zip-upload-unpacks-models-design.md).
//
// THE FORM IS STILL THE DOOR for every selection without a model zip: `change` submits it exactly
// as the inline `onchange="this.form.requestSubmit()"` it replaced did — one multipart POST to
// FilesController#create, its batch notice, project intake filing a plain zip into archives/. Only
// a selection holding a zip with a model-role entry is taken over: unpacked in the browser through
// lib/zip_unpack.js, every file — the zip's entries and the rest of the selection — sent through the
// JSON door (uploadPortFile) one at a time.
//
// A SELECTION WITH NO .zip NEVER REACHES JSZip, so the ordinary upload pays nothing for this.
export default class extends Controller {
  static targets = ["input", "parent", "status"]
  static values = { createUrl: String, unpackUrl: String, unpackedUrl: String, modelExts: Array }

  async change() {
    const files = Array.from(this.inputTarget.files || [])
    if (files.length === 0) return
    if (!files.some(isZip)) return this.element.requestSubmit()

    this.setStatus("Reading…")
    const split = await splitSelection(files, this.modelExtsValue)
    if (split.zips.length === 0) {
      this.setStatus("")
      return this.element.requestSubmit()
    }

    try {
      const out = await uploadSplit(split, {
        parentNodeId: this.parentTarget.value,
        unpackUrl: this.unpackUrlValue,
        unpackedUrl: this.unpackedUrlValue,
        upload: (file, parentNodeId) => uploadPortFile(file, { createUrl: this.createUrlValue, parentNodeId }),
        setStatus: (text) => this.setStatus(text)
      })
      reportAndLand(out, (text) => this.setStatus(text))
    } finally {
      this.inputTarget.value = ""
    }
  }

  setStatus(text) { if (this.hasStatusTarget) this.statusTarget.textContent = text }
}
```

- [ ] **Step 5: Give the chunk uploader the same branch**

In `app/javascript/controllers/uploader_controller.js`:

(a) Imports become:
```js
import { Controller } from "@hotwired/stimulus"
import { uploadChunkFile } from "lib/chunk_upload"
import { isZip, reportAndLand, splitSelection, uploadSplit } from "lib/zip_unpack"
```

(b) `static values` becomes:
```js
  static values  = { beginUrl: String, finalizeUrl: String, attachUrl: String, redirectUrl: String, parentNodeId: String,
                     unpackUrl: String, unpackedUrl: String, modelExts: Array }
```

(c) Replace the whole `async upload() { … }` method with the two methods below. The body of
`uploadEach` is the old loop, unchanged except that its `try/finally` moved up into `upload`:

```js
  async upload() {
    const files = Array.from(this.inputTarget.files || [])
    if (files.length === 0) return
    try {
      // THE TOP BAR UNPACKS A MODEL ZIP (2026-10-21; spec docs/superpowers/specs/
      // 2026-10-20-zip-upload-unpacks-models-design.md). Only where the view passed the unpack doors
      // — the top bar does, the build log's "Upload & attach" does not — and only for a selection
      // holding a .zip, so every other upload takes the loop below exactly as before.
      if (this.unpackUrlValue && files.some(isZip)) {
        const split = await splitSelection(files, this.modelExtsValue)
        if (split.zips.length > 0) {
          const out = await uploadSplit(split, {
            parentNodeId: this.parentNodeIdValue,
            unpackUrl: this.unpackUrlValue,
            unpackedUrl: this.unpackedUrlValue,
            upload: (file, parentNodeId) => uploadChunkFile(file, {
              beginUrl: this.beginUrlValue, finalizeUrl: this.finalizeUrlValue, parentNodeId
            }),
            setStatus: (text) => this.setStatus(text)
          })
          reportAndLand(out, (text) => this.setStatus(text))
          return
        }
      }
      await this.uploadEach(files)
    } finally {
      this.inputTarget.value = ""
    }
  }

  async uploadEach(files) {
    const failed = []
    let done = 0
    for (const file of files) {
      const progress = files.length > 1 ? ` (${done + 1} of ${files.length})` : ""
      try {
        this.setStatus(`Uploading ${file.name}…${progress}`)
        const { nodeId } = await uploadChunkFile(file, {
          beginUrl: this.beginUrlValue, finalizeUrl: this.finalizeUrlValue, parentNodeId: this.parentNodeIdValue
        })
        if (this.hasAttachUrlValue && this.attachUrlValue) {
          this.setStatus(`Attaching ${file.name}…${progress}`)
          await this.postAttach(nodeId)
        }
        done += 1
      } catch (e) {
        // Recorded and carried past, not rethrown: losing files 4 and 5 because file 3 hit a
        // name that was already taken is the failure this loop exists to avoid.
        failed.push(`${file.name} (${e.message})`); console.error(e)
      }
    }

    if (done === 0) {
      this.setStatus(`Upload failed: ${failed.join(", ")}`)
      return
    }
    this.setStatus(failed.length ? `Uploaded ${done}; failed: ${failed.join(", ")}` : "Done.")
    if (this.hasRedirectUrlValue && this.redirectUrlValue) window.location.href = this.redirectUrlValue
    else window.location.reload()
  }
```

Run the markup test again → both tests PASS.

- [ ] **Step 6: Write the browser test (share flow)**

Create `test/system/topbar_zip_upload_test.rb`:

```ruby
require "application_system_test_case"
require "zip"

# A MODEL ZIP UPLOADED THROUGH THE TOP BAR UNPACKS (2026-10-21; docs/superpowers/specs/
# 2026-10-20-zip-upload-unpacks-models-design.md). Only a browser can see this: the zip is read by
# JSZip in the page and never reaches the server, so no request test can tell an unpacked zip from
# a skipped one. Share only (use_fresh_share_library!), for the README's reason — the chunk flow's
# copy of the branch is in uploader_test.rb and shares lib/zip_unpack.js with this one.
#
# FIXTURES ARE BUILT IN A Dir.mktmpdir, never under the repo: Selenium cannot read a file under
# ~/Desktop (macOS TCC; test/system/README.md), and JSZip reads the bytes.
#
# MUTATION-CHECKED (fill in what you observed when you ran each):
#   - splitSelection's `if (firstModel)` → `if (false)` in lib/zip_unpack.js: <result>
#   - `const wrapped = false` in lib/zip_bundle.js: <result>
#   - `return parent` as the first line of Files::UnpacksController#destination: <result>
class TopbarZipUploadTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("zip-upload-#{SecureRandom.hex(4)}@example.com")
    @cad = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "cad")
    @dir = Dir.mktmpdir("topbar_zip")
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    FileLayer.reset!
  end

  test "a zip holding a model unpacks into a folder named after it, without the zip" do
    zip = build_zip("iris.zip",
                    "iris/gate.stl" => "solid gate\nendsolid\n",
                    "iris/parts/ring.stl" => "solid ring\nendsolid\n",
                    "iris/readme.txt" => "hello",
                    "__MACOSX/iris/._gate.stl" => "junk")
    visit files_path(folder: @cad.node_id)
    attach_file("topbar_upload_file", zip, make_visible: true)

    folder = eventually("the zip was never unpacked") do
      @user.nodes.present.find_by(parent_node_id: @cad.node_id, name: "iris", kind: "dir")
    end
    assert_current_path files_path(folder: folder.node_id), wait: 30
    assert @user.nodes.present.exists?(name: "gate.stl", parent_node_id: folder.node_id), "wrapper not dropped"
    assert @user.nodes.present.exists?(name: "readme.txt", parent_node_id: folder.node_id)
    ring = @user.nodes.present.find_by!(name: "ring.stl")
    assert_equal "parts", @user.nodes.find_by!(node_id: ring.parent_node_id).name
    refute @user.nodes.present.exists?(name: "iris.zip"), "the zip itself was uploaded too"
    refute @user.nodes.present.exists?(name: "._gate.stl")
    assert_no_console_errors
  end

  test "a zip with no model file uploads as the zip itself" do
    zip = build_zip("firmware.zip", "main.c" => "int main(void) { return 0; }", "README.md" => "x")
    visit files_path(folder: @cad.node_id)
    attach_file("topbar_upload_file", zip, make_visible: true)

    assert_text "firmware.zip"
    assert_equal @cad.node_id, @user.nodes.present.find_by!(name: "firmware.zip").parent_node_id
    refute @user.nodes.present.exists?(name: "main.c")
    assert_no_console_errors
  end

  test "at a project's folder the zip unpacks into its models folder" do
    folder = FileLayer.current.mkdir(@user, parent_node_id: FileLayer.current.mkdir(@user, parent_node_id: nil, name: "Projects").node_id,
                                            name: "stargate")
    project = @user.maker_projects.create!(name: "Stargate")
    project.update_column(:folder_node_id, folder.node_id)
    zip = build_zip("iris.zip", "gate.stl" => "solid gate\nendsolid\n")

    visit project_path(project)
    attach_file("topbar_upload_file", zip, make_visible: true)

    unpacked = eventually("the zip was never unpacked") { @user.nodes.present.find_by(name: "iris", kind: "dir") }
    models = @user.nodes.find_by!(node_id: unpacked.parent_node_id)
    assert_equal [ "models", folder.node_id ], [ models.name, models.parent_node_id ]
    eventually("gate.stl never landed") { @user.nodes.present.find_by(name: "gate.stl", parent_node_id: unpacked.node_id) }
    assert_no_console_errors
  end

  private

    def build_zip(name, entries)
      path = File.join(@dir, name)
      Zip::File.open(path, create: true) do |zip|
        entries.each { |entry, body| zip.get_output_stream(entry) { |io| io.write(body) } }
      end
      path
    end

    # Polls the DATABASE until the block answers something truthy, and returns it. Capybara's waits
    # only watch the DOM.
    def eventually(message, timeout: 30)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        value = yield
        return value if value
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
    end
end
```

- [ ] **Step 7: Run it, then mutation-check it**

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/topbar_zip_upload_test.rb test/system/topbar_upload_test.rb`
Expected: `6 runs, 0 failures, 0 errors` (the three existing top-bar tests must stay green — they now go
through `change` → `requestSubmit`).

Then the three mutations named in the file header, one at a time (`cp` the new JS files to your
scratchpad first; `git checkout -- app/controllers/files/unpacks_controller.rb` is safe — Task 1
committed it). Each must turn at least one test RED. Write what reddened into the header comment
in place of each `<result>`. Restore and re-run green.

- [ ] **Step 8: The chunk-flow copy (skips off chunk_remote)**

In `test/system/uploader_test.rb`:

(a) Add `require "zip"` under `require "support/chunk_remote_journey"`.

(b) In `setup`, change `@user = sign_in_as("uploader@example.com")` to
`@user = sign_in_as("uploader-#{SecureRandom.hex(4)}@example.com")` and add above it:
```ruby
    # A FRESH EMAIL PER TEST: on chunk_remote, signing up provisions a sync-server library per email
    # and refuses a reused one, and this file has two tests since 2026-10-21.
```

(c) Add this test before `private`:

```ruby
  # THE TOP BAR UNPACKS A MODEL ZIP ON THE PRESIGNED FLOW TOO (2026-10-21). lib/zip_unpack.js is the
  # same code the share flow's topbar_zip_upload_test.rb drives; what only this test reaches is
  # uploader_controller.js's branch into it and uploadChunkFile as the per-file door. It runs only
  # where this file runs — with a sync server configured — so CI's share-only system leg skips it.
  test "a model zip chosen in the top bar unpacks through the presigned flow" do
    visit files_path
    @attach_dir = Dir.mktmpdir("uploader_zip")
    zip_path = File.join(@attach_dir, "kit.zip")
    Zip::File.open(zip_path, create: true) do |zip|
      zip.get_output_stream("kit/part.stl")  { |io| io.write("solid p\nendsolid\n") }
      zip.get_output_stream("kit/notes.txt") { |io| io.write("n") }
    end
    attach_file(zip_path, make_visible: true)

    folder = nil
    assert_eventually("the zip was never unpacked") do
      folder = @user.nodes.find_by(name: "kit", kind: "dir", deleted: false)
    end
    part = nil
    assert_eventually("part.stl never landed") do
      part = @user.nodes.find_by(name: "part.stl", parent_node_id: folder.node_id, deleted: false)
    end
    assert_equal "solid p\nendsolid\n", FileLayer.current.read(@user, node_id: part.node_id)
    refute @user.nodes.exists?(name: "kit.zip", deleted: false)
    assert_no_console_errors
  end
```

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/uploader_test.rb`
Expected: `2 runs, 0 failures, 0 errors, 2 skips` (no sync server here — that is the file's gate).

- [ ] **Step 9: Rubocop and commit**

Run: `bin/rubocop app/models/maker/file_attachment.rb test/integration/web/topbar_zip_markup_test.rb test/system/topbar_zip_upload_test.rb test/system/uploader_test.rb`

```bash
git add app/models/maker/file_attachment.rb app/views/layouts/_topbar_upload.html.erb app/javascript/controllers/zip_upload_controller.js app/javascript/controllers/uploader_controller.js test/integration/web/topbar_zip_markup_test.rb test/system/topbar_zip_upload_test.rb test/system/uploader_test.rb
git commit -F <msgfile> -- <the same paths>
```
Message: `The top bar's Upload unpacks a zip holding a model, on both flows`.

---

### Task 4: Attaching a whole model, and a project's models (services)

**Files:**
- Modify: `app/services/maker/attach_to_project.rb`
- Create: `app/services/maker/project_models.rb`
- Test: `test/services/maker/attach_model_test.rb` (new), `test/services/maker/project_models_test.rb` (new)

- [ ] **Step 1: Write the failing service tests**

Create `test/services/maker/attach_model_test.rb`:

```ruby
require "test_helper"

module Maker
  # ATTACHING A MODEL BY NAME (Maker::AttachToProject#attach_model, 2026-10-21) and the batched
  # owner lookup the project page's Models panel reads (.owners_by_node). BACKEND-NEUTRAL FIXTURES:
  # a bundle attach writes attachment rows and moves nothing, so bare node rows are complete.
  class AttachModelTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "am-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Lamp")
      @model = @user.maker_models.create!(title: "Shade", origin: "import")
    end

    def file(node_id, name, deleted: false)
      @user.nodes.create!(node_id:, name:, kind: "file", mtime: 1, size: 1, deleted:)
    end

    def member(model, node_id) = model.file_attachments.create!(user: @user, node_id:, role: "other")

    def service = Maker::AttachToProject.new(user: @user, project: @project)

    test "every live file of the model is attached once, each with its own role, and nothing moves" do
      file("n-stl", "shade.stl")
      file("n-pdf", "howto.pdf")
      file("n-gone", "old.stl", deleted: true)
      %w[n-stl n-pdf n-gone].each { |id| member(@model, id) }

      result = service.attach_model(@model)

      assert_equal :model_bundle, result.relocation
      assert result.created
      assert_equal @model, result.model
      assert_equal({ "n-pdf" => "instructions", "n-stl" => "model" },
                   @project.file_attachments.reload.to_h { |a| [ a.node_id, a.role ] })
      assert_nil @user.nodes.find_by!(node_id: "n-stl").parent_node_id
    end

    test "a second attach adds no row and says nothing was created" do
      file("n-stl", "shade.stl")
      member(@model, "n-stl")
      service.attach_model(@model)

      again = service.attach_model(@model)

      refute again.created
      assert_equal 1, @project.file_attachments.count
    end

    test "a model with no live file is :empty_model and writes nothing" do
      file("n-gone", "old.stl", deleted: true)
      member(@model, "n-gone")

      result = service.attach_model(@model)

      assert_equal :empty_model, result.relocation
      assert_empty result.attachments
      assert_equal 0, @project.file_attachments.count
    end

    test "owners_by_node answers the oldest model per node — #model_owning's rule" do
      file("n-shared", "shared.stl")
      newer = @user.maker_models.create!(title: "Other", origin: "import")
      member(@model, "n-shared")
      member(newer, "n-shared")

      assert_equal({ "n-shared" => @model.id },
                   Maker::AttachToProject.owners_by_node(@user, [ "n-shared", "n-none" ]))
      assert_equal @model, service.model_owning(@user.nodes.find_by!(node_id: "n-shared"))
      assert_equal({}, Maker::AttachToProject.owners_by_node(@user, []))
    end
  end
end
```

Create `test/services/maker/project_models_test.rb`:

```ruby
require "test_helper"

module Maker
  # A PROJECT'S MODELS (Maker::ProjectModels, 2026-10-21): the ones its folder holds plus the ones
  # attached from elsewhere. BACKEND-NEUTRAL FIXTURES, as in model_projects_test.rb: the class reads
  # rows and never touches the port.
  class ProjectModelsTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pm-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "lamp", "d-projects")
      dir("d-lamp-models", "models", "d-lamp")
      dir("d-shade", "shade", "d-lamp-models")
      dir("d-catan", "catan", "d-projects")
      dir("d-catan-models", "models", "d-catan")
      dir("d-loose", "3d models", nil)
      @lamp = project("Lamp", "d-lamp")
      @catan = project("catan", "d-catan")
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    def project(name, folder)
      @user.maker_projects.create!(name:).tap { |p| p.update_column(:folder_node_id, folder) }
    end

    def auto_model(title, key, attach: key)
      @user.maker_models.create!(title:, origin: "auto", auto_node_id: key,
                                 folder_node_id: (key if key.start_with?("d-"))).tap do |m|
        m.file_attachments.create!(user: @user, node_id: attach, role: "model")
      end
    end

    def link(project, node_id) = project.file_attachments.create!(user: @user, node_id:, role: "model")

    def for_lamp
      Maker::ProjectModels.for(@user, @lamp, attached_node_ids: @lamp.file_attachments.pluck(:node_id))
    end

    test "a model in the folder and a linked one both show, by title; only the linked one is linked" do
      file("n-shade", "shade.stl", "d-shade")
      shade = auto_model("shade", "d-shade", attach: "n-shade")
      file("n-benchy", "benchy.stl", "d-loose")
      benchy = auto_model("Benchy", "n-benchy")
      link(@lamp, "n-benchy")

      r = for_lamp

      assert_equal [ benchy, shade ], r.models
      assert_equal Set[benchy.id], r.linked_ids
      assert_equal Set["n-benchy"], r.owned_node_ids
    end

    test "a one-file model loose in models/ is in the folder" do
      file("n-knob", "knob.stl", "d-lamp-models")
      knob = auto_model("knob", "n-knob")

      assert_equal [ knob ], for_lamp.models
      assert_empty for_lamp.linked_ids
    end

    test "a model both in the folder and linked shows once, as in the folder" do
      file("n-shade", "shade.stl", "d-shade")
      shade = auto_model("shade", "d-shade", attach: "n-shade")
      link(@lamp, "n-shade")

      r = for_lamp

      assert_equal [ shade ], r.models
      assert_empty r.linked_ids
      assert_equal Set["n-shade"], r.owned_node_ids
    end

    test "a dismissed model never shows, and its files stay unowned" do
      file("n-benchy", "benchy.stl", "d-loose")
      auto_model("Benchy", "n-benchy").update!(dismissed_at: Time.current)
      link(@lamp, "n-benchy")

      r = for_lamp

      assert_empty r.models
      assert_empty r.owned_node_ids
    end

    test "a model in another project's folder is not this project's" do
      file("n-robber", "robber.stl", "d-catan-models")
      auto_model("robber", "n-robber")

      assert_empty for_lamp.models
    end

    test "a file owned by two models links the older one" do
      file("n-shared", "shared.stl", "d-loose")
      older = @user.maker_models.create!(title: "Older", origin: "import")
      newer = @user.maker_models.create!(title: "Newer", origin: "import")
      older.file_attachments.create!(user: @user, node_id: "n-shared", role: "model")
      newer.file_attachments.create!(user: @user, node_id: "n-shared", role: "model")
      link(@lamp, "n-shared")

      assert_equal [ older ], for_lamp.models
    end

    test "a project with no folder still shows its linked models" do
      bare = @user.maker_projects.create!(name: "Bare")
      file("n-benchy", "benchy.stl", "d-loose")
      benchy = auto_model("Benchy", "n-benchy")
      link(bare, "n-benchy")

      r = Maker::ProjectModels.for(@user, bare, attached_node_ids: [ "n-benchy" ])

      assert_equal [ benchy ], r.models
    end
  end
end
```

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/attach_model_test.rb test/services/maker/project_models_test.rb`
Expected: errors — `undefined method 'attach_model'`, `uninitialized constant Maker::ProjectModels`.

- [ ] **Step 2: `attach_model` and `owners_by_node`**

In `app/services/maker/attach_to_project.rb`:

(a) Directly ABOVE `def initialize(user:, project:)`, add:

```ruby
    # WHICH MODEL OWNS EACH OF `node_ids`, as { node_id => model_id } — #model_owning's rule (the
    # OLDEST Maker::Model row naming the node) for a whole list in ONE query, for the project page's
    # Models panel (Maker::ProjectModels), which asks it of every attached file at once. The two are
    # the same ORDER BY id read two ways; attach_model_test.rb pins that they agree.
    def self.owners_by_node(user, node_ids)
      return {} if node_ids.empty?

      user.maker_file_attachments.where(attachable_type: "Maker::Model", node_id: node_ids)
          .order(:id).pluck(:node_id, :attachable_id)
          .each_with_object({}) { |(node_id, model_id), owners| owners[node_id] ||= model_id }
    end

```

(b) Directly AFTER the `end` that closes `def call(node)`, add:

```ruby

    # ATTACH A MODEL BY NAME RATHER THAN THROUGH ONE OF ITS FILES (2026-10-21; docs/superpowers/specs/
    # 2026-10-20-attach-model-to-project-design.md) — the model page's "Attach to project" and the
    # project page's Add-model picker. It is #call's bundle write, not a second one, so the file
    # page's door and the model's own door cannot attach a model two different ways. A model with no
    # live file answers `:empty_model` instead of an attach of nothing; the caller words it.
    def attach_model(model)
      result = attach_bundle(model)
      result.attachments.empty? ? result.with(relocation: :empty_model) : result
    end
```

- [ ] **Step 3: `Maker::ProjectModels`**

Create `app/services/maker/project_models.rb`:

```ruby
module Maker
  # A PROJECT'S 3D MODELS, FOR ITS MODELS PANEL (2026-10-21; docs/superpowers/specs/
  # 2026-10-20-attach-model-to-project-design.md). Derived on every render from rows that already
  # exist — there is no project↔model table, by decision:
  #
  #   IN THE FOLDER — a catalogued model Maker::ModelProjects places in this project (the nearest
  #     project folder at-or-above it: a folder or a lone file under `Projects/<x>/models/`). Asked
  #     of ModelProjects rather than re-derived, so this panel and the 3D models view's grouping
  #     cannot disagree about where a model is.
  #   LINKED — a catalogued model that owns one of the project's attached files, by
  #     Maker::AttachToProject's rule (the oldest model row per file). A bundle attach writes those
  #     rows; so did every bundle attached before this panel existed, which is why they show as cards
  #     with no migration.
  #
  # A model that is both shows once, as in the folder: it is the project's by where it is, and a
  # Detach there would delete rows and change nothing a maker can see.
  #
  # `owned_node_ids` is the attached files whose owner is shown here — ProjectsController#show drops
  # them from "Linked from elsewhere" so each file appears once, inside its model.
  #
  # CONSTANT IN QUERY COUNT: the owner pluck, the catalogued models with their attachments, and
  # ModelProjects' own three. It loads every catalogued model, as the 3D models view does.
  class ProjectModels
    Result = Data.define(:models, :linked_ids, :owned_node_ids)

    def self.for(user, project, attached_node_ids:)
      owners = Maker::AttachToProject.owners_by_node(user, attached_node_ids)
      catalogued = user.maker_models.catalogued.includes(:file_attachments).to_a
      return Result.new(models: [], linked_ids: Set.new, owned_node_ids: Set.new) if catalogued.empty?

      located = Maker::ModelProjects.group(user, catalogued).find { |g| g.project&.id == project.id }&.models || []
      located_ids = located.to_set(&:id)
      by_id = catalogued.index_by(&:id)
      linked = owners.values.uniq.filter_map { |id| by_id[id] }.reject { |m| located_ids.include?(m.id) }

      models = (located + linked).sort_by { |m| [ m.title.downcase, m.id ] }
      shown = models.to_set(&:id)
      Result.new(models:, linked_ids: linked.to_set(&:id),
                 owned_node_ids: owners.select { |_, model_id| shown.include?(model_id) }.keys.to_set)
    end
  end
end
```

Note: if `Enumerable#to_set` with a block is unavailable on this Ruby, use `.map(&:id).to_set`.

- [ ] **Step 4: Run the tests**

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/attach_model_test.rb test/services/maker/project_models_test.rb test/services/maker/model_projects_test.rb test/integration/web/attach_model_bundle_test.rb`
Expected: all green (the last two are existing neighbours that must not move).

- [ ] **Step 5: Mutation-check**

1. In `ProjectModels.for`, delete `.reject { |m| located_ids.include?(m.id) }` → the "both … shows once"
   test must go RED. Restore.
2. In `owners_by_node`, change `.order(:id)` to `.order(id: :desc)` → the owners test and "two models"
   test must go RED. Restore. `rm -rf tmp/cache/bootsnap*`, re-run green.

- [ ] **Step 6: Rubocop and commit**

```bash
bin/rubocop app/services/maker/attach_to_project.rb app/services/maker/project_models.rb test/services/maker/attach_model_test.rb test/services/maker/project_models_test.rb
git add app/services/maker/attach_to_project.rb app/services/maker/project_models.rb test/services/maker/attach_model_test.rb test/services/maker/project_models_test.rb
git commit -F <msgfile> -- app/services/maker/attach_to_project.rb app/services/maker/project_models.rb test/services/maker/attach_model_test.rb test/services/maker/project_models_test.rb
```
Message: `Attach a whole model; derive a project's models from rows that already exist`.

---

### Task 5: Attach / detach routes and the Add-model picker

Depends on Task 4.

**Files:**
- Modify: `config/routes.rb` (`resources :projects` block and `resources :models` block)
- Create: `app/controllers/models/projects_controller.rb`
- Create: `app/controllers/projects/models_controller.rb`
- Create: `app/views/projects/models/new.html.erb`
- Test: `test/integration/web/attach_model_to_project_test.rb`

- [ ] **Step 1: Write the failing request test**

Create `test/integration/web/attach_model_to_project_test.rb`:

```ruby
require "test_helper"

module Web
  # ATTACH A MODEL TO A PROJECT FROM EITHER END (2026-10-21; docs/superpowers/specs/
  # 2026-10-20-attach-model-to-project-design.md): Models::ProjectsController (attach, detach) and
  # the project page's Add-model picker (Projects::ModelsController). Runs on the ambient backend:
  # nothing here touches the port — a bundle attach writes rows only.
  class AttachModelToProjectTest < ActionDispatch::IntegrationTest
    setup do
      @user = sign_in_web!(User.create!(email: "amp-#{SecureRandom.hex(4)}@example.com",
                                        password: WEB_PASSWORD, confirmed_at: Time.current))
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @model = @user.maker_models.create!(title: "Shade", origin: "import")
      file("n-stl", "shade.stl")
      file("n-pdf", "howto.pdf")
      %w[n-stl n-pdf].each { |id| @model.file_attachments.create!(user: @user, node_id: id, role: "other") }
    end

    teardown { FileLayer.reset! }

    def file(node_id, name) = @user.nodes.create!(node_id:, name:, kind: "file", mtime: 1, size: 1)

    def node_ids(project = @project) = project.file_attachments.reload.pluck(:node_id).sort

    test "attach links every file of the model and goes back where it came from" do
      post model_projects_path(@model), params: { project_id: @project.slug },
                                        headers: { "HTTP_REFERER" => "http://www.example.com#{model_path(@model)}" }

      assert_redirected_to model_path(@model)
      assert_equal "Attached Shade to Desk Lamp.", flash[:notice]
      assert_equal %w[n-pdf n-stl], node_ids
    end

    test "attach from the picker goes to the project's Models panel" do
      post model_projects_path(@model), params: { project_id: @project.slug, return_to: "project" }

      assert_redirected_to project_path(@project, anchor: "models")
    end

    test "attaching twice says so and adds nothing" do
      2.times { post model_projects_path(@model), params: { project_id: @project.slug } }

      assert_equal "Shade is already in Desk Lamp.", flash[:notice]
      assert_equal %w[n-pdf n-stl], node_ids
    end

    test "a model with no live files is refused" do
      empty = @user.maker_models.create!(title: "Empty", origin: "import")

      post model_projects_path(empty), params: { project_id: @project.slug }

      assert_equal "That model has no files to attach.", flash[:alert]
      assert_empty node_ids
    end

    test "an archived project is refused" do
      @project.update!(status: "archived")

      post model_projects_path(@model), params: { project_id: @project.slug }

      assert_match "archived", flash[:alert]
      assert_empty node_ids
    end

    test "detach removes only this project's rows for this model's files" do
      file("n-own", "own.txt")
      @project.file_attachments.create!(user: @user, node_id: "n-own", role: "other")
      other = @user.maker_projects.create!(name: "Other")
      Maker::AttachToProject.new(user: @user, project: @project).attach_model(@model)
      Maker::AttachToProject.new(user: @user, project: other).attach_model(@model)

      delete model_project_path(@model, @project)

      assert_redirected_to project_path(@project)
      assert_equal "Detached Shade from Desk Lamp.", flash[:notice]
      assert_equal %w[n-own], node_ids
      assert_equal %w[n-pdf n-stl], node_ids(other)
      assert_equal 2, @model.file_attachments.count
      assert @user.nodes.present.exists?(node_id: "n-stl")
    end

    test "another user's model or project is a 404 and attaches nothing" do
      stranger = User.create!(email: "amp-stranger-#{SecureRandom.hex(4)}@example.com",
                              password: WEB_PASSWORD, confirmed_at: Time.current)
      their_model = stranger.maker_models.create!(title: "Theirs", origin: "import")
      their_project = stranger.maker_projects.create!(name: "Theirs")

      post model_projects_path(their_model), params: { project_id: @project.slug }
      assert_response :not_found
      post model_projects_path(@model), params: { project_id: their_project.slug }
      assert_response :not_found
      delete model_project_path(@model, their_project)
      assert_response :not_found
      assert_empty node_ids
    end

    test "the picker lists catalogued models matching the title, each attaching to this project" do
      base = @user.maker_models.create!(title: "Lamp Base", origin: "import")
      @user.maker_models.create!(title: "Lamp Arm", origin: "auto", auto_node_id: "n-arm", dismissed_at: Time.current)

      get new_project_model_path(@project, q: "LAMP")

      assert_response :success
      assert_select ".picker-result .picker-name", text: "Lamp Base"
      assert_select ".picker-result .picker-name", text: "Lamp Arm", count: 0
      assert_select ".picker-result .picker-name", text: "Shade", count: 0
      assert_select "form[action=?] input[name='project_id'][value=?]", model_projects_path(base), @project.slug
      assert_select "form[action=?] input[name='return_to'][value='project']", model_projects_path(base)
    end

    test "the picker with no query lists recent models" do
      get new_project_model_path(@project)

      assert_response :success
      assert_select ".picker-result .picker-name", text: "Shade"
    end
  end
end
```

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/attach_model_to_project_test.rb`
Expected: errors — `undefined method 'model_projects_path'`.

- [ ] **Step 2: Routes**

In `config/routes.rb`:

(a) Inside `resources :projects do … end`, directly after the `resources :attachments, … do … end`
block (the one holding `post :relocate, on: :collection`), add:

```ruby
    # THE ADD-MODEL PICKER (2026-10-21, attach-a-model spec): the project page's Models panel opens
    # it. `new` only — the attach itself is POST /models/:model_id/projects, one door for both ends.
    resources :models, only: %i[new], module: :projects
```

(b) Inside `resources :models do … end`, after `resources :print_runs, …`, add:

```ruby
    # A MODEL'S PROJECTS (2026-10-21, attach-a-model spec): attach (create) and detach (destroy).
    # NOT shallow, for the reason `attachments` above is not: a shallow DELETE /projects/:id would
    # be projects#destroy. `:id` is the PROJECT's slug.
    resources :projects, only: %i[create destroy], module: :models
```

- [ ] **Step 3: `Models::ProjectsController`**

Create `app/controllers/models/projects_controller.rb`:

```ruby
module Models
  # A MODEL'S PROJECTS (2026-10-21; docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md).
  #
  # ATTACH IS A LINK, NEVER A MOVE: Maker::AttachToProject#attach_model writes the model's live files
  # as the project's attachment rows — the bundle path a model's FILE already took from the file page
  # — so the model stays where it is and can be in several projects. The project page derives its
  # Models panel from those rows (Maker::ProjectModels).
  #
  # DETACH DELETES THIS PROJECT'S ROWS FOR THE MODEL'S FILES AND NOTHING ELSE: no file moves, nothing
  # leaves the library, the model and its own rows are untouched. A row the maker attached by hand
  # before the model owned that file goes with it — the same rule attaching uses.
  #
  # Both ends post here: the model's "Attach to project" (models/_projects) and the project page's
  # picker (projects/models/new, `return_to=project`). HTML only — no caller wants JSON.
  class ProjectsController < ApplicationController
    before_action :set_model

    # POST /models/:model_id/projects { project_id (slug), return_to? }
    def create
      project = current_user.maker_projects.find_by!(slug: params.require(:project_id).to_s)
      if project.status == "archived"
        return redirect_back_or_to(model_path(@model),
                                   alert: "#{project.name} is archived — unarchive it to attach models.")
      end

      result = Maker::AttachToProject.new(user: current_user, project:).attach_model(@model)
      if result.relocation == :empty_model
        return redirect_back_or_to(model_path(@model), alert: "That model has no files to attach.")
      end

      notice = result.created ? "Attached #{@model.title} to #{project.name}." : "#{@model.title} is already in #{project.name}."
      if params[:return_to] == "project"
        redirect_to project_path(project, anchor: "models"), notice:
      else
        redirect_back_or_to model_path(@model), notice:
      end
    end

    # DELETE /models/:model_id/projects/:id (the project's slug)
    def destroy
      project = current_user.maker_projects.find_by!(slug: params[:id].to_s)
      # THE TABLE, NOT `project.file_attachments`: that association carries an `order(:position)`
      # scope, and a DELETE … ORDER BY is not portable. No callbacks to lose — Maker::FileAttachment
      # has none (Maker::AttachToProject#attach_bundle's insert_all relies on the same fact).
      current_user.maker_file_attachments
                  .where(attachable_type: "Maker::Project", attachable_id: project.id,
                         node_id: @model.file_attachments.pluck(:node_id))
                  .delete_all
      redirect_back_or_to project_path(project), notice: "Detached #{@model.title} from #{project.name}."
    end

    private

    def set_model
      @model = current_user.maker_models.find_by!(slug: params[:model_id].to_s)
    end
  end
end
```

- [ ] **Step 4: The picker**

Create `app/controllers/projects/models_controller.rb`:

```ruby
module Projects
  # THE ADD-MODEL PICKER (2026-10-21; docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md):
  # Projects::AttachmentsController#new's page, for models. Search by title, or the most recently
  # changed with no query; each result posts to Models::ProjectsController#create — the one attach
  # door — with `return_to=project` so the maker lands back on the Models panel.
  #
  # CATALOGUED ONLY: a dismissed auto model is one the maker removed from the catalog, and offering
  # it here would put it back on a page through a side door.
  class ModelsController < ApplicationController
    RECENT_LIMIT = 40

    # GET /projects/:project_id/models/new?q=
    def new
      @project = current_user.maker_projects.find_by!(slug: params[:project_id].to_s)
      scope = current_user.maker_models.catalogued
      if params[:q].present?
        # LOWER on both sides: Postgres (managed) LIKE is case-sensitive where SQLite's is not.
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s.downcase)}%"
        scope = scope.where("LOWER(title) LIKE ?", pattern)
      end
      @results = scope.order(updated_at: :desc, id: :desc).limit(RECENT_LIMIT).to_a
    end
  end
end
```

Create `app/views/projects/models/new.html.erb`:

```erb
<% content_for :title, "Add a model — Tinkerex" %>

<div class="page-head"><h1>Add a model to <%= @project.name %></h1></div>

<%= form_with url: new_project_model_path(@project), method: :get, class: "picker-search" do |f| %>
  <%= f.search_field :q, value: params[:q], placeholder: "Search your models by title…", autofocus: true %>
  <%= f.submit "Search", class: "btn" %>
<% end %>

<% if @results.empty? %>
  <p class="muted">No models found<%= " for “#{params[:q]}”" if params[:q].present? %>.</p>
<% else %>
  <div class="picker-results">
    <% @results.each do |model| %>
      <div class="picker-result">
        <span class="picker-name"><%= model.title %></span>
        <%= button_to "Attach", model_projects_path(model),
                      params: { project_id: @project.slug, return_to: "project" }, class: "btn small" %>
      </div>
    <% end %>
  </div>
<% end %>

<p><%= link_to "← Back to project", project_path(@project), class: "linkbtn" %></p>
```

- [ ] **Step 5: Run the tests**

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/attach_model_to_project_test.rb test/integration/web/models_flow_test.rb test/integration/web/project_attachments_test.rb`
Expected: all green. If the shell nav/rail test (`ShellHelper::SECTIONS`) or `template_hygiene_test.rb`
complains about the new page, run it and follow its message.

- [ ] **Step 6: Mutation-check the detach scope**

In `destroy`, drop `attachable_id: project.id,` → the detach test must go RED (the other project's
rows vanish too). Restore; `rm -rf tmp/cache/bootsnap*`; re-run green.

- [ ] **Step 7: Correct the spec's one stale line**

In `docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md`, the Routes section says
`HTML redirects back with the notice; JSON answers { project_id, model_id, created }.` — replace with
`HTML only: redirects back with the notice (no caller wants JSON).`

- [ ] **Step 8: Rubocop, brakeman, commit**

```bash
bin/rubocop app/controllers/models/projects_controller.rb app/controllers/projects/models_controller.rb test/integration/web/attach_model_to_project_test.rb config/routes.rb
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
git add config/routes.rb app/controllers/models/projects_controller.rb app/controllers/projects/models_controller.rb app/views/projects/models/new.html.erb test/integration/web/attach_model_to_project_test.rb docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md
git commit -F <msgfile> -- <the same paths>
```
Message: `Attach and detach a model from either end; the Add-model picker`.

---

### Task 6: The project page's Models panel

Depends on Tasks 4 and 5.

**Files:**
- Modify: `app/models/maker/project.rb` (`PANELS`, `PANEL_LABELS`)
- Modify: `app/controllers/projects_controller.rb` (`#show`)
- Create: `app/views/projects/_models.html.erb`
- Modify: `app/assets/stylesheets/pages/projects.css`
- Test: `test/integration/web/project_models_panel_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/project_models_panel_test.rb`:

```ruby
require "test_helper"

module Web
  # THE PROJECT PAGE'S MODELS PANEL (2026-10-21; docs/superpowers/specs/
  # 2026-10-20-attach-model-to-project-design.md). Node ROWS only and project_folder_rows!, so the
  # page reads a folder without the port on every backend leg.
  class ProjectModelsPanelTest < ActionDispatch::IntegrationTest
    setup do
      @user = sign_in_web!(User.create!(email: "pmp-#{SecureRandom.hex(4)}@example.com",
                                        password: WEB_PASSWORD, confirmed_at: Time.current))
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = project_folder_rows!(@user, @project)
      @models_dir = row("d-models", "models", "dir", @folder.node_id)
      @elsewhere = row("d-lib", "3d models", "dir", nil)
      @shade = located_model!("Shade")
      @knob = elsewhere_model!("Knob")
    end

    teardown { FileLayer.reset! }

    def row(node_id, name, kind, parent)
      @user.nodes.create!(node_id:, name:, kind:, parent_node_id: parent, mtime: 1, size: (kind == "file" ? 1 : 0))
    end

    # A folder model inside the project's models/ — Maker::ModelIntake's `Projects/*/models` shelf.
    def located_model!(title)
      key = "d-#{SecureRandom.hex(4)}"
      row(key, title.downcase, "dir", @models_dir.node_id)
      file = row("n-#{SecureRandom.hex(4)}", "#{title.downcase}.stl", "file", key)
      @user.maker_models.create!(title:, origin: "auto", auto_node_id: key, folder_node_id: key).tap do |m|
        m.file_attachments.create!(user: @user, node_id: file.node_id, role: "model")
      end
    end

    # A one-file model outside the project.
    def elsewhere_model!(title)
      file = row("n-#{SecureRandom.hex(4)}", "#{title.downcase}.stl", "file", @elsewhere.node_id)
      @user.maker_models.create!(title:, origin: "auto", auto_node_id: file.node_id).tap do |m|
        m.file_attachments.create!(user: @user, node_id: file.node_id, role: "model")
      end
    end

    def attach(model) = Maker::AttachToProject.new(user: @user, project: @project).attach_model(model)

    test "the panel shows the folder's models and the linked ones; only linked ones carry Detach" do
      attach(@knob)

      get project_path(@project)

      assert_response :success
      assert_select "section.models-panel .model-name", text: "Knob"
      assert_select "section.models-panel .model-name", text: "Shade"
      assert_select "section.models-panel form[action=?]", model_project_path(@knob, @project)
      assert_select "section.models-panel form[action=?]", model_project_path(@shade, @project), count: 0
      assert_select "section.models-panel a[href=?]", new_project_model_path(@project), text: "Add model"
    end

    test "a linked model's files leave Linked from elsewhere" do
      attach(@knob)

      get project_path(@project)

      assert_no_match "Linked from elsewhere", response.body
    end

    test "with the panel hidden, a linked model's files stay in Linked from elsewhere" do
      attach(@knob)
      @project.update!(panels: { "hidden" => %w[models] })

      get project_path(@project)

      assert_select "section.models-panel", count: 0
      assert_match "Linked from elsewhere", response.body
    end

    test "a project with no models says so beside Add model" do
      bare = @user.maker_projects.create!(name: "Bare")
      project_folder_rows!(@user, bare)

      get project_path(bare)

      assert_select "section.models-panel", text: /No models yet\./
      assert_select "section.models-panel a[href=?]", new_project_model_path(bare)
    end

    test "the page's query count does not grow with the number of models" do
      counts = [ 1, 4 ].map do |n|
        n.times { |i| located_model!("Located #{n} #{i}"); attach(elsewhere_model!("Linked #{n} #{i}")) }
        get project_path(@project)
        count_queries { get project_path(@project) }
      end

      assert_equal counts.first, counts.last,
                   "the project page issued #{counts.first} queries with few models and #{counts.last} with more"
    end

    private

      def count_queries
        n = 0
        sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
          n += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
        end
        yield
        n
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end
  end
end
```

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/project_models_panel_test.rb`
Expected: FAIL — no `section.models-panel`.

- [ ] **Step 2: The panel key**

In `app/models/maker/project.rb`:

`PANELS = %w[attachments photos schematics build_log tasks bom wiring releases sheets publish].freeze`
becomes
`PANELS = %w[attachments photos models schematics build_log tasks bom wiring releases sheets publish].freeze`

and in `PANEL_LABELS`, after `"photos" => "Photos",` add `"models" => "Models",`.

Directly above `PANELS = …`, add one comment line:
`# \`models\` (2026-10-21): the project's 3D models as cards — projects/_models, Maker::ProjectModels.`

(`models` sits third so every kind's derived order — `(LEAD + first + PANELS) & PANELS` — puts it right
after the folder's own two panels; `Maker::ProjectKind` needs no edit: no views offered, default width
half, hidden by no preset.)

- [ ] **Step 3: `ProjectsController#show`**

In `app/controllers/projects_controller.rb`, find:

```ruby
    @linked_rows = @attachments.reject { |a| @listing.contains?(@page_nodes[a.node_id]) }
```

Insert directly ABOVE the comment block that precedes that line (keep that comment block intact):

```ruby
    # THE MODELS PANEL (2026-10-21; docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md):
    # the models in this project's folder plus the ones attached from elsewhere, derived from rows
    # that already exist (Maker::ProjectModels). ONLY WHEN THE PANEL SHOWS — and that condition is
    # load-bearing, not a saving: a carded model's files leave "Linked from elsewhere" below, so with
    # the panel hidden they would be on the page nowhere at all.
    @project_models = if @panel_layout.visible?("models")
      Maker::ProjectModels.for(current_user, @project, attached_node_ids: @attachments.map(&:node_id))
    end
    carded = @project_models&.owned_node_ids || Set.new
```

and change the `@linked_rows` line to:

```ruby
    @linked_rows = @attachments.reject { |a| @listing.contains?(@page_nodes[a.node_id]) || carded.include?(a.node_id) }
```

Then in the `@page_thumbs = Maker::Previews::ThumbnailMap.for(` call, append the cards' covers to the
id list — the call becomes:

```ruby
    @page_thumbs = Maker::Previews::ThumbnailMap.for(
      current_user, recent_ids + tile_ids + @photo_rows.map(&:node_id) + block_thumb_ids +
                    (@cover_node ? [ cover_id ] : []) +
                    (@project_models ? @project_models.models.filter_map(&:cover_node_id) : [])
    )
```

(`cover_node_id` falls back to `derived_cover_node_id`, which reads the already-loaded attachments —
no query per card.)

- [ ] **Step 4: The partial**

Create `app/views/projects/_models.html.erb`:

```erb
<%#
  THE MODELS PANEL (2026-10-21; docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md).
  The project's 3D models as cards: the ones its folder holds (a folder or a lone model file under
  `models/`, placed by Maker::ModelProjects — the answer the 3D models view groups by) and the ones
  attached from elsewhere (Maker::AttachToProject#attach_model). Built by Maker::ProjectModels in
  ProjectsController#show, and NIL WHEN THE LAYOUT HIDES THIS PANEL — then this renders nothing,
  which in edit mode is the placeholder.

  ONLY AN ATTACHED MODEL HAS DETACH. A model in the folder is the project's by where it is, and
  moving the folder out is what removes it; a Detach there would delete rows and change nothing.

  ITS OWN `thumbs` CONTROLLER, for the reason projects/_attachments gives: no ancestor covers it.
%>
<% if @project_models %>
  <section class="panel models-panel" id="models"
           data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
    <div class="panel-head">
      <h2><%= panel_title(@panel_layout, "models") %></h2>
      <%= link_to "Add model", new_project_model_path(@project), class: "btn small" %>
    </div>
    <%= panel_intro(@panel_layout, "models") %>
    <% if @project_models.models.empty? %>
      <p class="muted">No models yet.</p>
    <% else %>
      <div class="projects-grid">
        <% @project_models.models.each do |model| %>
          <div class="project-model">
            <%= render "models/card", model: model, thumb: @page_thumbs.thumb(model.cover_node_id) %>
            <% if @project_models.linked_ids.include?(model.id) %>
              <%= button_to "Detach", model_project_path(model, @project), method: :delete, class: "btn small",
                            form: { data: { turbo_confirm: "Detach #{model.title} from #{@project.name}?" } } %>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
  </section>
<% end %>
```

- [ ] **Step 5: CSS**

In `app/assets/stylesheets/pages/projects.css`, inside the `@layer pages { … }` block, after the
`.projects-grid { … }` rule, add (two-space indentation, as the file uses):

```css
  /* THE MODELS PANEL (2026-10-21): a model card with its Detach under it, centred. */
  .models-panel .project-model { display: flex; flex-direction: column; gap: 6px; }
  .models-panel .project-model > form { align-self: center; }
```

- [ ] **Step 6: Run the panel test and every test that pins the panel list**

Run:
```
LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/project_models_panel_test.rb test/integration/web/project_page_test.rb test/integration/web/project_tabs_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/public_project_test.rb test/integration/web/project_preview_test.rb test/integration/web/public_preview_test.rb test/integration/web/template_hygiene_test.rb test/models/maker/project_test.rb test/services/maker/project_kind_test.rb
```
Expected: all green. If a test pins an exact panel list or an absolute query count that now includes
`models`, update THAT assertion to the new truth and say why in its comment — do not change the panel's
behaviour to satisfy a stale pin. `grep -rln "PANELS\|PANEL_LABELS\|panel_layout" test` lists the
candidates; run any that the command above missed.

- [ ] **Step 7: Mutation-check**

1. Drop `|| carded.include?(a.node_id)` → "a linked model's files leave Linked" goes RED. Restore.
2. Change the `@project_models` condition to always compute (remove the `if @panel_layout.visible?`
   wrapper but keep the panel hidden) → "with the panel hidden …" goes RED. Restore.
`rm -rf tmp/cache/bootsnap*`; re-run green.

- [ ] **Step 8: Rubocop and commit**

```bash
bin/rubocop app/models/maker/project.rb app/controllers/projects_controller.rb test/integration/web/project_models_panel_test.rb
git add app/models/maker/project.rb app/controllers/projects_controller.rb app/views/projects/_models.html.erb app/assets/stylesheets/pages/projects.css test/integration/web/project_models_panel_test.rb <any pinned test you updated>
git commit -F <msgfile> -- <the same paths>
```
Message: `The project page's Models panel: folder models and attached ones, as cards`.

---

### Task 7: "In projects" on a model (its page and its folder strip)

Depends on Task 5 (routes). Disjoint from Task 6.

**Files:**
- Create: `app/services/maker/model_project_choices.rb`
- Create: `app/views/models/_projects.html.erb`
- Modify: `app/views/files/_model_strip.html.erb`, `app/views/files/index.html.erb`, `app/controllers/files_controller.rb` (`#load_model_strip`)
- Modify: `app/views/models/show.html.erb`, `app/controllers/models_controller.rb` (`#show`)
- Modify: `app/assets/stylesheets/pages/models.css`
- Test: `test/services/maker/model_project_choices_test.rb`, `test/integration/web/model_projects_row_test.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/services/maker/model_project_choices_test.rb`:

```ruby
require "test_helper"

module Maker
  # A MODEL'S "IN PROJECTS" ROW (Maker::ModelProjectChoices, 2026-10-21). Backend-neutral rows.
  class ModelProjectChoicesTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "mpc-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "lamp", "d-projects")
      dir("d-lamp-models", "models", "d-lamp")
      dir("d-shade", "shade", "d-lamp-models")
      @user.nodes.create!(node_id: "n-shade", name: "shade.stl", kind: "file", parent_node_id: "d-shade", mtime: 1, size: 1)
      @lamp = project("Lamp", "d-lamp")
      @desk = project("desk", nil)
      @bench = project("Bench", nil)
      @old = project("Old", nil).tap { |p| p.update!(status: "archived") }
      @shade = @user.maker_models.create!(title: "shade", origin: "auto", auto_node_id: "d-shade", folder_node_id: "d-shade")
      @shade.file_attachments.create!(user: @user, node_id: "n-shade", role: "model")
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def project(name, folder)
      @user.maker_projects.create!(name:).tap { |p| p.update_column(:folder_node_id, folder) }
    end

    def link(project) = project.file_attachments.create!(user: @user, node_id: "n-shade", role: "model")

    def choices = Maker::ModelProjectChoices.for(@user, @shade)

    test "the folder's project is located, attached ones are linked, the rest are offered by name" do
      link(@desk)
      link(@old)

      c = choices

      assert_equal @lamp, c.located
      assert_equal [ @desk ], c.linked
      assert_equal [ @bench ], c.available
    end

    test "a project that holds the model and also links it is located only" do
      link(@lamp)

      c = choices

      assert_equal @lamp, c.located
      assert_empty c.linked
      assert_equal [ @bench, @desk ], c.available
    end

    test "a model in no project's folder has no located project" do
      @user.nodes.create!(node_id: "n-loose", name: "loose.stl", kind: "file", mtime: 1, size: 1)
      loose = @user.maker_models.create!(title: "loose", origin: "auto", auto_node_id: "n-loose")
      loose.file_attachments.create!(user: @user, node_id: "n-loose", role: "model")

      c = Maker::ModelProjectChoices.for(@user, loose)

      assert_nil c.located
      assert_equal [ @bench, @desk, @lamp ], c.available
    end
  end
end
```

Create `test/integration/web/model_projects_row_test.rb`:

```ruby
require "test_helper"

module Web
  # "IN PROJECTS" ON A MODEL (2026-10-21; docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md):
  # the model's folder strip and the model page render one partial (models/_projects). Node rows
  # only — both pages read the catalog, never the port.
  class ModelProjectsRowTest < ActionDispatch::IntegrationTest
    setup do
      @user = sign_in_web!(User.create!(email: "mpr-#{SecureRandom.hex(4)}@example.com",
                                        password: WEB_PASSWORD, confirmed_at: Time.current))
      @lamp = @user.maker_projects.create!(name: "Lamp")
      @desk = @user.maker_projects.create!(name: "Desk")
    end

    teardown { FileLayer.reset! }

    def model_with_file(title, parent:, folder: nil)
      file = @user.nodes.create!(node_id: "n-#{SecureRandom.hex(4)}", name: "#{title.downcase}.stl", kind: "file",
                                 parent_node_id: parent, mtime: 1, size: 1)
      @user.maker_models.create!(title:, origin: "auto", auto_node_id: folder || file.node_id,
                                 folder_node_id: folder).tap do |m|
        m.file_attachments.create!(user: @user, node_id: file.node_id, role: "model")
      end
    end

    test "a model's folder strip lists its projects with Detach and offers the rest" do
      @user.nodes.create!(node_id: "d-shade", name: "shade", kind: "dir", mtime: 1, size: 0)
      shade = model_with_file("Shade", parent: "d-shade", folder: "d-shade")
      Maker::AttachToProject.new(user: @user, project: @lamp).attach_model(shade)

      get files_path(folder: "d-shade")

      assert_response :success
      assert_select ".model-strip .model-projects .project-chip a", text: "Lamp"
      assert_select ".model-strip .model-projects form[action=?]", model_project_path(shade, @lamp)
      options = ".model-strip .model-projects form[action=?] select[name='project_id'] option"
      assert_select options, model_projects_path(shade), count: 1
      assert_select options, model_projects_path(shade), text: "Desk"
    end

    test "the model page shows the same row" do
      knob = model_with_file("Knob", parent: nil)

      get model_path(knob)

      assert_response :success
      assert_select ".model-side .model-projects select[name='project_id'] option", count: 2
    end
  end
end
```

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/model_project_choices_test.rb test/integration/web/model_projects_row_test.rb`
Expected: errors — `uninitialized constant Maker::ModelProjectChoices`; no `.model-projects`.

- [ ] **Step 2: `Maker::ModelProjectChoices`**

Create `app/services/maker/model_project_choices.rb`:

```ruby
module Maker
  # A MODEL'S "IN PROJECTS" ROW (2026-10-21; docs/superpowers/specs/
  # 2026-10-20-attach-model-to-project-design.md) — FilesController#attach_choices_for's two halves,
  # for a whole model: what it is already in, and what it could be attached to.
  #
  #   located   — the project whose folder holds the model (Maker::ModelProjects, the answer the
  #               3D models view groups by), or nil. A chip with no ×: it is the project's by where
  #               it is.
  #   linked    — non-archived projects holding an attachment row for any of the model's files —
  #               what a bundle attach writes — minus the located one. A chip with ×.
  #   available — every other non-archived project, for the dropdown.
  #
  # Archived projects are left out of `linked` and `available` as files/_attach leaves them out;
  # `located` keeps one, because an archived project still claims its folder.
  # Sorted by FilesController#name_key's rule. Constant in query count.
  class ModelProjectChoices
    Choices = Data.define(:located, :linked, :available)

    def self.for(user, model)
      located = Maker::ModelProjects.group(user, [ model ]).first&.project
      node_ids = model.file_attachments.map(&:node_id)
      linked_ids = if node_ids.empty?
        []
      else
        user.maker_file_attachments.where(attachable_type: "Maker::Project", node_id: node_ids)
            .distinct.pluck(:attachable_id)
      end
      open = user.maker_projects.where.not(status: "archived").to_a.reject { |p| p.id == located&.id }
      linked, available = open.partition { |p| linked_ids.include?(p.id) }
      Choices.new(located:, linked: by_name(linked), available: by_name(available))
    end

    def self.by_name(projects) = projects.sort_by { |p| [ p.name.downcase, p.name ] }
    private_class_method :by_name
  end
end
```

- [ ] **Step 3: The partial**

Create `app/views/models/_projects.html.erb`:

```erb
<%# locals: (model:, choices:) %>
<%# A MODEL'S PROJECTS (2026-10-21; docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md):
    files/_attach's chips-and-dropdown, for a whole model. `choices` is Maker::ModelProjectChoices.
    Attach posts to Models::ProjectsController#create and comes back here; × is its #destroy. The
    located project's chip has no ×: the model is in that project by where it is. %>
<% if choices.located || choices.linked.any? || choices.available.any? %>
  <div class="attach-to-project model-projects">
    <% if choices.located || choices.linked.any? %>
      <span class="muted">In projects:</span>
      <% if choices.located %>
        <span class="project-chip"><%= link_to choices.located.name, project_path(choices.located) %></span>
      <% end %>
      <% choices.linked.each do |project| %>
        <span class="project-chip">
          <%= link_to project.name, project_path(project) %>
          <%= button_to "×", model_project_path(model, project), method: :delete,
                form: { data: { turbo_confirm: "Detach #{model.title} from #{project.name}?" } },
                class: "chip-x", "aria-label": "Detach from #{project.name}" %>
        </span>
      <% end %>
    <% end %>

    <% if choices.available.any? %>
      <%= form_with url: model_projects_path(model), method: :post, class: "attach-form",
                    data: { turbo: false } do |f| %>
        <%= f.label :project_id, "Attach to project:", class: "muted", for: "model_attach_project_id" %>
        <%= f.select :project_id, choices.available.map { |p| [ p.name, p.slug ] }, {},
                     id: "model_attach_project_id" %>
        <%= f.submit "Attach", class: "btn small" %>
      <% end %>
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 4: Render it on the folder strip**

(a) `app/controllers/files_controller.rb`, in `def load_model_strip(model)`, add as the last line of
the method body:
```ruby
    @strip_projects = Maker::ModelProjectChoices.for(current_user, model)
```
and extend the method's comment's list ("the cover …, the print log, and the composer's choices") with
`, and its projects row (Maker::ModelProjectChoices — constant too)`.

(b) `app/views/files/index.html.erb` — the `render "files/model_strip", …` call gains
`projects: @strip_projects` (spell it out; never the `projects:` shorthand at a line end — an ERB
shorthand swallows the next line):
```erb
      <%= render "files/model_strip", model: @folder_model, cover_live: @strip_cover_live, covers: @strip_covers,
                 print_runs: @strip_print_runs, printers: @strip_printers, materials: @strip_materials,
                 projects: @strip_projects %>
```

(c) `app/views/files/_model_strip.html.erb` — the strict-locals line becomes
`<%# locals: (model:, cover_live:, covers:, print_runs:, printers:, materials:, projects:) %>`, and
directly after the `</div>` that closes `<div class="model-strip-head">`, add:
```erb
  <%= render "models/projects", model: model, choices: projects %>
```

- [ ] **Step 5: Render it on the model page**

(a) `app/controllers/models_controller.rb`, in `#show`, after
`@printers, @materials = Maker::PrintRun.composer_choices(current_user)`, add:
```ruby
    # THE "IN PROJECTS" ROW (2026-10-21, attach-a-model spec) — the folder strip renders the same
    # partial off the same object, so the two pages offer the same projects.
    @project_choices = Maker::ModelProjectChoices.for(current_user, @model)
```

(b) `app/views/models/show.html.erb`, inside `<aside class="model-side">`, directly after the
`</dl>` that closes `<dl class="meta">`, add:
```erb
    <%= render "models/projects", model: @model, choices: @project_choices %>
```

- [ ] **Step 6: CSS**

In `app/assets/stylesheets/pages/models.css`, inside its `@layer pages { … }` block, add:
```css
  /* A MODEL'S PROJECTS ROW (2026-10-21): on the strip it sits under the head; on the page, in the
     side column under the metadata. */
  .model-strip .model-projects, .model-side .model-projects { margin-top: 8px; }
```

- [ ] **Step 7: Run the tests and the pages' neighbours**

Run:
```
LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/model_project_choices_test.rb test/integration/web/model_projects_row_test.rb test/integration/web/models_flow_test.rb test/integration/web/models_redirects_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/page_nodes_test.rb test/integration/web/template_hygiene_test.rb
```
(If `page_nodes_test.rb` lives elsewhere, `find test -name page_nodes_test.rb`.) Expected: all green.
An absolute query pin that now counts the row's queries is updated with a comment saying why.

- [ ] **Step 8: Mutation-check**

In `ModelProjectChoices.for`, delete `.reject { |p| p.id == located&.id }` → the "holds and links"
test goes RED. Restore; `rm -rf tmp/cache/bootsnap*`; re-run green.

- [ ] **Step 9: Rubocop and commit**

```bash
bin/rubocop app/services/maker/model_project_choices.rb app/controllers/files_controller.rb app/controllers/models_controller.rb test/services/maker/model_project_choices_test.rb test/integration/web/model_projects_row_test.rb
git add app/services/maker/model_project_choices.rb app/views/models/_projects.html.erb app/views/files/_model_strip.html.erb app/views/files/index.html.erb app/controllers/files_controller.rb app/views/models/show.html.erb app/controllers/models_controller.rb app/assets/stylesheets/pages/models.css test/services/maker/model_project_choices_test.rb test/integration/web/model_projects_row_test.rb
git commit -F <msgfile> -- <the same paths>
```
Message: `"In projects" on a model: attach and detach from its page and its folder strip`.

---

### Task 8: Full verification, PR, merge, deploy (parent session)

- [ ] **Step 1:** Mechanical check: `git diff origin/main --stat` matches the file map above; every new
  file exists; no stray files.
- [ ] **Step 2:** Full local gates from the worktree, one at a time:
  `export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync`, then
  `bin/ci style`, `bin/ci scan`, `bin/ci test`, `bin/ci test-s3`, `bin/ci test-chunk-remote`,
  `bin/ci system`. Compare RUN counts across the three backend legs (they must match).
- [ ] **Step 3:** Push the branch, open the PR (body ends with the Claude Code line), bind it with
  `ccd_pr`, wait for CI (allow ~8 min for the run to appear).
- [ ] **Step 4:** Merge when green (owner's standing instruction for this work, 2026-10-21).
- [ ] **Step 5:** Deploy the three Unraid destinations per the deploy-from-worktree recipe
  (`git checkout -B deploy-<tag> origin/main`, clean tree, `config/master.key`, `bin/secrets-preflight --all`,
  `kamal build push`, then each `kamal deploy -d <dest> --skip-push`), and probe one container that the
  new routes and `Maker::FileAttachment::MODEL_EXTS` are present.
