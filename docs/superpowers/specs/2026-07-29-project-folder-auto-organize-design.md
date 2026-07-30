# Design: a project folder that files itself

**Date:** 2026-07-29 · **Status:** DESIGN (approved, no code yet)

> **One-liner:** a file that lands anywhere under `Projects/<slug>/` becomes an attachment
> on that project automatically, and a file sitting at the folder's **root** is filed into
> a category subfolder (`cnc`, `laser`, `design`, `models`, `cad`, `docs`, `images`,
> `other`) — created lazily, on demand.

---

## 1. Why

Today the arrow points one way only. You attach a file to a project and
`Maker::AttachToProject` moves it into `Projects/<slug>/` for you. There is no reverse: drop
three `.dxf` files onto the NAS in Finder, straight into `Projects/desk-lamp/`, and the app
indexes them as ordinary library files that the project knows nothing about. The obvious
gesture — *put the file where it belongs and let the app notice* — does nothing.

And the folder itself is flat. A project that spans a laser cutter, a CNC router and a
printer ends up with `.lbrn2`, `.nc`, `.dxf`, `.stl` and a PDF in one list, ordered by
whatever the browser sorts on.

Both halves are the same missing idea: **the project folder should be a working surface, not
a bucket the app writes into.**

---

## 2. Settled decisions

Each of these was a live choice; they are recorded so they are not silently reopened.

1. **The folder set covers the library's real mix**, not only the four categories named in
   the request. With `cnc / laser / design / other` alone, every `.stl`, `.pdf`, `.png` and
   `.f3d` lands in `other` — the biggest folder in a print-heavy project, which defeats the
   point.
2. **Root = inbox.** Only files at the project folder's root are filed. Anything already in
   a subfolder is never touched again, *including one filed "wrong" by hand.* Position is
   the marker, so there is no state to keep and no new column; dragging a file back to the
   root reads as an explicit "sort this again."
3. **The first run is retroactive** — every file currently at a project root gets filed.
   Mitigated by a dry-run task rather than by holding back (§7).
4. **Sweep + eager nudge**, not per-door hooks. §5 makes the argument.
5. **The folder comes from the filename** (`Maker::FileAttachment.role_for`), never from the
   stored `role` column. A stale column would misfile; `role_for` is pure and current.
6. **One vocabulary.** The role table is extended in place rather than a second
   extension→folder map being introduced beside it (§3).

**Out of scope, deliberately:** a per-project toggle; UI for editing the folder map; a
separate `archives` folder; re-organizing files already in subfolders; backfilling the stale
`vector` role on existing `.lbrn2` attachment rows (a separate task — nothing here reads
that column).

---

## 3. The vocabulary change

`Maker::FileAttachment::ROLE_BY_EXT` is the app's **single** file-type vocabulary. As of
2026-07-29 `FilesHelper::EXT_FAMILIES` *derives* from it precisely so a second copy cannot
disagree with it (CLAUDE.md §12 step 9). The categories in this request do not map onto it
as it stands:

- `svg`, `dxf` and `lbrn2` are all one role (`vector`), so **"laser" vs "design" is a split
  the current vocabulary does not make.**
- **No CNC extension is registered at all** — `gcode`/`gco` exist as role `gcode`; `.nc`,
  `.tap`, `.ngc` are absent.

So the vocabulary is extended in place:

| change | consequence that follows for free |
|---|---|
| add `"laser" => "Laser"` to `ROLE_LABELS` | a project-panel heading and a Files-page filter chip, both via `EXT_FAMILIES` |
| `lbrn2`: `vector` → `laser` | the laser/design split, in the one place that defines it |
| add `nc`, `tap`, `ngc` → `gcode` | CNC files get a role at all; the G-code chip widens |

Two existing constraints hold:

- **`pdf` stays `instructions`.** `Models::AttachmentsController` dispatches
  `ExtractPdfMetadataJob` on that exact value — the column is behavioural, not decorative.
