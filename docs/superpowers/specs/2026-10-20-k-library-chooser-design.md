# K — Choose the library folder in-app, Plex-style: design

**Date:** 2026-10-20 · **Status:** design, awaiting a plan · **Source:** the owner's question of
2026-10-19 ("is there a better way to set the library? can it be done as part of a setup process
after the container is running like Plex?"), answered here. Builds on J
(`2026-10-15-j-folder-is-the-library-design.md`: the compose file's folder is the library, the app
runs as its owner, the first scan follows the first account) and keeps every one of its decisions.
Facts cite `main` at c0e461f7.

## The problem

After J, a stranger on Docker Desktop or plain compose has exactly one way to say which folder is
the library: put `docker-compose.yml` in it, or write `LIBRARY_HOST_PATH` in a `.env` beside the
file and run `docker compose up -d` again. Nothing in the app ever asks. Three costs follow:

1. **The library is always the whole mount.** `FileLayer::Share.new` takes `ENV["LIBRARY_PATH"]`
   as its root (`app/services/file_layer/share.rb:10`), and the boot guard probes that path
   (`lib/library_backend_check.rb`, `check_share!`). A person who mounts a parent, the way every
   Plex install maps `/media` and picks `/media/Movies` inside, cannot narrow it afterwards.
2. **The folder is named on screen only after the first scan has run on it.** J's §2 sentence
   ("the folder your `docker-compose.yml` is in is your library") appears on Recent, by which time
   the first scan J added in §3b has already hashed the folder and a `.trash/` may exist. The
   Downloads foot-gun J accepted is discovered, not prevented.
3. **A wrong folder has no in-app fix.** The only correction is to stop the container, move the
   file or edit `.env`, and start again, with a catalog that now points at paths that are gone.

What Docker does not allow, stated once so the rest of this design is not read as promising it: a
container can only see what was mounted into it. "Choose the library after the container is
running" therefore means "mount something once, choose inside it from the browser". Plex's compose
examples mount `/path/to/media` by hand too; its wizard only picks within that.

## Where this does and does not apply

- **The Unraid template already does this.** `unraid/tinkerex.xml:36` is a `Type="Path"` field
  defaulting to `/mnt/user/`, and Unraid's own form is the folder picker. Nothing here changes the
  template, and a share picked there keeps working exactly as today.
- **The Kamal destinations set `LIBRARY_PATH`** (`config/deploy.share.yml`), and keep doing so.
- **The audience is `docker-compose.yml` users**: Docker Desktop on a Mac or Windows machine and
  plain compose on Linux. The `s3` and `chunk_remote` backends have no folder and are untouched.

## Decisions

Taken on the owner's behalf from the question above, with the alternative named where one was
weighed; any of them is the owner's to reverse at review.

- **The mount stays the compose file's folder by default** (J §1 holds: `${LIBRARY_HOST_PATH:-.}`).
  *Alternative weighed:* mount the home directory by default so anything under it is pickable.
  Rejected: it hands the container every file in the person's home for a convenience the
  `LIBRARY_HOST_PATH` line already provides, one line and one restart, and `~` is a valid value
  there for whoever wants exactly that.
- **The library is the mount plus a stored relative path.** `LIBRARY_PATH` is now the *mount* (the
  parent the chooser browses); a settings row holds the chosen folder *relative to it*; the share
  root is their join. Nothing chosen means the whole mount, which is today's behaviour, so every
  existing deployment keeps its library without a migration touching the filesystem.
- **A fresh share install confirms its library once, before the first scan.** After the owner
  account is created, one screen names the mounted folder and offers "Use this folder" (the
  default, one click) or "Choose a folder inside it". The first scan follows the confirmation,
  not the sign-up. *Alternative weighed:* no confirmation screen, scan the whole mount at sign-up
  as J does, and treat a later narrowing as a reset. Rejected: with a broad mount that first scan
  hashes everything under it before the person has said what the library is, and the reset then
  races the scan.
- **No boot-time setup mode.** The whole mount is always a valid root, so `LibraryBackendCheck`
  keeps refusing to boot on a missing or unwritable mount and nothing in §14a's boot story moves.
  "Pending" is a fact the *web layer* and the *scan schedule* consult, never the boot.
- **Changing the folder later keeps the catalog by default and resets it on request.** A node's
  `storage_path` is relative to the root (`share.rb:728`), so pointing the root at a folder that
  holds the same files is a no-op for the catalog, and a folder that holds most of them is an
  ordinary reorganisation the scan already handles. A folder that holds a *different* library
  trips the existing mass-deletion guard, which is the safety net. "Start over" is a separate,
  explicit action that wipes the catalog and never touches disk.
- **No new environment variable.** The stored choice is the only new state. An operator who wants
  the whole mount back clears the choice on the same page.

## 1. What a stranger does

1. Install Docker, put `docker-compose.yml` in a folder, `docker compose up -d`. Unchanged.
2. Open `http://localhost:8080`, create the owner account. Unchanged.
3. **New:** the next screen says "Your library will be *the folder your docker-compose.yml is in*"
   (J §2's sentence, with the typed path when `LIBRARY_HOST_PATH` names one) and lists what will
   happen to it: indexed every 15 minutes, uploads land in it, deletions move into its `.trash/`.
   One accent button, "Use this folder". Below it, "Choose a folder inside it", which opens the
   chooser over the mount.
4. The first scan runs on the confirmed folder. Recent names it, as J §2 already does.

To offer a wider choice than the compose folder: `LIBRARY_HOST_PATH=~` (or `/mnt/user`, or
`D:\Workshop`) in `.env`, one restart, then pick inside it from the browser. That is the Plex
shape, and it is one line because Docker needs the line.

## 2. The stored choice

A new table, `settings(key string primary, value text, timestamps)`, with one model, `Setting`,
and two class methods, `Setting.get(key)` and `Setting.put(key, value)`. Key-value rather than a
one-row table because the next deployment-wide fact (there is none yet; YAGNI decides the shape,
not the contents) reuses it without a migration. The one key this design adds is `library.root`.

Its value is the chosen folder **relative to the mount**, with no leading slash, `""` for the
whole mount, and the row **absent** while the choice is pending. Relative on purpose: the row never
holds a host path, so changing `LIBRARY_HOST_PATH` to a wider or narrower parent keeps the choice
meaningful or makes it visibly missing, never silently wrong.

| row | meaning | who writes it |
|---|---|---|
| absent | pending: a fresh share install whose owner has not confirmed | nobody yet |
| `""` | the whole mount, today's behaviour | the confirm button; `tinkerex:owner`; the migration below |
| `"Workshop/3d"` | that folder under the mount | the chooser |

**`Tinkerex::LibraryRoot`** (`lib/tinkerex/library_root.rb`, beside `registration.rb` and
`secret_key_base.rb`) is the one reader and writer, so no second place joins the two halves:

- `mount` — `Pathname(ENV["LIBRARY_PATH"]).expand_path`, the thing the boot guard probes.
- `relative` — the row's value, or `nil` when absent.
- `pending?` — `relative.nil?` **and the backend is share**; false on s3 and chunk_remote, which
  have nothing to choose, so every gate below is a no-op there.
- `path` — `mount.join(relative.to_s)`; while pending, the mount itself, so `FileLayer.current` can
  always be built (the CSP header resolves it per response, §14a) and nothing 500s.
- `choose!(relative)` — validates (§4), probes (§4), writes the row, calls `FileLayer.reset!`.
- `clear!` — writes `""`.

`FileLayer::Share.new`'s default root becomes `Tinkerex::LibraryRoot.path`. The constructor's
`root:` keyword stays, because 241 tests construct adapters with tmpdir roots and must keep doing so.

**One process, and the exception stated.** `FileLayer.current` memoizes one adapter per process
(§14a). `choose!` resets it, and on every deployment this repo ships, jobs run inside that same
process (`SOLID_QUEUE_IN_PUMA`), so the next request and the next job both see the new root. A
deployment that runs `bin/jobs` as a second process would serve the old root there until that
process restarts; the Settings page says so in one sentence when `SOLID_QUEUE_IN_PUMA` is off.
Making the memo compare a settings version per request is the fix if that deployment shape ever
exists; it does not today.

**The migration.** `CreateSettings` creates the table and, in the same migration, inserts
`library.root = ""` **when any user exists**. An existing share deployment has been using the whole
mount all along, so it is confirmed by construction and its scans never pause; a fresh install has
no user at migration time, so its row stays absent and the first-run screen is pending. s3 and
chunk_remote deployments get the row too, harmlessly, because `pending?` is already false there.

## 3. Pending: what waits and what does not

While `Tinkerex::LibraryRoot.pending?`:

- **Scans wait.** `Library::ScanJob.scan_all!` and `.enqueue_first_for` return early, beside
  their existing `scannable?` gate, so neither the boot hook (`config/puma.rb`), the 15-minute
  schedule nor the sign-up form scans the unconfirmed mount. `.enqueue_for` stays a command and is
  not gated: its callers are pages the redirect below already keeps away, and
  `docs/invariants/project-intake.md`'s "an explicit scan does something" rule holds.
  `Library::TrashPurgeJob.purge_all!` waits the same way; the intake and catalogue sweeps already
  run inside the scan on share and so wait with it, with nothing added.
- **Sign-up no longer scans on share.** J §3b's `enqueue_first_for` call stays in
  `Users::RegistrationsController`, where the new early return makes it a no-op while pending, so
  s3 keeps its first scan at sign-up untouched; the confirm action (§4) calls the same method once
  the choice is written. `bin/rails tinkerex:owner` writes `""` first and then calls it: an
  operator at a console has chosen the mount by mounting it, and the console path must keep
  working with no browser.
- **Every signed-in page redirects to `/settings/library`.** One `before_action` in
  `ApplicationController`, skipped on that controller, the Devise controllers, `HelpController` and
  the sign-out route; `Public::` controllers stand on `ActionController::Base` and are untouched
  (§14d). It runs only on share and only while pending, so every other deployment pays one
  predicate per request and no query: `pending?` reads a memoised `Setting` lookup that `choose!`
  and `clear!` invalidate.
- **The v1 API is not gated.** A device enrolled on a share deployment (§8: `devices` is ungated on
  purpose) gets an empty catalog until the owner confirms, which is what it would get anyway.

Nothing else knows the word. `FileLayer.current` is a Share over the mount; the boot guard,
`library_present?`, the banner, the port's write guards all behave as on any empty library.

## 4. The page and the chooser

One controller, `Settings::LibraryController`, one page at `/settings/library`, two states told
apart by `pending?`. It appears in the Settings navigation on every backend; on s3 and
chunk_remote it renders the existing "where files come from" partial with nothing to choose, so the
link never leads to a dead end.

**The pending state** is the first-run screen of §1. The accent button posts `PATCH
/settings/library` with `relative = ""`. "Choose a folder inside it" opens the chooser.

**The chosen state** shows the current folder as a path (`<mount as the person knows it>/<relative>`,
using `LibraryFolderHelper`'s three states for the mount half), the live file count, and two
actions: "Choose a different folder" and, when the catalog is not empty, "Start over" (§5).

**The chooser** is `lib/file_chooser.js`'s modal with a path-based data source rather than the
node-based one `LibraryBrowseController#children` serves. `GET /settings/library/children?parent=<relative>`
answers the same JSON shape the modal already consumes (`{parent, crumbs, entries:[{node_id,name,kind}]}`)
with the relative path standing in for `node_id`, so the modal needs no change beyond accepting
an omitted `createUrl` (no "New folder" on this screen; a folder is made on the host). If the modal
turns out to assume anything about the identifier's shape, that change is in scope. The source:

- Lists **directories only**, by `Dir.children` plus `lstat`, the Scanner's own dispatch: a symlink
  is neither listed nor followed (`scanner.rb:125-131`), and the mount's realpath must prefix the
  entry's realpath.
- **Hides** dot-directories, `Library::OsClutter`, `.trash`, `.maker-tmp-*` and anything at or
  beneath a `.git` (`Library::RepoMetadata.marker_prefix`): none of them may become the root.
- **Rejects** a `parent` that is absolute, contains `..` or an empty segment, or resolves outside
  the mount, with 422 and no listing: `key_for`'s rule, reject and never normalise (§14a).
- **Caps** at 500 entries, sorted case-insensitively, with the response saying it was cut.
- Exposes directory **names** under the mount to a signed-in user, never files, never contents.
  On share every account sees the same library already, and sign-ups are closed (§8), so this
  widens nothing.

**`PATCH /settings/library` with `relative`** runs `Tinkerex::LibraryRoot.choose!`, which in order:

1. Validates the value by the same rules as the listing (absolute, `..`, empty segment, outside
   the mount, reserved or clutter name, inside `.git`): 422 naming the rule.
2. Requires `File.directory?` of the join: "`<folder>` is not a folder any more; choose again."
3. Probes writability with `LibraryBackendCheck.writable!`, the boot guard's real touch (never
   `File.writable?`, §14a). On failure the message names the fix, in the operator's words:
   > The app runs as user `<Process.uid>:<Process.gid>` and cannot write in `<folder>`. On Linux,
   > set `PUID` and `PGID` in `.env` to that folder's owner (`stat -c '%u:%g' <folder>` on the
   > host) and run `docker compose up -d` again.
   The uid is inferred at container start from the *mount's* owner (`bin/docker-entrypoint`), so
   a subfolder owned by someone else is exactly the case this message exists for.
4. Writes the row, resets `FileLayer.current`.
5. If the catalog was empty (no live node for any user), enqueues the first scan through
   `Library::ScanJob.enqueue_first_for`. Otherwise §5 decides.

The page is session-authed like every Settings page. There is no owner role (B decided "the
first account" is the whole mechanism); on share the deployment is single-user by design.

## 5. Changing the folder later

A chosen folder is changed on the same page. Two cases, told apart by whether any live node exists.

**Empty catalog:** write the row, scan. Nothing to protect.

**Non-empty catalog:** the page offers the two outcomes side by side, one sentence each, and asks
which the person means:

- **"Switch, keeping my files' projects and notes"** (the default): write the row, enqueue a scan.
  Because `storage_path` is relative to the root, a folder that holds the same files (the old one
  moved or renamed on the host) scans as unchanged, and one that holds most of them is a
  reorganisation: pairing by content keeps each node's identity, attachments and tags survive, and
  the rest is tombstoned on the ordinary 30-day grace. A folder that holds a *different* library
  makes the scan tombstone more than `LIBRARY_SCAN_MAX_DELETE_PCT` (20%) of the catalog, and
  `Library::Scanner::UnsafeScan` refuses it exactly as it refuses an unmounted share. The page then
  shows that refusal with the next step: start over, or choose again. **The guard is the safety
  net for this path and nothing here weakens or bypasses it.**
- **"Start over with this folder"**: for a different set of files. A confirmation names what is
  wiped, then `Library::ResetJob` runs `Library::Reset`:
  - It holds the **scan's own semaphore**: Solid Queue `limits_concurrency` with the same
    per-user key in a shared `group:` with `Library::ScanJob`, `on_conflict: :block`, so a running
    scan finishes first and no scan starts underneath it.
  - In one transaction, for every user (share: all users share the library), it destroys the rows
    whose identity *is* a node and nulls the pointers that merely name one. From `db/schema.rb`'s
    `node_id` columns, to be confirmed against the schema at plan time: **destroyed** —
    `maker_file_attachments`, `maker_file_links`, `maker_pins`, `maker_notes`, `maker_previews`
    (with their Active Storage blobs purged), `maker_repo_edits`, `maker_release_files`,
    `maker_addon_files`, and finally `nodes`, tombstones included; **nulled** — the optional
    pointers on `maker_projects` (folder and cover), `maker_releases`, `maker_project_blocks`,
    `maker_bom_lines`, `maker_items`; **models** — `maker_models` rows whose `auto_node_id` or
    `folder_node_id` is being wiped go through `Maker::ModelIntake`'s existing prune
    (`rake models:prune`, `docs/invariants/model-intake.md`), never a bare delete, so a dismissed
    model stays dismissed by that file's rules. Projects, tasks, build-log entries, inventory, BOMs,
    suppliers, locations, tags and releases survive: they are the maker's, not the folder's.
  - **Never touches disk.** The old folder, its `.trash/`, every file: untouched. The confirmation
    says so, because "start over" otherwise reads as "delete".
  - Enqueues the first scan of the new root when done.
- **A scan enqueued before the change must not run on the old root.** `Library::ScanJob#perform`
  compares its `root:` argument with `FileLayer.current.root` and discards (logging which) when
  they differ. The semaphore stops it running *during* the reset; this stops it running *after*.

Uploads and tool output through the port during a reset land under the new root and are indexed
by the scan that follows; the page says the library is being re-indexed until that scan completes,
using the same scan-status endpoint the Files page polls.

## 6. Invariants touched, and how each is kept

| rule | where | what changes | why it still holds |
|---|---|---|---|
| The boot guard touch-probes the share root, in `after_initialize` | §14a | nothing | it probes the **mount**; the chosen folder is probed at selection with the same `writable!` |
| `FileLayer.current` is one adapter per process; no per-request cache | §14a | `choose!` calls the existing `reset!` | a reset is not a cache; jobs share the process (`SOLID_QUEUE_IN_PUMA`) |
| Production refuses a blank `LIBRARY_BACKEND` | §14a | nothing | pending is not a boot state |
| `.trash` lives at `<root>/.trash/<node_id>/<name>` | §14a | nothing | the root is the chosen folder; the mount's own `.trash` is never read |
| The skip lists are one predicate consulted by observers and write guards | §14b | nothing added | the chooser hides those names and refuses them as a root; no node is created for any of them |
| The mass-deletion guard counts post-pairing tombstones | §14b | nothing | it is the "switch" path's safety net; the reset path bypasses the scan, not the guard |
| `scannable` gates the scan jobs; `is_a?(Share)` never does | §14b | a second early return on `pending?` | both read the adapter/the setting, not ENV; `pending?` is false wherever `scannable?` is false |
| `Share#absolute_path` never resolves a NULL `storage_path` to the root | §14b | nothing | paths stay relative to the root; the root itself moves |
| The project and model intake run inside the scan on share, strictly after the reconcile | §14f, §14k | nothing | they wait with the scan while pending and run with it after |
| A verb more than one controller performs gets a service | §14d | `Tinkerex::LibraryRoot`, `Library::Reset` | one reader and writer of the setting; one reset |
| `Public::` never reads the session | §14d | nothing | the redirect is on `ApplicationController` only |
| `docs/INSTALL.md` names every variable the app reads | `install_docs_test` | no new variable | the table gains prose, not rows |

One line for CLAUDE.md §14a when this lands, in the branch that lands it (§15): *the share root is
the mount plus a stored relative choice; the mount is probed at boot and the choice at selection;
changing the choice is a scan under the mass-deletion guard, and only an explicit reset wipes the
catalog, which never touches disk.*

## 7. Tests

Every test runs on all three backend legs and branches on the backend rather than skipping, so the
legs keep identical run counts (§15); the share-only behaviour is asserted present on share and
asserted absent on s3 and chunk_remote.

- **`Tinkerex::LibraryRoot`** (unit): `pending?` by backend and row; `path` while pending and after;
  `choose!` rejects absolute, `..`, empty segments, a symlink escaping the mount, each reserved and
  clutter name, a folder under `.git`, a non-directory; writes `""` and a nested value; resets the
  adapter. **Mutation:** remove the realpath prefix check and the symlink test goes green only if
  the assertion is on the resolved path, so assert that.
- **The migration** (unit, against a throwaway schema): a user present writes `""`; no user writes
  nothing. **Mutation:** drop the `EXISTS users` clause and the fresh-install case goes red.
- **The gates** (unit): with the row absent on share, `scan_all!`, `enqueue_first_for` and
  `purge_all!` enqueue nothing; with `""` they enqueue; on the other two legs the row is ignored.
  `boot_scan_test.rb`'s second test is extended to the pending case. **Mutation:** delete the
  `pending?` return in `scan_all!` and the first assertion goes red.
- **The redirect** (integration): pending on share redirects Recent, Files, Projects, Tools and
  Settings to `/settings/library`; Help, sign-out and the page itself do not; nothing redirects on
  s3 or chunk_remote, and nothing redirects once chosen. **Mutation:** remove the `skip_before_action`
  on the controller and the page redirects to itself (red).
- **The listing** (integration, a real tmpdir mount): lists subfolders only; hides a dot-dir, a
  `.trash`, a `.maker-tmp-x`, a `.DS_Store` directory, a symlinked directory and `repo/.git`;
  answers 422 for `..`, an absolute path and an escaping symlink; cuts at the cap and says so.
  **Mutation:** each hidden name has its own assertion, so removing one filter is one red.
- **The choice** (integration): `PATCH` with `""` on an empty catalog enqueues exactly one scan and
  the page then names the folder; a nested value does the same; a read-only subfolder answers the
  PUID message naming `Process.uid`, enqueues nothing and writes no row (`chmod 0555` on a tmpdir,
  which `writable!` refuses; on an ACL filesystem no unit test can tell `writable!` from
  `File.writable?`, which `library_backend_check.rb` already records). The sign-up form on share no
  longer enqueues a scan; `tinkerex:owner` still does and writes `""` (`console task test`).
- **Switch** (integration): with a catalog over folder A, moving A to B on disk and choosing B
  scans with zero tombstones and every `node_id` unchanged; choosing an unrelated folder C with
  more files than the guard allows gone leaves the catalog intact and surfaces `UnsafeScan`'s
  message on the page. **Mutation:** raise `LIBRARY_SCAN_MAX_DELETE_PCT` to 100 in the test and the
  C case must go red, proving the guard is what protected it.
- **Reset** (integration): with attachments, pins, notes, previews (with blobs), links and a model
  over A, choosing C with "start over" leaves zero rows in every destroyed table, nulls every
  pointer named in §5, keeps every project, task, inventory item and BOM line, leaves every file
  under A on disk, and enqueues one scan of C. One assertion per table, so the list in §5 cannot
  shrink silently. A `ScanJob` enqueued with `root: A` before the change performs as a discard.
  **Mutation:** remove one table from `Library::Reset` and its assertion goes red; remove the
  root comparison in `ScanJob#perform` and the discard assertion goes red.
- **System** (one): on share, sign up, land on the library screen, open the chooser, pick a
  subfolder, confirm, and read it back on Recent. The CI runners' Chrome reports `hover: none` and
  draws classic scrollbars; neither matters to this screen.
- **Hygiene:** `compose_hygiene_test` is unchanged (no compose change); `install_docs_test` is
  unchanged (no new variable); `docs_hygiene_test` sees the one new §14a line; `css_hygiene_test`
  sees only existing component classes.

## 8. Docs

- **`docs/INSTALL.md`** §2 gains step 3 of §1 above, between creating the owner and "where your
  files come from". §3's `LIBRARY_HOST_PATH` bullet gains the sentence: "mount a parent and choose
  the library inside it from the browser; `~` works on Docker Desktop and Linux". The
  `PUID`/`PGID` bullet gains the subfolder case. §8's table gains no row.
- **`README.md`** quick start: "then confirm the folder, or pick one inside it".
- **`.env.example`**: the `LIBRARY_HOST_PATH` comment says a wider folder can be chosen inside.
- **The Help page** gains one paragraph under the library: the folder, how to change it, what
  "start over" does and does not do.
- **`unraid/tinkerex.xml`**: unchanged; its description already says the share is picked there.
- **`CLAUDE.md` §14a**: the one line in §6, with the plan.

## Out of scope

- More than one library per server on share. B decided share and s3 stay single-library; this
  design narrows the one library, it does not multiply it.
- A chooser for s3 (a prefix is already `LIBRARY_S3_PREFIX`) or chunk_remote (no folder).
- Mounting anything the compose file does not mount. Docker decides that, as the opening says.
- Per-request settings versioning for a multi-process deployment that does not exist.
- A role column. The first account is still the owner, and the page is any signed-in user's,
  because on share they all share the one library.
