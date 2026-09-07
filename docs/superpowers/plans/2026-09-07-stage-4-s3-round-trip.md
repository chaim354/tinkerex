# Stage 4, S4-3: the round trip closes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S4-3 of `docs/superpowers/specs/2026-09-07-stage-4-bench-maker-design.md` (§5's S4-3 row). The file page shows the file's **library path** with a Copy button; the file page **refreshes its own preview** instead of waiting for a manual reload; a browser **Save re-enqueues** the thumbnail that save just invalidated; Measure's **Download SVG** and **Print** gain **Save to library** twins that ride the existing two-door upload flow into the source file's own folder; and **Rescan polls a real "scan finished"** instead of guessing 6 seconds. Stories 2.10, 2.11, 2.12 and 2.13's stale half.

**Architecture:** One column (`users.library_scanned_at`), stamped by `Library::ScanJob#perform` when a pass completes, read by one new JSON endpoint (`GET /files/scan_status`) that `scanreload_controller.js` polls. The file page's poster joins the existing `thumbs` poll through a **reload mode** rather than a fourth copy of poster markup. Save-to-library builds the same Blob the download builds and hands it to `lib/chunk_upload.js`'s two existing doors — `uploadPortFile` (share/s3 multipart into `FilesController#create`) or `uploadChunkFile` (chunk_remote presigned two-phase) — chosen the way `importer_controller.js` already chooses, so bytes stay out of Rails wherever they can (§15). The print sheet's save uses `buildSheets` + `renderSheet`, `print_sheet.js`'s own **pure** half, never `buildPrintFrame`.

**Tech Stack:** Rails 8, Hotwire (one new Stimulus controller, `copy`; two existing ones extended), Minitest, Capybara + headless Chrome for the four JS claims. No new gem, no new JS dependency.

---

## Amendments (orchestrator review, 2026-09-07) — the six open questions, decided

1. **`-parts.svg` for both the download and the save.** One set of bytes, one name. The spec row's
   `-flat.svg` is superseded; `measure_export_test.rb`'s existing assertion stands.
2. **No `running:` key.** `/files/scan_status` answers `{ scanned_at: }` only; the client bounds its
   own wait and ends with the neutral sentence. A second column is a spec change and is not made here.
3. **A refused scan (`UnsafeScan`) stamps nothing**, and the browser cannot tell it from a slow one.
   Accepted for this slice; the close-out records it against story 2.11 as remaining friction.
4. **The same-name save divergence is the port's** (share/s3 refuse a clobber; chunk_remote mints a
   new node). No name check at the door; the PR body states the divergence and that the refusal test
   is share-shaped by construction.
5. **Keep the Files-page Rescan poll.** Both Rescan doors behave the same; the four `rescan_test.rb`
   redirect edits stay in scope.
6. **A second fixture copy under `@root.join("laser")`** for mutation (ii) — never move the shared
   `sample.lbrn2`, never weaken the assertion.