- All three new extensions satisfy `FilesController::EXT_RE` (`/\A[a-z0-9]{1,8}\z/`).
  An extension that fails it renders a chip that links and silently does nothing.

`ROLE_LABELS` is display order, so `"laser"` is inserted next to `"vector"` rather than
appended.

---

## 4. `Maker::ProjectFolders`

A role → folder-name map, and the one new piece of vocabulary this design adds:

```ruby
ROLE_FOLDERS = {
  "gcode"          => "cnc",
  "laser"          => "laser",
  "vector"         => "design",
  "model"          => "models",
  "cad_source"     => "cad",
  "instructions"   => "docs",
  "document"       => "docs",
  "image"          => "images",
  "source_archive" => "other",
  "other"          => "other"
}.freeze

def self.folder_for(name) = ROLE_FOLDERS.fetch(Maker::FileAttachment.role_for(name))
```

**Lowercase, and not `ROLE_LABELS`.** These names appear in Finder and on the NAS. `cnc`
reads better there than `G-code`, and the request named them.

**`fetch`, not `fetch(..., "other")`, and the totality test is the point.** A test asserts
`ROLE_FOLDERS.keys.to_set == Maker::FileAttachment::ROLES.to_set`. Adding a role then
*forces* a folder decision instead of defaulting to a silent skip — the same "the default is
not false, it is *you must say*" that `Capabilities#scannable` uses, and for the same reason:
a role with no folder is a file that is never filed, with no error and no log. Mutation-check
it by deleting a key and watching it go red.

`source_archive → other` puts a project `.zip` in `other`. One line if that should become
its own `archives` folder.

---

## 5. `Maker::ProjectIntake`

One object, one purpose: **make the catalog agree with what is in this project's folder.**

Two entry points, one policy:

- `.for_project(user:, project:)` — the sweep. The job calls this.
- `.for_node(user:, node:)` — one file, resolving its owning project by walking up the
  ancestor chain until a node matches some project's `folder_node_id`, or the library root is
  reached. Bounded by a depth cap with a visited set, for the same reason the subtree walk is
  (a cycle must not spin).

**It READS `project.folder_node_id`; it never calls `ensure_library_folder!`.** A project whose
folder is nil or tombstoned is skipped outright. This is not an optimization — calling the
ensure would make a *sweep* create `Projects/<slug>` for every project that never had one, as
a side effect of looking. That is precisely the bug `Projects::AttachmentsController#relocate`
shipped ("the endpoint created `Projects/<slug>` as a side effect of being POSTed to"), and
the `MoveConflicts` concern already reads rather than calls for the same reason.

**Archived projects are swept too.** An archived project's folder is still its folder, and
skipping it would let files pile up in it permanently unattached — silently, since nothing
would report the omission. Archiving is a status, not a lock on the folder.

Two steps, in this order:

1. **Attach.** Every live file node in the folder **subtree** with no attachment row for this
   project gets one — `find_or_create_by!`, role from `role_for(name)`, matching
   `AttachToProject#call`'s dedupe (the table has no uniqueness index).
2. **File.** Every live file whose `parent_node_id == folder.node_id` moves into
   `Projects/<slug>/<folder_for(name)>/`.

**Attach before file, and the order is load-bearing.** It inherits `AttachToProject`'s rule
that *the attach is the durable half and the move is best-effort*: a collision or an
unmounted NAS must never cost you the reference, which is exactly as true with the bytes
still at the root.

**The subtree walk is iterative BFS over `parent_node_id` with a visited set.** Bounded and
cycle-safe on purpose: CLAUDE.md records that a cycle in `nodes` makes a recursive walk spin
unboundedly, which is *fatal* on SQLite — it has no statement timeout. A project folder is
shallow, so no CTE is needed.

**It adds zero new copies of the `port_writable?` branch.** That branch is already written out
five times (CLAUDE.md §12 step 9), and the rule there is that a new one needs an argument for
being inline. This design needs none: `Maker::MoveNode` owns the move, and
`Maker::LibraryFolder.ensure_path!` owns the mkdir. Both already branch correctly.

