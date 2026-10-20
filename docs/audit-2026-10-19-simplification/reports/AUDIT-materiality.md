# AUDIT-materiality — materiality and over-abstraction pass

Pass: "audit the audit", materiality and over-abstraction. Subject: AUDIT.md §2 (49 F-entries) plus
reports/S01–S29.md. Repository: /Users/charlesschwartz/Desktop/repos/tinkerex at HEAD
75124d67982f4c6d110e39e21c0b58452aa3916e (confirmed with `git rev-parse HEAD`; working tree holds only
the pre-existing untracked app/assets/images/landing/library.jpg, untouched).

Method. For every F-entry I re-opened the cited repo lines myself (sed/grep/git show only; nothing
executed), re-read the CLAUDE.md §14 bullet or docs/invariants/*.md rule each one touches, and read the
worker report's "Considered and rejected" list where a narrower fix seemed possible, so as not to
recommend an alternative the worker had already rejected for a recorded reason. Sibling repos
(../tinkerex-sync, ../tinkerex-client, ../tinkerex-addons) were read as they stand locally, not fetched.

Verdict legend.
- KEEP: real at HEAD, removes at least as much as it adds, and the stated scope is right.
- NARROW: keep it, but with the smaller scope given.
- DEMOTE: not a material simplification. It changes no representation (a pure index, a one-line
  fix, a contract fix), or its trigger is hypothetical or unreachable at HEAD, or it is housekeeping.
  It becomes a §4 note or a defect/perf ticket.
- REJECT: not real, misreads intentional semantics, undoes a recorded invariant, or relocates
  complexity.

Priority tiers inside KEEP/NARROW: T1 = data, security or deploy-gate impact; T2 = a visible
defect or a duplicated decision that has already drifted; T3 = preventive or local value.

Tally: KEEP 33 · NARROW 6 · DEMOTE 9 · REJECT 1 (49).

---

## A. Per-finding verdicts (AUDIT.md §2 order)

### F-S04-1 — ChangelogSync: one typed node-state value
**NARROW (T3; latent defect).** I confirmed the bug. `full_resync` calls `upsert(n, deleted: false)`
with no `version:` (changelog_sync.rb:166). `upsert` then guesses `version ||= payload["version"]`
(:222). But /v1/tree nodes carry `version_id`/`size`/`manifest` flat (docs/sync-protocol.md:672-686;
../tinkerex-sync services/tree.rs:19-23), so a resync never sets `current_version_id` or `size`. The
test fake nests a `"version"` hash that no server sends (changelog_sync_test.rb:150), which is
§14e's "a fake that shares the code's misunderstanding confirms it" (CLAUDE.md:992).
The defect is latent: `prune_changelog` (tinkerex-sync gc.rs:202) has no caller, so `gapped?` never
fires today.
A `NodeState` Data type with two constructors adds more than the fix needs. Narrower scope:
- pass `version:` and `manifest:` explicitly from the two call sites (:166 and :186-188);
- delete the `||` guess and the `@current_manifest` ivar;
- correct the three fake tree nodes.
The same invariants still hold afterwards: a pruned-version put, `store_manifest` idempotency, and
the nudge fed only by `apply_page` (project-intake.md).

### F-S01-1 — One reading of LIBRARY_BACKEND; retire the `chunk` sentinel and the dead module
**KEEP (T2).** I found five readers with four different defaults or normalisations:
- `ENV.fetch(...,"share")` (file_layer.rb:169);
- `env.fetch(...,"chunk")` (library_backend_check.rb:107);
- `.to_s.strip.present?` (:126);
- `env["LIBRARY_BACKEND"].to_s` (registration.rb:47);
- the dead `LibraryBackend.name` (lib/library_backend.rb, `DEFAULT = "chunk"`, three test callers
  and none in app/lib/config).

actionpack 8.1's CSP middleware applies the header to every response, with no HTML check
(content_security_policy.rb:37-55 in the gem), and the `connect_src` lambda resolves
`FileLayer.current` on each one (config/initializers/content_security_policy.rb:53-56). So a typo,
the retired `chunk`, or a space-padded value passes both boot guards and then makes every
response a 500.

This does not undo §14a (CLAUDE.md:641-656). An unset value still boots in development, and the
guard still receives the resolved name. Only the "match no arm" sentinel becomes an explicit nil.
Net abstraction is about zero: `configured`, `boot!` and `UnknownBackend` come in; the module, the
sentinel and the hand-require go.

Two notes:
- Rewrite both §14a bullets in the same slice.
- On Kamal destinations the /up health check already stops a bad value from going live, so the
  gain is mainly for compose and Unraid-template installs.

### F-S11-1 — Stamp each addon file row with the revision that wrote it
**KEEP (T2).** The code records the missing fact itself: "NOTHING ON THE ROW SAYS WHICH SAVE THAT
WAS ... arbitrary and unrecoverable" (library_output.rb:107-112). Where it is read:
- the association orders `(:position, :id)` and calls that "a tiebreak, not a repair"
  (addon_state.rb:9-23);
- `latest_output_folder` orders `position ASC, id ASC`, so the oldest row wins
  (tools/addons_controller.rb:682);
- docs/addon-api-v1.md promises save order back from `state.list()`.

I checked the cheaper alternative of touching `maker_addon_files.updated_at` on every upsert. It
fails: rows from one save would then order by write time and reverse `position`.

The fix adds one column (net +1) to replace a guess nothing else can recover. It is not a count
column, so it does not contradict addons.md:341-343. Keep S23's backfill-test caveat (the state
must sit at revision 2 or above).

### F-S10-1 — One bounded content-read door for the two zip readers
**NARROW (T1 for the defect).** I verified this from source.
- Both `self.for` methods wrap `read` in `Rails.cache.fetch(..., expires_in: CACHE_TTL)`
  (gerber_archive.rb:88-90, three_mf_manifest.rb:91-93).
- `read` rescues port failures to nil inside the block (gerber_archive.rb:93-97,
  three_mf_manifest.rb:98-105).
- activesupport writes a nil unless `skip_nil` is set (cache.rb:1123). Production uses Solid Cache
  (production.rb:109); the test env uses `:null_store` (test.rb:47).
- An anonymous visitor reaches the code through `Public::FilesController#view`
  (public/files_controller.rb:57-60).

files-preview.md:171's "nil cached too" means the PARSER's nil, and the fix keeps that.

The material part is the bug, and it needs no new type:
- move each rescue outside its own `fetch`;
- add GerberArchive's missing banner arm;
- bump both cache namespaces.

The shared `Maker::ContentRead` door (one module for two callers) is optional consolidation. The
already-drifted banner arm is a fair argument for it. Land the in-place fix first.

### F-S10-2 — Resolve the file page's viewer once as a typed `Viewer`
**NARROW (T3).** The same ~18-line assembly appears twice (files_controller.rb:537-574,
public/files_controller.rb:57-73). Public tests cover Gerber layers only
(public_file_view_test.rb:112-122), not zips or 3MF.

The "provisional `@kind`" hazard is not reachable. `@editable = @kind == :text` runs at :522,
before the zip override at :539, but a `.zip` never resolves to `:text`.

Narrower scope: one concern method that returns the archive / layer list / single trio, which is
the only part that holds a decision, plus the missing public zip and 3MF tests. Those tests are most
of the value. The 5-field `Viewer` Data type and moving the `colors`/`unit_factor` defaults
(`@viewer_manifest&.colors || []`, twice) are line-count.

### F-S15-1 — One editing-aware "subfolders with no tiles", read by the recent row and the thumbnail union
**KEEP (T2).** Both derivations are as described:
- `dirs_without_tiles` drops hidden and browser-view panels (projects_controller.rb:632-643);
- the union subtracts only `hidden_in_repos = repo_subtree_ids - @generated_ids - unrolled`
  (:402-406), which is keyed on `repo?`;
- the comment at :626-631 says the two agree, and they do not.

`ProjectPhotos` takes image rows at any depth (project_photos.rb:13). But `@photo_rows` is built at
:432, after the union. So an image inside a browsed repository is painted and never backfilled, and
the comment at :428-431 is false for it.

The proposal deletes `unrolled`, `hidden_in_repos`, `ProjectFolderListing#repo_subtree_ids` and two
subsumed union terms. That is net removal, in memory, with no change to query counts. The edit-mode
reading of a hidden panel is the owner's call.

### F-S15-2 — "The browser draft is the whole truth of blocks and tabs" belongs in `merge(:draft)`
**KEEP (T2).** What the code does today:
- `merge` re-appends every saved entry the draft omits (layout_document.rb:352);
- it runs the Publish note, the block cap and the tab checks on that merged set (:353-376);
- only `PanelsController#replace` filters the merge afterwards (`held_by_browser`,
  panels_controller.rb:55, :87-90);
- `LayoutsController#yaml` and `#parse` use the raw merge (layouts_controller.rb:23-39).

`from_draft` has exactly these three callers (grep), all of them browser drafts. The editor posts
every slot (layout_editor_controller.js:32-33, :83-84).

This revises content-blocks spec §10.9 (docs/superpowers/specs/2026-09-09-content-blocks-design.md:234-241).
That is a spec decision, not a CLAUDE.md §14 or docs/invariants rule, so revising it is allowed with
a spec note. Net removal: one `reject`, and `held_by_browser` is deleted.

### F-S05-1 — Partial index for the Reconciler's tombstone-revive lookups
**DEMOTE (perf ticket; disagrees with keeping it in §2).** The mechanism is right:
- the only `storage_path` index is partial, `WHERE deleted = false` (db/schema.rb:507);
- the file lookup asks `deleted: true` (reconciler.rb:535-536);
- the dir lookup omits `deleted` (:605);
- so neither can use the index.

But the proposal changes no representation, state or control flow. It is an index. The brief admits
an index only where it "materially simplif[ies] behavior", and this one changes cost, not behaviour.
Its materiality also depends on scale: negligible on the ~5k-row real library, and minutes only past
~100k files (the reviewer's in-memory probe, not a deployment measurement).

Keep it as a cheap scalability ticket, with S23's two corrections. The behavioural risk, overlapping
scans once the 1-hour per-user semaphore is exceeded, starts around 240k files. That is a projection.

### F-S05-2 — Give the Reconciler's pass state one owner
**KEEP (T3).** The hand-kept invariant is as described:
- `LiveRow` is a mutable Struct (reconciler.rb:59-65);
- `#live` says "Count them against the code, not against this sentence" (:717-727);
- there are eight write sites (:163, :311, :449, :450, :552, :582, :618, :671-672) and three
  verbatim `LiveRow.new` blocks;
- every `@dir_ids` stamp (:595, :609) has a matching `live[...]` row, so `parent_id_for`'s
  `@dir_ids[dir] || live[dir]&.node_id` (:686) reads one fact from two places.

Two private writers plus deleting `@dir_ids` is about net-zero inside one private file. The payoff
is preventive: one recorded miss (0a160454). Do not touch the "present rows only" rule
(reconciler.rb:728-733).

### F-S06-1 — `ProjectIntake::Result` as one row per inbox file
**KEEP (T3).** What I found:
- `Result` carries derivable counters and a `conflict_folders` side channel behind a defaulted
  initializer (project_intake.rb:32-48);
- `#place` returns a String or a Symbol, which `file_all` sorts with `is_a?(Symbol)` (:729), and
  `file_all` returns a positional tuple (:737, :747);
- the Collision arm writes the side map from inside a rescue (:849, :878);
- the consumer re-derives the folder on a miss (project_folder_intake.rb:203-206). That is the shape
  that shipped the wrong "archives/" flash (521bfb30).

`Filing` rows remove the pun, the tuple, the side channel and the fallback. Derived readers keep the
shapes of `plan` and `skips`. Net: 4 fields fewer, one small Data type more. The invalid
combinations cannot be reached in production, so the value is local and preventive.

### F-S08-1 — One owner for "does this preview row need a job?"
**KEEP (T1).** The stall heal is unreachable from every read door:
- `ThumbnailMap.backfill!` skips rows where `map.current?` (thumbnail_map.rb:140);
- the map holds rows that pass `Enqueue.current_preview?`, which compares version and revision only
  and ignores status (enqueue.rb:215-220);
- `#current_thumbnail` returns a current row before reaching `Enqueue` (files_controller.rb:1230-1237);
- `#geometry` enqueues only `if preview.nil?` (:479-483);
- `MissingBackfill` skips any row whose triple matches, whatever its status (missing_backfill.rb:89-108).

measure-view.md:320-327 says these doors reach `STALLED_AFTER`. That is the heal written for a
recorded production wedge (three rows, the oldest over a week). In practice only the v1 API reaches it.

One predicate used by `call` and by the doors replaces five weaker copies.
`current_preview?` stays status-blind, as §14h requires.

### F-S08-2 — `ready` means two things during a renderer rebuild: a `rebuilding` status
**KEEP (T2, after F-S08-1).** I confirmed the window.
- On a renderer-only rebuild, `Enqueue` stamps the new revision and leaves `ready` (enqueue.rb:100-117).
- The second `#geometry` poll comes 250 ms after the first (`POLL_DELAYS_MS`,
  measure_controller.js:49). It finds a current `ready` row and serves `url_for(preview.asset)`, the
  old build (files_controller.rb:484-487), whenever the 3-thread worker (queue.yml:7) has not started
  the job yet.
- The job's start write `update!(status: "processing")` (generate_preview_job.rb:89-90) blanks the
  picture that measure-view.md:278-285 says stays visible.

It adds state (net +). The lighter alternatives are worse:
- Geometry-only blanking inside `Enqueue`: the S08 reviewer rejected this because it puts a
  consumer's policy in the shared writer, against measure-view.md:286-291 ("A CONSUMER THAT CANNOT
  TOLERATE AN OLDER BUILD'S OUTPUT SAYS SO ITSELF").
- A desired/observed split: needs a migration.

So `rebuilding` is the smallest representation that keeps that rule. It has the widest blast radius
of the preview findings: 15 `"ready"` literals and 6 in-flight literals (grep). Its first, neutral
step (predicates on `Maker::Preview`) is useful on its own and absorbs S10's repeated
ready-and-attached check.

### F-S03-1 — One S3 trash-entry shape; drive delete and undelete from one subtree walk
**KEEP (T1; one slice with F-S02-1).** All three defects follow from the code:
- **(a) A folder holding an out-of-band-deleted file can never be deleted.**
  `delete_directory!` builds its object set with `where.not(storage_path: nil)`, on the premise "a
  descendant already tombstoned by a scan has a NULL path" (s3.rb:531-532). But the Reconciler
  tombstones with `node.update!(deleted: true)` and keeps the path (reconciler.rb:161-162). So the
  vanished object is copied, the copy fails, and the delete fails on every retry.
- **(b) A deleted app-made folder comes back under new node ids.** `mkdir`'s `<key>/` marker
  (s3.rb:417-425) is excluded by `kind: "file"`, so it stays in the bucket. S3Observer treats a
  marker as positive evidence of a directory (s3_observer.rb:154).
- **(c) A deleted folder cannot be restored.** `undelete` reads `trash_key(node)` =
  `.trash/<id>/<name>` (s3.rb:731, :842-844). A directory delete never writes that key, so the
  restore answers "purged?" and every child answers "restore the folder first". That contradicts
  §14a's "a refusal is recoverable" (CLAUDE.md:470).

The root-relative entry shape is not over-abstraction. It is necessary for (c): today's keys embed
each file's full `storage_path`, and the cascade NULLs it. Step 1 (the delete side) is narrow and
ships on its own.

### F-S03-2 — `ObjectIdentity.for_reported` and FakeS3's `LastModified`
**DEMOTE.** The drift is real:
- `move` and `restored_stat` guard with `present?` (s3.rb:675-676, :1002);
- only `store_identity` rescues the `ArgumentError` that `normalize_etag` raises for a quoted-empty
  `""` (object_identity.rb:107-118; s3.rb:1120-1129);
- FakeS3's copy result omits `last_modified` (fake_s3.rb:205), although the SDK's
  `CopyObjectResult` has it (aws-sdk-s3 types.rb).

But the trigger needs a store that sends blank ETags on COPY or HEAD while sending real ones on LIST.
A blank listing ETag already raises in the observer, by design. I found no evidence of such a store:
b3741f76 added the guard in review, not from an observed store. The mtime half "heals at the next
scan", in the finding's own words.

What remains is a two-line hardening ticket and a fake-fidelity ticket. `BlankEtag` and
`for_reported` add two names for a hypothetical input.

### F-S09-1 — The Measure view's phase has two owners
**KEEP (T2).** What the controller does:
- `load()` has no generation and no shared promise (measure_controller.js:125-135);
- `connect()` never resets the element (:95-117);
- `--ready` is set only in `draw()` (:235) and alone drives visibility (preview.css:245-248), so
  Measure stays clickable while generating;
- `restingStatus()` dereferences `this.allShapes.length` without a guard (:693-696).

The fix applies the house rule already recorded for the Gerber viewer, "A Turbo-restored snapshot of
an open viewer is reset to the poster on connect" (files-preview.md:277-278), using the sibling's
mechanism (gerber_controller.js:73-120). Two fields come in; the dependency on the DOM class as state
goes. Client-only, leg-neutral. Leave the optional `this.view` bundling out of the first slice.

### F-S02-1 — Record which trash entry a tombstone belongs to
**KEEP (T1; same slice as F-S03-1).** What the code does today:
- the cascade runs `update_all(deleted: true, storage_path: nil, updated_at: ...)` over
  `Subtree.node_ids`, which includes tombstones by design (share.rb:422-424; subtree.rb:17-18);
- `revive_subtree!` revives any walked child whose rebuilt path exists, in no fixed order, without
  restoring `content_hash` (share.rb:694-712);
- `trashed` lists rows with `deleted AND storage_path IS NULL` (:81-82);
- TrashController has no `RecordNotUnique` arm (trash_controller.rb:36, :59, :65).

So: delete `x.stl`, upload a replacement `x.stl`, then delete and restore the folder. The restore
reaches two rows for one path. The new column is the minimal exact fix for that case. Within the
trash window, "`.present` on the cascade" plus "skip a row that owns its own `.trash/<id>` entry"
handles (a), (c) and (b). Once `LIBRARY_TRASH_DAYS` has purged the older entry, no inference can tell
the two rows apart.

Two cautions:
- The column is a second spelling of "trash tombstone" (§14a two kinds, CLAUDE.md:600), so the
  coordinator's equivalence guard is required, not optional.
- Ship the one-word `.present` change on the cascade first. It is correct on its own.

### F-S02-2 — A directory move rewrites its descendants' `storage_path`
**DEMOTE.** The state is real. `move` rewrites only the moved row (share.rb:499), and the adapter
itself calls the cascade "the right end state and it is NOT in this phase's plan" (:449-452).

But no production door can move a directory. FilesController refuses with `FOLDERS_NOT_YET`
(files_controller.rb:1022, :1046) and already says to "lift it with that port change, as its own
slice" (:1018-1021). S3 refuses directory moves too.

At HEAD this is a prerequisite for a future feature, already recorded at both ends, and the brief
excludes hypothetical extensibility. Attach the design (a prefix-guarded rebase and a refusal to move
a folder into its own subtree) to the FOLDERS_NOT_YET follow-up.

### F-S14-1 — One "shown" answer for a visitor's project page
**KEEP (T2).** Four bases answer one question:
- the hidden sets are built from the capped tree (public_project.rb:147-157);
- seven readers each filter by hand (:123, :299, :313, :328, :342, :365, :381), with a comment asking
  new readers to remember to (:139-146);
- `permitted_cover_ids` never reads a layout (:491-513), while the hero's `cover_node` refuses a
  hidden cover (:374-381);
- `thumbs` = `listing.node_ids + page_nodes.keys` (:429-431).

On the last one the view admits "a cover outside the listing is simply not in that map"
(public/projects/_page.html.erb:126-128), even when a ready row exists.

One lineage predicate and one `shown_rows` starting list replace three sets and seven filters (net
removal). `permits?` stays "the ONE answer" (§14d), because "hidden is not unpermitted" is kept.
The /u/:handle card change needs the owner's yes.

### F-S13-1 — The commit box computes each path's row once
**KEEP (T2).** Every row is computed twice and the commit authority is defined twice:
- `#show` builds the pending rows through `status_for`;
- `full_status` then rebuilds every dirty row and throws the twins away
  (repo_commits_controller.rb:27-37; local_repo.rb:96-105). Each `row_for` reads the whole file
  (:249-270);
- `binary_paths` re-reads 8 kB of every listed file (:200-212);
- `#create` repeats both scans (:51-53, :151-153);
- `node_ids_for` reads an ivar that `reconcile` wrote (:130, :213);
- the authority is defined twice, and the comment at :45-50 records it shipping wrong once.

A `Staging` builder (one Data type, plus `Row#binary`) deletes three methods and two ivars, so this
is net removal. Binary stays decided by content (git-editing.md:579-581), and `checked:` stays in
the view. The I/O saving is estimated from the CIFS figure, not measured.

### F-S13-2 — `CommitPaths` decides each selected path once
**KEEP (T3).** Two things are read twice:
- `stage` recurses with the same `rel`, so `File.exist?` runs at every level (commit_paths.rb:76-102),
  despite the comment "ASKED ONCE" (:86);
- `refresh_index` re-reads existence, blob and mode after `Rugged::Commit.create` has moved the ref
  (:46-53, :157-166).

Reading each path once into `{oid, mode} | nil` makes the class header's and git-editing.md:183-185's
"write window is two operations wide" true. It keeps the three-way index branch git-editing.md:589-597
requires. No new types; one local hash. Materiality is modest: the race needs a concurrent SMB write
during one commit, and the I/O saving matters only near the 500-path cap.

### F-S16-1 — Sheet autosave saves on five named events only
**KEEP (T2; defect-first).** Only five named events schedule a save (sheet_controller.js:77-81). The
vendored grid has sorting, column rename, resize and row/column drag switched on unless set to false
(`0!=e.options.columnSorting` and siblings in vendor/javascript/jspreadsheet.js). It fires
`onsort`, `onundo`, `onredo`, `onresizecolumn`, `onmoverow` and `onchangeheader`, and none of them is
handled. `save()` sends the whole grid (:127-132), and `disconnect()` drops a pending timer.

One catch-all hook plus a comparison against the last stored grid replaces an enumerated list that
fails silently. The code size is about the same, but the "Saved" label can no longer sit over unsaved
state. Whether sorts and drags should persist or be switched off is the owner's call.

### F-S16-2 — A stock BOM line's unit is stored twice
**KEEP (T2; shape flagged in B).** The two copies disagree in practice:
- only the web door copies `item.unit` (projects/bom_lines_controller.rb:37-42);
- v1 accepts `:unit` verbatim (v1/maker/bom_lines_controller.rb:29-34);
- the shipped desktop composer sends `unit: $("blUnit").value` for every line kind
  (../tinkerex-client/client/maker-app/src/projects.js:424);
- one table row shows `line.unit` in Qty (_bom_lines.html.erb:64) and `item.unit` in Consume (:74).

The rule belongs in the model. But the proposed shape keeps the duplicate and adds two hooks to keep
it in step (`before_validation` on BomLine, `after_update` on InventoryItem) plus a data migration.
S18's alternative instead derives the unit from the item for stock lines and copies it in
`release_bom_lines`, which removes the duplicate's authority. Both shapes respect §14d's
dangling-id rule (CLAUDE.md:921). The owner picks. If the hook is chosen, scope its `update_all` to
the user, as `release_bom_lines` is scoped (inventory_item.rb:61-69).

### F-S19-1 — `InventoryTransaction` owns what a postable ledger row is
**KEEP (T1; security track first).** How the leak and the corruption happen:
- the model validates `delta` with a bare `numericality: true` (inventory_transaction.rb:21);
- only the web door holds `MAX_DELTA`/`parse_delta` (inventory_items_controller.rb:120-138) and drops
  a foreign project id (:108-113);
- v1 `adjust` passes `params.require(:delta)` and `params[:project_id]` straight through
  (v1/maker/inventory_items_controller.rb:32-41);
- the ledger view renders `link_to(t.project.name, project_path(t.project))` through an unscoped
  `belongs_to` (show.html.erb:88; inventory_transaction.rb:18).

So any device token can make another tenant's project name and slug show on its own ledger page, and
can post non-finite deltas into an immutable ledger. Moving validity and scoping into the model
removes the door-only rule (net removal). Confirm the disclosure with one request and fix it on its
own track, as AUDIT.md §4 says.

### F-S20-1 — The icon-only rail as one container query
**KEEP (T2).** What the stylesheet does:
- the collapsed-rail rules exist twice: once prefixed `.rail--collapsed` (shell.css:71-82) and once
  unprefixed under `@media (max-width: 1099px)` (:160-168);
- the unprefixed `.brand-name { display: none }` has to be undone by `.public-header .brand-name`
  (:29, with its own comment at :22-25) and by `.landing-nav .brand-name` (landing.css:17-21);
- `.auth-card .brand` (shell.css:146) sets padding only, and six Devise views render `.brand-name`.

So the sign-in card loses its wordmark below 1100px. That is read from the cascade, not observed in a
browser.

One container-scoped block removes a duplicated rule set and two overrides (net removal). No
design-system.md rule conflicts: rules 7 and 8 cover cookies and the lit link.

### F-S20-2 — Help uses the shared "where files come from" partial
**DEMOTE.** The copies have drifted. help/show.html.erb:31-50 and
shared/_where_files_come_from.html.erb say "a folder on this server" versus
`library_folder_label`, and "Files" versus "Library". The Help file itself asks for the swap
(:19-22).

This is a recorded TODO about user-facing copy. It removes no state, control flow or decision the app
acts on. File it as a housekeeping ticket.

### F-X-1 — Dead port keyword arguments `device:` and `broadcast:`
**KEEP (T2).** No adapter reads either keyword:
- chunk_remote says so itself: "`device:` IS ACCEPTED AND UNUSED" (chunk_remote.rb:321-325) and
  "`broadcast:` IS ACCEPTED AND UNUSED" (:374-378);
- share and s3 refuse both verbs, and their `finalize_upload` does not even accept `broadcast:`
  (share.rb:322, s3.rb:400).

Yet `web_device` and `addon_device` find-or-create a `devices` row for it
(application_controller.rb:63-67; library_output.rb:216-218). That is the table §8 calls the API's
only credential.

The §14a bullet (CLAUDE.md:489-495) describes a parameter with no effect: chunk_remote's server
broadcasts every commit. Deleting it does not undo a live behaviour; it corrects a false statement.
Net removal.

### F-S17-1 — One predicate for the demo's promise
**KEEP (T3).** The rule is spelled in three places:
- `Demo.available?` asks only `accounts_sharing_library(except:).zero?` (demo.rb:48-50), and claims
  "the button, the links and POST /demo all ask this";
- POST /demo re-derives it (demo_sessions_controller.rb:37-46);
- `DemoReset.refusal` also refuses any port that is not Share or S3 (demo_reset.rb:75-79);
- `accounts_sharing_library` returns 0 when `syncable?` (:93-97), the capability coincidence §14b
  warns about (CLAUDE.md:709).

So on chunk_remote the door opens while the reset refuses every night, and the banner promises a
reset. One predicate replaces three spellings. It is reachable only when an operator sets
`DEMO_ACCOUNT_EMAIL` on chunk_remote (shipped configs set it only on OVH, which is s3), hence low
priority. The direction is the owner's.

### F-S07-1 — The catalog's "claimed?" includes discovery's positional claim
**KEEP (T1).** The path to a wrong row:
- `claimed_folders` unions only the claims that already exist (model_intake.rb:145-150) and leaves
  correctness to ScanJob's ordering (:137-138);
- discovery is capped at `MAX_PROJECTS = 50` (project_discovery.rb:58), and `adoptable` is private
  (:188);
- `*` makes `Projects` a shelf (shelf.rb:21-24), and `owner_key` keys the folder directly below the
  nearest shelf (model_intake.rb:255-269).

So on a first scan the 51st `Projects/<x>` becomes an auto folder model, and later a project too,
until someone runs `rake models:prune`. A public, uncapped `positional_claims` that `adoptable` also
uses is one rule with two callers. Net abstraction is about zero, and an ordering dependency
disappears. Consistent with model-intake.md:88-98, and it leaves :205-211's intake-then-catalogue
ordering alone.

### F-S07-2 — Let the sweep reconcile auto-model rows; retire `ModelIntake::Prune`
**REJECT (as written).** It retires `Prune` and makes the unattended sweep delete rows. That
reverses model-intake.md:177-192: "`Maker::ModelIntake::Prune` IS THE REPAIR HALF, AND IT IS NOT IN
THE SWEEP ON PURPOSE". The finding itself says it "REVERSES a recorded decision", and its first run's
delete volume is unmeasured.

The evidence is sound:
- the only `Models::AttachmentsController#create` caller is the importer, posting to a just-created
  import model (importer_controller.js:122; models_controller.rb:130);
- Prune's guard 3 breaks when a file moves (prune.rb:57-60).

That is grounds for the owner to reopen the rule, not for this audit to recommend reversing it.
Three pieces do not reverse it and could stand alone:
1. Make the attach door refuse an auto model, which makes `origin` the door discriminator.
2. Teach Prune that a moved node belongs to the plan's model (guard 3's premise).
3. Insert only the missing pairs (pluck-and-reject, as ProjectIntake does), so a steady-state tick
   writes nothing.

### F-S21-1 — Retire `Projects::UploadsController`'s project-target arm
**KEEP (T2).** The arm has no caller:
- the nested `resources :uploads` route still exists (routes.rb:257);
- nothing calls `project_uploads_path`; grep finds only `build_log_entry_uploads_path`
  (_log_entry.html.erb:20);
- the controller branches on target type and carries an ordering invariant that applies only to the
  project case (uploads_controller.rb:41-80).

Deleting an unreachable second door that disagrees with the top-bar door is net removal. It is
`port_writable`-gated, so chunk_remote is untouched, and the deleted tests are Share-only on every
leg. Update project-intake.md:69-70, which names `#upload_parent` as a nil-handling caller.

### F-S21-2 — `UploadBatch` owns every per-file refusal
**NARROW (T2; defect-first).** The defect:
- `write_batch` rescues only `UnsupportedOperation` and `FetchError` (upload_batch.rb:49-65);
- `Share#write` raises `NotFound` for a non-leaf name, a reserved path and the size cap
  (share.rb:742, :788, :831).

So a `.DS_Store` in the middle of a selection aborts the batch after earlier files have landed.
FilesController answers "File not found." (its `rescue_from` at :130), and Projects::UploadsController
has no `NotFound` arm (:30-36), so it answers 500.

Smallest fix that removes the invalid state:
1. refuse `NotFound` per file inside the loop;
2. add a `NotFound` `rescue_from` to the build-log door;
3. route previews through `LibraryOutput`'s one stat-then-enqueue. The concern calls an
   `enqueue_preview` it does not define (:51).

The `REFUSED_BECAUSE` table and the `uploaded_files` single/batch rework are optional tidy-up: a map
in front of three rescue arms.

### F-S18-1 — Retire `rescue_from ArgumentError` from `V1::BaseController`
**KEEP (T3).** `rescue_from ArgumentError, with: :unprocessable` renders `e.message` to the client
(v1/base_controller.rb:37, :44). Nothing intended produces one any more:
- there is no `enum` and no `raise ArgumentError` in app/models or the Maker services, except
  `MoveNode::InvalidName`, which no v1 controller reaches (grep);
- no v1 controller parses input with `Integer()`, `Float()`, `BigDecimal()` or `Date.parse` (grep).

The house rule is that a bare ArgumentError is a programming error and should 500
(move_node.rb:58-64). Deleting this one vestigial line removes the second answer to one error class.
Low priority.

### F-S22-1 — The 3D viewer's lifecycle on the Gerber viewer's model
**KEEP (T2).** The controller and the vendored engine disagree:
- `connect()` resets `generation = 0` and does not reset the element (modelviewer_controller.js:35-40);
- callbacks go through per-load controller fields (:95-97, :117-118);
- the vendored engine silently drops a second `LoadModel` while one is running
  (`LoadModel(e,t,n){this.inProgress||(...)`);
- it nulls `progressDiv` before calling it, and the running import's `onImportStart` then
  dereferences it (`this.progressDiv.innerHTML`);
- `Destroy()` only nulls the importer (all in vendor/javascript/o3dv.js).

One engine record and one token replace two tokens and per-load re-wiring, about net-neutral. It also
applies files-preview.md:277-278's reset-on-connect rule. Cases (b)-(d) are read from the engine, not
driven, so run the new tests against today's code first.

### F-S23-1 — Make `SchemaMap::EDGES` complete by check
**KEEP (T3; guard gap).** `EDGES` is written by hand (schema_map.rb:104 onward). The header admits a
NEW app-level reference nobody adds to EDGES goes uncaught, on the premise "no naming convention to
key on" (:25-32). The examples behind that premise (`manifest_id`, `chunk_hash`) left with the engine
tables.

`StructuralOrphanTest` derives its cases from EDGES (structural_orphan_test.rb:20-28), so an undrawn
pointer is never checked. `maker_releases.repo_node_id` exists (schema.rb:405) and is not drawn
(schema_map.rb:196-198).

A `NOT_EDGES` list turns five prose explanations into data and closes the derived guard for `*_id`
columns. Preventive; low priority.

### F-S23-2 — Retire schema state nothing maintains
**DEMOTE.** The state is dead:
- `updated_seq` has no reader or writer in app/lib/config (two comments only);
- `maker_file_attachments.version_id` is written only through the v1 permit list
  (v1/maker/file_attachments_controller.rb:33) and echoed back (:37);
- `Maker::Preview.ready` (preview.rb:30) and the `(user_id, status)` index (schema.rb:318) have no
  reader.

Dropping dead indexes and columns is housekeeping with "no live defect", in the finding's own words.
The column half changes the v1 wire, rewrites CLAUDE.md §5 (:149-151), and needs a product answer
first. Take the two DROP INDEX statements and the dead scope as a hygiene ticket.

### F-S24-1 — State the post-catalog sequence once (`LibrarySweepJob`)
**DEMOTE (disagrees with the coordinator's "Both land").** Its correctness motivation is the one
F-S07-1 removes:
- after positional claims, a file under `Projects/<x>` keys to a claimed folder before intake moves
  it (`owner_key`, model_intake.rb:255-269, with `Projects` a shelf), so discover → file → catalogue
  order on chunk_remote changes only latency. The coordinator's own §5 note says so;
- `chain_intake` already runs intake after a productive discovery (project_discovery_job.rb:80-87).

What remains is consolidating three recurring entries and four one-line gates. To do it, the
proposal must add a shared concurrency `group:` between `ProjectIntakeJob` and the new job, because
an inline intake bypasses `ProjectIntakeJob`'s own semaphore (the finding's "CONCURRENCY CORNER").
The finding rates that coupling "medium ... only a live worker proves".

That relocates complexity into a subtler place. Record it as a §4 note in case chunk_remote filing
latency is reported.

### F-S24-2 — Retire the Solid Cable database
**DEMOTE.** The wiring is there:
- production `adapter: solid_cable` in config/cable.yml;
- a cable role in config/database.yml (:116-119, :132-135);
- `gem "solid_cable"` (Gemfile:50);
- the nightly backup (ops/backup-db.sh:229);
- INSTALL.md:383, "The derived databases must exist".

Nothing broadcasts: §14e (CLAUDE.md:1028) and `mount_path = nil` (application.rb:57). Removing an
unused database is operational housekeeping (one fewer database for a Postgres installer, one fewer
backup) with no change to code structure. The finding calls it "housekeeping-grade". Ticket.

### F-S25-1 — One secret-site walk and one destination list
**KEEP (T1).** `secret_key_names` in bin/secrets-preflight:73-119 and in
test/deploy_hygiene_test.rb:653-688 is the same walk, and each copy says "widen both together". The
mutation-checked oracle exercises only the test's copy, and no test runs the preflight.

So the copy that actually gates a deploy can lose an arm with bin/ci still green. That is the silent
empty-secret failure deploy-secrets.md:10 exists to prevent. One module required by both removes the
duplicate and closes the guard gap. The walk stays static and vault-free. Keep `kamal` lazily
required, because Zeitwerk eager-loads lib/tinkerex in production.

### F-S25-2 — One backup-destination table
**KEEP (T2).** The set `{chunk, share, s3, sync}` is enumerated in the argument case, the `PING_*`
whitelist, `container_for` and `volume_for` (ops/backup-db.sh:40, :106-112, :189-214), and again in
bin/restore-db:51-60. The script names the price itself: "Nothing catches a missing arm ... `sync`
shipped in exactly that state" (:98-105).

One table, read by all four sites and by restore-db, removes five enumerations, including the
high-stakes volume mapping for a restore. It must keep backup-restore.md's rules: ping.env is parsed,
never sourced (:14), and the argument guards exit before any ping (:40).

### F-S26-1 — `bin/ci` compares the three legs' run counts
**KEEP (T1).** Today no one compares the counts:
- CLAUDE.md:1272-1276 says `bin/ci` "PRINTS the three counts and never COMPARES them";
- config/ci.rb runs the gates and nothing after them (:276), and tees only the chunk_remote leg
  (:209, :212);
- the close-out command that actually loads, .claude/commands/finish-branch.md:28-29, names a
  non-existent `test-share`, omits `test-chunk-remote`, and asks for identical "run/assertion"
  counts. Assertion counts always differ between legs.

A small parser and one comparison give the repo's stated definition of green a single owner, and
remove a human step restated in four documents. It adds code (a gate), and that is justified.
Compare run counts only.

### F-S26-2 — Gate jobs carry runner plumbing only
**KEEP (T3).** ci.yml sets `RAILS_ENV: test` on four gate jobs (:222, :235, :252, :280) and runs two
`ci/ensure-resvg.sh` pre-steps (:219, :232). config/ci.rb has neither, against CLAUDE.md §13's
"config/ci.rb is the single definition".

The live effect is narrow. Locally, `db:test:prepare` boots development and runs the boot guard (the
initializer skips only `Rails.env.test?`); in CI it does not. Still, it is a duplicated gate
definition, and the allowlist test follows the `LOCAL_ONLY_GATES` "exception as data" precedent.
Decide the direction with one measured CI run, land it with F-S26-1, and leave the resvg steps to
F-S29-2.

### F-S28-1 — Retire `bin/migrate-record`
**KEEP (T2).** The script calls itself a "ONE-TIME MIGRATION TOOL ... Deleted once the cutover is
verified" (bin/migrate-record:4). It has a `Net::HTTP::Delete` arm and `delete_project` (:73, :451).
git grep finds no reference outside its plan.

It contradicts CLAUDE.md §11/§13: write the record "with `bin/log` and nothing else" (:298, :369).
Pure removal.

### F-S28-2 — Each `bin/log` write phase names its own unfiled record
**KEEP (T2).** The payload is attached in the wrong place:
- `api`'s re-wrap claims to attach the payload "at the ONE raise site" (bin/log:87-92, :176-185);
- but a write verb's first call is a read, so per-verb rescues fill the payload in (:403-411,
  :556-563);
- `close` has no such rescue (:587-603). A failed PUT spools `{"status":"done"}` under an opaque task
  path, with no issue number.

Two nullable fields filled from different places (`payload`, `path`, :93-100) become one `Unfiled`
record set by a phase helper. That removes four rescues and the re-wrap; exit codes 3/4/5 are
unchanged. The defect class has recurred four times.

### F-S29-1 — Make `render.mjs`'s exit-code wire true
**DEMOTE.** Exit 3 cannot fire for "not a Gerber". `read` throws inside the top-level `await` and
escapes as node's exit 1 (render.mjs:54-58). The bundle throws "File type not recognized"
(tracespace.mjs). Ruby maps every code except 4 to `RenderError` (gerber.rb:91), so today's Ruby
behaviour is identical for 1 and 3.

The change makes the declared wire true and the stored error readable. It is a contract fix in a tool
script (one unreachable arm out, one catch in), not a simplification. Ticket.

### F-S29-2 — One locked resvg declaration per image; retire `ci/ensure-resvg.sh`
**NARROW (T2).** resvg is pinned three times, none with `--locked` (Dockerfile:107;
ci/runner/Dockerfile:162; ci/ensure-resvg.sh:24). Yet ci/runner/Dockerfile:175-181 records
"`--locked` IS NOT OPTIONAL" for stl-thumbnailer, and its claim that the two pins "cannot disagree"
(:141-142) is checked by nothing.

Narrower scope:
- add `--locked` to both resvg installs;
- add one hygiene assertion that the two pins are equal and locked, over a non-empty set;
- delete the no-op script and its two workflow steps.

The CI-only presence gate is a separate guard. It would encode the known renderer-parity gap (it must
name Mesh as absent, because F3D is not in the CI image), so decide it together with the S26
renderer-parity defect.

### F-S27-1 — The harness owns the `FileLayer.current` memo's per-test lifetime
**KEEP (T2).** The shared teardown resets the memo only behind `@file_layer_backend_pinned` or
`@fresh_share_library_roots` (test_helper.rb:243-256). Meanwhile 90 direct `FileLayer.current =`
assignments in 45 files depend on their own resets (158 `FileLayer.reset!` calls, by grep). The six
`pin_file_layer_backend` calls (model_intake_job_test.rb:13, :42; project_discovery_job_test.rb:17,
:37, :54, :93) are each superseded by the line after them.

One unconditional reset removes a convention kept by hand at about 90 sites, two flags and a helper.
Net removal, harness-only. Run counts rise identically on all legs.

### F-S27-2 — One verifying web sign-in helper
**NARROW (T2).** `post user_session_path` appears 129 times in 107 files (grep).
`PublicFixture#sign_in_as` checks nothing (public_fixture.rb:100-102). attach_from_files_test.rb's
local `sign_in` (:10-15) does not verify either, so its `count: 0` assertion (:44-49) passes on the
redirect body of a failed sign-in.

The material first step is three things: the verifying helper in test_helper.rb,
`PublicFixture#sign_in_as` delegating to it (13 suites), and the three named vacuous tests. The
~100-file sweep is mechanical churn; do it opportunistically.

### F-S12-1 — One parameter-schema representation per sidecar
**DEMOTE.** Boxes emits `param_groups` plus a lossy flat `params` whose own comment says "Safe to
drop once every app consumes `param_groups`" (sidecar/boxes/app.py:387-391). Openscad returns both
(schema.py:22-26). No first-party bundle reads a top-level schema `params`: a grep of the local
../tinkerex-addons checkout finds only `group.params`/`param_groups` and the saved
`state.data.params` values.

This finishes a recorded back-compat removal (F-62) in sidecar code that bin/ci does not test. It
removes dead data, not a decision the app acts on. Ticket, verified by hand.

### F-S12-2 — One owner for the openscad catalog's static admission policy
**KEEP (T3; guard gap).** The external-reference rule exists only in
sidecar/openscad/tests/test_catalog.py:77-84, and neither config/ci.rb nor ci.yml runs pytest (grep).
So a catalog `.scad` that does `use <>` or `import()` on an outside file passes every gate. The
licence rule lives in three places in two languages (deploy_hygiene_test.rb:491-506 and two Python
copies).

Making the Ruby block (run by bin/ci, driven by `CATALOG_GLOB`) the one owner closes a live gap and
removes duplicated policy. Low priority: catalog additions are rare and vetted.

---

## B. Over-abstraction list

### B1. Proposals that add more abstraction than they remove (the extra is not needed)
| Finding | Adds | Removes | Smaller alternative |
|---|---|---|---|
| F-S04-1 | `NodeState` Data type, 2 constructors | 1 ivar side channel, 1 `\|\|` guess | explicit `version:`/`manifest:` keywords at 2 call sites |
| F-S10-2 | `FilePreview::Viewer` (5-field Data) + `viewer_for` | one duplicated 18-line block, 2 template defaults | one concern method returning the archive/layers/single trio |
| F-S10-1 | `Maker::ContentRead` module + its tests | two ~10-line wrappers | in-place: rescue outside each `fetch`, banner arm, namespace bump |
| F-S21-2 | `REFUSED_BECAUSE` map, `uploaded_files` helper | 2 copied `raise` lines, the `errors` array | one `NotFound` arm + one `rescue_from` + one enqueue helper |
| F-S16-2 | 2 sync hooks (BomLine `before_validation`, InventoryItem `after_update`) + data migration | 1 door rule (the duplicate stays) | derive a stock line's unit from its item (S18's shape) |
| F-S24-1 (DEMOTE) | `LibrarySweepJob` + `STEPS` + a cross-class concurrency `group:` | 2 recurring entries, 3 one-line gates, `chain_intake` (about 110 lines of per-step wrappers move rather than disappear) | none needed once F-S07-1 lands |
| F-S03-2 (DEMOTE) | `ObjectIdentity::BlankEtag` + `for_reported` | 3 guards (2 of them wrong only for a hypothetical store) | rescue the existing refusal at the two sites |
| F-S29-2 (CI presence gate part) | a CI-only test that must list Mesh as deliberately absent | nothing; it encodes a known gap | decide with the S26 renderer-parity defect |

### B2. Adds more than it removes, but justified
- F-S11-1: +1 column. Which save wrote a row is not recoverable any other way.
- F-S02-1: +1 column, +1 partial index, +backfill, +a mandatory equivalence guard. It is the only
  exact answer once a purge has run.
- F-S08-2: +1 status, `IN_FLIGHT`, +2-3 predicates, +a template guard, +a v1 mapping. The lighter
  fixes either break measure-view.md:286-291 or need a migration.
- F-S26-1: +a parser, tee logs and a comparison step. It enforces §15's definition of green.
- F-S09-1 / F-S22-1: +generation and pending (or engine-record) fields. They mirror the Gerber fix
  that was measured and recorded (files-preview.md:277-278).
- F-S23-1: +`NOT_EDGES` and a rule. It turns five prose sites into data.

### B3. Materiality that rests on claims I could not verify at HEAD
- F-S05-1: minute-scale first scans and the 240k semaphore overrun come from an in-memory probe. The
  real library is about 5k rows.
- F-S13-1 / F-S13-2: the I/O savings are estimated from the ~15 ms/object CIFS figure, and the SMB
  race was not reproduced.
- F-S08-2: stale geometry is served only if the worker has not started the job within ~250 ms of the
  first poll. That depends on load and was not run.
- F-S09-1 / F-S22-1: cases (b)-(d) are read from controller and engine code. No test drives Turbo
  Back today, and frequency is unknown.
- F-S14-1 (b): the past-FILE_CAP leak was traced, not reproduced.
- F-S19-1: the cross-tenant disclosure was read through the unscoped association, the preload and the
  view, not probed.
- F-S20-1: the auth card's missing wordmark is inferred from the cascade, not observed.
- F-S03-1 / F-S02-1: traced through FakeS3 and Share semantics, not run against SeaweedFS or a real
  NAS.
- F-S04-1: unreachable until tinkerex-sync schedules `prune_changelog`.
- F-S17-1: needs `DEMO_ACCOUNT_EMAIL` on chunk_remote, which no shipped config sets.
- F-S24-1: the chunk_remote race is reasoned, and the semaphore claim needs a live worker.
- F-S29-2: tiny-skia/usvg drift between image builds is latent and unmeasured.
- F-S11-1: "a save there rewrites the OLD file" is partly inferred.
- F-S07-2: the first-run delete volume on live databases is unmeasured.
- F-S12-1: the search for readers covered only the local, unfetched tinkerex-addons checkout.

---

## C. Defects mis-filed as simplifications
Each of these is first a bug fix or a guard gap. Judge it as one, not as a representation change.
In the "Kind" column:
- **defect-first** means the representation change in the finding is the right fix;
- **pure defect** means the fix needs no representation change;
- **latent** means real code, but not reachable at HEAD.

| Finding | Defect (one sentence) | Kind |
|---|---|---|
| F-S03-1 | On s3, a folder holding an out-of-band-deleted file can never be deleted, a deleted app-made folder comes back under new ids, and a deleted folder cannot be restored. | defect-first (T1) |
| F-S02-1 | On share, deleting and restoring a folder after a same-name replace can 500 mid-restore and orphan attachments; the cascade also lists unrestorable scan tombstones and restarts their reap grace. | defect-first (T1) |
| F-S19-1 | Any device token can make the ledger page show another tenant's project name and slug, and can post non-finite deltas that permanently corrupt an immutable ledger. | defect-first; security (T1) |
| F-S10-1 | One store outage, triggerable by an anonymous visitor, caches "not a board / no manifest" for 30 days, breaking board viewers and 3MF colours and units and misfiling board zips. | pure defect (T1) |
| F-S08-1 | A preview row wedged in pending or processing on current content is never healed by any read door or the backfill rake, despite the documented `STALLED_AFTER` heal. | defect-first (T1) |
| F-S07-1 | Past discovery's 50-folder cap (or on chunk_remote before discovery runs), a `Projects/<x>` folder becomes a permanent auto model as well as a project. | defect-first (T1) |
| F-S08-2 | During a renderer rebuild the Measure endpoints can serve the previous build's geometry, and a lost rebuild is never re-enqueued. | defect-first |
| F-S16-1 | Sorts, column renames and resizes, drags, and undo/redo are never saved while the label reads "Saved". | defect-first |
| F-S16-2 | A stock BOM line created through v1 or the desktop app can carry a different unit from its item, so Qty, Consume, the CSV and the public table disagree. | defect-first |
| F-S21-2 | A reserved name or oversize file in the middle of a selection aborts the batch with "File not found." (500 on the build-log door) after earlier files were written. | pure defect |
| F-S15-1 | The project page backfills thumbnails for tiles it never paints, and never backfills repo images it does paint ("Preview not supported" for good on chunk_remote). | defect-first |
| F-S15-2 | Apply brings back deleted blocks and tabs, YAML export lists them, and Save refuses valid drafts under cap churn or a reused tab name. | defect-first |
| F-S14-1 | The /u/:handle card can show a hidden folder's picture, a hidden file past FILE_CAP can reach the hero, and an outside-folder cover with a ready row shows no hero. | defect-first |
| F-S09-1 | Turbo Back restores a dead Measure view (Reset throws), and a double click runs two loads whose selection disagrees with what is drawn. | defect-first |
| F-S22-1 | Turbo Back restores a dead 3D viewer, and switching models during an import wedges the engine until ✕ Image. | defect-first |
| F-S11-1 | After a revise-under-new-name, "Edit in …" starts in the stale file's folder, the states list mixes in stale files, and stale files carry the current revision label. | defect-first |
| F-S20-1 | Below 1100px the sign-in card, which is the self-host front door, loses its wordmark. | defect-first |
| F-S01-1 | An unknown, typo'd or retired LIBRARY_BACKEND passes both boot guards and then 500s every response. | defect-first |
| F-S17-1 | On chunk_remote with a demo account, the demo door opens but the nightly reset always refuses. | defect-first (config-gated) |
| F-S13-2 | A write between staging and the index refresh makes the index record a blob the commit did not. | defect-first (narrow race) |
| F-S28-2 | `bin/log close` against a failing PUT spools a record with no issue number. | defect-first |
| F-S04-1 | A pruned-gap resync would leave file versions, sizes and manifests stale: new files 404 and changed files serve old bytes. | latent |
| F-S29-1 | "Not a Gerber" exits 1 and leaves a minified stack trace in `maker_previews.error` instead of the declared exit 3. | pure defect |
| F-S05-1 | The first scan of N files is quadratic in N, because the revive lookups cannot use any index. | pure perf defect |
| F-S25-1 | The deploy-gating copy of the secret-site walk has no test, so losing one of its arms ships an empty secret silently. | guard gap (T1) |
| F-S26-1 | Nothing compares the three legs' run counts, and the close-out command gives the wrong instruction. | guard gap (T1) |
| F-S12-2 | The rule against external file references in catalog `.scad` files runs in no gate. | guard gap |
| F-S23-1 | A new `*_id` reference escapes both guards derived from EDGES. | guard gap |
| F-S27-1 | A test's `FileLayer.current` leaks into the next test unless it resets by hand. | guard gap (harness) |
| F-S27-2 | Sign-ins are not verified, and three tests pass with nobody signed in. | guard gap (harness) |
| F-S29-2 | The resvg pins are neither locked nor checked against each other. | guard gap (toolchain) |
| F-S26-2 | A gate's environment differs between local runs and CI. | guard gap (CI config) |

---

## D. Summary

**Counts.** KEEP 33 · NARROW 6 · DEMOTE 9 · REJECT 1.
- NARROW: F-S04-1, F-S10-1, F-S10-2, F-S21-2, F-S27-2, F-S29-2.
- DEMOTE: F-S05-1, F-S03-2, F-S02-2, F-S20-2, F-S23-2, F-S24-1, F-S24-2, F-S29-1, F-S12-1.
- REJECT: F-S07-2.

**Five most material.**
1. **F-S03-1 + F-S02-1, one slice.** Three live data-facing dead ends on the deployed s3 backend, a
   silent attachment-orphaning path on share, and a §14a sentence ("a refusal is recoverable") that is
   false on s3.
2. **F-S19-1.** A cross-tenant disclosure reachable with any device token, plus irreparable ledger
   corruption. Moving validity and scoping into the model fixes both.
3. **F-S10-1.** A 30-day poisoned cache that an anonymous request can trigger. It degrades viewers,
   measurement units and filing. The fix is small and needs no new type.
4. **F-S25-1.** The copy of the secret-site walk that gates every deploy is untested.
5. **F-S08-1.** The only verifier of in-flight preview rows is unreachable from the doors that render
   them, and wedged rows have been observed in production.

Close behind: F-S07-1 (a deterministic cap hole on any first scan with more than 50 project folders)
and F-S26-1 (the repo's own definition of green).

**Five weakest.**
1. **F-S07-2 (REJECT).** It reverses model-intake.md:177-192. Its evidence argues for reopening the
   rule, not for the audit to reverse it.
2. **F-S02-2.** Unreachable at HEAD behind FOLDERS_NOT_YET, and the code already records the coupling
   at both ends.
3. **F-S03-2.** It needs a store with blank COPY/HEAD ETags but real LIST ETags, and its mtime half
   heals itself at the next scan.
4. **F-S24-1.** Its correctness motivation goes away once F-S07-1 lands, and the replacement adds a
   cross-job semaphore coupling.
5. **F-S20-2.** Copy drift on the Help page, which the file itself already asks to fix.

F-S05-1, F-S23-2, F-S24-2, F-S29-1 and F-S12-1 are also DEMOTE: perf, housekeeping, or contract
tickets.

**Patterns.**
- **Second-slot fill.** Five of the nine DEMOTEs are a reviewer's Opportunity 2 (F-S03-2, F-S02-2,
  F-S20-2, F-S23-2, F-S24-2). The infrastructure rows (S12, S23, S24, S29) produced most of the
  housekeeping-grade items. The "at most two" cap seems to have drawn a second, weaker entry where a
  single one or a skip would have done.
- **Recorded-TODO restatements.** F-S20-2, F-S12-1 and F-S02-2 restate a change the code already
  schedules ("render that partial in place of...", "Safe to drop once...", "lift it with that port
  change"). They are cheap but are not discoveries. F-S28-1 survives as KEEP only because the dead
  script still carries destructive verbs against the canonical record.
- **A named type around a small fix.** Every NARROW except the two harness and toolchain items wraps a
  defect fix in a new type, door or map (NodeState, ContentRead, Viewer, REFUSED_BECAUSE) the fix does
  not need; F-S16-2's sync hooks and F-S24-1's sweep job are the same shape at larger size. No single
  worker over-abstracts systematically: S10's report rejects six abstractions before proposing its
  two. The reflex appears across S04, S10, S21 and S24.
- **The strong findings are defect-led.** About 22 of the 33 KEEPs rest on a concrete, reachable
  defect where the representation change is the fix. The purely preventive KEEPs (F-S05-2, F-S06-1,
  F-S13-2, F-S23-1, F-S26-2, F-S12-2, F-S18-1) are all T3.

---

## What I could not check
- I executed nothing: no tests, bin/ci, rails, rake, EXPLAIN, sqlite3, node, cargo or browser.
  Behavioural consequences are read from code, not observed.
- Live data: the would-delete set for F-S07-2, the backfill rows for F-S02-1, any populated
  `version_id` values for F-S23-2, the size of the real library for F-S05-1.
- Browser rendering and timing for F-S20-1, F-S09-1, F-S22-1 and F-S16-1, and queue load for F-S08-2's
  window.
- Real S3 or SeaweedFS behaviour for F-S03-1 and F-S03-2 (ETag shapes, `CopyObjectResult.LastModified`,
  marker handling).
- CIFS I/O cost for F-S13-1 and F-S13-2, and scan timings for F-S05-1.
- The resvg crate's packaged `Cargo.lock` and its effect on PNG bytes (F-S29-2).
- GitHub Actions run history for F-S26-1 and F-S26-2.
- Sibling repos were read from local checkouts as they stand, without a fetch, so the reader searches
  for F-S12-1 and the wire claims for F-S04-1 and F-S16-2 may be behind origin.
- I did not re-verify every test line each finding's validation plan names; that is the schema
  pass's job. I checked only the lines that bore on materiality.
