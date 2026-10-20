# K — Choose the library folder in-app: implementation plan

> **For agentic workers:** execute with `.claude/commands/execute-plan.md` (this repo's default):
> one task per unit, disjoint tasks in parallel, one capped quality review per task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** a fresh `share` install confirms its library folder once, in the browser, before the
first scan, and can narrow it to a subfolder of the mount; the folder can be changed later, keeping
the catalog (a scan under the mass-deletion guard) or starting over (a catalog wipe that never
touches disk).

**Spec:** `docs/superpowers/specs/2026-10-20-k-library-chooser-design.md`.

**Architecture:** `LIBRARY_PATH` becomes the *mount*; a new `settings` row (`library.root`) holds
the chosen folder relative to it; `Tinkerex::LibraryRoot` is the one reader/writer and
`FileLayer::Share`'s default root is their join. "Pending" (row absent, backend share) pauses the
scan schedule and redirects signed-in HTML pages to `/settings/library`. A change is applied per
user by `Library::RootChangeJob`, which holds the scan's own semaphore, optionally runs
`Library::Reset`, then scans inline.

**Tech stack:** Rails 8.1, Solid Queue concurrency controls, Stimulus + `lib/file_chooser.js`,
Minitest (three backend legs: share / s3 / chunk_remote — RUN counts must match, §15).

---

## Deviations from the spec, decided here (each is the owner's to reverse at review)

1. **`settings` has an integer `id` and a unique index on `key`**, not `key` as primary key — every
   other table here has an `id`, and the YAML fixture (below) then needs nothing special.
2. **Two migrations, not one**: `CreateSettings` (schema) and `ConfirmExistingLibraryRoot` (the
   data step), so the data step is testable by `.new.up` the way
   `test/models/maker/seed_pcb_filing_rules_migration_test.rb` tests its migration.
3. **`users.library_scan_refusal` (text) is added**, because §5 needs the page to *show* an
   `UnsafeScan` refusal and nothing persists one today (`FilesController#scan_status` says why the
   queue tables are not a source). `Library::ScanJob` writes it on refusal and clears it on success.
4. **The stale-root discard keys on `enqueued_at`, not on the root alone.** The spec's "compare
   `root:` with `FileLayer.current.root` and discard" contradicts `ScanJob#perform`'s pinned
   contract — *"`root:` given = a caller named a share root and gets it scanned, whatever the
   deployment is"* (`scan_job_test.rb`'s second test, and ~40 tests that scan a tmpdir). So a job is
   discarded only when it was **enqueued before the library folder last changed** *and* names a
   different root. `perform_now` (a command) has no `enqueued_at` and keeps the contract.
5. **A folder change goes through `Library::RootChangeJob` per user**, not a bare
   `ScanJob.perform_later`. Solid Queue releases a semaphore only when a job *finishes*, so a scan
   enqueued from inside the reset would be discarded by `ScanJob`'s own `on_conflict: :discard`, and
   a scan enqueued while an old-root scan runs would be dropped the same way. The job declares
   `group: "Library::ScanJob"` (so its key IS the scan's key), `on_conflict: :block`, and scans
   inline with `perform_now`. The first-run confirmation still uses `enqueue_first_for` (spec §4.5).
6. **The reset runs per user, one transaction each, under that user's semaphore** — the scan's
   semaphore is per user, so one all-users transaction could not hold it.
7. **The reset table list, confirmed against `db/schema.rb`:**
   - destroyed: `maker_file_attachments`, `maker_file_links`, `maker_pins`, `maker_notes` (rich
     text, so `destroy`), `maker_previews` (`destroy`, which purges the blob), `maker_repo_edits`,
     `maker_addon_files` (through the user's addon states), `nodes` (tombstones included);
   - nulled: `maker_projects.folder_node_id`/`cover_node_id`, `maker_releases.repo_node_id`,
     `maker_items.primary_node_id`, and an import model's `folder_node_id`/`cover_node_id`;
   - **`maker_bom_lines.node_id` is not simply nulled**: `exactly_one_target` would then lock the
     row (§14d), so the line takes the file's name as its `part_name` first —
     `InventoryItem#release_bom_lines`' precedent;
   - **auto-origin `maker_models` are destroyed**, dismissed ones too. `Maker::ModelIntake::Prune`
     cannot do this job (it only destroys models whose folder a project claims), and a dismissal
     names a `node_id` that the reset deletes and no later scan can mint again, so there is nothing
     for it to keep dismissed. Import models are the maker's and survive, pointers nulled;
   - **kept**: `maker_release_files` (history by design: "a file deleted … after the release keeps
     this row", and it renders "gone"), and `maker_project_blocks` (an image block requires its
     `node_id`; a dangling one is already hidden by `projects/_block_panel`).
   - also: `users.library_scanned_at` and `library_scan_refusal` → nil.
8. **The demo account cannot change the folder** (`Tinkerex::Demo.demo?`), the same refusal it
   gets for its credentials.
9. **(Found while building Task 4.)** The form posts `start_over=1` from the Start over button only,
   not `mode=switch|reset`: a plain submit (Switch, Use this folder, Enter) keeps the catalog, and
   the accent button carries no `value` for `accent_spend_test.rb` to read as its label.
10. **(Found in review; reverses the spec's §2 "One process".)** Jobs do NOT run in the Puma process:
    Solid Queue 1.7's Puma plugin forks its supervisor and workers (`start_forked`, the default
    mode; `config/puma.rb` never sets `solid_queue_mode :async`). So `Setting.get` is cached per
    request and per job in `Current`, never per process, and the factory-built `FileLayer::Share`
    resolves its root per call (`Tinkerex::LibraryRoot.path`) instead of fixing it at construction.
    Every process follows a change at its next request or job, nothing is reset, and the page's
    "restart the jobs process" sentence is gone. Cost: one indexed query per request or job on
    share; none off share (`pending?` asks the adapter first).
12. **(The owner's call after review: "relink".)** Start over no longer nulls a project's folder.
    The folders the maker's surviving records live in -- projects' `folder_node_id`, import models'
    `folder_node_id`, releases' `repo_node_id` -- are kept as SCAN tombstones (path kept, no trash
    entry, no parent), with their pins, notes and attachments; the scan of the new folder revives
    each one found at the same path with its old node_id (`Library::Reconciler#ensure_dirs`). So a
    start over onto the same `Projects/` layout re-links instead of adopting `desk-lamp-2`, and an
    archived project keeps its claim. A folder the new library lacks stays a tombstone (the existing
    "folder was deleted" state, which never re-mints); a pathless trash tombstone is forgotten.
11. **(Found in review.)** While pending, a non-HTML WRITE is refused 409 (a JSON
    `POST /files/rescan` indexed the whole mount); `tinkerex:demo:setup` confirms the mount for a
    freshly created demo account (refused the choice, it would otherwise face it forever).

## File map

| unit | files |
|---|---|
| T1 storage + reader | `db/migrate/20261020180000_create_settings.rb`, `db/migrate/20261020180100_confirm_existing_library_root.rb`, `db/schema.rb`, `app/models/setting.rb`, `lib/tinkerex/library_root.rb`, `app/services/file_layer/share.rb` (default root), `app/services/file_layer.rb` (one comment), `test/fixtures/settings.yml`, `test/test_helper.rb`, `lib/schema_map.rb`, `docs/schema-map.html`, tests `test/models/setting_test.rb`, `test/lib/library_root_test.rb`, `test/models/confirm_existing_library_root_migration_test.rb` |
| T2 gates + doors | `app/jobs/library/scan_job.rb`, `app/jobs/library/trash_purge_job.rb`, `lib/tasks/tinkerex.rake`, tests `test/jobs/library/scan_job_test.rb`, `test/jobs/library/trash_purge_job_test.rb`, `test/boot_scan_test.rb`, `test/tasks/tinkerex_tasks_test.rb`, `test/integration/web/registration_mode_test.rb` |
| T3 reset + change job | `app/services/library/reset.rb`, `app/jobs/library/root_change_job.rb`, tests `test/services/library/reset_test.rb`, `test/jobs/library/root_change_job_test.rb`, `test/jobs/concurrency_limits_test.rb` |
| T4 web | `app/controllers/application_controller.rb`, `app/controllers/help_controller.rb`, `app/controllers/settings/library_controller.rb`, `app/controllers/settings_controller.rb`, `config/routes.rb`, `app/views/settings/library/show.html.erb`, `app/views/settings/show.html.erb`, `app/views/shared/_where_files_come_from.html.erb`, `app/views/shared/_folder_field.html.erb`, `app/helpers/library_folder_helper.rb`, `app/javascript/lib/file_chooser.js`, `app/assets/stylesheets/pages/settings.css`, tests `test/integration/web/settings_library_test.rb`, `test/integration/web/settings_hub_test.rb`, `test/integration/web/template_hygiene_test.rb`, `test/helpers/library_folder_helper_test.rb` |
| T5 browser | `test/system/library_chooser_test.rb`, `test/system/accent_spend_test.rb` |
| T6 docs | `docs/INSTALL.md`, `README.md`, `.env.example`, `app/views/help/show.html.erb`, `CLAUDE.md` §14a, `test/docs_hygiene_test.rb` (ceiling, only if needed) |

**Order:** T1 → (T2 ∥ T3 ∥ T6) → T4 → T5 → bare `bin/ci`.

Every focused run needs the share env (memory: bare `bin/rails test` errors without it):
`LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test <files>`. Only one agent runs a
full suite at a time; commit with a pathspec; never `git add -A`.

---

## Task 1: the stored choice and its one reader

**Files:** as in the map.

- [ ] **Step 1 — migrations.**

`db/migrate/20261020180000_create_settings.rb`:

```ruby
# DEPLOYMENT-WIDE FACTS CHOSEN IN THE APP RATHER THAN IN THE ENVIRONMENT (K, 2026-10-20). One row per
# fact, keyed by name, because the next such fact should not need a migration of its own; the one key
# today is `library.root` (Tinkerex::LibraryRoot). An integer id beside a unique `key`, like every
# other table here, so the YAML fixture that confirms the test library needs nothing special.
#
# `users.library_scan_refusal` rides along: Library::ScanJob records an UnsafeScan's message there so
# /settings/library can show a refused folder change with its next step. A per-user stamp beside
# `library_scanned_at`, which is the same kind of fact.
class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings do |t|
      t.string :key, null: false
      t.text :value, null: false, default: ""
      t.timestamps
    end
    add_index :settings, :key, unique: true

    add_column :users, :library_scan_refusal, :text
  end
end
```

`db/migrate/20261020180100_confirm_existing_library_root.rb`:

```ruby
# AN EXISTING DEPLOYMENT HAS BEEN USING THE WHOLE MOUNT ALL ALONG, SO IT IS CONFIRMED BY CONSTRUCTION
# (K §2). With any account present, write `library.root = ""` -- the whole mount, today's behaviour --
# so its scans never pause and nobody is sent to a first-run screen. A fresh install has no account
# when this runs (and a brand-new database loads schema.rb, which runs no migration at all), so its
# row stays absent and the first-run screen is pending. s3 and chunk_remote deployments get the row
# too, harmlessly: Tinkerex::LibraryRoot.pending? is false there whatever it says.
#
# RAW SQL, NOT the Setting model: a model used in a migration drifts from the schema the migration
# saw. Quoted identifiers, because `key` and `value` are keywords to some dialects. Idempotent on the
# NOT EXISTS, so a re-run never fails on the unique index.
class ConfirmExistingLibraryRoot < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      INSERT INTO settings ("key", "value", created_at, updated_at)
      SELECT 'library.root', '', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      WHERE EXISTS (SELECT 1 FROM users)
        AND NOT EXISTS (SELECT 1 FROM settings WHERE "key" = 'library.root')
    SQL
  end

  # Nothing to undo: deleting the row would send a running deployment to the first-run screen.
  def down; end
end
```

Run `LIBRARY_PATH=$(mktemp -d) bin/rails db:migrate` and confirm `db/schema.rb` gains the
`settings` table, the `users.library_scan_refusal` column and version `2026_10_20_180100`.

- [ ] **Step 2 — `app/models/setting.rb`:**

```ruby
# DEPLOYMENT-WIDE FACTS CHOSEN IN THE APP (K, 2026-10-20) -- see db/migrate/*_create_settings.rb.
# Read through `get`, written through `put`, and nothing else touches the table.
#
# `get` IS MEMOISED PER PROCESS, and that is the point rather than an optimisation: the library
# redirect (ApplicationController) asks on EVERY signed-in request, and a setting changes once in a
# deployment's life. `put` and `forget` drop the memo in THIS process. Another process -- a bin/jobs
# container -- keeps its memo until it restarts, the same caveat FileLayer.current's memo carries
# (Tinkerex::LibraryRoot says where the page states it). Tests clear it per test (test_helper.rb),
# because the memo outlives each test's rollback.
#
# NO TABLE MEANS NO VALUE, AND IS NOT MEMOISED: migrations older than this table build
# FileLayer.current (db/migrate/*_purge_repo_metadata_nodes.rb), which now reads a setting, so a
# database part-way through `db:migrate` must answer nil rather than raise.
class Setting < ApplicationRecord
  validates :key, presence: true, uniqueness: true

  class << self
    def get(key)
      cache = (@cache ||= {})
      return cache[key] if cache.key?(key)
      return nil unless table_exists?

      cache[key] = find_by(key:)&.value
    end

    # An UPSERT on the unique key, so two people confirming at once cannot raise RecordNotUnique.
    def put(key, value)
      upsert({ key:, value: value.to_s }, unique_by: :key)
      @cache&.delete(key)
      value
    end

    def forget(key)
      where(key:).delete_all
      @cache&.delete(key)
    end

    # When the value last changed, for a job that must know whether it was queued before that.
    # Unmemoised: its one caller is a background scan, never a page.
    def changed_at(key) = where(key:).pick(:updated_at)

    def reset_cache! = @cache = nil
  end
end
```

- [ ] **Step 3 — `lib/tinkerex/library_root.rb`:**

```ruby
module Tinkerex
  # THE LIBRARY FOLDER IS THE MOUNT PLUS A STORED CHOICE INSIDE IT (K, 2026-10-20). LIBRARY_PATH is
  # the MOUNT -- what compose bound to /library and what the boot guard probes; the `library.root`
  # setting is the chosen folder RELATIVE to it ("" = the whole mount, absent = not chosen yet); the
  # share root is their join. This module is the one reader and writer of that setting, so no second
  # place joins the two halves.
  #
  # RELATIVE ON PURPOSE: the row never holds a host path, so widening or narrowing LIBRARY_HOST_PATH
  # keeps the choice meaningful or makes it visibly missing, never silently wrong.
  #
  # PENDING IS NOT A BOOT STATE. The whole mount is always a valid root, so `path` answers it while
  # nothing is chosen and FileLayer.current can always be built (the CSP header resolves it per
  # response, §14a). Pending is a fact the web layer (the redirect) and the scan schedule consult.
  #
  # ONE PROCESS. `choose!` resets FileLayer.current, which is memoised per process; every deployment
  # this repo ships runs its jobs inside Puma (Tinkerex::SolidQueueInPuma), so the next request and
  # the next job both see the new root. A separate bin/jobs process keeps the old root until it
  # restarts, and /settings/library says so when SOLID_QUEUE_IN_PUMA is off.
  module LibraryRoot
    KEY = "library.root".freeze

    # The chooser's listing stops here and says it did; a folder of more than 500 folders is
    # navigated by narrowing the mount, not by scrolling.
    LIST_CAP = 500

    # A choice the app refuses. The message is the sentence the page shows, naming the rule.
    Invalid = Class.new(StandardError)

    Listing = Data.define(:parent, :entries, :truncated)

    def self.mount
      raw = ENV["LIBRARY_PATH"]
      Pathname.new(raw).expand_path if raw.present?
    end

    def self.relative = Setting.get(KEY)

    def self.changed_at = Setting.changed_at(KEY)

    # Asked of the ADAPTER, so a test that installs `FileLayer.current = Share.new(root:)` is a share
    # deployment here too. The chooser is a share fact by nature: s3 has a prefix and chunk_remote no
    # folder, so every gate below is a no-op there.
    def self.share? = FileLayer.current.is_a?(FileLayer::Share)

    # The row first: once chosen, a deployment pays one memoised read and never builds the adapter.
    def self.pending? = relative.nil? && share?

    # FileLayer::Share's default root. ENV.fetch, as Share always did: FileLayer.build runs
    # LibraryBackendCheck first, so a missing LIBRARY_PATH is explained before it gets here.
    def self.path
      base = Pathname.new(ENV.fetch("LIBRARY_PATH")).expand_path
      rel = relative
      rel.blank? ? base : base.join(rel)
    end

    # "No live node for any user": on share every account indexes the one library.
    def self.catalog_empty? = !Node.present.exists?

    # Validates, probes, writes the row and resets the adapter, in that order; nothing is written
    # unless every check passed. Returns the normalised relative path.
    def self.choose!(relative)
      rel, dir = resolve!(relative)
      begin
        LibraryBackendCheck.writable!(dir.to_s)
      rescue LibraryBackendCheck::Error
        raise Invalid, unwritable_message(rel)
      end
      Setting.put(KEY, rel)
      FileLayer.reset!
      rel
    end

    # The whole mount: the console door's answer (an operator chose the mount by mounting it).
    def self.clear!
      Setting.put(KEY, "")
      FileLayer.reset!
    end

    # One folder's subfolders, for the chooser. DIRECTORIES ONLY, by lstat -- the Scanner's own
    # dispatch, so a symlink is neither listed nor followed -- and never a name `unchoosable?` refuses.
    def self.children(parent, limit: LIST_CAP)
      rel, dir = resolve!(parent)
      names =
        begin
          Dir.children(dir.to_s)
        rescue SystemCallError => e
          raise Invalid, "#{display(rel)} cannot be listed (#{e.message})."
        end
      dirs = names.select { |name| name.valid_encoding? && !unchoosable?(name) && real_dir?(dir.join(name)) }
                  .sort_by { |name| [ name.downcase, name ] }
      Listing.new(parent: rel, entries: dirs.first(limit).map { |name| rel.empty? ? name : "#{rel}/#{name}" },
                  truncated: dirs.size > limit)
    end

    # REJECT, NEVER NORMALISE -- FileLayer::S3#key_for's rule (§14a): `a/../b` is refused, not turned
    # into `b`. Every segment is lstat'd from the mount down, so a link anywhere on the way is refused
    # by name rather than followed out of the mount. -> [normalised relative, absolute Pathname]
    def self.resolve!(relative)
      base = mount or raise Invalid, "No library folder is mounted here (LIBRARY_PATH is not set)."
      rel = relative.to_s
      raise Invalid, "That folder name is not valid text." unless rel.valid_encoding?
      return [ "", base ] if rel.empty?
      raise Invalid, "Choose a folder inside the mounted folder, not an absolute path." if rel.start_with?("/")
      raise Invalid, "That folder name is not allowed." if rel.include?("\0")

      segments = rel.split("/", -1)
      raise Invalid, "#{rel.inspect} has an empty folder name in it." if segments.any?(&:empty?)
      if segments.any? { |s| s == "." || s == ".." }
        raise Invalid, "A folder path may not step outside the mounted folder (#{rel.inspect})."
      end
      if (bad = segments.find { |s| unchoosable?(s) })
        raise Invalid, "#{bad.inspect} is hidden or reserved by the library, so it cannot be the library's folder."
      end

      dir = base
      segments.each do |segment|
        dir = dir.join(segment)
        stat = begin
          dir.lstat
        rescue SystemCallError
          nil
        end
        raise Invalid, "#{rel} is a link, not a folder: the library never follows links." if stat&.symlink?
        raise Invalid, "#{rel} is not a folder any more; choose again." unless stat&.directory?
      end
      [ rel, dir ]
    end

    # Never the root, never listed: a dot-folder (which covers `.trash`, `.maker-tmp-*`, `.git` and
    # every dot-named clutter), and the library's reserved names that carry no dot (`__MACOSX`).
    # Library::ReservedNames is the write doors' own predicate, so the two cannot drift.
    def self.unchoosable?(name) = name.start_with?(".") || Library::ReservedNames.reserved?(name)

    def self.real_dir?(path)
      path.lstat.directory?
    rescue SystemCallError
      false
    end
    private_class_method :real_dir?

    def self.display(rel) = rel.empty? ? "The mounted folder" : rel
    private_class_method :display

    # THE OPERATOR'S FIX, IN THE OPERATOR'S WORDS (K §4.3). bin/docker-entrypoint infers the app's
    # uid from the MOUNT's owner, so a subfolder owned by someone else is exactly this case.
    def self.unwritable_message(rel)
      "The app runs as user #{Process.uid}:#{Process.gid} and cannot write in #{display(rel)}. " \
        "On Linux, set PUID and PGID in .env to that folder's owner (stat -c '%u:%g' on the folder, " \
        "on the host) and run docker compose up -d again."
    end
    private_class_method :unwritable_message
  end
end
```

- [ ] **Step 4 — `FileLayer::Share`'s default root** (`app/services/file_layer/share.rb:10`):

```ruby
    # THE ROOT IS THE MOUNT PLUS THE CHOSEN FOLDER (K, 2026-10-20; Tinkerex::LibraryRoot). `root:`
    # stays a keyword because ~240 tests build adapters over their own tmpdirs and must keep doing so.
    def initialize(root: Tinkerex::LibraryRoot.path)
```

and in `app/services/file_layer.rb` the comment at the `when "share"` arm becomes "Share.new
defaults to Tinkerex::LibraryRoot.path, which ENV.fetches LIBRARY_PATH and raises a bare KeyError
naming nothing…" (the reasoning is unchanged).

- [ ] **Step 5 — the test baseline.** `test/fixtures/settings.yml`:

```yaml
# EVERY TEST STARTS ON A CONFIRMED LIBRARY -- the state ConfirmExistingLibraryRoot gives an existing
# deployment. Without it the share leg is a fresh install, every signed-in page redirects to
# /settings/library, and the scan schedule pauses. A test about the first run deletes this row with
# Setting.forget(Tinkerex::LibraryRoot::KEY).
library_root:
  key: library.root
  value: ""
```

and in `test/test_helper.rb`'s per-test `setup` block, beside the two cache clears:

```ruby
      # Setting.get is memoised per process (app/models/setting.rb) and the memo outlives each test's
      # rollback, so a test that wrote or forgot a setting would leak it into the next.
      Setting.reset_cache!
```

- [ ] **Step 6 — schema map.** Add to `lib/schema_map.rb` `LAYOUT`, before the queue row:
`{ "label" => "Deployment settings", "group" => "ops", "tables" => %w[settings] },`. Regenerate
with `LIBRARY_PATH=$(mktemp -d) bin/rails schema:map` and run `test/schema_map_test.rb`.

- [ ] **Step 7 — tests.**

`test/models/setting_test.rb` — `get` nil for an absent key and the value for a present one;
`put` inserts then updates one row (`assert_equal 1, Setting.where(key:).count`) and `get` sees the
new value; `forget` deletes and `get` answers nil; **the memo**: after one `get`,
`assert_queries_count(0) { Setting.get(key) }`, and a value written behind its back with
`update_all` is NOT seen until `reset_cache!` (mutation: delete the `return cache[key] if` line → the
zero-query assertion goes red).

`test/lib/library_root_test.rb` — builds a real mount: `@mount = Pathname(Dir.mktmpdir("mount"))`,
`ENV["LIBRARY_PATH"] = @mount.to_s` saved and restored in `teardown`, `FileLayer.reset!` both ends.
Assertions, each its own test:
- `pending?` is true with the row forgotten on a share adapter (`FileLayer.current =
  FileLayer::Share.new(root: @mount.to_s)`), false with `""`, and **false with the row forgotten
  on a non-share adapter** (install `FileLayer::S3.new(... client: FakeS3.new.client)` as
  `scan_job_test.rb#with_injected_s3` does);
- `path` is the mount while pending and with `""`, and `mount/Workshop/3d` after
  `choose!("Workshop/3d")`;
- `choose!` rejects, each asserting the message names the rule: `"/etc"`, `"a/../b"`, `"a//b"`,
  `"a/"`, `".config"`, `".trash"`, `".maker-tmp-x"`, `"repo/.git"`, `"__MACOSX"`, a regular file,
  a missing folder, **a symlink to a directory outside the mount** (`File.symlink(outside, @mount +
  "escape")` → message matches `/link/`), and a symlinked segment in the middle
  (`"linked/inner"`); each rejection leaves `Setting.get(KEY)` unchanged;
- `choose!("")` writes `""`; `choose!("Workshop/3d")` writes it and `FileLayer.current.root`
  equals `@mount.join("Workshop/3d")` (proves the reset);
- a read-only folder (`chmod 0555`) is refused with a message naming `Process.uid` and writes no
  row (restore mode 0755 in an `ensure` so the tmpdir can be removed);
- `children("")` lists `Alpha`, `beta`, `Gamma` sorted case-insensitively and hides, with one
  assertion each: `.config` (dot rule), `__MACOSX` (reserved rule), a symlinked directory (lstat
  rule) and a plain file (directory rule); `.trash`, `.maker-tmp-x` and `repo/.git` are also
  asserted absent; `children("", limit: 2)` answers two entries and `truncated: true`;
  `children("..")` raises `Invalid`.
- **Mutations to run and report:** drop `start_with?(".") ||` → the `.config` assertion red; drop
  `|| Library::ReservedNames.reserved?(name)` → the `__MACOSX` assertion red; replace `dir.lstat`
  with `dir.stat` in `resolve!` → the outside-symlink test red.

`test/models/confirm_existing_library_root_migration_test.rb` (require the migration file):
`Setting.forget(KEY)`; with a user present, `ConfirmExistingLibraryRoot.new.up` writes exactly one
row with value `""`; with `User.delete_all`, it writes nothing; running it twice leaves one row.
**Mutation:** drop the `WHERE EXISTS (SELECT 1 FROM users)` clause → the no-user case goes red.

- [ ] **Step 8 — run and commit.**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/models/setting_test.rb test/lib/library_root_test.rb test/models/confirm_existing_library_root_migration_test.rb test/schema_map_test.rb test/services/file_layer
git commit -m "K: the library folder is the mount plus a stored choice" -- <the T1 paths>
```

---

## Task 2: pending pauses the schedule; the two doors; the refusal stamp; the stale-root discard

- [ ] **Step 1 — `Library::ScanJob` gates.** In `.scan_all!` and `.enqueue_first_for`, after the
existing `scannable?` return:

```ruby
      # NOT WHILE THE LIBRARY FOLDER IS UNCONFIRMED (K §3). A fresh share install scans nothing until
      # its owner has said which folder is the library -- the boot hook, the schedule and the sign-up
      # form all reach these two methods. `.enqueue_for` stays a command and is not gated.
      return if Tinkerex::LibraryRoot.pending?
```

- [ ] **Step 2 — `Library::TrashPurgeJob.purge_all!`**: the same return after its `scannable?` line.

- [ ] **Step 3 — the refusal stamp.** In `ScanJob#perform`, wrap only `observer.call`:

```ruby
      begin
        observer.call
      rescue Library::Scanner::UnsafeScan => e
        # THE REFUSAL IS RECORDED AND STILL RAISED (K §5): /settings/library shows it with its next
        # step, and the failed-jobs row stays the operator's report.
        user.update_column(:library_scan_refusal, e.message)
        raise
      end
```

and the final stamp becomes `user.update_columns(library_scanned_at: Time.current,
library_scan_refusal: nil)` (keep its existing comment; add "and clears a refusal: the folder
scanned").

- [ ] **Step 4 — the stale-root discard.** First line of `#perform` after `User.find`:
`return if stale_root?(root)`, and the private method:

```ruby
    # A SCAN QUEUED BEFORE THE LIBRARY FOLDER CHANGED MUST NOT RUN ON THE OLD ONE (K §5). The
    # semaphore Library::RootChangeJob shares stops one running DURING a change; this stops one queued
    # before it from running AFTER. Only a QUEUED job is judged: `enqueued_at` is nil for perform_now,
    # so a command still scans the root it names (this job's header), and a job queued after the
    # change names the new root anyway.
    def stale_root?(root)
      return false if root.nil? || enqueued_at.nil?

      changed = Tinkerex::LibraryRoot.changed_at
      return false if changed.nil? || enqueued_at >= changed

      current = FileLayer.current
      return false unless current.is_a?(FileLayer::Share) && current.root.to_s != root

      Rails.logger.warn("Library::ScanJob: discarding a scan of #{root} queued before the library " \
                        "folder changed to #{current.root}")
      true
    end
```

- [ ] **Step 5 — `tinkerex:owner`** (`lib/tasks/tinkerex.rake`), before `User.create!`:

```ruby
    # An operator at a console chose the mount by mounting it (K §3): confirm it, so the first scan
    # below is not paused waiting for a browser.
    Tinkerex::LibraryRoot.clear! if first && Tinkerex::LibraryRoot.pending?
```

- [ ] **Step 6 — tests**, each branching on the backend, never skipping (§15):
  - `scan_job_test.rb`: with `Setting.forget(KEY)` and a share adapter, `scan_all!` and
    `enqueue_first_for` enqueue nothing; with `""` they enqueue (the existing positive tests already
    cover it). A refused scan writes `library_scan_refusal` matching `/is missing/`; a later
    successful scan clears it. **Stale root:** with `travel_to` separating the two events by a day,
    `perform_enqueued_jobs` on a ScanJob enqueued (`perform_later(user_id:, root: old_dir)`) BEFORE
    `Setting.put(KEY, "x")` with `FileLayer.current` over a different dir indexes nothing; the same
    job enqueued AFTER the change indexes; `perform_now` with an old root still indexes (the command
    contract). Mutations: delete `return if Tinkerex::LibraryRoot.pending?` in `scan_all!` → red;
    delete the `enqueued_at >= changed` clause → the "after" case red.
  - `trash_purge_job_test.rb`: pending on share → `purge_all!` enqueues nothing.
  - `boot_scan_test.rb`'s second test: on a share adapter with the row forgotten, `scan_all!`
    enqueues nothing (assert, do not skip, on the other legs: there it is the scannable gate).
  - `tinkerex_tasks_test.rb`: with `User.delete_all` and the row forgotten, `tinkerex:owner` on
    share writes `""` and enqueues the scan; on s3 writes nothing and enqueues the scan; on
    chunk_remote enqueues nothing.
  - `registration_mode_test.rb`'s first-scan test: with the row forgotten (a fresh install), the
    first sign-up on share enqueues NO scan and lands on `/settings/library`; on s3 it still
    enqueues; on chunk_remote nothing.

- [ ] **Step 7 — run the six files, commit.**

---

## Task 3: `Library::Reset` and `Library::RootChangeJob`

- [ ] **Step 1 — `app/services/library/reset.rb`:**

```ruby
module Library
  # "START OVER WITH THIS FOLDER" (K §5): forget everything the catalog learned from the old folder,
  # for one user, in one transaction. NEVER TOUCHES DISK -- the old folder, its .trash and every file
  # stay exactly where they are; this deletes rows. Run only by Library::RootChangeJob, under the
  # scan's own semaphore, which then scans the new folder.
  #
  # WHAT GOES IS WHAT A NODE IS: a row whose identity is a node is destroyed, a pointer that merely
  # names one is nulled, and the maker's own things -- projects, tasks, build logs, inventory, BOMs,
  # suppliers, locations, tags, releases, import models -- survive. Every node of this user goes
  # (tombstones included), so every pointer into them dangles; the nulls are therefore unconditional,
  # with no node-id list to carry.
  #
  # Three are handled differently, each for a recorded rule:
  #   - a BOM line that names a file takes the file's name as its part first: nulling alone leaves
  #     no target and `exactly_one_target` locks the row (§14d, InventoryItem#release_bom_lines);
  #   - AUTO models are destroyed, dismissed ones too: a dismissal names a node_id this deletes and
  #     no later scan can mint again, so there is nothing left for it to keep dismissed;
  #   - release files and image blocks keep their dangling ids: a release file is history by design
  #     (it renders "gone"), and an image block requires its id and already hides when it resolves
  #     to nothing (projects/_block_panel).
  class Reset
    Result = Data.define(:nodes, :attachments, :previews, :models)

    def self.call(user) = new(user).call

    def initialize(user) = @user = user

    def call
      result = nil
      User.transaction do
        release_bom_lines!
        attachments = @user.maker_file_attachments.delete_all
        @user.maker_file_links.delete_all
        @user.maker_pins.delete_all
        @user.maker_repo_edits.delete_all
        Maker::AddonFile.where(addon_state_id: @user.maker_addon_states.select(:id)).delete_all
        @user.maker_notes.find_each(&:destroy!)     # rich text rows go with them
        previews = 0
        @user.maker_previews.find_each { |p| p.destroy!; previews += 1 } # purges the blob
        models = @user.maker_models.where(origin: "auto").to_a.each(&:destroy!).size
        @user.maker_models.update_all(folder_node_id: nil, cover_node_id: nil, auto_node_id: nil)
        @user.maker_projects.update_all(folder_node_id: nil, cover_node_id: nil)
        @user.maker_releases.update_all(repo_node_id: nil)
        @user.maker_items.update_all(primary_node_id: nil)
        nodes = @user.nodes.delete_all
        @user.update_columns(library_scanned_at: nil, library_scan_refusal: nil)
        result = Result.new(nodes:, attachments:, previews:, models:)
      end
      Rails.logger.info("Library::Reset: user #{@user.id}: #{result.to_h}")
      result
    end

    private

    def release_bom_lines!
      lines = @user.maker_bom_lines.where.not(node_id: [ nil, "" ]).to_a
      return if lines.empty?

      names = @user.nodes.where(node_id: lines.map(&:node_id)).pluck(:node_id, :name).to_h
      lines.each do |line|
        line.update_columns(node_id: nil, part_name: line.part_name.presence || names[line.node_id] || "Missing file")
      end
    end
  end
end
```

(Implementer: confirm each association name exists on `User` — `maker_file_links`, `maker_pins`,
`maker_repo_edits`, `maker_addon_states`, `maker_notes`, `maker_previews`, `maker_models`,
`maker_releases`, `maker_items`, `maker_bom_lines` all do per `app/models/user.rb`.)

- [ ] **Step 2 — `app/jobs/library/root_change_job.rb`:**

```ruby
module Library
  # WHAT A LIBRARY-FOLDER CHANGE ENQUEUES, ONE PER USER (K §5). Waits for any running scan, optionally
  # starts the catalog over (Library::Reset), then scans the new folder INLINE.
  #
  # THE SCAN'S OWN SEMAPHORE: `group: "Library::ScanJob"` makes this job's concurrency key identical
  # to Library::ScanJob's for the same user (Solid Queue keys are "<group>/<key>"), so a reset never
  # runs underneath a scan and no scan starts underneath a reset. `on_conflict: :block` here where
  # the scan says :discard: a queued scan only repeats the running one, but a change must happen.
  #
  # INLINE, NOT ENQUEUED: Solid Queue releases a semaphore when the job FINISHES, so a scan enqueued
  # from inside this perform would meet this job's own lock and be discarded by the scan's
  # :discard. perform_now bypasses enqueue-time controls (the reason ScanJob runs its intakes inline).
  class RootChangeJob < ApplicationJob
    queue_as :background
    discard_on ActiveRecord::RecordNotFound

    limits_concurrency to: 1, key: ->(args) { args[:user_id] }, group: "Library::ScanJob",
                       duration: 1.hour, on_conflict: :block

    def perform(user_id:, start_over: false)
      user = User.find(user_id)
      Library::Reset.call(user) if start_over
      adapter = FileLayer.current
      # The chooser is share-only; a job left over from a backend switch has nothing to scan.
      return unless adapter.is_a?(FileLayer::Share)

      Library::ScanJob.perform_now(user_id: user.id, root: adapter.root.to_s)
    end
  end
end
```

- [ ] **Step 3 — tests.**
  - `test/jobs/concurrency_limits_test.rb`: `RootChangeJob.new(user_id: @a.id).concurrency_key ==
    ScanJob.new(user_id: @a.id).concurrency_key`, different users differ, limit 1,
    `concurrency_on_conflict == :block`. Mutation: drop `group:` → the equality goes red.
  - `test/services/library/reset_test.rb` (runs on every leg — it is rows only): build, for one
    user, a node file + dir (`create_node!`-style rows are fine here), an attachment on a project,
    a file link, a pin, a note (with body), a preview with an attached blob, a repo edit, an addon
    state with one addon file, a project with `folder_node_id`/`cover_node_id`, a release with
    `repo_node_id` and one release file, an item with `primary_node_id`, a BOM line targeting the
    file node, an image project block, an auto model (attached), a dismissed auto model, an import
    model with `folder_node_id`, a task, an inventory item; plus a SECOND user with a node and a pin.
    After `Library::Reset.call(user)`: one assertion per destroyed table (zero rows for the user),
    one per nulled pointer, the BOM line's `part_name` equals the node's name and it `valid?`, the
    release file and image block survive, the project/task/inventory item/release/import model
    survive, the blob is gone (`ActiveStorage::Blob.count` back down, perform the purge job), the
    second user's node and pin survive, and `library_scanned_at` is nil. Mutation: comment out the
    pins line → its assertion red; comment out `release_bom_lines!` → the BOM line's `valid?` red.
  - `test/jobs/library/root_change_job_test.rb` (share only by nature: on s3/chunk_remote assert the
    job enqueues no scan and leaves the catalog alone, so RUN counts match). With a real mount:
    - **switch, same files:** scan folder A (`FileLayer.current = Share.new(root: mount/A)`), record
      node ids, `mv` A → B on disk, `Tinkerex::LibraryRoot.choose!("B")` with `ENV["LIBRARY_PATH"]
      = mount`, perform `RootChangeJob(start_over: false)` → zero tombstones, every node_id
      unchanged;
    - **switch, different files:** A holds 10 files, C holds 10 different files → perform raises
      `Library::Scanner::UnsafeScan`, the catalog is intact (10 live nodes) and
      `user.reload.library_scan_refusal` is present. Mutation: set
      `LIBRARY_SCAN_MAX_DELETE_PCT=100` for that test → it goes red (the guard is what protected it);
    - **start over:** same C → `start_over: true` → the catalog holds exactly C's 10 files, every
      file under A is still on disk.

- [ ] **Step 4 — run the three files, commit.**

---

## Task 4: the page, the chooser's data source, the redirect

- [ ] **Step 1 — routes** (`config/routes.rb`, inside `namespace :settings`):

```ruby
    # K (2026-10-20): which folder under the mount is the share library. Singular, like /settings
    # itself; `controller:` because Rails would otherwise pluralise it to `libraries`. `children` is
    # the chooser's path-based data source (LibraryBrowseController#children is the node-based one).
    resource :library, only: %i[show update], controller: "library" do
      get :children
    end
```

- [ ] **Step 2 — the redirect** (`app/controllers/application_controller.rb`, after `before_action
:authenticate_user!`):

```ruby
  # A FRESH SHARE INSTALL CONFIRMS ITS LIBRARY FOLDER BEFORE ANYTHING ELSE (K §3). Every signed-in
  # HTML page goes to /settings/library while Tinkerex::LibraryRoot.pending?; that page and Help skip
  # this, Devise's pages are excluded by the condition, and Public:: stands on ActionController::Base
  # and never reaches here (§14d). HTML only, so a poller or a JSON door answers as itself. Off share,
  # or once chosen, this is one memoised read per request and no query.
  before_action :require_library_folder!, if: -> { !devise_controller? && user_signed_in? && Tinkerex::LibraryRoot.pending? }

  ...

  private

  def require_library_folder!
    redirect_to settings_library_path if request.format.html?
  end
```

`HelpController`: `skip_before_action :require_library_folder!`.

- [ ] **Step 3 — helper** (`app/helpers/library_folder_helper.rb`), two additions beside
`library_folder_label`:

```ruby
  # THE MOUNT AS PLAIN TEXT, for the chooser's root label (an attribute, which cannot carry markup).
  def library_folder_text
    value = ENV["LIBRARY_HOST_PATH"]
    return "The library folder on the server" if value.nil?
    return "The folder your docker-compose.yml is in" if value.strip.empty?

    value.strip
  end

  # THE LIBRARY AS IT IS NOW (K): the mount's label, plus the chosen folder when one is narrower.
  # A typed host path reads as one path; the other two labels are prose, so the folder follows them.
  def library_root_label(relative = Tinkerex::LibraryRoot.relative)
    return library_folder_label if relative.blank?

    host = ENV["LIBRARY_HOST_PATH"].to_s.strip
    return tag.code("#{host.chomp('/')}/#{relative}") if host.present?

    safe_join([ library_folder_label, ", in its folder ", tag.code(relative) ])
  end
```

`shared/_where_files_come_from.html.erb`: the share sentence's subject becomes
`library_root_label` (update the partial's comment line that names the helper).

- [ ] **Step 4 — `app/javascript/lib/file_chooser.js`**: in `buildModal`, after
`document.body.appendChild(this.overlay)`… after `this.newWrap = …`:

```js
    // NO createUrl, NO "New Folder" (K: the library-folder chooser lists folders on the host, where
    // a folder is made by the person, not by the app).
    if (!this.createUrl) this.newWrap.hidden = true
```

and `shared/_folder_field.html.erb`: `create_url = local_assigns.fetch(:create_url, nil)` and the
locals doc line says `[optional — omitted, the modal offers no New Folder]`.

- [ ] **Step 5 — `app/controllers/settings/library_controller.rb`:**

```ruby
# WHICH FOLDER IS THE LIBRARY (K, 2026-10-20). One page, two states told apart by
# Tinkerex::LibraryRoot.pending?: the first-run confirmation and, once chosen, the change form. On s3
# and chunk_remote it renders the "where files come from" partial with nothing to choose, so the
# Settings link never leads to a dead end. Session-authed like every Settings page; on share every
# account shares the one library and sign-ups are closed (§8), so any signed-in account may change it.
module Settings
  class LibraryController < ApplicationController
    skip_before_action :require_library_folder!
    before_action :require_share!, only: %i[update children]
    before_action :refuse_demo_account!, only: :update

    def show
      load_page
    end

    # GET /settings/library/children?parent=<relative> -> the chooser's JSON, in the shape
    # lib/file_chooser.js consumes, with the relative path standing in for node_id.
    def children
      listing = Tinkerex::LibraryRoot.children(params[:parent])
      render json: {
        parent: listing.parent,
        crumbs: crumbs(listing.parent),
        entries: listing.entries.map { |rel| { node_id: rel, name: File.basename(rel), kind: "dir" } },
        truncated: listing.truncated
      }
    rescue Tinkerex::LibraryRoot::Invalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # PATCH /settings/library {relative, mode: switch|reset}.
    def update
      first_run = Tinkerex::LibraryRoot.pending?
      start_over = params[:mode] == "reset" && !Tinkerex::LibraryRoot.catalog_empty?
      rel = Tinkerex::LibraryRoot.choose!(params[:relative])

      if first_run
        # THE FIRST SCAN FOLLOWS THE CONFIRMATION, NOT THE SIGN-UP (K §3), through the sign-up form's
        # own door.
        Library::ScanJob.enqueue_first_for(current_user)
        redirect_to root_path, notice: "Your library is #{rel.empty? ? 'the mounted folder' : rel}. Indexing it now."
      else
        User.find_each { |user| Library::RootChangeJob.perform_later(user_id: user.id, start_over:) }
        redirect_to settings_library_path(scanning: 1),
                    notice: start_over ? "Starting over with #{display(rel)}." : "Switching to #{display(rel)}."
      end
    rescue Tinkerex::LibraryRoot::Invalid => e
      @error = e.message
      load_page
      render :show, status: :unprocessable_entity
    end

    private

    def load_page
      @share = Tinkerex::LibraryRoot.share?
      return unless @share

      @pending = Tinkerex::LibraryRoot.pending?
      @relative = Tinkerex::LibraryRoot.relative.to_s
      @catalog_empty = Tinkerex::LibraryRoot.catalog_empty?
      @file_count = current_user.nodes.present.where(kind: "file").count
      @root_missing = !@pending && !Tinkerex::LibraryRoot.path.directory?
      @refusal = current_user.library_scan_refusal
      @split_jobs = Rails.env.production? && !Tinkerex::SolidQueueInPuma.enabled?
    end

    def display(rel) = rel.empty? ? "the whole mounted folder" : rel

    def crumbs(rel)
      segments = rel.split("/")
      segments.each_index.map { |i| { node_id: segments[0..i].join("/"), name: segments[i] } }
    end

    def require_share!
      return if Tinkerex::LibraryRoot.share?

      respond_to do |format|
        format.json { render json: { error: "This library has no folder to choose." }, status: :not_found }
        format.html { redirect_to settings_library_path, alert: "This library has no folder to choose." }
      end
    end

    def refuse_demo_account!
      return unless Tinkerex::Demo.demo?(current_user)

      redirect_to settings_library_path, alert: "The shared demo account can't change the library folder.",
                                         status: :see_other
    end
  end
end
```

- [ ] **Step 6 — `app/views/settings/library/show.html.erb`** (ONE template, both states, so the
template-hygiene coverage sees it on every leg). Content:
  - `content_for :title, "Library folder — Tinkerex"`; `.page-head` with `h1` "Library folder"
    and a `btn ghost small` link back to Settings (omitted while pending — there is nowhere else to go).
  - `@error` → `p.flash-alert` with the message.
  - **not share** → `render "shared/where_files_come_from", projects: false`.
  - **pending** → "Your library will be <%= library_folder_label %>." and a `ul` of three facts
    (indexed every 15 minutes; uploads land in it; deletions move into its `.trash/`); a
    `form_with url: settings_library_path, method: :patch, class: "settings-add library-choice"`
    holding `render "shared/folder_field", name: "relative", value: "", label: "Choose a folder
    inside it", root_label: library_folder_text, children_url: children_settings_library_path` and
    `button.btn.primary` "Use this folder".
  - **chosen** → "Your library is <%= library_root_label(@relative) %>." with `pluralize(@file_count,
    "file")` indexed; `@root_missing` → `p.flash-alert` "That folder is not there any more…choose
    again."; `@refusal` → `p.flash-alert` "The last scan of this folder was refused: <%= @refusal %>
    Choose the folder that holds your files, or start over with this one."; `params[:scanning]` →
    the scanreload span exactly as `files/index.html.erb` renders it, with
    `url: settings_library_path`; `@split_jobs` → one muted sentence ("Background jobs run in a
    separate process here; restart it after changing the folder so it scans the new one."). The
    form: the same folder field with `value: @relative`, `label: @relative.presence ? "/#{@relative}"
    : library_folder_text`; then, if `@catalog_empty`, one `button.btn.primary name=mode value=switch`
    "Use this folder"; else two one-sentence explanations and `button.btn.primary name=mode
    value=switch` "Switch to this folder" plus `button.btn name=mode value=reset` "Start over with
    this folder" carrying `data-turbo-confirm` = "Start over? Tinkerex forgets every file it has
    indexed, with their previews, notes, pins and the 3D models it found, and indexes this folder
    fresh. Your projects, tasks, inventory and BOMs stay. Nothing is deleted from disk: the old folder
    and its files are untouched."
  - Only existing component classes (`btn`, `primary`, `ghost`, `small`, `muted`, `flash-alert`,
    `settings-add`) plus a page class `library-choice` defined in `pages/settings.css`
    (`.library-choice { flex-direction: column; align-items: flex-start; }` and
    `.library-choice .library-outcomes { display: flex; gap: 10px; flex-wrap: wrap; }`).

- [ ] **Step 7 — hub row.** `SettingsController#show` gains nothing new to count; the view's list
gains a first row: `link_to "Library", settings_library_path, class: "settings-name"` with fact
`library_hub_fact` computed in the view: share → `@library_relative.presence ? "/#{rel}" : "whole
folder"`, else `capabilities.presignable? ? "storage bucket" : "sync server"` (set
`@library_relative = Tinkerex::LibraryRoot.relative.to_s` in the controller).

- [ ] **Step 8 — tests.**
  - `test/integration/web/settings_library_test.rb` (each test branches on
    `Tinkerex::LibraryRoot.share?`; on the other legs assert the absence):
    - **redirect:** with the row forgotten, Recent, Files, Projects, Tools and Settings each
      redirect to `/settings/library`; Help, sign-out and the page itself do not; JSON
      `scan_status` does not; once `""` nothing redirects. Mutation: remove the controller's
      `skip_before_action` → the page redirects to itself (red).
    - **listing:** with `ENV["LIBRARY_PATH"]` a tmpdir mount holding `Alpha/`, `beta/inner/`,
      `.config/`, `__MACOSX/`, a symlinked dir and a file: `children` answers `["Alpha","beta"]`
      with `kind: "dir"`; `parent=beta` answers `["beta/inner"]` with crumbs; `parent=..`,
      `parent=/etc` and `parent=<escaping symlink>` answer 422 with no `entries`.
    - **choice:** pending + `PATCH relative=""` → `Setting.get(KEY) == ""`, exactly one
      `Library::ScanJob` enqueued for the user, redirect to `/`; `relative="Alpha"` likewise; a
      `chmod 0555` subfolder → 422, the body names `Process.uid`, no job, the row still absent.
      Chosen + catalog non-empty + `mode=switch` → one `RootChangeJob` per user with
      `start_over: false`; `mode=reset` → `start_over: true`; chosen + empty catalog + `mode=reset`
      → `start_over: false`. The demo account (`DEMO_ACCOUNT_EMAIL` set to the user) is refused.
    - **page:** chosen state names the folder and the count; a recorded
      `library_scan_refusal` is shown; Start over appears only with a non-empty catalog.
  - `settings_hub_test.rb`: eight rows, `"Library"` first, linking `settings_library_path`.
  - `template_hygiene_test.rb` `pages`: `"settings/library" => settings_library_path`.
  - `test/helpers/library_folder_helper_test.rb`: `library_root_label` for the three
    `LIBRARY_HOST_PATH` states × relative blank / `"Workshop"`; `library_folder_text` for the three.

- [ ] **Step 9 — run the four files plus `test/stimulus_hygiene_test.rb`,
`test/css_hygiene_test.rb`, `test/architecture_invariants_test.rb`, commit.**

---

## Task 5: the browser

- [ ] `test/system/library_chooser_test.rb` — on share: `ENV["LIBRARY_PATH"]` = a tmpdir mount with
`Workshop/3d/` and `Downloads/`, `FileLayer.reset!`, `Setting.forget(KEY)`, `User.delete_all`;
sign up through the form (first account) → `assert_current_path settings_library_path`; click
"Choose a folder inside it"; in the modal click `Workshop`, then `3d`, then Choose; assert the
field reads `/Workshop/3d` and the modal had no "New Folder"; click "Use this folder"; assert
`/` and that Recent's getting-started panel shows `3d`; `assert_no_console_errors`. Off share:
the sign-up lands on `/` directly. Restore `LIBRARY_PATH` in teardown.
- [ ] `accent_spend_test.rb`: add `"/settings/library" => [ "Switch to this folder" ]` (the setup's
model folder makes the catalog non-empty) — on share; on the other legs the page spends none, so
the expectation branches: `Tinkerex::LibraryRoot.share? ? [ "Switch to this folder" ] : []`.

---

## Task 6: docs

- [ ] `docs/INSTALL.md` §2: after "First run: the first account is the owner", a paragraph: the next
screen names the folder and asks once — **Use this folder**, or **Choose a folder inside it** —
and the first scan follows that, not the sign-up. §3's `LIBRARY_HOST_PATH` bullet gains: "Mount a
wider folder and choose the library inside it from the browser: `~` works on Docker Desktop and
Linux." The `PUID`/`PGID` bullet gains: "A subfolder you choose in the browser must be writable by
that user too; the page names the fix when it is not." §8 gains no row.
- [ ] `README.md` quick start: "then confirm the folder, or pick one inside it".
- [ ] `.env.example`: the `LIBRARY_HOST_PATH` comment says a wider folder can be mounted and the
library chosen inside it from the browser.
- [ ] `app/views/help/show.html.erb`, in the share arm of "Your library": one paragraph — the folder
is chosen at Settings → Library folder; changing it keeps your files' projects and notes when the
new folder holds the same files; "start over" forgets the catalog and never deletes a file.
- [ ] `CLAUDE.md` §14a: one bullet, *the share root is the mount plus a stored relative choice
(`Tinkerex::LibraryRoot`); the mount is probed at boot and the choice at selection; changing the
choice is a scan under the mass-deletion guard, and only an explicit reset wipes the catalog,
which never touches disk.* Keep the file at or under `MAX_LINES` by tightening a neighbouring
bullet's wrap in §14a; raise the ceiling only by the line count actually added, with the reason
in the test's comment.
- [ ] Run `test/install_docs_test.rb test/docs_hygiene_test.rb test/compose_hygiene_test.rb`,
the help page test (`grep -rl help_path test/integration`), commit.

---

## Close-out

Bare `bin/ci` (all gates; RUN counts across `test`, `test-s3`, `test-chunk-remote` must match),
then `/finish-branch`, `bin/log arc --from-pr <n>`.