**Category folders are created lazily** — `ensure_path!` runs only when a file needs that
folder. Eager creation would put eight empty directories in every project (visible in Finder
and on the NAS) and, in chunk mode, emit eight changelog entries per project broadcast to
every device.

**It asks `AttachToProject#refusal_for` before every move.** This is that class's own
headline lesson: when `#relocate` was added it called the move *below* all three rules, and
silently pulled one file out of a model bundle while reporting success. A third door that
does not ask is that bug for the third time. `refusal_for` is already public for exactly this
reason.

### The trigger, and the scan race

The sweep must not run **concurrently** with a library scan, and that is a correctness
constraint rather than tidiness. If it moves a file after the Scanner has captured its
observations, the Reconciler sees the node at `design/part.svg` unobserved and the
observation at the root unclaimed, pairs them by `(content_hash, size)` — that is
`best_pairing` working exactly as designed — and re-points the node **back** to the root path
while the bytes sit in `design/`. It self-heals on the next scan, but in the window the
node's `storage_path` has no bytes behind it and a download answers 503.

So the trigger is placed to make the overlap impossible rather than to survive it:

- **share / s3:** called inline at the end of `Library::ScanJob#perform`, strictly after
  `observer.call`. Sequential by construction, and no new schedule entry. (A job
  orchestrating a maker service is not the inversion `ScanJob.observer_for` refuses — that
  objection is about a *FileLayer adapter* reaching up into the catalog layer. A job is the
  top level.)
- **chunk:** its own `recurring.yml` entry, `Maker::ProjectIntakeJob.sweep_all!`, **every 15
  minutes** — the interval `library_scan` already establishes, so the two deployments have the
  same worst-case lateness rather than two numbers to reason about. `sweep_all!` fans out per
  user, mirroring `ScanJob.scan_all!`, and gates on `scannable?` being **false**: on a scanned
  backend `ScanJob` is already the caller, and running both would reintroduce the very overlap
  this section exists to prevent. (The gate names a capability rather than a class, per
  `ScanJob.scan_all!`'s recorded lesson — `is_a?(Share)` there answered false for S3 and
  silently never indexed the library.)
- **eager nudge:** `FilesController#create`, `#finalize_upload` and the tool-save path call
  `.for_node`, so a web upload into a project folder shows as attached and filed immediately
  instead of looking broken until the next tick.

This is the shape the sync engine already uses and states: the nudge is the fast path, the
poll is the correctness fallback.

### Why not hook the write doors

A file can reach `Projects/<slug>/` six ways: `FilesController#create` (share/s3),
`#finalize_upload` (chunk), `Library::Reconciler` (the scan), `Sync::Commit#finalize` (a
device push), `Maker::Addons::LibraryOutput`, `Maker::MoveNode`, and a trash restore.

There is no single funnel — that is the structural fact. Hooking each door is six call sites
that must agree, and a seventh door silently skips the rule; this repo has that failure
recorded more than once (`AttachToProject`'s header; the five `port_writable?` copies; the
four instances of the Scanner skip-list blind spot, each found only after the previous
explanation said it could not happen). It would also put maker-layer policy inside
`Library::Reconciler`.

A sweep reads `nodes` — the catalog **all three backends populate** — so it covers all six
doors and any future one without touching any of them.

---

## 6. What it costs to be late

The sweep is polling, so there is latency. It is worth stating where, because it is not
uniform:

- **share / s3, files dropped out of band:** none added. The catalog does not learn about a
  file on the NAS until the scan sees it anyway, and the sweep runs at the end of that same
  job.
- **web upload / tool save:** none — the eager nudge covers these.
- **chunk, a device writing through the mount:** up to the sweep's interval. This is the one
  genuinely-late case, and it is the same interval the scan already establishes elsewhere.

---

## 7. The retroactive first run