Everything else stands as written. - **The migration task also runs `bin/rails schema:map` and commits `docs/schema-map.html`** —
  `test/schema_map_test.rb` fails the full gate otherwise, and no per-task run reaches it (S4-2's gate).

When a step below conflicts with an amendment, the amendment wins.

## Before you start

- Branch from `main`. Never push to `main`. S4-1 has landed (`claude/stage-4-s1-project-page`); S4-3 depends on nothing it added.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time; from a worktree `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci`. The three backend legs must report identical run counts.
- **Read first, in full:** `docs/invariants/files-preview.md` (the `/files/thumbnails` two-no-row-cases table, `thumb_cell_data`'s wire contract, why a cell with no answer spins forever), `docs/invariants/measure-view.md`'s last section (the export's mm/viewBox scale mechanism, the `xmlns`-written-twice trap, `renderSheet` pure / `buildPrintFrame` not, `targetShapes()`/`targetNoun()` as the one definition), `docs/invariants/git-editing.md` lines 28–45 (the save door is `LibraryOutput.write_bytes!(replace: true)`, never `File.write`, never delete-then-create) and CLAUDE.md §14a's `port_writable` bullet (**it names which door the UI drives, not "can this deployment take uploads"**) and §15 (bytes out of Rails).
- **Fixtures.** A node that must have a *content token* on all three legs carries **both** `content_hash` and `current_version_id` — the idiom and its reasoning are at `test/integration/web/template_hygiene_test.rb:266-276`. A bare `nodes.create!` has a nil `content_token`, and `app/views/files/show.html.erb:115` short-circuits the whole preview tree on that, so no preview branch renders at all. Real bytes go through `port_upload` (`test/test_helper.rb`), never `File.write`.
- **Upload-control assertions branch on `capabilities.port_writable?`** — chunk_remote renders the presigned flow, so a form-shaped assertion is red only on that leg (memory: `upload-form-assertions-must-branch-on-port-writable`).
- `git add` a new file before a mutation check; restore with `git checkout -- <file>`; clear `tmp/cache/bootsnap*` after an equal-length restore; `git status --porcelain` before the next run.
- Helpers you will call: `thumb_cell_data(node_id, ext_label)` (`app/helpers/files_helper.rb:62`), `thumbnails_files_path`, `blob_file_path`, `files_query_base` (a `helper_method`, `app/controllers/files_controller.rb:1129`), `capabilities` (`app/controllers/concerns/library_capabilities.rb:76`), `Maker::LibraryTree#path_for` (`app/services/maker/library_tree.rb:43`).

## File structure

| path | responsibility | task |
|---|---|---|
| new `db/migrate/<ts>_add_library_scanned_at_to_users.rb`, `db/schema.rb`, `app/models/user.rb`, `app/jobs/library/scan_job.rb`, `config/routes.rb`, `app/controllers/files_controller.rb` (`#scan_status`, `#rescan`, `#update`, `#create`, `#finalize_upload`); `test/jobs/library/scan_job_test.rb`, `test/integration/web/rescan_test.rb`, `test/integration/web/repo_edit_flow_test.rb`, `test/integration/web/files_flow_test.rb` | the server side: one honest "a scan finished" stamp, the endpoint that reports it, the editor's Save re-enqueue, and one notice shape from **both** upload doors | A |
| `app/javascript/controllers/scanreload_controller.js`, `app/views/files/index.html.erb`, `app/views/projects/_attachments.html.erb`; `test/integration/web/rescan_test.rb`, `test/integration/web/project_scan_button_test.rb`, `test/system/project_scan_reload_test.rb` | the two Rescan doors poll it instead of guessing | B |
| `app/controllers/files_controller.rb` (`#show`), `app/views/files/show.html.erb`, new `app/javascript/controllers/copy_controller.js`, `app/javascript/controllers/thumbs_controller.js`, `app/assets/stylesheets/pages/preview.css`; `test/integration/web/file_page_test.rb`, `test/integration/web/files_flow_test.rb`, `test/system/files_pages_test.rb` | the file page: its library path with Copy, and its own preview | C |
| `app/javascript/lib/chunk_upload.js`, `app/javascript/controllers/uploader_controller.js`, `app/javascript/controllers/importer_controller.js`, `app/javascript/lib/print_sheet.js`, `app/javascript/controllers/measure_controller.js`, `app/views/files/_measure.html.erb`, `app/assets/stylesheets/pages/preview.css`; `test/integration/web/file_page_test.rb`, `test/system/measure_export_test.rb` | Save to library, both artifacts, both doors | D |
| `docs/user-stories.md` (re-tag 2.10–2.13), `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md` (S4-3 row → landed), `docs/invariants/files-preview.md` (the poll's reload mode), `docs/invariants/measure-view.md` (the save twins) | close-out | E |

**Dependencies.** A first: B, C and D all read what it writes, and A owns every `files_controller.rb` change except `#show`. **B and C are disjoint — dispatch them in parallel.** D starts when C has committed (both append to `app/assets/stylesheets/pages/preview.css` and both add tests to `test/integration/web/file_page_test.rb`). E closes out.

---

### Task A: the scan stamp, the status endpoint, and one notice from both doors

**Files:**
- Create: `db/migrate/<timestamp>_add_library_scanned_at_to_users.rb`
- Modify: `db/schema.rb` (generated), `app/models/user.rb`, `app/jobs/library/scan_job.rb`, `config/routes.rb`, `app/controllers/files_controller.rb`
- Test: `test/jobs/library/scan_job_test.rb`, `test/integration/web/rescan_test.rb`, `test/integration/web/repo_edit_flow_test.rb`, `test/integration/web/files_flow_test.rb`

- [ ] **Step 1: the migration.** `bin/rails generate migration AddLibraryScannedAtToUsers`, then replace the body:

```ruby
# WHEN A LIBRARY SCAN LAST FINISHED, so Rescan can say so instead of guessing (stage 4, S4-3).
# NULL means "no scan has ever completed for this user", which is the state a fresh install and a
# chunk_remote deployment both sit in permanently — chunk_remote's catalog is a mirror of the sync
# server's changelog and no Library::ScanJob ever runs for it (§14b's `scannable`).
#
# NULLABLE, NO DEFAULT, NO INDEX. A default would claim a scan that never happened; the only reader
# is `current_user`, already loaded by the session, so there is nothing to index (and
# test/architecture_invariants_test.rb's prefix guard is about indexes, not columns).
class AddLibraryScannedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :library_scanned_at, :datetime
  end
end
```

- [ ] **Step 2: run it in dev AND test, and commit the schema.**

```bash
bin/rails db:migrate && LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails db:migrate RAILS_ENV=test
git diff --stat db/schema.rb
```
Expect `db/schema.rb` to gain exactly `t.datetime "library_scanned_at"` between `last_sign_in_ip` and `locked_at` (the dump sorts columns) and to bump `version:` to the new timestamp.

- [ ] **Step 3: the failing job test.** Append inside `Library::ScanJobTest` in `test/jobs/library/scan_job_test.rb` (its `setup`/`teardown` already reset `FileLayer`; `user!` is the file's own helper):

```ruby
    # THE ONE HONEST "A SCAN FINISHED" MARKER (stage 4, S4-3). The browser polls this through
    # /files/scan_status, so what it means matters: a pass that completed, INCLUDING the discovery
    # and intake steps whose results the reloaded page is expected to show.
    test "a completed scan stamps when it finished" do
      Dir.mktmpdir do |dir|
        user = user!
        File.binwrite(File.join(dir, "j.stl"), "bytes")
        assert_nil user.library_scanned_at, "nothing has scanned for a fresh user"

        travel_to Time.utc(2026, 9, 7, 12, 0, 0) do
          Library::ScanJob.perform_now(user_id: user.id, root: dir)
        end

        assert_equal Time.utc(2026, 9, 7, 12, 0, 0), user.reload.library_scanned_at
      end
    end

    # A REFUSAL IS NOT A FINISH, AND THE POLLER MUST NOT BE TOLD IT WAS. Library::Scanner::UnsafeScan
    # is the reconcile declining (a missing root, a mass-deletion trip); the catalog is untouched, so
    # a stamp here would send every watching page into a reload showing nothing new and reading as
    # "the scan worked". The failed-jobs row is the report (this job's own header), and the browser
    # gives up with a neutral sentence instead.
    test "a refused scan stamps nothing" do
      user = user!

      assert_raises(Library::Scanner::UnsafeScan) do
        Library::ScanJob.perform_now(user_id: user.id, root: "/nonexistent-#{SecureRandom.hex(4)}")
      end

      assert_nil user.reload.library_scanned_at
    end
```

- [ ] **Step 4: run it, expect FAIL.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/jobs/library/scan_job_test.rb -n /stamp/` → 2 runs, 1 failure (`NoMethodError: undefined method 'library_scanned_at'` on the first — the column is on the row but `assert_nil user.library_scanned_at` passes; the failure is `Expected: 2026-09-07 12:00:00 UTC / Actual: nil`) and 1 pass (the refusal test passes vacuously, which is why the first is the one that drives the code).

- [ ] **Step 5: stamp it.** In `app/jobs/library/scan_job.rb#perform`, append one line after `intake_models(user)`:

```ruby
      intake_models(user)
      # A SCAN FINISHED, AND THIS IS THE ONLY PLACE THAT SAYS SO (stage 4, S4-3). Read by
      # FilesController#scan_status, polled by scanreload_controller.js, which reloads the page when
      # it moves — replacing a fixed 6-second guess.
      #
      # LAST, NOT AFTER observer.call, AND THAT IS THE POINT OF THE POSITION: the three steps above
      # are what a maker expects the reloaded page to SHOW (a discovered project, a filed file, a
      # catalogued model). All three are rescued, so a bug in one still stamps — correct, because
      # the reconcile above it committed and that is what "the scan finished" claims.
      #
      # NOT IN AN `ensure`. Library::Scanner::UnsafeScan propagates from observer.call (this job
      # deliberately has no retry_on for it), and a stamp on that path would tell every watching
      # page the scan succeeded while the catalog was never touched.
      #
      # update_column: a bookkeeping stamp, not a user edit — no validations, no callbacks, and
      # `updated_at` left alone so a scan does not look like a profile change.
      user.update_column(:library_scanned_at, Time.current)
```

- [ ] **Step 6: run, expect PASS.** Same command → 2 runs, 0 failures.

- [ ] **Step 7: mutation check the placement.** Move the `user.update_column` line to directly after `observer.call`; run `bin/rails test test/jobs/library/scan_job_test.rb -n /stamp/` → still GREEN (both tests pass), which is the honest result and is why the *position* is argued in the comment rather than pinned. Now mutate what IS pinned: wrap the body of `#perform` in `begin … ensure user.update_column(:library_scanned_at, Time.current) end` → the refusal test FAILS with `Expected nil to be nil` → `Expected 2026-09-07 …` (`assert_nil` reports the actual Time). Restore with `git checkout -- app/jobs/library/scan_job.rb`; run → PASS. Report both outputs, and report the first mutation's green as green — it is a limit of the test, stated rather than hidden.

- [ ] **Step 8: the one spelling of the stamp.** In `app/models/user.rb`, beside the other small readers:

```ruby
  # THE ONE SPELLING OF "when did a library scan last finish" (stage 4, S4-3). The page renders it
  # into a data attribute and scanreload_controller.js compares the poll's answer to it as a
  # STRING, so the two sides must format identically or the comparison is either never equal (a
  # permanent reload loop) or always equal (a poll that never fires). One method, both callers.
  #
  # SIX DIGITS, NOT `.to_i`. §15: "a timestamp compared at .to_i is a guard that usually cannot
  # fail" — two scans inside one second would read as one, which on this poll means the page never
  # notices the second. Both Postgres and SQLite keep microseconds here.
  def library_scanned_stamp = library_scanned_at&.iso8601(6)
```

- [ ] **Step 9: the failing endpoint test.** Append to `test/integration/web/rescan_test.rb` inside `RescanTest`:

```ruby
    # --- The status endpoint the Rescan reload polls ---

    # THE WHOLE CONTRACT: one key, an ISO string or null, and the CLIENT decides whether it moved.
    # `running:` is deliberately NOT in this payload — see the action's own comment for the two
    # sources that were rejected and why each would lie.
    test "scan_status reports null before any scan and the stamp after one" do
      use_scannable_backend
      get scan_status_files_path, headers: { "Accept" => "application/json" }
      assert_response :success
      assert_nil JSON.parse(response.body).fetch("scanned_at")

      at = Time.utc(2026, 9, 7, 12, 0, 0)
      @user.update_column(:library_scanned_at, at)

      get scan_status_files_path, headers: { "Accept" => "application/json" }
      assert_equal @user.reload.library_scanned_stamp, JSON.parse(response.body)["scanned_at"]
      assert_match(/^2026-09-07T12:00:00\.000000/, JSON.parse(response.body)["scanned_at"],
                   "microseconds, so two scans in one second are two answers")
    end

    # UNGATED ON `scannable`, ON PURPOSE. require_scannable! redirects with a flash — the right
    # refusal for a button, and a 302 to an HTML page is nonsense to a JSON poller. chunk_remote
    # never renders the element that polls this, and `null` is the true answer there anyway.
    test "scan_status answers on a non-scannable backend too, rather than redirecting" do
      FileLayer.current = FileLayer::ChunkRemote.new
      get scan_status_files_path, headers: { "Accept" => "application/json" }
      assert_response :success
      assert_nil JSON.parse(response.body).fetch("scanned_at")
    end

    # ONE USER'S SCAN IS ONE USER'S. The column is on `users` and the action reads current_user;
    # this is the guard that keeps it that way if the action is ever "optimised" into a global.
    test "scan_status reports only the signed-in user's scan" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      other.update_column(:library_scanned_at, Time.current)

      get scan_status_files_path, headers: { "Accept" => "application/json" }
      assert_nil JSON.parse(response.body).fetch("scanned_at")
    end
```

- [ ] **Step 10: run, expect FAIL.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/rescan_test.rb -n /scan_status/` → 3 runs, 3 errors, `NameError: undefined local variable or method 'scan_status_files_path'`.

- [ ] **Step 11: the route.** In `config/routes.rb`, inside the `resources :files` `collection do` block, after `get "thumbnails"`:

```ruby
      # "Has a library scan finished since the page I am looking at was rendered?" (stage 4, S4-3).
      # JSON, polled by scanreload_controller.js after a Rescan, which is what replaced a fixed
      # 6-second guess at how long a NAS walk takes. Session-authed web endpoint like #thumbnails
      # beside it, not the device-token v1 API.
      get "scan_status"
```

- [ ] **Step 12: the action.** In `app/controllers/files_controller.rb`, directly after `#thumbnails` ends (line 347, before the `# GET /files/:id/geometry` comment block):

```ruby
  # GET /files/scan_status (JSON) — when this user's last library scan FINISHED, or null.
  #
  # ONE KEY, AND THE CLIENT OWNS THE COMPARISON. The page renders the stamp it was built with into
  # `data-scanreload-since-value`; the poller reloads when this answer is present and different.
  # That is the whole mechanism, and it needs nothing else to be correct: a scan that finished and
  # changed nothing still advances the stamp, and reloading to see "nothing new" is the honest
  # outcome of pressing Rescan.
  #
  # `running:` IS DELIBERATELY ABSENT, AND BOTH SOURCES FOR IT WERE REJECTED RATHER THAN OVERLOOKED.
  # (1) Solid Queue's semaphore: Library::ScanJob's `limits_concurrency` duration is ONE HOUR, a
  # safety valve for a dead worker rather than a runtime, so after a crash it would answer "running"
  # for an hour — and those tables do not exist under the test adapter, so no assertion here could
  # ever catch that. (2) A cache flag set at the top of #perform: §14e's rate-limit lesson exactly —
  # the test env's store would make the flag unfalsifiable, so its guard would pass for the wrong
  # reason. A key that can lie is worse than a key that is missing; the client bounds its own wait
  # instead and says something true when it gives up.
  #
  # NOT GATED ON `scannable`. require_scannable! answers a browser button with a redirect and a
  # flash, which is right for #rescan and nonsense for a poller. chunk_remote renders no element
  # that polls this, and null is its true answer forever.
  def scan_status
    render json: { scanned_at: current_user.library_scanned_stamp }
  end
```

- [ ] **Step 13: run, expect PASS.** Same command → 3 runs, 0 failures.

- [ ] **Step 14: mutation check the scoping.** Change `current_user.library_scanned_stamp` to `User.maximum(:library_scanned_at)&.iso8601(6)`; run → the third test FAILS (`Expected "2026-09-…" to be nil`). Restore; PASS. Report both.

- [ ] **Step 15: the Rescan door tells the truth about what happens next.** Four assertion edits in `test/integration/web/rescan_test.rb`, then the action.

  - line 68 → `assert_redirected_to files_path(scanning: 1)`
  - line 69 → `assert_match(/scanning your library/i, flash[:notice])`
  - line 98 → `assert_redirected_to files_path(folder: "dir-1", scanning: 1)`
  - line 109 → `assert_redirected_to files_path(ext: "stl,3mf", scanning: 1)`
  - line 112 → `assert_redirected_to files_path(scanning: 1)`

  (`files_path`'s query is built through `Hash#to_query`, which sorts keys, so the extra param cannot make these order-dependent. Line 150's non-scannable redirect stays bare: that branch never starts a scan.)

  Then in `app/controllers/files_controller.rb#rescan`:

```ruby
  def rescan
    Library::ScanJob.enqueue_for(current_user)
    where = { folder: params[:folder].presence, ext: resolve_exts.presence&.join(",") }.compact
    # `scanning: 1` IS WHAT THE PAGE READS to render the poll element, exactly as the project page's
    # own scan door does (Projects::ScansController#enqueue_scan) — one marker, one meaning, two
    # doors. The element's own url is this same path WITHOUT the marker, which is what stops the
    # reloaded page polling again.
    #
    # THE FLASH NO LONGER SAYS "refresh in a moment" (stage 4, S4-3): it said that because nothing
    # here knew when a scan ended. Now something does, and promising a refresh the page will
    # actually perform is the difference story 2.11 named.
    redirect_to files_path(where.merge(scanning: 1)),
                notice: "Scanning your library. This page refreshes when the scan finishes."
  end
```

- [ ] **Step 16: run the rescan suite, expect PASS.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/rescan_test.rb` → 11 runs, 0 failures.

- [ ] **Step 17: the failing re-enqueue test.** Append to `test/integration/web/repo_edit_flow_test.rb`, inside `RepoEditFlowTest` beside the other save tests (its `setup` pins a share library and signs `@user` in; `seed_repo_file!`, `token_for` and `read_back` are `GitRepoFixture`'s):

```ruby
  # THE SAVE INVALIDATES THE PICTURE OF THE FILE, AND UNTIL NOW NOTHING SAID SO (stage 4, S4-3;
  # story 2.13's "the thumbnail and page stay stale after Save"). Every text extension has a
  # renderer — Maker::Previews::Registry DERIVES TextThumb for all 37 of them — so a saved .md
  # kept serving a thumbnail of the bytes it no longer had, on the Files grid, on the project
  # panel and on its own page, until the next 15-minute scan happened to notice.
  #
  # THE SAME DOOR THE TWO UPLOAD PATHS USE, not a third spelling: #enqueue_preview re-stats for the
  # content token the write just minted and swallows a vanished/unmounted library, because a
  # preview is best-effort UX and must never turn a successful save into an error.
  test "saving re-enqueues the thumbnail the save just invalidated" do
    node = seed_repo_file!("notes.md", "old\n")
    before_token = token_for(node)
    preview = @user.maker_previews.create!(
      node_id: node.node_id, version_id: before_token, kind: "thumbnail", status: "ready",
      renderer_revision: Maker::Previews::Enqueue.revision_for_name("notes.md", "thumbnail")
    )

    assert_enqueued_with(job: Maker::GeneratePreviewJob) do
      patch file_path(node.node_id), params: { content: "new\n", base_token: before_token }
    end

    assert_response :success
    preview.reload
    assert_equal "pending", preview.status, "a content repoint blanks the artifact (§14h)"
    assert_not_equal before_token, preview.version_id, "the row points at the bytes that now exist"
    assert_equal token_for(node.reload), preview.version_id
  end

  # A REFUSED SAVE MUST NOT TOUCH THE PREVIEW. The 409 writes nothing, so re-enqueueing there would
  # blank a correct picture for a save that never happened.
  test "a stale base_token refuses without disturbing the preview" do
    node = seed_repo_file!("notes.md", "old\n")
    preview = @user.maker_previews.create!(
      node_id: node.node_id, version_id: token_for(node), kind: "thumbnail", status: "ready",
      renderer_revision: Maker::Previews::Enqueue.revision_for_name("notes.md", "thumbnail")
    )

    assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
      patch file_path(node.node_id), params: { content: "new\n", base_token: "stale" }
    end

    assert_response :conflict
    assert_equal "ready", preview.reload.status
  end
```

Add `include ActiveJob::TestHelper` to the class if it is not already there (check line 5–13 first; if `assert_enqueued_with` resolves, it is).

- [ ] **Step 18: run, expect FAIL.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/repo_edit_flow_test.rb -n /re-enqueues|disturbing/` → 2 runs, 1 failure: `No enqueued job found with {job: Maker::GeneratePreviewJob}`.

- [ ] **Step 19: one line in `#update`.** In `app/controllers/files_controller.rb#update`, between the `Maker::RepoEdit.record!` line and the `render json:` line:

```ruby
    Maker::RepoEdit.record!(user: current_user, repo_root_node_id: root.node_id, node_id: node.node_id) if
      FileLayer.current.capabilities.local_worktree?
    # THE PICTURE OF THIS FILE IS NOW WRONG, AND THIS IS WHERE THAT IS SAID (stage 4, S4-3). The
    # SAME door both upload paths use (#create, #finalize_upload) rather than a third copy of
    # stat-then-Enqueue: it re-stats for the token `replace: true` just minted, and it swallows a
    # vanished or unmounted library, because a preview is best-effort and a save that reached the
    # store has already succeeded. Text files all have a renderer (Registry derives TextThumb), so
    # this is not a no-op for anything the editor can save.
    enqueue_preview(node_id: node.node_id, name: node.name)
```

- [ ] **Step 20: run, expect PASS.** Same command → 2 runs, 0 failures.

- [ ] **Step 21: mutation check.** Move the `enqueue_preview` call ABOVE the `write_bytes!` call; run → the first test FAILS on `assert_equal token_for(node.reload), preview.version_id` (the row points at the OLD bytes). Restore; PASS. Report both — this mutation is the one that matters, because an enqueue in the wrong order still enqueues a job and still passes `assert_enqueued_with`.

- [ ] **Step 22: the failing notice test.** Both upload doors must hand a JSON caller the same sentence, because S4-3 gives `#create` a second JSON caller and `#finalize_upload` its first. Append to `test/integration/web/files_flow_test.rb` inside `FilesFlowTest`:

```ruby
    # THE JSON DOOR CARRIES THE SWEEP'S OWN SENTENCE (stage 4, S4-3). #create's HTML branch has
    # always answered with project_intake_notice; its JSON branch answered `{node_id:}` alone,
    # deliberately, because its only caller was the model importer, which never uploads into a
    # PROJECT folder. Save-to-library is the second caller and does exactly that — so the fact the
    # old comment called "not threaded in" is now a fact somebody reads.
    test "a port upload's JSON answer carries the same notice its HTML answer would" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder = project.ensure_library_folder!(user)

      post files_path, params: { file: fixture_file_upload("sample.svg", "image/svg+xml"),
                                 parent_node_id: folder.node_id },
                       headers: { "Accept" => "application/json" }

      assert_response :created
      body = JSON.parse(response.body)
      assert body["node_id"].present?
      assert_equal "Uploaded sample.svg.", body["notice"]
    end
```

(If `test/fixtures/files/sample.svg` does not exist, use `Rack::Test::UploadedFile.new(StringIO.new("<svg xmlns='http://www.w3.org/2000/svg'/>"), "image/svg+xml", original_filename: "sample.svg")` — check `ls test/fixtures/files | grep svg` first and prefer a real fixture.)

- [ ] **Step 23: run, expect FAIL.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/files_flow_test.rb -n /JSON answer carries/` → 1 run, 1 failure: `Expected "Uploaded sample.svg." to equal nil`.

- [ ] **Step 24: both doors answer with the notice.** In `#create`, replace the `format.json` line and rewrite the paragraph above it that argued for its absence (lines 686–694):

```ruby
    # THE CONFLICT FACT (ProjectFolderIntake#left_unfiled_by_conflict?) IS THREADED INTO THIS JSON
    # BRANCH AS OF STAGE 4, S4-3, AND THIS COMMENT USED TO ARGUE THE OPPOSITE. Its argument was
    # sound and its precondition is gone: the omission was justified because `uploadPortFile`'s one
    # caller (importer_controller.js) always targets a MODEL's bundle folder, so
    # #intake_project_folder answered nil on this path regardless. Save-to-library (measure
    # _controller.js) targets the SOURCE FILE'S OWN parent, which is routinely a project folder —
    # so the sweep really can leave a save at the project root, and a caller with a readout really
    # can say so. The old comment's own instruction is what this follows: "#left_unfiled_by_conflict?
    # / #project_intake_notice already exist for it — wire it in here rather than reinventing the
    # check." ONE sentence, built by the concern, identical to the HTML branch's.
    respond_to do |format|
      format.html do
        redirect_to file_path(info.node_id), notice: project_intake_notice(intake_result, upload.original_filename)
      end
      format.json do
        render json: { node_id: info.node_id,
                       notice: project_intake_notice(intake_result, upload.original_filename) },
               status: :created
      end
    end
```

And in `#finalize_upload`, replace the body and the paragraph above it (lines 782–800) that argued the same omission:

```ruby
  def finalize_upload
    result = FileLayer.current.finalize_upload(
      current_user, commit_id: params.require(:commit_id), verify: true
    )
    # THE SAME SENTENCE AS #create's, FOR THE SAME REASON AND SINCE THE SAME SLICE (stage 4, S4-3).
    # This comment previously recorded that the fact was deliberately not surfaced because
    # `uploadChunkFile` "never reads a single key from its response body" — true then, false now:
    # Save-to-library reads `notice` off both doors, and lib/chunk_upload.js returns it from both,
    # so a chunk_remote maker gets the same feedback a share maker gets. Two doors, one wording,
    # which is what stops them drifting (§14a's one-condition-two-answers).
    notice = nil
    if result.info
      enqueue_preview(node_id: result.info.node_id, name: result.info.name)
      notice = project_intake_notice(intake_project_folder(result.info.node_id), result.info.name)
    end
    render json: { version_id: result.version_id, seq: result.seq, notice: }
  rescue FileLayer::ChunksMissing => e
    render json: { error: "chunks_missing", missing: e.hashes }, status: :unprocessable_entity
  end
```

- [ ] **Step 25: run, expect PASS.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/files_flow_test.rb test/integration/web/project_folder_intake_test.rb test/integration/web/project_upload_attach_test.rb test/integration/web/models_import_test.rb` → 0 failures. (The two intake suites assert the full HTML sentence; they must be untouched by this.)

- [ ] **Step 26: mutation check the notice.** In `#create`'s `format.json`, replace `project_intake_notice(intake_result, upload.original_filename)` with `"Uploaded."`; run the new test → FAILS (`Expected "Uploaded." to equal "Uploaded sample.svg."`). Restore; PASS. Report both.

- [ ] **Step 27: commit.**

```bash
git add db/migrate db/schema.rb app/models/user.rb app/jobs/library/scan_job.rb config/routes.rb app/controllers/files_controller.rb test/jobs/library/scan_job_test.rb test/integration/web/rescan_test.rb test/integration/web/repo_edit_flow_test.rb test/integration/web/files_flow_test.rb
git commit -m "A scan says when it finished, an editor's save re-enqueues its preview, and both upload doors answer with one sentence"
```

---

### Task B: the two Rescan doors poll a real "scan finished"

Starts after A. Disjoint from C — dispatch them together.

**Files:**
- Modify: `app/javascript/controllers/scanreload_controller.js`, `app/views/files/index.html.erb`, `app/views/projects/_attachments.html.erb`
- Test: `test/integration/web/rescan_test.rb`, `test/integration/web/project_scan_button_test.rb`, `test/system/project_scan_reload_test.rb`

- [ ] **Step 1: the failing view tests.** Append to `test/integration/web/rescan_test.rb`:

```ruby
    # THE FILES PAGE GETS THE RELOAD ELEMENT THE PROJECT PAGE HAS HAD (stage 4, S4-3). Before this
    # its Rescan said "refresh in a moment" and left the refreshing to the user.
    test "the files page schedules a poll only after a scan started, and points at the param-free url" do
      use_scannable_backend
      get files_path
      assert_select "[data-controller~=?]", "scanreload", false

      get files_path(scanning: 1)
      assert_select "[data-controller~=?]", "scanreload", 1
      assert_select "[data-scanreload-url-value=?]", files_path
      assert_select "[data-scanreload-status-url-value=?]", scan_status_files_path
      # NEVER SCANNED: an empty `since`, which the controller reads as "any stamp is news".
      assert_select "[data-scanreload-since-value=?]", ""
    end

    test "the poll element carries the stamp the page was rendered with, and keeps the folder" do
      use_scannable_backend
      create_node!(@user, node_id: "dir-1", name: "cad", kind: "dir")
      @user.update_column(:library_scanned_at, Time.utc(2026, 9, 7, 12, 0, 0))

      get files_path(folder: "dir-1", scanning: 1)

      assert_select "[data-scanreload-since-value=?]", @user.reload.library_scanned_stamp
      assert_select "[data-scanreload-url-value=?]", files_path(folder: "dir-1")
    end

    test "a non-scannable backend schedules no poll even with the marker" do
      FileLayer.current = FileLayer::ChunkRemote.new
      get files_path(scanning: 1)
      assert_select "[data-controller~=?]", "scanreload", false
    end
```

Append to `test/integration/web/project_scan_button_test.rb`, inside the existing reload-element test at line 223 (after its `assert_select "[data-scanreload-url-value=?]"` at line 233):

```ruby
      # THE POLL, NOT A GUESS (stage 4, S4-3). The element now carries where to ask and what it
      # already knew, so the reload fires when the scan actually finished.
      assert_select "[data-scanreload-status-url-value=?]", scan_status_files_path
      assert_select "[data-scanreload-since-value=?]", ""
```

- [ ] **Step 2: run, expect FAIL.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/rescan_test.rb test/integration/web/project_scan_button_test.rb` → 4 failures, each `Expected at least 1 element matching "[data-controller~='scanreload']"` / `"[data-scanreload-status-url-value=…]"`.

- [ ] **Step 3: the controller.** Replace `app/javascript/controllers/scanreload_controller.js` entirely:

```js
import { Controller } from "@hotwired/stimulus"

// A share/s3 library scan is a BACKGROUND job — an unbounded NAS walk or bucket listing, which is
// why library_scan polls every 15 minutes rather than every 15 seconds — so the page that started
// one cannot show the result. This waits for it and then reloads, ONCE.
//
// IT POLLS A REAL "SCAN FINISHED" AS OF STAGE 4, S4-3, AND USED TO GUESS 6000 ms. The guess was
// honest about being one (its own comment said "a large library outlasts it"), and the flash beside
// it had to tell the user to reload again. `users.library_scanned_at` is stamped by
// Library::ScanJob when a pass completes; `sinceValue` is what that column read when this page was
// RENDERED, so "different and present" means a scan finished after the page was built. A scan that
// finished having changed nothing still advances it, and reloading to see nothing new is the honest
// answer to pressing Rescan.
//
// IT NAVIGATES TO A URL RATHER THAN CALLING reload(), AND THAT IS WHAT STOPS IT LOOPING. The page
// renders this element only when ?scanning=1 is present; urlValue is the same page WITHOUT that
// param, so the reloaded page renders no scanreload element and polls nothing. A bare
// location.reload() would carry the param forward and reload forever.
//
// GIVING UP SAYS SOMETHING TRUE FOR ALL THREE ENDINGS. At the deadline the scan may still be
// walking, or it may have REFUSED (Library::Scanner::UnsafeScan stamps nothing, by design — see
// Library::ScanJob#perform), and this page cannot tell those apart. "Still scanning" would be a
// guess again; "nothing yet" is what is actually known.
const NOTHING_YET = "Nothing yet — reload to check again."

export default class extends Controller {
  static values = {
    url: String,
    statusUrl: String,
    since: String,
    interval: { type: Number, default: 2000 },
    timeout: { type: Number, default: 60000 }
  }

  connect() {
    this.deadline = Date.now() + this.timeoutValue
    this.tick()
  }

  // Turbo caches and restores pages, so a poll left running after the user navigates away would
  // yank them back to a page they had left.
  disconnect() {
    clearTimeout(this.timer)
  }

  async tick() {
    if (Date.now() >= this.deadline) return this.giveUp()

    try {
      const res = await fetch(this.statusUrlValue, { headers: { Accept: "application/json" } })
      if (res.ok) {
        const stamp = (await res.json()).scanned_at
        // PRESENT **AND** DIFFERENT. `stamp` alone would reload on a deployment that has scanned
        // before and has not scanned since; `!==` alone would reload forever on a user who has
        // never scanned at all, because null !== "".
        if (stamp && stamp !== this.sinceValue) return window.location.replace(this.urlValue)
      }
    } catch (_e) {
      /* transient; ask again below */
    }

    this.timer = setTimeout(() => this.tick(), this.intervalValue)
  }

  giveUp() {
    this.element.textContent = NOTHING_YET
  }
}
```

- [ ] **Step 4: the two views.** In `app/views/projects/_attachments.html.erb`, replace the element at lines 72–75:

```erb
  <% if @scan_started && capabilities.scannable? %>
    <span class="muted" data-controller="scanreload"
          data-scanreload-url-value="<%= project_path(@project) %>"
          data-scanreload-status-url-value="<%= scan_status_files_path %>"
          data-scanreload-since-value="<%= current_user.library_scanned_stamp %>"></span>
  <% end %>
```

(and extend the comment above it: the delay is a poll now, and the `class="muted"` is there because the give-up sentence lands in this element.)

In `app/views/files/index.html.erb`, directly after the `</div>` that closes `.page-head` (line 109) and before the `<% if project_upload %>` caption:

```erb
<%# THE RESCAN RELOAD (stage 4, S4-3). Same element, same rules and the same controller as the
    project page's (projects/_attachments.html.erb): rendered only on the async path, pointed at
    this page WITHOUT ?scanning=1 so the reloaded page schedules nothing, and carrying the scan
    stamp this render read so the poll can tell "finished" from "still going". `files_query_base`
    is the folder/type/query the user was in, so the reload lands where they were.
    §14d — a data-controller name that resolves to nothing is a SILENT no-op, which is why
    app/javascript/controllers/scanreload_controller.js must exist and stimulus_hygiene_test
    guards that it does. %>
<% if params[:scanning] == "1" && capabilities.scannable? %>
  <span class="muted" data-controller="scanreload"
        data-scanreload-url-value="<%= files_path(files_query_base) %>"
        data-scanreload-status-url-value="<%= scan_status_files_path %>"
        data-scanreload-since-value="<%= current_user.library_scanned_stamp %>"></span>
<% end %>
```

Also soften the project door's flash so it stops promising a timed refresh — in `app/controllers/projects/scans_controller.rb#enqueue_scan`:

```ruby
      redirect_to project_path(@project, scanning: 1),
                  notice: "Scanning your library for new files. This page refreshes when the " \
                          "scan finishes."
```

(`project_scan_button_test.rb:67` matches `/scanning your library/i`, which this keeps.)

- [ ] **Step 5: run, expect PASS.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/rescan_test.rb test/integration/web/project_scan_button_test.rb test/stimulus_hygiene_test.rb test/integration/web/template_hygiene_test.rb` → 0 failures.

- [ ] **Step 6: the system test, which is the only thing that can see the poll fire.** In `test/system/project_scan_reload_test.rb`, rewrite the class comment's mutation list (mutations 2 and 3 are about the 6000 ms delay and the param-free url; the delay is gone) and change the body of the first test so the scan is made to *finish*:

```ruby
    assert_selector "[data-controller~='scanreload']", visible: :all

    # THE SCAN FINISHES — IN RUBY, BECAUSE ActiveJob's test adapter never runs what it queues.
    # A system test shares its database connection with the server thread, so this row is what the
    # browser's next poll reads. Stamping it is exactly what Library::ScanJob#perform's last line
    # does, and pinning that line's EFFECT here rather than re-running the job keeps this test about
    # the browser half.
    @user.update_column(:library_scanned_at, Time.current)

    # THE ASSERTION THIS FILE EXISTS FOR: nobody drives this navigation. No click, no `visit`, no
    # Turbo submission — the browser leaves `?scanning=1` on its own, which it can only do if the
    # controller was constructed, connect() started the poll, the poll read a stamp different from
    # the one this page rendered with, and urlValue named where to go.
    assert_current_path project_path(@project), wait: 15
```

and add a second test for the half that used to be impossible to state:

```ruby
  # THE POLL DOES NOT RELOAD ON A SCAN THAT NEVER FINISHED, which is the whole difference between
  # this and the 6-second guess it replaced: the old controller navigated whether or not anything
  # had happened. NO_LOOP_WATCH outlives several poll intervals, so this is a claim about the
  # comparison rather than about timing.
  test "no scan finishing means no reload" do
    visit project_path(@project)
    click_on "Scan folder"
    assert_current_path project_path(@project, scanning: 1)
    assert_selector "[data-controller~='scanreload']", visible: :all

    sleep NO_LOOP_WATCH

    assert_current_path project_path(@project, scanning: 1), wait: 0
    assert_no_console_errors
  end
```

Change `NO_LOOP_WATCH`'s comment: it is no longer "past the controller's 6000 ms delay" but "past several 2000 ms poll intervals".

- [ ] **Step 7: run the system tests, expect PASS.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/project_scan_reload_test.rb` → 2 runs, 0 failures.

- [ ] **Step 8: mutation checks.** (i) In `scanreload_controller.js#tick`, drop `&& stamp !== this.sinceValue` → the new "no scan finishing means no reload" test still passes (nothing stamped), but the FIRST test's `assert_no_selector "[data-controller~='scanreload']"` after the reload still passes too — so instead mutate `if (stamp && stamp !== this.sinceValue)` to `if (stamp === undefined)`: the first test FAILS with `expected "/projects/desk-lamp?scanning=1" to equal "/projects/desk-lamp"`. (ii) Change `data-scanreload-since-value` in `projects/_attachments.html.erb` to a literal `""` → the first test still passes; then stamp the user in that test's *setup* instead of mid-test and the same mutation makes it FAIL — do not add that; report it as the known limit, and rely on `rescan_test.rb`'s `since-value` assertion (Step 1) for the attribute itself. (iii) Remove the `giveUp()` call → nothing goes red (the sentence is on a path no test outlives); state that plainly rather than adding a 60-second test. Restore each; PASS. Report all outputs.

- [ ] **Step 9: commit.**

```bash
git add app/javascript/controllers/scanreload_controller.js app/views/files/index.html.erb app/views/projects/_attachments.html.erb app/controllers/projects/scans_controller.rb test/integration/web/rescan_test.rb test/integration/web/project_scan_button_test.rb test/system/project_scan_reload_test.rb
git commit -m "Rescan waits for the scan that actually finished, on both doors, instead of guessing six seconds"
```

---

### Task C: the file page shows its library path, and refreshes its own preview

Starts after A (both edit `app/controllers/files_controller.rb`). Disjoint from B.

**Files:**
- Modify: `app/controllers/files_controller.rb` (`#show`), `app/views/files/show.html.erb`, `app/javascript/controllers/thumbs_controller.js`, `app/assets/stylesheets/pages/preview.css`
- Create: `app/javascript/controllers/copy_controller.js`
- Test: `test/integration/web/file_page_test.rb`, `test/integration/web/files_flow_test.rb`, `test/system/files_pages_test.rb`

- [ ] **Step 1: the failing path test.** Append to `test/integration/web/file_page_test.rb` inside `FilePageTest`:

```ruby
    # WHERE THE FILE IS ON THE SHARE — story 2.10's whole complaint. The page showed Name, Size,
    # Type and Modified and never once said where the thing lives, so the way back to LightBurn was
    # to remember the folder. Root-relative and NOT a URL: this app cannot know the mount's name on
    # the maker's own machine, and inventing an smb:// would be a guess dressed as a fact.
    test "the meta list carries the file's library path, with a copy button over it" do
      cad = @user.nodes.create!(node_id: "d-cad", name: "cad", kind: "dir",
                                mtime: 1_000_000_000, size: 0)
      deep = @user.nodes.create!(node_id: "d-lids", name: "lids", kind: "dir",
                                 parent_node_id: cad.node_id, mtime: 1_000_000_000, size: 0)
      node = @user.nodes.create!(node_id: "n-lid", name: "lid.lbrn2", kind: "file",
                                 parent_node_id: deep.node_id, mtime: 1_000_000_000, size: 12)

      get file_path(node.node_id)

      assert_response :success
      assert_select "dl.meta dt", text: "Path"
      assert_select "dl.meta dd .file-path-value", text: "cad/lids/lid.lbrn2"
      assert_select "dl.meta dd [data-controller~=?]", "copy"
      assert_select "dl.meta dd [data-copy-text-value=?]", "cad/lids/lid.lbrn2"
      assert_select "dl.meta dd button[data-action=?]", "copy#copy", text: "Copy"
    end

    test "a file at the library root is its own path" do
      get file_path(@node.node_id)
      assert_select "dl.meta dd .file-path-value", text: "coaster.lbrn2"
    end

    # A BROKEN ANCESTOR CHAIN IS "WE DO NOT KNOW", NOT A ROOT-LEVEL FILE. Maker::LibraryTree
    # #path_for answers nil for a tombstoned or missing ancestor; rendering the bare name there
    # would say the file sits at the top of the library, which is a confident lie about where to
    # find it. No row at all is the honest answer.
    test "a file whose folder chain is broken shows no path rather than a wrong one" do
      orphan = @user.nodes.create!(node_id: "n-orphan", name: "stray.svg", kind: "file",
                                   parent_node_id: "d-gone", mtime: 1_000_000_000, size: 1)
      get file_path(orphan.node_id)
      assert_select "dl.meta dt", text: "Path", count: 0
    end
```

- [ ] **Step 2: run, expect FAIL.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/file_page_test.rb` → 3 failures, `Expected at least 1 element matching "dl.meta dt"` with text "Path".

- [ ] **Step 3: the controller.** In `app/controllers/files_controller.rb#show`, directly after the `@move_conflict = move_conflict_prompt` line:

```ruby
    # WHERE THIS FILE IS, IN THE LIBRARY'S OWN TERMS (stage 4, S4-3; story 2.10). The SAME reader
    # #index uses for its folder column (#folder_paths_for) — Maker::LibraryTree is ONE pluck of
    # this user's dir rows and an in-memory walk, so this is constant in the size of the library
    # and needs no port read at all. Asking `folder_crumbs`-style, one find_by per level, would be
    # a query per ancestor for the same answer.
    #
    # NIL WHEN THE CHAIN IS BROKEN, AND THE VIEW RENDERS NOTHING THEN. `path_for` answers nil for a
    # tombstoned or missing ancestor (its own contract: "nil IS AN ANSWER, NOT AN ERROR"), and
    # falling back to the bare name would say the file sits at the library root — a confident wrong
    # answer to the one question this row exists to answer.
    #
    # ROOT-RELATIVE, WITH NO SCHEME. `path_for(nil)` is "" for a file at the root, so the join
    # drops it. This app cannot know what the share is mounted as on the maker's machine, so an
    # smb:// or file:// here would be a guess printed as a fact; the maker pastes this into
    # whatever their own Finder/Explorer path is.
    folder_path = Maker::LibraryTree.new(current_user).path_for(@node.parent_node_id)
    @library_path = folder_path && [ folder_path.presence, @node.name ].compact.join("/")
```

- [ ] **Step 4: the meta row.** In `app/views/files/show.html.erb`, insert between the `Modified` row (line 65) and `</dl>` (line 66):

```erb
  <%# WHERE IT IS, AND A BUTTON THAT PUTS IT ON THE CLIPBOARD (stage 4, S4-3; story 2.10). The
      path is root-relative on purpose — see FilesController#show. `dl.meta dd` is already mono
      (components.css), so the value needs no class of its own for its font; `.file-path-value` is
      what the copy fallback selects when the clipboard API is unavailable, which is the ordinary
      case on a self-hosted plain-http box.

      LAST IN THE LIST, because it is the longest value here and the four-column layout above 900px
      pairs rows: a wrapping path at the end of the grid disturbs nothing above it. %>
  <% if @library_path %>
    <dt>Path</dt>
    <dd class="file-path" data-controller="copy" data-copy-text-value="<%= @library_path %>">
      <span class="file-path-value" data-copy-target="source"><%= @library_path %></span>
      <button type="button" class="linkbtn" data-action="copy#copy">Copy</button>
    </dd>
  <% end %>
```

- [ ] **Step 5: run, expect FAIL on the missing controller only.** Same command → 3 runs, 0 failures for the request tests; `bin/rails test test/stimulus_hygiene_test.rb` → FAILS, `app/views/files/show.html.erb declares "copy", which has no controller file`. That failure is the §14d guard doing its job: a name that resolves to nothing is a silent no-op.

- [ ] **Step 6: the copy controller.** Create `app/javascript/controllers/copy_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// Put one string on the clipboard and say so on the button that asked.
//
// WHY A FALLBACK EXISTS AT ALL, AND WHY IT IS NOT BELT AND BRACES. `navigator.clipboard` is gated
// on a SECURE CONTEXT, and this app is routinely self-hosted at a plain-http hostname on a LAN
// (docs/DEPLOY.md) — so on the deployment this button is FOR, the modern API is simply `undefined`.
// A copy button that silently does nothing there is worse than no button. `document.execCommand`
// is deprecated and is still the only thing that works in that context.
//
// THREE OUTCOMES, EACH VISIBLE: the clipboard took it (the button flashes), the fallback took it
// (same flash — the user cannot tell and does not need to), or neither could, in which case the
// text is SELECTED so a manual ⌘C finishes the job. Nothing here fails silently.
//
// S4-4 MOUNTS THIS ON THE PUBLIC URL, so `text` is a value rather than something read off the DOM:
// a caller that has the string does not have to also render it.
const FLASH_MS = 1500

export default class extends Controller {
  static values = { text: String, label: { type: String, default: "Copied" } }
  static targets = ["source"]

  async copy(event) {
    // CAPTURED BEFORE THE AWAIT, WHICH IS NOT TIDINESS. `event.currentTarget` is nulled by the
    // browser once dispatch finishes, so reading it after `await` gives null and the flash lands
    // nowhere — with no error, on a button that appears to do nothing.
    const button = event?.currentTarget
    const text = this.textValue
    if (!text) return

    let ok = false
    try {
      if (window.isSecureContext && navigator.clipboard) {
        await navigator.clipboard.writeText(text)
        ok = true
      }
    } catch (_e) {
      ok = false
    }
    if (!ok) ok = this.execCopy(text)
    if (ok) this.flash(button)
    else this.selectSource()
  }

  // The insecure-context path. The textarea must be IN the layout to be selectable — `hidden` and
  // `display:none` cannot be selected, so the copy silently does nothing — hence off-screen and
  // transparent rather than hidden. `readonly` keeps iOS from raising the keyboard.
  execCopy(text) {
    const area = document.createElement("textarea")
    area.value = text
    area.setAttribute("readonly", "")
    area.style.cssText = "position:fixed;top:0;left:-9999px;opacity:0"
    document.body.appendChild(area)
    area.select()
    let ok = false
    try {
      ok = document.execCommand("copy")
    } catch (_e) {
      ok = false
    }
    area.remove()
    return ok
  }

  // Neither door worked: leave the text selected so ⌘C finishes it by hand.
  selectSource() {
    if (!this.hasSourceTarget) return
    const range = document.createRange()
    range.selectNodeContents(this.sourceTarget)
    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
  }

  // `original` is captured on the FIRST flash, before the label is replaced, so a second click
  // inside the window restores the real word rather than "Copied".
  flash(button) {
    if (!button) return
    clearTimeout(this.timer)
    this.original ??= button.textContent
    button.textContent = this.labelValue
    this.timer = setTimeout(() => { button.textContent = this.original }, FLASH_MS)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
```

- [ ] **Step 7: run, expect PASS.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/file_page_test.rb test/stimulus_hygiene_test.rb` → 0 failures.

- [ ] **Step 8: the failing self-refresh tests.** Append to `test/integration/web/files_flow_test.rb` inside `FilesFlowTest` (its `setup` pins a fresh share library, so these run identically on all three legs):

```ruby
    # THE FILE PAGE FINISHES ITS OWN PREVIEW (stage 4, S4-3; story 2.11). Until now only the GRIDS
    # polled — thumbs_controller.js ran on files/_list and files/_grid and on nothing else — so a
    # page opened while a render was in flight showed "Generating preview…" until the maker
    # reloaded it by hand. The poll cell is on the preview ROW, so it covers every branch below it
    # at once (measure poster, 3D poster, Gerber poster, the plain thumbnail) rather than four
    # copies of one marker.
    test "a page whose preview is still rendering polls for it and asks to be reloaded" do
      user = sign_in
      node_id = upload("widget.3mf", "zzz".b)   # #create enqueues; the row is pending

      get file_path(node_id)

      assert_response :success
      assert_select ".preview-row[data-controller~=?]", "thumbs"
      assert_select ".preview-row[data-thumbs-url-value=?]", thumbnails_files_path
      assert_select ".preview-row[data-thumbs-reload-value=?]", "true"
      assert_select "[data-thumbs-target='cell'][data-node-id=?][data-thumbs-pending='true']", node_id
    end

    test "a page whose preview is ready declares nothing pending, so it polls nothing" do
      user = sign_in
      node_id = upload("widget.3mf", "zzz".b)
      token = FileLayer.current.stat(user, node_id:).content_token
      preview = user.maker_previews.find_by!(node_id:, version_id: token, kind: "thumbnail")
      preview.update!(status: "ready")
      preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png",
                           content_type: "image/png")

      get file_path(node_id)

      assert_select "img.preview-image"
      assert_select "[data-thumbs-target='cell']", count: 0
    end

    # A NAME NOTHING CAN RENDER HAS NOTHING COMING. Maker::Previews::Enqueue creates no row for it
    # (skip_unrenderable), so @thumbnail is nil and a cell here would poll forever for an answer
    # the endpoint would only ever call `unsupported`.
    test "a file no renderer claims declares nothing pending" do
      sign_in
      node_id = upload("archive.tar", "zzz".b)
      get file_path(node_id)
      assert_select "[data-thumbs-target='cell']", count: 0
    end
```

- [ ] **Step 9: run, expect FAIL.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/files_flow_test.rb -n /polls for it|declares nothing/` → 3 runs, 1 failure (the first: no `.preview-row[data-controller~='thumbs']`); the two negative tests pass vacuously, which is why the first drives the code.

- [ ] **Step 10: the poll cell.** In `app/views/files/show.html.erb`, replace **lines 113–114** (the `.preview-row` opener *and* the `.preview` opener directly under it — the snippet below re-emits the second one, so replacing only 113 would leave two `<div class="preview">`):

```erb
<%# THE PAGE FINISHES ITS OWN PREVIEW (stage 4, S4-3). One `thumbs` controller on the row covers
    every branch below — the Measure poster, the 3D poster, the Gerber poster and the plain
    thumbnail all show the same server render, so one poll answers for all four instead of four
    copies of a marker. It costs a connected controller and ZERO requests on a page with nothing
    pending: `pendingIds()` is empty, so `poll()` returns before it fetches.

    RELOAD MODE, NOT AN IMAGE SWAP, AND THE REASON IS THAT THE WHOLE PAGE IS STALE. The four
    posters have four different resting markups (a poster plus a download link, a status <p> a
    Gerber controller targets, a bare sentence), so swapping an <img> in would put the JS in charge
    of markup the ERB owns, in four shapes. And the picture is not the only thing waiting on that
    render: the Laser Settings and CNC panels are drawn from @thumbnail.metadata, and Size and
    Modified come from the same stat. A reload is one mechanism and the honest one. %>
<div class="preview-row<%= " has-settings" if @thumbnail&.metadata.present? %>"
     data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>"
     data-thumbs-reload-value="true">
  <%# THE POLL SET, DECLARED RATHER THAN INFERRED. Grid cells announce themselves as pending by
      holding a `.thumb-spinner`; there is no spinner here, so this element says so outright and
      the controller clears the flag the moment an answer arrives. Rendered ONLY while a render is
      genuinely in flight: a name with no renderer has no row and nothing coming, and a ready row
      has arrived. %>
  <% if %w[pending processing].include?(@thumbnail&.status) %>
    <span class="preview-poll" hidden data-thumbs-target="cell"
          data-node-id="<%= @node.node_id %>" data-thumbs-pending="true"></span>
  <% end %>
  <div class="preview">
```

- [ ] **Step 11: the poll's reload mode.** In `app/javascript/controllers/thumbs_controller.js`:

(a) the values, replacing line 7:
```js
  static values = { url: String, reload: Boolean }
```

(b) `connect`, replacing lines 10–13:
```js
  connect() {
    this.tries = 0
    this.reloaded = false
    this.poll()
  }
```

(c) `pendingIds`, replacing lines 19–23:
```js
  // A CELL IS PENDING IF IT LOOKS IT OR SAYS IT. A grid cell announces itself by holding a
  // `.thumb-spinner`; the file page's cell has no thumb box at all (its poster is the page's own
  // full-width preview), so it declares `data-thumbs-pending` instead and the flag is cleared as
  // soon as an answer arrives — so a page never polls past the answer it was waiting for.
  pendingIds() {
    return this.cellTargets
      .filter((c) => c.querySelector(".thumb-spinner") || c.dataset.thumbsPending === "true")
      .map((c) => c.dataset.nodeId)
  }
```

(d) the answer loop, replacing lines 43–51:
```js
        for (const cell of this.cellTargets) {
          const entry = data[cell.dataset.nodeId]
          if (!entry) continue
          if (entry.status === "ready" && entry.url) {
            const declared = cell.dataset.thumbsPending === "true"
            delete cell.dataset.thumbsPending
            this.setImage(cell, entry.url)
            // RELOAD MODE (stage 4, S4-3), for a surface whose poster is not a `.thumb` and whose
            // OTHER content — the laser/CNC settings panel, Size, Modified — came from the same
            // render. `setImage` above is a no-op there (no `.thumb` to fill), so the reload is
            // what makes the answer visible. Only for a cell that DECLARED itself pending, so a
            // grid never reloads: its cells are found by their spinner and behave exactly as
            // before this mode existed.
            if (declared && this.reloadValue) return this.reloadOnce()
          }
          // A terminal non-ready state (no permissive renderer for this file here, or a render
          // error) resolves the spinner to a static icon — otherwise it would spin forever and
          // keep the cell in the poll set.
          else if (entry.status === "unsupported" || entry.status === "failed") {
            delete cell.dataset.thumbsPending
            this.setIcon(cell)
          }
        }
```

(e) a new method beside `resolveStragglers`:
```js
  // ONCE PER CONNECT, WHICH IS WHAT BOUNDS THIS. The reloaded page renders the ready poster, so no
  // cell declares itself pending, so nothing polls and nothing reloads — the loop closes on the
  // server's own answer rather than on a counter. The guard is here anyway because a page that
  // reloaded itself repeatedly would be unusable and unrecoverable by the user.
  reloadOnce() {
    if (this.reloaded) return
    this.reloaded = true
    clearTimeout(this.timer)
    window.location.reload()
  }
```

- [ ] **Step 12: run, expect PASS.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/files_flow_test.rb test/integration/web/file_cell_payload_test.rb test/integration/web/maker_page_thumbnails_test.rb test/integration/web/template_hygiene_test.rb` → 0 failures.

- [ ] **Step 13: the CSS.** Append inside `@layer pages { … }` in `app/assets/stylesheets/pages/preview.css`, after the `.preview-row.has-settings` rules (line 275):

```css
  /* --- The library path row (stage 4, S4-3). `dl.meta dd` is already mono and already wraps
     anywhere (components.css), so this only lays the value and its button on one line and keeps
     the button from stretching. A page rule qualified inside `.meta`, never a redeclaration of
     `dl.meta` (design-system rule 3). --- */
  .meta .file-path { display: flex; align-items: baseline; gap: 8px; }
  .meta .file-path-value { min-width: 0; overflow-wrap: anywhere; }
  .meta .file-path .linkbtn { flex: 0 0 auto; }
```

- [ ] **Step 14: the browser tests.** Append to `test/system/files_pages_test.rb` (its `setup` pins a share library and signs in):

```ruby
  # THE COPY BUTTON, DRIVEN. Only a browser can say whether a Stimulus identifier resolved, whether
  # the click reached `copy#copy`, and whether the label flashed and came back — §14d's silent
  # no-op is exactly the failure a request test cannot see.
  #
  # `navigator.clipboard.writeText` IS STUBBED RATHER THAN READ BACK. Reading the real clipboard
  # needs a permission this driver does not grant, and the assertion that matters is what the
  # controller passed — the same shimming idiom measure_export_test.rb uses for
  # URL.createObjectURL.
  test "the path's Copy button copies the path and says it did" do
    node = @user.nodes.create!(node_id: "n-copy", name: "lid.svg", kind: "file",
                               mtime: 1_000_000_000, size: 4,
                               content_hash: "h-copy", current_version_id: "v-copy")
    visit file_path(node.node_id)
    assert_selector ".meta .file-path-value", text: "lid.svg"

    page.execute_script(<<~JS)
      window.__copied = null
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: { writeText: (t) => { window.__copied = t; return Promise.resolve() } }
      })
    JS

    find(".meta .file-path button", text: "Copy").click

    assert_equal "lid.svg", page.evaluate_script("window.__copied")
    assert_selector ".meta .file-path button", text: "Copied"
    assert_selector ".meta .file-path button", text: "Copy", wait: 5
    assert_no_console_errors
  end

  # THE INSECURE-CONTEXT PATH, WHICH IS THE ORDINARY ONE ON A SELF-HOSTED PLAIN-HTTP BOX. With
  # `navigator.clipboard` shadowed away the controller must reach execCommand rather than doing
  # nothing — and doing nothing is exactly what an unguarded `navigator.clipboard.writeText` would
  # do there, silently.
  test "with no clipboard API the copy falls back to execCommand" do
    node = @user.nodes.create!(node_id: "n-copy2", name: "tray.svg", kind: "file",
                               mtime: 1_000_000_000, size: 4,
                               content_hash: "h-copy2", current_version_id: "v-copy2")
    visit file_path(node.node_id)

    page.execute_script(<<~JS)
      window.__exec = null
      Object.defineProperty(navigator, "clipboard", { configurable: true, value: undefined })
      document.execCommand = (cmd) => { window.__exec = cmd; return true }
    JS

    find(".meta .file-path button", text: "Copy").click

    assert_equal "copy", page.evaluate_script("window.__exec")
    assert_selector ".meta .file-path button", text: "Copied"
    assert_no_console_errors
  end

  # THE PAGE FINISHES ITS OWN PREVIEW (story 2.11). Nobody drives this reload: the poll asks
  # /files/thumbnails, the row goes ready underneath it, and the page comes back carrying the
  # picture. The row is made ready IN RUBY because ActiveJob's test adapter never runs what it
  # queues, and a system test shares its connection with the server thread.
  test "a page opened mid-render reloads itself when the preview lands" do
    node_id = port_upload("widget.3mf", "zzz".b)
    visit file_path(node_id)
    assert_selector "[data-thumbs-target='cell'][data-thumbs-pending='true']", visible: :all
    assert_no_selector "img.preview-image"

    token = FileLayer.current.stat(@user, node_id:).content_token
    preview = @user.maker_previews.find_by!(node_id:, version_id: token, kind: "thumbnail")
    preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png",
                         content_type: "image/png")
    preview.update!(status: "ready")

    assert_selector "img.preview-image", wait: 15
    assert_no_selector "[data-thumbs-target='cell']", visible: :all,
                       "the reloaded page has nothing left to wait for, so it polls nothing"
    assert_no_console_errors
  end
```

(`port_upload` is `test_helper.rb`'s shared uploader; check it is reachable from `ApplicationSystemTestCase` — if not, upload through `FileLayer.current.write` directly and record the node id.)

- [ ] **Step 15: run the browser tier, expect PASS.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/files_pages_test.rb` → 5 runs, 0 failures.

- [ ] **Step 16: mutation checks.** Report all six outputs.
  - (i) In `files/show.html.erb`, change `if @library_path` to `if false` → `file_page_test.rb`'s path test FAILS on `dl.meta dt` "Path".
  - (ii) In `#show`, change `folder_path && [...]` to `[ folder_path.presence, @node.name ].compact.join("/")` (the nil-chain fallback) → the broken-chain test FAILS: `Expected 0 to match "dl.meta dt"` with text "Path" — 1 found.
  - (iii) In `copy_controller.js`, move `const button = event?.currentTarget` to AFTER the `await` (`const button = event?.currentTarget` inside `flash`'s caller) → the browser copy test FAILS at `assert_selector "…", text: "Copied"` (the flash lands on nothing).
  - (iv) In `copy_controller.js`, drop the `if (!ok) ok = this.execCopy(text)` line → the fallback test FAILS on `Expected "copy" to equal nil`.
  - (v) In `thumbs_controller.js#pendingIds`, drop `|| c.dataset.thumbsPending === "true"` → the system reload test FAILS at `assert_selector "img.preview-image", wait: 15`.
  - (vi) In `thumbs_controller.js`, change `if (declared && this.reloadValue)` to `if (this.reloadValue)` → the GRID suites stay green (no grid page sets `reload`), so instead change it to `if (declared)` and run `bin/rails test test/system/files_pages_test.rb test/system/file_menu_test.rb` → still green; report that as the known limit and rely on (v). Restore each; PASS.

- [ ] **Step 17: commit.**

```bash
git add app/controllers/files_controller.rb app/views/files/show.html.erb app/javascript/controllers/copy_controller.js app/javascript/controllers/thumbs_controller.js app/assets/stylesheets/pages/preview.css test/integration/web/file_page_test.rb test/integration/web/files_flow_test.rb test/system/files_pages_test.rb
git commit -m "The file page says where the file is, hands you the path, and finishes its own preview"
```

---

### Task D: Save to library, for the SVG export and the print sheet

Starts after C (both append to `app/assets/stylesheets/pages/preview.css` and both add cases to `test/integration/web/file_page_test.rb`).

**Files:**
- Modify: `app/javascript/lib/chunk_upload.js`, `app/javascript/controllers/uploader_controller.js`, `app/javascript/controllers/importer_controller.js`, `app/javascript/lib/print_sheet.js`, `app/javascript/controllers/measure_controller.js`, `app/views/files/_measure.html.erb`, `app/assets/stylesheets/pages/preview.css`
- Test: `test/integration/web/file_page_test.rb`, `test/system/measure_export_test.rb`

- [ ] **Step 1: the failing control test.** Append to `test/integration/web/file_page_test.rb` (`@node` is `coaster.lbrn2`, but its bare row has a nil `content_token`, which short-circuits the whole preview tree at `show.html.erb:115` — so this test needs its own node carrying BOTH content columns, `template_hygiene_test.rb:266-276`'s idiom):

```ruby
    # THE SAVE TWINS, AND THE ASSERTION BRANCHES ON THE DEPLOYMENT (§14a). `port_writable` names
    # WHICH DOOR the bytes go in, not whether uploads are possible: share and s3 POST them to
    # FilesController#create, chunk_remote drives begin_upload/finalize_upload. A form-shaped
    # assertion here would be red on the chunk_remote leg alone, which is the memory
    # `upload-form-assertions-must-branch-on-port-writable` records twice.
    test "the Measure bar offers Save to library beside each download, wired to this deployment's door" do
      node = @user.nodes.create!(node_id: "n-plate", name: "plate.lbrn2", kind: "file",
                                 mtime: 1_000_000_000, size: 90,
                                 content_hash: "h-plate", current_version_id: "v-plate")

      get file_path(node.node_id)

      assert_response :success
      assert_select ".measure-actions button[data-action=?]", "measure#saveSvg", text: "Save SVG"
      assert_select ".measure-actions button[data-action=?]", "measure#savePrint", text: "Save sheet"
      # The SOURCE's own parent — a save lands beside the file it came from, never at the root.
      assert_select ".measure-view[data-measure-parent-node-id-value=?]", ""
      # `capabilities` is a controller helper_method, so it is NOT in scope in an integration test:
      # ask the port directly, which is the same object the view's helper resolves to.
      if FileLayer.current.capabilities.port_writable?
        assert_select ".measure-view[data-measure-port-writable-value=?]", "true"
        assert_select ".measure-view[data-measure-create-url-value=?]", files_path
      else
        assert_select ".measure-view[data-measure-port-writable-value=?]", "false"
        assert_select ".measure-view[data-measure-begin-url-value=?]", begin_upload_files_path
        assert_select ".measure-view[data-measure-finalize-url-value=?]", finalize_upload_files_path
      end
    end

    test "the save target is the source file's own folder" do
      dir = @user.nodes.create!(node_id: "d-design", name: "design", kind: "dir",
                                mtime: 1_000_000_000, size: 0)
      node = @user.nodes.create!(node_id: "n-lid2", name: "lid.lbrn2", kind: "file",
                                 parent_node_id: dir.node_id, mtime: 1_000_000_000, size: 90,
                                 content_hash: "h-lid2", current_version_id: "v-lid2")

      get file_path(node.node_id)

      assert_select ".measure-view[data-measure-parent-node-id-value=?]", "d-design"
    end
```

Add `include LibraryCapabilities`-style access if `capabilities` is not reachable in an integration test — it is not; read it as `FileLayer.current.capabilities.port_writable?` in the test instead, and say so in a comment.

- [ ] **Step 2: run, expect FAIL.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/file_page_test.rb -n /Save to library|save target/` → 2 runs, 2 failures on the missing buttons.

- [ ] **Step 3: both doors return the notice as well as the id.** In `app/javascript/lib/chunk_upload.js`:

```js
// Upload a File/Blob (with a name) into parentNodeId. Returns { nodeId, notice } — the notice is
// the server's own sentence about what the project-folder sweep then did with it, or null. BOTH
// DOORS ANSWER THE SAME SHAPE (stage 4, S4-3): Save-to-library reads it, and a caller that only
// wants the id destructures the id. A door that answered a bare id here and an object there is the
// one-condition-two-answers divergence §14a forbids, one layer up.
export async function uploadChunkFile(file, { beginUrl, finalizeUrl, parentNodeId }) {
  const bytes = new Uint8Array(await file.arrayBuffer())
  const hash = await sha256Hex(bytes)
  const manifest = [{ hash, offset: 0, length: bytes.length }]
  const begin = await postJSON(beginUrl, { name: file.name, size: bytes.length, manifest, parent_node_id: parentNodeId || null })
  for (const [, url] of Object.entries(begin.put_urls || {})) {
    const res = await fetch(url, { method: "PUT", body: bytes })
    if (!res.ok) throw new Error(`chunk PUT failed (${res.status})`)
  }
  const final = await postJSON(finalizeUrl, { commit_id: begin.commit_id })
  return { nodeId: begin.node_id, notice: final.notice || null }
}

// Upload via the share/s3 multipart door (FilesController#create). Returns { nodeId, notice }.
export async function uploadPortFile(file, { createUrl, parentNodeId }) {
  const form = new FormData()
  form.append("file", file, file.name)
  if (parentNodeId) form.append("parent_node_id", parentNodeId)
  const res = await fetch(createUrl, {
    method: "POST", headers: { "Accept": "application/json", "X-CSRF-Token": csrfToken() }, body: form
  })
  const data = await res.json().catch(() => ({}))
  // THE SERVER'S OWN REFUSAL, NOT A STATUS CODE (stage 4, S4-3). A name already taken at the
  // destination is FileLayer::UnsupportedOperation, which FilesController maps to 422 with
  // `{ error: "…" }` — "plate-parts.svg already exists" is actionable and "upload failed (422)"
  // is not. `postJSON` above has always read the body this way; this door did not, so the two
  // doors gave a user two different answers to one condition.
  if (!res.ok) throw new Error(data.error || `upload failed (${res.status})`)
  if (!data.node_id) throw new Error("upload did not return a node id")
  return { nodeId: data.node_id, notice: data.notice || null }
}
```

Then the two existing callers, which must destructure:
- `app/javascript/controllers/uploader_controller.js:15` → `const { nodeId } = await uploadChunkFile(file, {`
- `app/javascript/controllers/importer_controller.js:119-121`:
```js
          const { nodeId } = this.portWritableValue
            ? await uploadPortFile(f.blob, { createUrl: this.portCreateUrlValue, parentNodeId: parent })
            : await uploadChunkFile(f.blob, { beginUrl: this.beginUrlValue, finalizeUrl: this.finalizeUrlValue, parentNodeId: parent })
```

- [ ] **Step 4: the print sheet's pure save half.** Append to `app/javascript/lib/print_sheet.js`, directly after `buildPrintFrame` (before the `spool` export):

```js
// THE SHEETS AS STANDALONE SVG DOCUMENTS, one string per page — the SAVE half of what `printSheets`
// spools (stage 4, S4-3).
//
// PURE, LIKE `renderSheet` AND UNLIKE `buildPrintFrame`, and that split is the whole reason this
// can exist as three lines. It builds a DETACHED XML document and never touches the host page: no
// iframe is created, no `.measure-print-frame` is swept, and a save can therefore never disturb a
// print the user is in the middle of. Going through `buildPrintFrame` and serialising its DOM
// would have done all three.
//
// THE `xmlns` COMES OFF BEFORE SERIALISING, AND IT IS NOT TIDINESS. `renderSheet` both creates the
// root through `el` (which is `createElementNS(SVG_NS, …)`) AND sets `xmlns` as an ordinary
// attribute — harmless in the print frame, which is never serialised. `XMLSerializer` writes the
// namespace declaration itself for an element in that namespace, so leaving the attribute on emits
// `xmlns` TWICE: not well-formed XML, and rejected outright by some importers. lib/export_svg.js
// records the same trap from the other side, which is why it never sets the attribute at all.
export function sheetDocuments(shapes, paper, meta) {
  const { pages } = buildSheets(shapes, paper)
  const doc = document.implementation.createDocument(null, null, null)
  return pages.map((page) => {
    const svg = renderSheet(doc, page, meta)
    svg.removeAttribute("xmlns")
    return `<?xml version="1.0" encoding="UTF-8"?>\n${new XMLSerializer().serializeToString(svg)}`
  })
}
```

- [ ] **Step 5: the two buttons.** In `app/views/files/_measure.html.erb`, add the upload wiring to the root element (lines 13–16):

```erb
<div class="measure-view"
     data-controller="measure"
     data-measure-url-value="<%= geometry_file_path(@node.node_id) %>"
     data-measure-name-value="<%= @node.name %>"
     <%#
       SAVE TO LIBRARY (stage 4, S4-3; story 2.12). Everything Measure produced was a browser
       download and nothing landed on the share, so an exported outline lived in ~/Downloads while
       the file it came from lived on the NAS.

       THE TWO DOORS, PICKED BY THE DEPLOYMENT AND NOT BY THE USER (§14a). `port_writable` names
       WHICH DOOR the bytes go in: true (share, s3) means one multipart POST to FilesController
       #create; false (chunk_remote) means the two-phase presigned flow, where the bytes go browser
       -> storage and never through Rails (§15). Both are rendered as values rather than one
       branch, because the controller has to choose in JavaScript anyway and
       importer_controller.js already picks between the same two functions the same way.

       THE DESTINATION IS THE SOURCE FILE'S OWN PARENT, so an export lands beside the thing it was
       exported from. Empty at the library root, which lib/chunk_upload reads as "no parent".
     %>
     data-measure-port-writable-value="<%= capabilities.port_writable? %>"
     data-measure-create-url-value="<%= files_path %>"
     data-measure-begin-url-value="<%= begin_upload_files_path %>"
     data-measure-finalize-url-value="<%= finalize_upload_files_path %>"
     data-measure-parent-node-id-value="<%= @node.parent_node_id %>">
```

and the two buttons, beside their download twins (after line 39 and after line 53):

```erb
      <button type="button" class="btn small" data-action="measure#print"
              data-measure-target="printButton">Print all</button>
      <%#
        SAVE, BESIDE PRINT. Constant text, for the reason the SVG button's is constant: the bar
        carries seven controls now and a second count-bearing label beside "Print 3 parts" is
        noise. The accessible name tracks the target, written by the same refreshPrintBar() from
        the same targetNoun(), so the four labels can only drift together.
      %>
      <button type="button" class="btn small ghost" data-action="measure#savePrint"
              data-measure-target="savePrintButton"
              aria-label="Save all as a print sheet in the library"
              title="Save all as a print sheet in the library">Save sheet</button>
```

```erb
      <button type="button" class="btn small ghost" data-action="measure#downloadSvg"
              data-measure-target="svgButton"
              aria-label="Download all as SVG" title="Download all as SVG">Download SVG</button>
      <button type="button" class="btn small ghost" data-action="measure#saveSvg"
              data-measure-target="saveSvgButton"
              aria-label="Save all as SVG in the library"
              title="Save all as SVG in the library">Save SVG</button>
```

- [ ] **Step 6: the controller.** In `app/javascript/controllers/measure_controller.js`:

(a) the imports (lines 2–3):
```js
import { PAPERS, printSheets, sheetDocuments } from "lib/print_sheet"
import { exportSvg } from "lib/export_svg"
import { uploadChunkFile, uploadPortFile } from "lib/chunk_upload"
```

(b) the values and targets (lines 59–60):
```js
  static values = {
    url: String, name: String,
    portWritable: Boolean, createUrl: String, beginUrl: String, finalizeUrl: String,
    parentNodeId: String
  }
  // EVERY VALUE HERE IS READ. Stimulus silently ignores a `data-*-value` the controller does not
  // declare — the trap `name` records above — and the converse costs nothing but is still a lie
  // about what this surface needs, so a value that no method reads does not get declared.
  static targets = ["stage", "dims", "fallback", "paper", "printButton", "svgButton",
                    "savePrintButton", "saveSvgButton"]
```

(c) `print()`'s meta, extracted so the two callers cannot drift — replace the `printSheets(...)` call's option hash with `this.sheetMeta()` and add the method beside `targetNoun()`:

```js
  // THE SHEET FURNITURE'S FACTS, IN ONE PLACE. `print()` and `savePrint()` render the SAME sheets
  // and must not disagree about the header, the date or how a size is written — the one-definition
  // rule targetShapes()/targetNoun() already keeps for the target set.
  //
  // sizeLabel READS `d` AND `b`, THE SERVER'S FULL-RESOLUTION NUMBERS, NEVER `p` (the THINNED
  // drawing points). Re-deriving a size from those under-reports every curve and loses the ⌀
  // outright, because this side has no circularity test (§14h). Measured: the mutation prints
  // "10 × 10 mm" where "⌀10 mm" belongs.
  sheetMeta() {
    return {
      name: this.nameValue,
      // LOCAL, NOT UTC. `toISOString()` stamps an evening print in the Americas with TOMORROW's
      // date, on a sheet whose header exists so a page found on a bench next week can be trusted.
      date: new Date().toLocaleDateString("en-CA"),
      sizeLabel: (shape) => this.sizeLabel(shape),
    }
  }
```

(d) the two save actions, after `downloadSvg()`:

```js
  // --- Save to library (stage 4, S4-3) ---------------------------------------------------
  //
  // THE SAME BYTES THE DOWNLOAD BUILDS, THROUGH THE SAME TWO DOORS EVERY OTHER UPLOAD USES.
  // `exportSvg` and `sheetDocuments` are the pure builders; this half owns the Blob, the name and
  // the door — the split print_sheet.js draws between renderSheet and buildPrintFrame, and
  // export_svg.js between the document and the anchor.
  //
  // NOT Maker::Addons::LibraryOutput, WHICH WAS THE OTHER CANDIDATE. That is the ADDON save door:
  // it takes bytes SERVER-side and calls the port's own put_chunk, which is right for a generator
  // whose output is produced in Rails and has no client to presign for. Here the browser already
  // holds the bytes, so the upload doors keep them out of Rails entirely on chunk_remote (§15) and
  // give share/s3 the same multipart write they already use.
  //
  // THE NAME IS THE SOURCE'S BASE NAME PLUS THE SAME SUFFIX THE DOWNLOAD USES. Two names for one
  // set of bytes is two answers to one question: `downloadSvg` writes `<base>-parts.svg`, so this
  // does too, and a maker who downloaded first and saved second gets one file, not two spellings.
  saveSvg() {
    const shapes = this.targetShapes()
    if (!shapes || !shapes.length) return
    const base = this.nameValue.replace(/\.[^.]+$/, "")
    this.saveAll([ { name: `${base}-parts.svg`, body: exportSvg(shapes, { colors: this.colors }) } ],
                 this.saveSvgButtonTarget)
  }

  // ONE FILE PER SHEET, AND THE PLURAL CASE IS NOT AN EDGE CASE. A to-scale plan that needs four
  // tiles IS four pages — that tiling is the whole point of the sheet — so collapsing them into one
  // document would throw away what the maker asked for. A single sheet keeps the plain name so the
  // common case reads as one thing.
  savePrint() {
    const shapes = this.targetShapes()
    if (!shapes || !shapes.length) return
    const base = this.nameValue.replace(/\.[^.]+$/, "")
    const paper = PAPERS[this.paperTarget.value] || PAPERS[DEFAULT_PAPER]
    let bodies
    try {
      bodies = sheetDocuments(shapes, paper, this.sheetMeta())
    } catch (e) {
      // buildSheets' refusals (nothing selected, MAX_SHEETS) reach the readout, the way print()'s
      // do — they throw before any file exists, so a swallowed message is a button that does
      // nothing whatsoever. AND IT LOGS, because this catch cannot tell a refusal from a bug.
      console.warn("[measure] sheet save refused:", e)
      return this.setStatus(e.message)
    }
    const files = bodies.map((body, i) => ({
      name: bodies.length === 1 ? `${base}-print.svg`
                                : `${base}-print-${i + 1}of${bodies.length}.svg`,
      body
    }))
    this.saveAll(files, this.savePrintButtonTarget)
  }

  // ONE UPLOAD LOOP FOR BOTH BUTTONS, sequential rather than parallel: the doors are the same doors
  // an ordinary upload uses, and a browser firing four concurrent multipart POSTs at a Puma pool is
  // the shape §14e records as a stall. A file that refuses (a name already taken on share/s3 — the
  // port's clobber refusal, 422) is REPORTED BY NAME and stops the run, because the sheets after it
  // would collide identically and four identical messages say nothing the first did not.
  async saveAll(files, button) {
    const previous = button.textContent
    button.disabled = true
    button.textContent = "Saving…"
    try {
      let last = null
      for (const file of files) {
        last = await this.uploadOne(new File([ file.body ], file.name, { type: "image/svg+xml" }))
      }
      // THE SERVER'S OWN SENTENCE WHEN IT HAS ONE. Both doors answer with `notice`, built by
      // ProjectFolderIntake — so when the project-folder sweep could not file the save into its
      // category folder because a file of that name is already there, the maker is told, in the
      // wording every other upload door uses. Otherwise: what was written, and how many.
      this.setStatus(last?.notice || `Saved ${files.length === 1 ? files[0].name : `${files.length} sheets`}.`)
    } catch (e) {
      console.warn("[measure] save refused:", e)
      this.setStatus(e.message)
    } finally {
      button.disabled = false
      button.textContent = previous
    }
  }

  // THE TWO-DOOR CHOICE, MADE THE WAY importer_controller.js MAKES IT. `port_writable` is the
  // deployment's answer to "which door do bytes go in", never "can this deployment take uploads" —
  // chunk_remote takes uploads all day, through the flow on the false branch (§14a).
  uploadOne(file) {
    return this.portWritableValue
      ? uploadPortFile(file, { createUrl: this.createUrlValue, parentNodeId: this.parentNodeIdValue })
      : uploadChunkFile(file, { beginUrl: this.beginUrlValue, finalizeUrl: this.finalizeUrlValue,
                                parentNodeId: this.parentNodeIdValue })
  }
```

(e) `refreshPrintBar()` writes all four accessible names from the one noun — replace its two `setAttribute` lines with:

```js
    const label = `Download ${noun} as SVG`
    this.svgButtonTarget.setAttribute("aria-label", label)
    this.svgButtonTarget.setAttribute("title", label)
    // THE SAVE TWINS TRACK THE SAME TARGET. Four labels, one targetNoun(), so a button can never
    // describe a set a sibling does not act on; the ERB's at-rest literals are these same strings
    // with `noun` = "all", which is what makes them drift together or not at all.
    const svgSave = `Save ${noun} as SVG in the library`
    this.saveSvgButtonTarget.setAttribute("aria-label", svgSave)
    this.saveSvgButtonTarget.setAttribute("title", svgSave)
    const sheetSave = `Save ${noun} as a print sheet in the library`
    this.savePrintButtonTarget.setAttribute("aria-label", sheetSave)
    this.savePrintButtonTarget.setAttribute("title", sheetSave)
```

- [ ] **Step 7: the bar wraps.** In `app/assets/stylesheets/pages/preview.css`, change line 230 and line 232:

```css
  /* Seven controls since stage 4, S4-3 (paper, Print, Save sheet, Download SVG, Save SVG, Reset,
     ✕ Image), so the row WRAPS rather than squashing them: flex items shrink by default, and a
     nowrap row of seven at 375px pushes the page sideways (design-system rule 11). */
  .measure-bar { display: flex; align-items: center; gap: 8px; margin-top: 8px; flex-wrap: wrap; }
  .measure-actions { display: none; gap: 4px; flex-wrap: wrap; }
```

- [ ] **Step 8: run the request tests, expect PASS.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/file_page_test.rb test/integration/web/template_hygiene_test.rb test/css_hygiene_test.rb test/stimulus_hygiene_test.rb` → 0 failures.

- [ ] **Step 9: the browser tests, which are the only tier that can run this JavaScript.** Append to `test/system/measure_export_test.rb`. Its setup already stands up a REAL share library holding `sample.lbrn2` and renders its geometry, so a save really lands on disk and really becomes a node.

```ruby
  # ---- Save to library --------------------------------------------------------------------

  # THE ROUND TRIP CLOSING (story 2.12): the same bytes the Download button builds, written into the
  # SOURCE file's own folder through the deployment's own upload door. This fixture pins SHARE
  # (`FileLayer.current =` in setup), so it exercises the `port_writable` branch on all three legs —
  # the chunk_remote branch is a rendered-attribute claim, pinned in file_page_test.rb, because a
  # browser here has no sync server to commit against.
  test "Save SVG writes the selection into the source file's folder and says so" do
    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10
    find(".measure-stage circle.measure-contour").click
    assert_text "1 part"

    find("[data-measure-target='saveSvgButton']").click

    assert_text "Uploaded sample-parts.svg.", wait: 15
    node = @user.nodes.present.find_by!(name: "sample-parts.svg")
    assert_equal @user.nodes.find_by!(node_id: @sample_id).parent_node_id, node.parent_node_id,
                 "a save lands beside the file it came from"
    # THE BYTES ARE REALLY THERE, AND THEY ARE REALLY THE EXPORT. 20mm is the circle alone — the
    # 40 x 20 Rect around it would read 40mm, the whole file 100mm.
    body = File.read(@root.join(node.storage_path))
    assert_includes body, 'width="20mm"'
    assert_includes body, "<circle "
    assert_no_console_errors
  end

  # A NAME ALREADY TAKEN IS THE PORT'S CLOBBER REFUSAL, AND IT MUST REACH THE READOUT AS WORDS.
  # FileLayer::Share#write refuses an overwrite with UnsupportedOperation, FilesController maps that
  # to 422 with `{ error: … }`, and lib/chunk_upload reads the body — before S4-3 it threw away the
  # message and said "upload failed (422)", which tells a maker nothing about what to do.
  test "saving over a name that exists refuses in words, not in a status code" do
    File.binwrite(@root.join("sample-parts.svg"), "<svg/>")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)

    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10

    find("[data-measure-target='saveSvgButton']").click

    assert_text(/already exists/i, wait: 15)
    assert_equal "<svg/>", File.read(@root.join("sample-parts.svg")), "nothing was overwritten"
  end

  # THE PRINT SHEET AS A FILE. `sheetDocuments` is print_sheet.js's PURE half, so this must produce
  # a paper-sized document with the header on it and no iframe anywhere — and exactly ONE xmlns,
  # which is the trap `renderSheet`'s own `xmlns` attribute sets for a serialiser.
  test "Save sheet writes a paper-sized, well-formed sheet" do
    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10
    page.execute_script("document.querySelector('.measure-paper').value = 'A4'")

    find("[data-measure-target='savePrintButton']").click

    assert_text(/Uploaded sample-print/, wait: 15)
    node = @user.nodes.present.find_by!(name: "sample-print.svg")
    body = File.read(@root.join(node.storage_path))
    assert_includes body, 'width="210mm"'
    assert_includes body, 'height="297mm"'
    assert_equal 1, body.scan(/xmlns=/).size, "a doubled xmlns is not well-formed XML"
    assert_no_console_errors
  end

  # THE ACCESSIBLE NAMES OF ALL FOUR BUTTONS COME FROM ONE targetNoun(), so a Save can never
  # describe a set its Download twin does not act on.
  test "the save buttons' accessible names track the same target the downloads do" do
    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10

    assert_selector "[data-measure-target='saveSvgButton'][aria-label='Save all as SVG in the library']"
    assert_selector "[data-measure-target='savePrintButton'][aria-label='Save all as a print sheet in the library']"

    find(".measure-stage circle.measure-contour").click

    assert_selector "[data-measure-target='saveSvgButton'][aria-label='Save 1 part as SVG in the library']"
    assert_selector "[data-measure-target='savePrintButton'][aria-label='Save 1 part as a print sheet in the library']"
    assert_selector "[data-measure-target='saveSvgButton']", exact_text: "Save SVG"
  end
```

- [ ] **Step 10: run the browser tier, expect PASS.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/measure_export_test.rb test/system/measure_print_test.rb test/system/uploader_test.rb test/system/importer_test.rb` → 0 failures (the last two are the destructuring change's callers).

- [ ] **Step 11: mutation checks.** Report all eight outputs.
  - (i) In `print_sheet.js#sheetDocuments`, drop `svg.removeAttribute("xmlns")` → the print-sheet test FAILS on `Expected: 1 / Actual: 2` for `xmlns=`.
  - (ii) In `measure_controller.js#saveSvg`, change `parentNodeId: this.parentNodeIdValue` to `parentNodeId: null` (in `uploadOne`) → the first save test FAILS on the parent assertion (`Expected "d-…" to equal nil`) — run it with the sample inside a folder if `sample.lbrn2` sits at the root, by moving the fixture into `@root.join("laser")` in that one test.
  - (iii) In `chunk_upload.js#uploadPortFile`, restore `throw new Error(\`upload failed (${res.status})\`)` → the clobber test FAILS on `expected to find text matching /already exists/i`.
  - (iv) In `measure_controller.js#saveAll`, drop `last?.notice ||` → the first save test FAILS (`expected to find text "Uploaded sample-parts.svg."`, found "Saved sample-parts.svg.").
  - (v) In `refreshPrintBar`, drop the four save `setAttribute` lines → the accessible-name test FAILS at the post-click assertion.
  - (vi) In `measure_controller.js#savePrint`, change `bodies.length === 1` to `false` → the print test FAILS on `find_by!(name: "sample-print.svg")` (`RecordNotFound`).
  - (vii) In `_measure.html.erb`, change `data-measure-port-writable-value` to a literal `"false"` → `file_page_test.rb`'s control test FAILS on the share leg.
  - (viii) In `chunk_upload.js#uploadChunkFile`, return the bare `begin.node_id` again → `test/system/importer_test.rb` FAILS (`nodeId` undefined → attach posts a null id). Restore each; PASS.

- [ ] **Step 12: commit.**

```bash
git add app/javascript/lib/chunk_upload.js app/javascript/lib/print_sheet.js app/javascript/controllers/measure_controller.js app/javascript/controllers/uploader_controller.js app/javascript/controllers/importer_controller.js app/views/files/_measure.html.erb app/assets/stylesheets/pages/preview.css test/integration/web/file_page_test.rb test/system/measure_export_test.rb
git commit -m "Measure can save its export and its print sheet into the library, beside the file they came from"
```

---

### Task E: close-out

- [ ] **Step 1: re-tag the stories** in `docs/user-stories.md`, T2's table, with the new evidence in the last column:
  - **2.10 → `works`** — the file page carries the library path as a mono value with a Copy button (`files/show.html.erb`, `copy_controller.js`, S4-3). The hand-off to a desktop program stays the OS's job and is named out of scope in the spec's §9, so this is `works` rather than `rough`: the app answers "where is it", which is what the story asked for.
  - **2.11 stays `rough`** — Rescan now polls a real "scan finished" (`users.library_scanned_at`, `GET /files/scan_status`, `scanreload_controller.js`) on both doors, and a file page opened mid-render finishes its own preview (`thumbs` reload mode). The remaining friction is the 15-minute recurring poll: a re-save you did not press Rescan for is still invisible until the schedule catches it.
  - **2.12 → `rough`** — Measure's SVG export and print sheet now write into the source file's folder through the deployment's own upload door (`measure_controller.js#saveSvg`/`#savePrint`, `lib/print_sheet.js#sheetDocuments`). Sheet CSV and BOM CSV are still browser downloads only.
  - **2.13 stays `rough`** — a save now re-enqueues the thumbnail it invalidated (`FilesController#update` → `#enqueue_preview`), so the page and the grids stop showing the old bytes' picture. Git-repos-only and the ≤200 KB cap are unchanged; the editable-anywhere half is S4-4 (D3).
  - Update the Coverage table: T2 becomes 5 `works` / 6 `rough` / 2 `missing`, and the `all` row 7 / 25 / 16 / 2. **Re-count from the table rather than trusting these numbers** — S4-1 and S4-2 may have moved rows first, and CLAUDE.md §15's own note about invented evidence figures applies to this line as much as any.
- [ ] **Step 2: the overview.** In `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md`, mark the S4-3 row landed with the branch and PR number, the way S4-1's row now reads.
- [ ] **Step 3: the two invariants files this slice changed behaviour in.**
  - `docs/invariants/files-preview.md`: under the `/files/thumbnails` section, add the reload mode — a cell may declare `data-thumbs-pending` instead of holding a spinner, `data-thumbs-reload-value` makes a *declared* pending cell reload the page once when its answer arrives, and the reason the file page reloads rather than swapping an `<img>` (four poster markups, plus the settings panel and the stat drawn from the same render).
  - `docs/invariants/measure-view.md`: beside the export rules, add the save twins — the same bytes and the same `<base>-parts.svg` name as the download, `sheetDocuments` as `print_sheet.js`'s pure save half, the `xmlns`-removed-before-serialising rule (the same trap `export_svg.js` records from the other side), one file per sheet, and that the door is chosen by `port_writable` and never by `LibraryOutput`.
- [ ] **Step 4: the gates.** `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci` green; read the three legs' run counts and confirm they are identical (a ±2 assertion / ±1 skip flap is `tinkerex#131`; a structural difference means a test depends on the ambient `LIBRARY_BACKEND` and is a real bug — the likeliest candidate here is `file_page_test.rb`'s `port_writable?` branch, so check that one first).
- [ ] **Step 5: commit, push, PR, record.** `git commit -m "S4-3 close-out: the stories re-tagged, the overview and two invariants files updated"`; `/finish-branch`; then `bin/log arc --from-pr <n>`.

---

## Self-review against the spec (§5's S4-3 row)

| spec item | task | how it is verified |
|---|---|---|
| the file page shows the library path with copy | C | `file_page_test.rb` (3 request tests: nested, root, broken chain), `files_pages_test.rb` (2 browser tests: clipboard path and execCommand fallback) |
| the file page refreshes its own preview | C | `files_flow_test.rb` (3 request tests: pending declares, ready does not, unrenderable does not), `files_pages_test.rb` (the undriven reload) |
| a browser Save re-enqueues the preview | A | `repo_edit_flow_test.rb` (enqueued + row repointed + status pending; and the 409 leaves it alone) |
| Measure's SVG export gains Save to library | D | `file_page_test.rb` (the control, branching on `port_writable?`), `measure_export_test.rb` (bytes on disk, in the source's folder) |
| the print sheet gains Save to library | D | `measure_export_test.rb` (paper-sized, single `xmlns`, `-print.svg`) |
| it rides the existing two-door upload flow | D | `uploadPortFile`/`uploadChunkFile` unchanged in mechanism; the door picked by `port_writable`, asserted per leg |
| into the source file's folder | D | `parent_node_id` = `@node.parent_node_id`, asserted in both tiers |
| a clobber surfaces as a message, not a 500 | D | `measure_export_test.rb`'s refusal test; `uploadPortFile` now reads the 422 body |
| the sweep's sentence reaches the maker | A, D | `files_flow_test.rb` (both doors answer `notice`), `measure_export_test.rb` (it is what the readout shows) |
| Rescan polls a real "scan finished" | A, B | `scan_job_test.rb` (stamped on success, not on refusal), `rescan_test.rb` (endpoint + element on the Files door), `project_scan_button_test.rb` (element on the project door), `project_scan_reload_test.rb` (the reload fires only when a scan finished) |
| bytes go through the port or the upload doors, never `File.write` | A, D | no `File.write` anywhere in this slice's app code; §15 kept on chunk_remote by using the presigned door |
| `Public::` untouched | — | this slice adds no public route and reads no session outside the private namespace |
| `page_query_budget_test.rb` does not grow | C | it has **no `files#show` entry** (checked); `#show` gains ONE `Maker::LibraryTree` pluck, constant in the library's size, on a single-file page |
| a new Stimulus controller exists before a template names it | C | `copy_controller.js` created in the same step as the attribute; `stimulus_hygiene_test.rb` derives it from the filename and is run at Step 5/7 |
| the migration runs in dev and test, schema committed | A | Step 2 |
| every guard mutation-checked | A–D | 4 + 3 + 6 + 8 mutations, each with its expected failing output named |

## Open questions the implementer must not decide alone

1. **`-parts.svg`, not `-flat.svg`.** The slice brief named `<basename>-flat.svg`; `measure_controller.js:322` already downloads `<basename>-parts.svg`, and giving the same bytes two names is two answers to one question. This plan uses `-parts.svg` for both. **If the spec author wants `-flat`, the download and the save must be renamed in the same edit**, and `measure_export_test.rb:218`'s `assert_equal [ "sample-parts.svg" ]` moves with them.
2. **`running:` is not in `/files/scan_status`.** The brief named `{ scanned_at:, running: }`. Both honest sources were rejected (Solid Queue's one-hour semaphore lies after a worker crash and has no rows under the test adapter; a cache flag is unfalsifiable in the test env, §14e). The client bounds its own wait and says "Nothing yet — reload to check again." **Adding `running:` needs a second column** (`library_scan_started_at`), which the spec's §4 data table does not list — so it is a spec change, not a plan choice.
3. **`UnsafeScan` stamps nothing, so a refused scan and a slow scan look the same to the browser.** The failed-jobs row is the operator's report (`Library::ScanJob`'s own header). If a maker-facing "your library refused to scan" is wanted, that is a second column or a flash mechanism and belongs in its own slice.
4. **A same-named save behaves differently per backend, and no test asserts otherwise.** Share/s3 refuse the clobber (422, surfaced as words); chunk_remote's `begin_upload` mints a new node id, so a second save of the same name does not refuse. That divergence is the backends', not this slice's, but it means the refusal test is share-shaped by construction. **Do not "fix" it by adding a name check at the door** — that would be a fourth copy of a guard the port owns (§14a).
5. **The Files-page Rescan poll is new surface** (the project page's already existed). If it must be cut for scope, cut it — `files/index.html.erb`'s block plus the four `rescan_test.rb` redirect edits — and keep the project door, which is what story 2.11's evidence cites. The endpoint and the column stay either way.
6. **`measure_export_test.rb`'s mutation (ii)** needs `sample.lbrn2` to sit inside a folder to prove the parent is threaded. Decide whether to move the fixture for that one test or to add a second fixture copy under `@root.join("laser")`; do not weaken the assertion to "a node exists".