Decision 3 is a bulk move: one changelog `move` per file broadcast to every device in chunk
mode, one rename per file on the live NAS in share mode. Bounded by the number of files
currently at project roots, but real. The mitigations:

- **`rake projects:organize:dry_run`** prints what would move, per project, so it can be
  inspected before it happens. `rake projects:organize` does it.
- **Per-file rescue** — one collision cannot stop a sweep over the whole library.
- **One summary line per project** (attached / moved / skipped). Nothing persists a marker,
  so the log *is* the audit trail — the same argument as `AttachToProject#log_failure`, and
  the counts are behaviour, not phrasing.

**No percentage guard, unlike the Reconciler's mass-deletion guard, and this is argued rather
than forgotten.** That guard exists because a tombstone propagates to every attachment, BOM
link and tag. A move does the opposite: `node_id` never changes — the port's stated promise —
so every reference survives, and the operation is reversible by dragging the file back. The
dry-run task is the safety valve a percentage would otherwise be.

---

## 8. Failures

| condition | answer |
|---|---|
| `MoveNode::Collision` — the destination name is taken (`design/part.svg` exists) | leave the file at the root, count it skipped. The attachment stands. |
| `FileLayer::FetchError` (share unmounted, bucket unreachable) | abort **this project's** sweep on the first one — one log line, not one per file |
| `FileLayer::NotFound` (tombstoned mid-sweep) | skip that file, continue |
| `FileLayer::UnsupportedOperation` (a backend refuses this move) | skip that file, continue |
| `MoveNode::InvalidName` | **not rescued** |

**`InvalidName` is deliberately absent.** Names come from existing `nodes` rows, which
`#leaf!` already vetted — there is no producer on this path. `AttachToProject#move` records
what a too-wide rescue list costs: it caught bare `ArgumentError` until a review drove the
consequence that arity drift, a kwarg rename or a nil reaching `File.extname` all became a
flash message with a green suite. An unjustified class here is a machine for turning bugs
into outage messages.

A permanently-colliding file stays a candidate on every sweep — the honest cost of the
stateless root-is-inbox rule. Summary-level logging is what stops that from becoming per-file
noise every 15 minutes.

---

## 9. Testing

The suite runs on all three legs — `bin/rails test`, `LIBRARY_BACKEND=share`,
`LIBRARY_BACKEND=s3` — and the counts must be identical, the house standard since Phase 2a.

- `ROLE_FOLDERS` is total over `ROLES` (mutation-checked: delete a key, it goes red)
- `EXT_FAMILIES` gains a Laser chip and the widened G-code chip, from the existing derivation
- attach reaches the whole subtree; filing touches **only** the root
- a file filed into the "wrong" subfolder by hand is never touched again
- idempotency: a second sweep writes nothing
- a collision leaves the file at the root **with the attachment intact**
- `refusal_for` is honored — a model-bundle file is not yanked by this third door
- `.for_node` resolves the project from inside a category subfolder
- a project with a nil or tombstoned `folder_node_id` is skipped and **no folder is created** —
  the side-effect bug this design is written to avoid
- an archived project is swept
- the scan-then-sweep order in `ScanJob#perform`, so the race in §5 cannot regress
- `sweep_all!` no-ops on a scannable backend, so the two triggers cannot both fire

**CI cannot run this.** Only `charless-MacBook-Pro-maker-mac` is registered and all seven
`ci.yml` jobs target linux, so they queue forever rather than failing (CLAUDE.md §15).
Verification is local, on all three legs.

---

## 10. Boundary check

Nothing here touches sync, the changelog, conflicts, locks or the mounts — the spec §10
tripwire from the maker/file-layer split. `ProjectIntake` is maker-layer policy that reaches
bytes only through `Maker::MoveNode` and `Maker::LibraryFolder`, which own the port-vs-sync
branch. The one file outside `app/*/maker/` that changes is `Library::ScanJob`, and it gains
a call, not a decision.
