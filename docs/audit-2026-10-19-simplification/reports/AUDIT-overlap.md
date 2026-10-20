# AUDIT-overlap — duplication and ownership-overlap pass (audit-the-audit)

Repository: `/Users/charlesschwartz/Desktop/repos/tinkerex` at `75124d67` (`git status`: only the pre-existing
`?? app/assets/images/landing/library.jpg`). Read-only throughout; nothing under the repo was written or executed.
This file is the only file this pass wrote.

Inputs: AUDIT.md as it stood at 16:37 (822 lines: §1 now carries S32–S35 and the coverage tie-breaks at AUDIT:229-232;
§2, §4 and §5 have the same lengths as the 793-line version this pass started from, and the spot-checked lines are unchanged),
BRIEF.md, AUDIT-PASS-BRIEF.md, the "Cross-subsystem notes" of all 29 worker reports, and report body text wherever a pair
needed it (S02, S03, S06, S07, S13, S14, S18, S22, S23, S24). I did not read the other audit-pass reports (independence).

Citation keys: `AUDIT:N` is AUDIT.md line N (header lines of the F-entries: F-S04-1 237, F-S01-1 247, F-S11-1 256,
F-S10-1 265, F-S10-2 274, F-S15-1 283, F-S15-2 292, F-S05-1 301, F-S05-2 310, F-S06-1 319, F-S08-1 328, F-S08-2 337,
F-S03-1 346, F-S03-2 355, F-S09-1 364, F-S02-1 373, F-S02-2 382, F-S14-1 391, F-S13-1 400, F-S13-2 409, F-S16-1 418,
F-S16-2 427, F-S19-1 436, F-S20-1 445, F-S20-2 454, F-X-1 463, F-S17-1 472, F-S07-1 481, F-S07-2 490, F-S21-1 499,
F-S21-2 508, F-S18-1 517, F-S22-1 526, F-S23-1 535, F-S23-2 544, F-S24-1 553, F-S24-2 563, F-S25-1 571, F-S25-2 580,
F-S26-1 589, F-S26-2 598, F-S28-1 607, F-S28-2 616, F-S29-1 625, F-S29-2 634, F-S27-1 643, F-S27-2 652, F-S12-1 661,
F-S12-2 670). `S07.md:N` is reports/S07.md line N. Bare paths are repo files at HEAD.

---

## 0. Results in brief

1. **One collision §5 misses (CONFLICTS).** F-S24-1's validation (a) ports DiscoveryOrderTest's *swallow* assertion
   (S24.md:139). F-S07-1 lands first by the recorded order, and it makes that assertion independent of job order. So (a)
   becomes a guard that cannot fail (CLAUDE.md §15). The order is still observable through the test's latency assertion
   (`scan_job_test.rb:680-682`), which is where the mutation must be shown red. See M1.
2. **§5's F-S02-1/F-S03-1 supersession covers half the collision.** It covers undelete membership. F-S03-1's report also keeps
   `Subtree.node_ids` as the S3 cascade's tombstone set (S03.md:94), while F-S02-1 narrows that same `update_all` to live rows
   (S02.md:63). This is the same root-cause defect. §5's "one slice" can also be two consistent slices. See M2 and E2.
3. **§5 misstates S03's rejection.** S03 rejected the `trash_root_id` column *by name* (S03.md:205), not only a "kind"
   column. Its argument (the entry location is derivable) does not reach membership, so F-S02-1 still stands. The record
   should say so (E3).
4. **Shared constraint: CLAUDE.md is exactly at its ceiling.** It has 1,360 lines, and `MAX_LINES = 1_360`
   (`test/docs_hygiene_test.rb:71`). Six F-entries edit it, and a seventh should (F-S10-1, §14d). No entry states the
   constraint (M14).
5. **Seven ordering pairs have no recorded dependency:** F-S21-1→F-S21-2, F-S03-2→F-S03-1, F-S23-1→F-S23-2, F-S04-1→F-S24-1,
   F-S29-2 step (1) before F-S26-2's resvg-step removal, F-S27-1↔F-S24-1, and F-S08-2 before F-S23-2's preview half.
6. **Ownership.** There are two candidate misassignments by file ownership:
   - F-S24-1: S24 owns 1 of the 7 code/config files.
   - F-S29-2: S29 owns 1 of the 5 files.

   In addition, 22 entries reach into another row's files without naming that row, and no row owns *edits* to
   `docs/invariants/*.md`. Fourteen entries edit those files; two of them overlap in line ranges.
7. **Cross-subsystem notes.** Six genuine items were not carried:
   - CLAUDE.md §6's endpoint count;
   - CLAUDE.md §14d's setter list;
   - the premise at `subtree.rb:17-18`;
   - a stale helper comment in `library_broadcast_test.rb`;
   - the importer's lost "skipped N" message;
   - a stale cap/order comment in `project_intake.rb`.

   Two §4 hand-offs went to recipients that were dispatched or harvested before the note existed: S05→S03 (the S3 listing
   race) and S09→S08 (geometry for any extension).

---

## 1. Overlap matrix

### 1a. Pairs that need an edit to AUDIT.md

| # | Pair | Class | Shared files / mechanism | Evidence | Recommended resolution |
|---|---|---|---|---|---|
| M1 | F-S07-1 × F-S24-1 | **CONFLICTS** (F-S24-1's validation (a) as written; the changes themselves complement) | DiscoveryOrderTest `test/jobs/library/scan_job_test.rb:594-688`; F-S07-1's prose edits `scan_job.rb:239-249,320-333` sit inside F-S24-1's rewrite of `:96-98,239-349`; `recurring.yml:162-166` inside `:75-194`; `project-intake.md:134-146` vs `:141-146`; `model-intake.md:88-98,205-211` vs `:91-93,205-211` (AUDIT:485, :558) | F-S24-1 (a) (AUDIT:560) ports "DiscoveryOrderTest's model-role case" with "mutation: move ModelIntakeJob first in STEPS → red". The report pins the assertion: "Assert no model has `auto_node_id` or `folder_node_id` equal to the folder" (S24.md:139), i.e. `scan_job_test.rb:673` `assert_nil swallowed`. F-S07-1 is recorded to land first (AUDIT:561 "Dependency: after F-S07-1"). It claims every adoptable `Projects/<x>` positionally, and says itself that "ordering mutations can no longer" fail that assertion (AUDIT:487). The latency assertion still discriminates: `:680-682` checks `models/bracket.stl` and `["bracket"]`. With the catalogue first, a claimed folder's loose file gets no model in that run (`[]`). With intake before discovery, nothing is filed. The original test also seeds files ON DISK ONLY (`:602`) and relies on ScanJob's reconcile. A bare `LibrarySweepJob.perform_now` port therefore has no node rows to discover. | Keep the order F-S07-1 → F-S24-1. Rewrite F-S24-1 (a): seed node rows, assert the swallow AND the latency outcome, and show both mutations red on the latency assertion. F-S07-1 limits its `scan_job.rb`/`recurring.yml`/invariants-doc edits to the truth fix; F-S24-1 rewrites those paragraphs (E1). |
| M2 | F-S02-1 × F-S03-1 | **CONFLICTS** (as written in the reports; §5 resolves membership only) | `app/services/file_layer/s3.rb#delete_directory!` (`:528-575`, the `update_all` at `:568-569`) and `#undelete` (`:704-786`) | S03.md:94: "A directory delete of the root keeps using `Subtree.node_ids` for the tombstone set". `Subtree.node_ids` includes tombstones by design (`subtree.rb:17-18`), so scan tombstones become trash tombstones on S3, as in F-S02-1 (a)/(c). S02.md:63: "`delete_directory!` (`:531-532` and `:568` — live rows only)". Membership: S03.md:88 ("revives only if its object came back…") vs F-S02-1's `where(trash_root_node_id: root)`. §5 (AUDIT:779) supersedes only the membership half. | Extend the supersession to the tombstone set. Replace "one slice" with two consistent slices: (A) no migration, (B) the column plus the S3 folder restore. Add F-S03-2 as a predecessor (E2). |
| M3 | F-S23-1 × F-S23-2 | **COMPLEMENTS** (F-S23-1 first) | `test/schema_map_test.rb:87-100` (F-S23-1 "retire or keep", AUDIT:539; F-S23-2 "narrow", AUDIT:548); the `lib/schema_map.rb:122-139` prose that becomes the NOT_EDGES entry `maker_file_attachments.version_id`; the CLAUDE.md §5 paragraph (`CLAUDE.md:149-151`, edited by both); regeneration of `docs/schema-map.html` | F-S23-2 says "NOT_EDGES shrinks to three" (AUDIT:547), which presupposes F-S23-1. F-S23-1's "NOT_EDGES names X, which does not exist" rule (AUDIT:538) will itself force F-S23-2's release 2 to delete that entry. | F-S23-1 first; F-S23-2 release 2 then deletes the NOT_EDGES entry rather than narrowing a retired test (E6). |
| M4 | F-S21-1 × F-S21-2 | **COMPLEMENTS** (F-S21-1 first) | `app/controllers/projects/uploads_controller.rb`: `#create` (`:47-100`), demo cap (`:38`), `rescue_from` block (`:30-37`), `#enqueue_preview` (`:142`); `upload_batch.rb` header; `demo_guards_test.rb` (F-S21-1 deletes `:252-255`; F-S21-2 validates `:202-262`) | Scopes at AUDIT:503 and :512; neither entry has a dependency line | F-S21-1 collapses the controller to its one target; F-S21-2 then gives that door the refusal table and the `NotFound` arm (E4). |
| M5 | F-S03-2 × F-S03-1 | **COMPLEMENTS** (F-S03-2 first) | `s3.rb#restored_stat` (`:999-1006`), reached after each copy-back; `test/support/fake_s3.rb` | F-S03-2: a blank ETag "makes `undelete` strand a restored object behind a trashed row" (AUDIT:357). F-S03-1 step 2 turns `undelete` into a loop over a folder's members. | Land F-S03-2 first, so the folder restore inherits a total blank-ETag rule (E5). |
| M6 | F-S04-1 × F-S24-1 | **COMPLEMENTS** (F-S04-1 first) | ChangelogSync's nudge: collected in `apply_page` (`changelog_sync.rb:178-195`), sent once per pull (`:121-124`), deliberately not fed by `full_resync` (`:58-59`); `ProjectIntakeJob.nudge_parents` (`project_intake_job.rb:107-112`) | F-S04-1 Risks (d): "the nudge fed by `apply_page` ONLY" (AUDIT:243). F-S24-1 puts `ProjectIntakeJob` in a shared `group:`. Its only remaining `perform_later` is that nudge. F-S24-1 also optionally replaces the nudge with a sweep enqueue from ChangelogSync (AUDIT:557; S24.md:116). | F-S04-1 first. If F-S24-1's optional step is taken, it hooks the same once-per-pull point and states its stance on `full_resync` (E8). |
| M7 | F-S26-2 × F-S29-2 | **COMPLEMENTS** (fixed order; one sub-step listed twice) | `.github/workflows/ci.yml:217-218,230-231` (the two `ci/ensure-resvg.sh` steps); `test/ci_hygiene_test.rb` | F-S26-2 scope: "−two `ensure-resvg` steps" (AUDIT:602). F-S29-2 scope (4) still reads "delete the script and `ci.yml:218-219,231-232`" (AUDIT:638), though §5 (AUDIT:793) and the tie-break (AUDIT:231) give the steps to F-S26-2. F-S29-2 (1) says "the CI-only presence test — land first". F-S26-2's own Risk: without the step "a future image that lost resvg writes no step-summary warning" (AUDIT:603). | Remove the `ci.yml` lines from F-S29-2 (4). F-S26-2's resvg-step removal lands with or after F-S29-2 (1) (E9). |
| M8 | F-S08-2 × F-S23-2 | **COMPLEMENTS** (F-S08-2 before F-S23-2's preview half) | `app/models/maker/preview.rb` (F-S23-2 deletes `scope :ready` at `:30`; F-S08-2 adds `IN_FLIGHT`/`showable?`/`current_build?` and changes what `ready` means); `index_maker_previews_on_user_id_and_status` (`db/schema.rb:318`) | F-S23-2 Risks: "F-S08-1/2 add no per-user status query (recheck at implementation)" (AUDIT:549). **Lineage F-S23-2 omits:** the 2026-08-19 audit carried this index as a fold-in to F-39, gated on F-14 (`docs/AUDIT-2026-08-19.md:56,1006,1638`). F-14 has since landed (`bd28c77b`, verified with `git log -S LbrnBackfill`). | Move the `ready`-scope deletion into F-S08-2's model step. Drop the status index after F-S08-1/2 (E6, E7). |
| M9 | F-S27-1 × F-S24-1 | **COMPLEMENTS** (F-S27-1 first, or re-point) | The six `pin_file_layer_backend` calls F-S27-1 removes are `model_intake_job_test.rb:13,42` and `project_discovery_job_test.rb:17,37,54,93`. F-S24-1 moves the gate pairs and deletes the chain tests (S24.md:137), i.e. the tests at `model_intake_job_test.rb:12` and `project_discovery_job_test.rb:16,92` | F-S27-1's mutation target, "the scheduled fan-out declines on a scannable backend" (AUDIT:649), is a test F-S24-1 moves to `LibrarySweepJob` | Land F-S27-1 first, or re-point its mutation if F-S24-1 lands first (E10). |
| M10 | F-S09-1 × F-S22-1 | **COMPLEMENTS** | The Turbo-Back system-test helper in `test/system/support/web_helpers.rb` (S27's file); the rest-on-connect mechanism | F-S22-1 names the helper (AUDIT:530). F-S09-1's validation (2) (AUDIT:370) describes the same recipe without it. §5 (AUDIT:788) records one helper. | F-S09-1 uses the shared helper; whichever entry lands first creates it (E11). |
| M11 | F-S02-1 × F-S23-1 | **COMPLEMENTS** (either order) | `SchemaMap::EDGES`: `nodes.trash_root_node_id → nodes.node_id` | F-S23-1: "F-S02-1's new column would pass every guard undrawn today" (AUDIT:537). S23 verdict item (3) on F-S02-1 (AUDIT:377). | Note in F-S02-1 that F-S23-1's rule enforces the EDGES line once landed. |
| M12 | F-S01-1 × F-S17-1 | **COMPLEMENTS** (F-S17-1's optional `Demo.validate!` after F-S01-1), with a caution | The resolved backend NAME; `Registration::SINGLE_LIBRARY_BACKENDS` (`lib/tinkerex/registration.rb:24`); DemoReset's port arm (`lib/tinkerex/demo_reset.rb:74-78`) | F-S17-1 lists the follow-on (AUDIT:476). §4 (AUDIT:742) proposes "one declaration beside S01's reading could serve both". The two lists coincide on {share, s3} for DIFFERENT facts: the reset "rebuilds the library through the port's byte write and empties its trash" (`demo_reset.rb:75-77`); registration refuses because "every account indexes the same library" (`registration.rb:47-50`). CLAUDE.md §14b: "Agreement across three samples is not identity". F-S17-1's own complaint (AUDIT:474) is exactly such a stand-in. | Keep two declarations, both fed the one resolved name. Amend the §4 note (E16). |
| M13 | F-S01-1 × F-S26-2 | **COMPLEMENTS** | The boot guard's only dynamic exercise: `config/initializers/library_backend_check.rb` skips `unless Rails.env.test?`. F-S26-2 records that only LOCAL `bin/ci` boots development (AUDIT:599), and its conservative option adds `RAILS_ENV=test` locally. | AUDIT:599-602; F-S01-1 validation, "a static initializer-wiring pin" (AUDIT:253) | If F-S26-2's conservative option lands, F-S01-1's static pin becomes the ONLY guard of the initializer. Say so in F-S01-1 (E27). |
| M14 | CLAUDE.md editors: F-S01-1, F-X-1, F-S23-1 (opt.), F-S23-2, F-S24-2, F-S26-1, plus F-S10-1 (A2) | **COMPLEMENTS** (shared constraint) | CLAUDE.md has 1,360 lines; `MAX_LINES = 1_360` (`test/docs_hygiene_test.rb:71`, S26's file). The ratchet comment (`:32-70`) lowers the constant in the commit that shrinks the file, and "a ratchet banks nothing". Bullets edited: §14a `CLAUDE.md:641`, `:651` (F-S01-1) and `:489` (F-X-1); §5 `:149` (F-S23-1/2); §4 `:112` and §14e `:1028` (F-S24-2); §15 `:1272` and §13 (F-S26-1); §14d `:938` (F-S10-1, A2) | `wc -l CLAUDE.md` = 1360; `docs_hygiene_test.rb:71-77` | One §6 sentence (E13). |
| M15 | Harness-first: F-S27-1 and F-S27-2 × every entry adding integration tests that assign `FileLayer.current =` or sign in (F-S01-1, F-S10-2, F-S14-1, F-S15-1, F-S15-2, F-S16-2, F-S17-1, F-S18-1, F-S19-1, F-S21-1, F-S21-2, …) | **COMPLEMENTS** (order) | `test/test_helper.rb` teardown; `post user_session_path` (129 sites, AUDIT:653) | Each new test written before F-S27-1/F-S27-2 adds to the hand-reset and unverified sign-in counts those entries exist to retire | Land F-S27-1 and F-S27-2's first step (two files) early (E26). |
| M16 | Recorded orders, re-checked: F-S05-1 → F-S05-2 (`reconciler.rb` `ensure_dirs` `:595-609`); F-S07-1 → F-S07-2 (`model_intake.rb`); F-S08-1 → F-S08-2 (`enqueue.rb`, `files_controller.rb#geometry`, `measure-view.md:320-333` vs `:278-291`); F-S26-1 with F-S26-2 (the same `config/ci.rb` commands: tee form vs `RAILS_ENV=test`) | **COMPLEMENTS** (already recorded) | Dependency lines at AUDIT:317, :497, :344, :594/:605 | Confirmed. F-S26-1's optional `legs-agree` job needs artifact upload/download steps, which F-S26-2's contract already allows ("cache/artifact `uses:` steps", AUDIT:601). | None. |

No pair is a whole-entry DUPLICATE or SUBSUMES. The only duplicated sub-step (the `ci.yml` resvg steps) is handled in M7.

### 1b. Apparent overlaps that are INDEPENDENT

| # | Pair / group | Shared file | Why independent (evidence) |
|---|---|---|---|
| I1 | F-S08-1, F-S08-2, F-S10-2, F-S21-2, F-X-1, F-S02-2's follow-on | `app/controllers/files_controller.rb` | The actions are disjoint: `#current_thumbnail`/`#geometry`; `#thumbnails`/`#geometry`; `#show`; `#create`/`#finalize_upload`/`#enqueue_preview`/`#refuse_oversized_demo_upload!`; `#begin_upload` (`:922-925`); FOLDERS_NOT_YET (`:1013-1022`). Only F-S08-1 and F-S08-2 share `#geometry` (M16). |
| I2 | F-S10-2, F-S08-1, F-S08-2 | `app/controllers/public/files_controller.rb` | F-S10-2 edits `#view` (`:41-75`), including the caller `enqueue_geometry(owner) if @kind == :measure` (`:74`). F-S08-1 edits the `#enqueue_geometry` body (`:158-163`), F-S08-2 edits `#preview` (`:90-109`). F-S10-2 changes only the caller's condition. |
| I3 | F-S10-2 × F-S08-2 (optional) | `app/views/files/show.html.erb` | Lines `:109-182` vs `:188`. |
| I4 | F-S10-1, F-S10-2, F-S22-1 | `docs/invariants/files-preview.md` | Disjoint lines: `:171,:518`; `:191,:200`; `:541-545`. |
| I5 | F-S10-1 × F-S10-2 | the readers' entry points | F-S10-1 keeps `GerberArchive.for`/`ThreeMfManifest.for` ("Call sites unchanged", AUDIT:269), and `viewer_for` calls them either way. F-S10-2's dependency line (AUDIT:281, "land F-S10-1 first so the shared door is what `viewer_for` calls") states a preference, not a code dependency (E12). |
| I6 | F-S02-1 × F-S02-2 | `app/services/file_layer/share.rb` | F-S02-2 rewrites only rows that still carry the old prefix (AUDIT:385); trash tombstones have NULL paths. The pair becomes COMPLEMENTS (F-S02-1 first) only if F-S02-2's alternative is chosen ("one path-rebuild walk used by both `move` and `undelete`"), because F-S02-1 redefines `revive_subtree!`'s candidate set. F-X-1 touches only the `begin_upload` signature in this file. |
| I7 | F-X-1 × F-S02-1, F-S03-1, F-S03-2; F-S03-2 × F-S02-1 | `app/services/file_layer/s3.rb` | Disjoint methods: `begin_upload` `:395`; delete/undelete; move/`restored_stat`/`store_identity`. |
| I8 | F-S05-1, F-S02-1, F-S23-2 | `nodes` indexes, `db/schema.rb` | F-S23-2's release 2 `remove_column` rebuilds `nodes` on SQLite. activerecord 8.1.3.1's `copy_table_indexes` re-adds `where:` (`…/sqlite3_adapter.rb:702`), so both partial predicates survive. After F-S23-2 drops `(user_id, updated_seq)`, `index_nodes_on_user_id` is still a strict prefix of three non-partial composites (`schema.rb` nodes block), so its `PREFIX_INDEX_EXEMPTIONS` entry stays live. One side claim moves: F-S05-1 says its index would serve `trashed` (§4 S05 bullet). If F-S02-1's `trashed` reads the new column, F-S02-1's index serves it instead (both are plan claims only). |
| I9 | F-S11-1, F-S16-2 (data), F-S23-2, F-S24-2 (`db/cable_schema.rb`), F-S19-1 (optional census) | `db/migrate`, `db/schema.rb` | Separate migration files; one schema dump per landing. |
| I10 | F-S24-2 × F-S23-1/F-S23-2 × F-S02-1 | `lib/schema_map.rb`, `docs/schema-map.html` | Different sections: SOURCES/LAYOUT for cable vs NOT_EDGES/EDGES. The last lander regenerates the page, as `schema_map_test`'s stale-page test requires. |
| I11 | F-S11-1, F-X-1, F-S21-2 | `app/services/maker/addons/library_output.rb` | Disjoint: `#upsert_file!` `:113`; `:193-194,:210` and `#addon_device` `:216`; F-S21-2 only *calls* `enqueue_preview` (`:226`). That method is already public as `LibraryOutput.enqueue_preview` via `module_function` (`:27`). |
| I12 | F-S16-2 × F-S19-1 | `app/controllers/projects/bom_lines_controller.rb` | Disjoint actions: `#create` `:37-42` vs `#consume` `:77-88`. `apply!` is `inventory_transaction.rb:38`, not `inventory_item.rb` (F-S16-2's hook file). |
| I13 | F-S25-1 × F-S12-2 | `test/deploy_hygiene_test.rb` | Disjoint: `:623-731` vs the catalog block, which reuses `CATALOG_GLOB` (`:491`). |
| I14 | F-S25-2 × F-S24-2 (optional) | `ops/backup-db.sh` | Disjoint: the arg guard `:40`, ping list `:109-112`, `container_for` `:191` and `volume_for` `:208-216`, vs the WORKER heredoc's database loop at `:229`. |
| I15 | F-S27-1 × F-S27-2 × F-S26-1 (reporter alternative) | `test/test_helper.rb` | Disjoint: teardown vs a new helper vs a reporter hook. |
| I16 | F-S12-1 × F-S12-2 | `sidecar/openscad/tests/{test_catalog,test_api}.py`, `README.md` | F-S12-1 re-points `test_catalog.py:93`, which is inside `test_every_entry_exposes_parameters` and is KEPT by F-S12-2 (AUDIT:673). It also re-points `test_api.py:95-107`, while F-S12-2 deletes `:37-53` and the duplicated catalog tests. The later lander updates the README's pytest counts. |
| I17 | F-S06-1 × F-S23-2; F-S06-1 × F-S10-1's optional end-to-end test | `app/services/maker/project_intake.rb` | F-S23-2 edits only the comment at `:566-568`. If both land, F-S10-1's board-zip test should assert through F-S06-1's `Filing`. |
| I18 | F-S06-1 × F-S21-1 × F-S21-2 × F-S11-1 | `ProjectFolderIntake` (included by FilesController, Projects::ScansController, Projects::UploadsController, Tools::BaseController — grep) | F-S06-1 keeps the concern's interface (`#left_unfiled_by_conflict?` `:111`, `#conflict_folder` `:203`). F-S21-1 edits only the header. |
| I19 | F-S06-1 × F-S21-1 | `docs/invariants/project-intake.md` | Disjoint: `:383-393` vs `:69-75,:497-503`. Only M1's pair overlaps in this file. |
| I20 | F-S07-2 × F-S24-1 | `app/jobs/maker/model_intake_job.rb` | F-S07-2 changes the log, F-S24-1 removes `sweep_all!`. Order is already implied: F-S07-1 → F-S07-2, and F-S07-1 → F-S24-1. |
| I21 | F-S14-1 × F-S15-1 × F-S08-1 | "what a page paints" → `ThumbnailMap` | Different files. F-S15-1 deletes `ProjectFolderListing#repo_subtree_ids`, whose only caller is `projects_controller.rb:404`; `public_project.rb` does not call it (grep). |
| I22 | F-S08-2 × F-S22-1 × F-S09-1 × F-S10-2 | viewer partials | F-S08-2 edits the status predicate at `viewers/_model3d.html.erb:39`, `_measure.html.erb:170`, `_gerber.html.erb:63`, `_static.html.erb:18`. F-S22-1 and F-S09-1 change controllers only ("no markup/CSS change"). F-S10-2 keeps "every viewer partial's strict locals". |
| I23 | F-S18-1 × F-S01-1 | the `ArgumentError` producer | `UnknownBackend < ArgumentError` keeps F-S18-1's test vehicle valid (`LIBRARY_BACKEND=bogus` + `reset!`) in either order. |
| I24 | F-S18-1 × F-S19-1 | `V1::BaseController` | F-S19-1 relies on RecordInvalid → 422, which F-S18-1 keeps. Not checked: whether any of F-S19-1's five inputs reaches an `ArgumentError` on the v1 path. F-S18-1 would turn such a 422 into a 500, so run F-S19-1 (b) after F-S18-1. |
| I25 | F-S06-1 × F-S24-1 | `ProjectIntake::Result` readers | F-S06-1 keeps `moved`/`skipped`/`skips`/`plan` as derived readers. ScanJob's step wrappers and the job log read them. |
| I26 | F-S11-1 × F-S06-1 | `Tools::AddonsController` | It uses the concern (`project_folder_intake.rb:231-238`); F-S11-1 changes only `latest_output_folder`'s ORDER BY. |
| I27 | F-S16-2 × F-S14-1 | public BOM / CSV | F-S16-2 corrects the unit data those pages print; F-S14-1 changes `bundle_path_for` for backups. |
| I28 | F-S20-2 × S06's partial | `app/views/shared/_where_files_come_from.html.erb` | The partial already declares `locals: (sources: true, projects: true)` (line 1), so F-S20-2 needs no edit there. This confirms "The partial (S06's) is untouched" (AUDIT:458). |
| I29 | F-S08-1 × F-S21-2 | `enqueue.rb:65-67` caller list | F-S21-2 merges the two upload-door callers into LibraryOutput's; F-S08-1 rewrites the adjacent `:43-63`. Whichever lands last fixes `:65-67`, which also names a nonexistent `V1::CommitsController` (A7). |
| I30 | F-S17-1 × §4 S17 SAFETY NOTE (AUDIT:741) | `lib/tinkerex/demo.rb` (`Demo.account`/`available?`) | Not an F-entry pair. If the owner adopts the interlock (a `users.demo` flag), it edits the same two methods as F-S17-1, so decide both together. |
| I31 | Same-row pairs on disjoint files: F-S13-1 × F-S13-2 (CommitPaths' public interface unchanged), F-S15-1 × F-S15-2, F-S16-1 × F-S16-2, F-S20-1 × F-S20-2, F-S25-1 × F-S25-2, F-S28-1 × F-S28-2, F-S29-1 × F-S29-2 | — | No shared file, mechanism or test. |

### 1c. The §5 adjudications, checked (AUDIT:775-794)

1. **AUDIT:777 — S10's "ready-and-attached" note → F-S08-2. CONFIRMED.** grep finds exactly ten
   `status == "ready" && …asset.attached?` sites:
   - `application_helper.rb:52`;
   - `files/_thumb.html.erb:26`;
   - `files/viewers/_gerber.html.erb:63`, `_measure.html.erb:170`, `_model3d.html.erb:39`, `_static.html.erb:18`;
   - `public/_project_card.html.erb:31`;
   - `public/projects/_page.html.erb:141`;
   - `files_controller.rb:386` (in `#thumbnails`);
   - `public/files_controller.rb:97` (in `#preview`).

   That is F-S08-2's consumer list exactly: the helper, seven partials and two actions.
2. **AUDIT:779 — F-S03-1 and F-S02-1 as one trash-entry design.**
   - Membership: CONFIRMED. S03.md:88's existence rule revives both rows of defect (b): the older trash tombstone and the
     re-uploaded row share a rebuilt key.
   - INCOMPLETE: S03.md:94's tombstone set needs superseding too (M2).
   - REFINE: "must land as one slice" can be two consistent slices (E2).
3. **AUDIT:780 — "S05 and S03 each REJECTED an explicit tombstone-KIND column". INACCURATE for S03.**
   - Accurate for S05 (S05.md:123) and S23 (S23.md:346).
   - S03.md:205 rejects "An explicit tombstone-kind or `trash_root_id` column", i.e. F-S02-1's column by name. Its
     argument is that root-relative keys make the entry LOCATION derivable. That does not answer MEMBERSHIP (which rows a
     given delete moved), and membership is what defect (b) turns on.
   - §5's conclusion survives, but the record should state the rejection and why it does not hold (E3).
4. **AUDIT:782 — S14 Opportunity 2 counted under F-S10-2. CONFIRMED.** S14.md:119-150 re-checks every claim, and the `.compact`
   refinement was carried. Residue not carried:
   - S14's second mutation: pass the public side `url: ->(_) { nil }`, and the new zip test plus `:99` go red.
   - The new public tests land in `public_file_view_test.rb`, which the tie-break gives to S22 (AUDIT:230).
5. **AUDIT:783 — S15's pointers to S14. CONFIRMED.** S14.md's rejected list:
   - `repo_cards` is line-count only;
   - the `hidden_*` re-walks are immaterial;
   - `thumbs` is absorbed into F-S14-1 (c).
6. **AUDIT:785 — the S01/S06 sequencing pattern resolved into F-S07-1. CONFIRMED.** S07.md Opp 1 §4 shows:
   - the cap hole exists inside ScanJob's own sequence;
   - a pull-driven pipeline costs 7.5× in catalog work.
7. **AUDIT:787 — S18 Opportunity 1 absorbed into F-S19-1 (ledger), F-S16-2 (unit) and X6/F-40 (task stamp). CONFIRMED**
   (S18.md:41-…; X6/F-40 at `docs/AUDIT-2026-08-19.md:993-1019`). Two residual divergences inside the absorption, to settle
   once:
   - (a) S18 prefers a reader override for the unit, while F-S16-2 uses a callback plus backfill. This is recorded as the
     owner's pick (§4 S18 bullet, AUDIT:752).
   - (b) S18 says the new delta validation needs `on: :create` so the immutability test keeps raising
     `ReadOnlyRecord` (§4 S18 bullet). F-S19-1 instead edits that test (AUDIT:441). The test is
     `inventory_transaction_test.rb:57`, `txn.update!(delta: 0)`, and validation runs before `before_update` at
     `inventory_transaction.rb:33`. Both remedies work; F-S19-1 should name one (E28).
8. **AUDIT:788 — S22's shared lifecycle module rejected. CONFIRMED** (S22.md:106).
9. **AUDIT:790 — S24 Opportunity 1 reconciled with F-S07-1. CONFIRMED in substance** (correctness vs representation and
   latency; F-S07-1 first). It **misses** the validation collision in M1.
10. **AUDIT:791 — deriving `maker_file_attachments.role` rejected by S23 and S06. CONFIRMED** (S23.md:330-337; S06.md:153-154).
11. **AUDIT:793 — the F-S29-2 / F-S26-2 split. CONFIRMED,** and consistent with tie-break AUDIT:231. Two gaps:
    - F-S29-2 scope (4) (AUDIT:638) still lists the `ci.yml` lines;
    - the order constraint (presence test before the steps go) is unstated (M7).

---

## 2. Ownership check

The §1 text compared against, quoted where a finding turns on it:

- S05: "`app/jobs/library/{scan_job,trash_purge_job}.rb`" (AUDIT:48).
- S06: "`app/jobs/maker/{project_intake_job,project_discovery_job,attachment_reaper_job}.rb` … `app/controllers/projects/{adoptions,scans,attachments}_controller.rb`" (AUDIT:54).
- S07: "`app/jobs/maker/model_intake_job.rb`" (AUDIT:60).
- S14: "`app/controllers/public/*` … `app/views/public/`" (AUDIT:102).
- S17: "`app/models/{user,user_identity,current}.rb`" (AUDIT:120).
- S18: "`app/controllers/v1/**`" (AUDIT:126).
- S20: "`app/helpers/{shell_helper,application_helper}.rb`" (AUDIT:138).
- S23: "`db/migrate/*`" and "`db/{cable,cache,queue}_schema.rb`" (AUDIT:156).
- S24: "`config/{application,boot,environment,puma}.rb`, `config/{database,queue,cache,cable,recurring,…}.yml` … `Dockerfile`" (AUDIT:162).
- S26: "`ci/**`, `.github/workflows/ci.yml` … `test/{ci_hygiene,ci_preflight,architecture_invariants,docs_hygiene}_test.rb`" (AUDIT:174).
- S27: "`test/system/support/*`" (AUDIT:180).
- Tie-breaks: "`viewers/{_gerber,…,_static}.html.erb` → S22"; "`ci/ensure-resvg.sh` → S29 … while S26 owns the two `ci.yml` steps" (AUDIT:231).

### 2a. Misassignments (the authoritative row owns a minority of the scope)

- **F-S24-1 (authoritative S24).** Scope (AUDIT:558):
  - new `app/jobs/maker/library_sweep_job.rb`;
  - `project_intake_job.rb`, `project_discovery_job.rb` and `projects/scans_controller.rb` (S06);
  - `model_intake_job.rb` (S07);
  - `scan_job.rb` (S05);
  - `recurring.yml` (S24).

  S24 owns one of these seven code/config files. S06 owns three, and the new job belongs beside them. **Recommend:** make
  S06 authoritative and credit S24 as author, with S05, S07 and S24 coordinating. Alternatively keep S24 and add an explicit
  "files are S05/S06/S07's" line. Either way §1 must assign `library_sweep_job.rb`.
- **F-S29-2 (authoritative S29).** Files:
  - `Dockerfile:107` (S24);
  - `ci/runner/Dockerfile:162`, `ci.yml` and `test/ci_hygiene_test.rb` (S26);
  - `ci/ensure-resvg.sh` (S29, per tie-break);
  - a new CI presence test that exercises S08's renderers.

  S29 owns one of the five, and the renderer-parity defect it guards is recorded under S26 (§4). **Recommend:** co-own
  S26 + S29 (S26 for the image declarations and the hygiene and presence tests, S29 for the script), coordinating S24.
- **F-X-1 (owner S01): not a misassignment, but S01 owns none of the scope's files.**
  - `app/services/file_layer.rb` defines only `current`, `reset!` and `build`. The verb signatures live in `share.rb:317`,
    `s3.rb:395` and `chunk_remote.rb:325,378`.
  - §1's S01 *Interfaces* line does claim "the port verbs every adapter answers (…`begin_upload`, `put_chunk`,
    `finalize_upload`)" (AUDIT:25), so S01 is the right coordinator. The entry must name S02, S03, S04 and S26 (2b).
  - Scope accuracy that bears on ownership: `broadcast:` exists only on `chunk_remote.rb:378`. `share.rb:322` and
    `s3.rb:400` declare `finalize_upload(_user, commit_id: nil, verify: true)`, so S02/S03 are touched for `device:` only.

### 2b. Cross-row reaches the entry does not name (with the coordination needed)

| Entry | Foreign file(s) (owning row) | What the entry says | Coordination to add |
|---|---|---|---|
| F-S01-1 | `config/application.rb:9-14,24` (S24); the three `LibraryBackend.name` call sites `test/services/file_layer/chunk_remote/mutation_contract_test.rb:96`, `upload_test.rb:91` (S04) and `test/system/uploader_test.rb:49` (S21); CLAUDE.md (S30); `test/docs_hygiene_test.rb` MAX_LINES (S26) | Files named as "retarget 3 test call sites" | Name S24, S04, S21 and S26 |
| F-X-1 | `share.rb` (S02), `s3.rb` (S03), `chunk_remote.rb` (S04), `architecture_invariants_test.rb:1195` (S26) | S11, S20 and S21 are named | Name S02, S03, S04 and S26 |
| F-S05-1 | `test/architecture_invariants_test.rb:1289-1291` (S26) | File named | Name S26 |
| F-S08-1 | `public/files_controller.rb#enqueue_geometry` (S14) | S10 is named; S14 is not | Name S14 |
| F-S08-2 | `application_helper.rb` (S20); `files/viewers/{_gerber,_model3d,_static}` (S22); `files/viewers/_measure` (S09); `files/_thumb` and `files_controller#thumbnails` (S10); `public/_project_card`, `public/projects/_page`, `public#preview` (S14); `v1/maker/previews_controller.rb` (S18) | Files listed, no rows | Name S09, S10, S14, S18, S20 and S22; the consumer step is a six-row edit |
| F-S10-1 | `app/models/current.rb:10-13` (S17) | File named | Name S17; add CLAUDE.md §14d (A2) |
| F-S10-2 | New public tests go in `test/integration/web/public_file_view_test.rb` (S22 by tie-break, AUDIT:230) | S14 is named | Name S22 for the test file |
| F-S11-1 (optional step) | `files/_meta.html.erb:16-17` (S10) and `projects/_generated_group.html.erb:49` (S15) print `addon_origin[:state].revision` / `state.revision` directly. `AddonOrigin` carrying the row's revision does not change them by itself. | "AddonOrigin carrying the row's revision so the labels are right" | Name both views and S10/S15 (E32) |
| F-S02-1 | Optional `TrashController#restore_refusal_message` (S10); the `subtree.rb:17-18` comment (S01) is missing | S03 and S23 are named | Name S10; add the S01 comment (A3) |
| F-S02-2 | The FOLDERS_NOT_YET lift in `files_controller.rb:1013-1022` (`#rename`/`#move` are S10's) | "Separate slice outside this row" | Name S10 |
| F-S07-1 | `scan_job.rb:239-249,320-333` and `scan_job_test.rb` (S05); `recurring.yml:162-166` (S24) | S06 is named | Name S05 and S24 (and see M1) |
| F-S07-2 | `projects/adoptions_controller.rb:203-218` prose (S06) | File named | Name S06 |
| F-S16-2 | The data migration in `db/migrate` (S23) | "a data migration" | Name S23. It is the only migration-bearing entry with no S23 consistency verdict (F-S05-1, F-S02-1 and F-S11-1 have one). |
| F-S19-1 | Validation (b) and (c) are v1 request tests in `test/integration/v1/*` (S18) | Not named in AUDIT (S19.md names S18) | Name S18 |
| F-S21-1 | Deleted or ported tests in `project_folder_intake_test.rb` (S06), `projects_flow_test.rb` (S15) and `demo_guards_test.rb` (S17, via `demo_*`); the header of `project_folder_intake.rb` (S06) | Files listed | Name S06, S15 and S17 |
| F-S22-1 | `test/system/support/web_helpers.rb` (S27) | File named | Name S27 |
| F-S23-2 | `app/models/node.rb` (S05); `app/models/maker/file_attachment.rb` and `project_intake.rb:566-568` (S06); `preview.rb`'s `ready` scope (S08); the v1 file_attachments/projects/items controllers (S18); `file_info.rb` (S01); CLAUDE.md §5 | Files listed, no rows | Name S01, S05, S06, S08 and S18 |
| F-S24-1 | Stale prose the change falsifies but the scope omits: `tools/addons_controller.rb:550` and `addons_controller_test.rb:1057` (S11); `remote_changelog_pull_job.rb:23` (S04); `shared/_where_files_come_from.html.erb:9-10` (S06); `project-intake.md:427`. Each names the `project_folder_intake` schedule or `ProjectIntakeJob.sweep_all!`, which F-S24-1 deletes (grep). | Not in scope | Add them (E30) |
| F-S24-2 | `db/cable_schema.rb` (S23) | S23 named only for `schema_map` | Name S23 for the schema file |
| F-S24-2 | `ops/backup-db.sh:229` (S25) | Not named | Name S25 |
| F-S26-1 | New `lib/ci/leg_runs.rb` falls under `config.autoload_lib(ignore: %w[assets tasks generators library_backend.rb])` (`config/application.rb:24`, S24). With no acronym inflection (`config/initializers/inflections.rb`), Zeitwerk expects `Ci::LegRuns` unless S24's ignore list grows. F-S25-1 records the same constraint for its new file; F-S26-1 does not. | Not stated | Add the Zeitwerk line (E29) |
| F-S27-1 | The six pinned tests are S06/S07 job tests (M9); `library_broadcast_test.rb:22-33` (S01) | "6 redundant pin lines" | Name S06, S07 and S01 |
| F-S29-2 | `ci/runner/Dockerfile` and `test/ci_hygiene_test.rb` (S26); the presence test exercises S08's renderers | Only `ci.yml` is tied to S26 (via §5) | See 2a |
| F-S17-1 (trivial) | `landings_controller.rb:12`'s comment "A find_by and a COUNT" (S20) becomes inexact | Not named | Optional |

### 2c. Files that no §1 row owns (or that two rows own)

- **New files with no row yet.** Proposed owners:
  - `app/services/maker/content_read.rb` (F-S10-1) → S10;
  - `app/jobs/maker/library_sweep_job.rb` (F-S24-1) → S06, per 2a;
  - `lib/tinkerex/deploy_secrets.rb` (F-S25-1) → S25 (`lib/tinkerex/*` is assigned per file across S12, S17, S20 and S24);
  - `lib/ci/leg_runs.rb` (F-S26-1) → S26;
  - `test/ops_backup_table_test.rb` (F-S25-2) → S25;
  - F-S27-1's harness guard test → S27;
  - F-S29-2's CI presence test (no path given) → S26;
  - F-S28-1's optional Kaneo-write hygiene test → S28;
  - F-S18-1's optional static pin → S26.
- **`docs/invariants/*.md` have no EDITING owner.** §1 calls them "read-only inputs to several rows … listed where they
  bind" (AUDIT:18-19), and S30 excludes them (AUDIT:198). Yet 14 entries edit them:
  - `project-intake.md`: F-S06-1, F-S07-1, F-S21-1, F-S24-1;
  - `model-intake.md`: F-S07-1, F-S07-2, F-S24-1;
  - `files-preview.md`: F-S10-1, F-S10-2, F-S22-1;
  - `measure-view.md`: F-S08-1, F-S08-2;
  - `git-editing.md`: F-S13-1, F-S13-2;
  - `addons.md`: F-S12-2;
  - `design-system.md`: F-S20-1.

  Overlapping line ranges exist only for F-S07-1 × F-S24-1 (M1). **Recommend:** each file's editing owner is the row its
  §14 stub points from (E25).
- **Double assignments: resolved.** The coverage tie-breaks (AUDIT:230-231) settle the three cases these F-entries touch:
  - `files/viewers/{…}` → S22 (S10's EXCEPT list at AUDIT:78 omitted them);
  - `viewers/_code` → S13;
  - `ci/ensure-resvg.sh` → S29.

  I found no further double assignment among the files the F-entries name.

### 2d. Verdict for all 49 entries

| Entry (row) | Verdict | Entry (row) | Verdict |
|---|---|---|---|
| F-S04-1 (S04) | OK | F-S16-2 (S16+S19) | (b) S23 |
| F-S01-1 (S01) | (b) S24, S04, S21, S26 | F-S19-1 (S19+S16) | (b) S18 |
| F-S11-1 (S11) | (b) optional step: S10, S15 | F-S20-1 (S20) | OK |
| F-S10-1 (S10) | (b) S17; doc gap A2 | F-S20-2 (S20) | OK (I28) |
| F-S10-2 (S10+S14) | (b) S22 test file | F-X-1 (S01) | (b) S02, S03, S04, S26 (2a note) |
| F-S15-1 (S15) | OK (S16 named) | F-S17-1 (S17) | OK |
| F-S15-2 (S15) | OK | F-S07-1 (S07+S06) | (b) S05, S24 |
| F-S05-1 (S05+S23) | (b) S26 | F-S07-2 (S07) | (b) S06 |
| F-S05-2 (S05) | OK | F-S21-1 (S21) | (b) S06, S15, S17 |
| F-S06-1 (S06) | OK (A6 ride-along) | F-S21-2 (S21) | OK (reuses S11's helper unedited) |
| F-S08-1 (S08) | (b) S14 | F-S18-1 (S18) | OK |
| F-S08-2 (S08) | (b) S09, S10, S14, S18, S20, S22 | F-S22-1 (S22) | (b) S27 |
| F-S03-1 (S03) | OK (S01 named) | F-S23-1 (S23) | OK |
| F-S03-2 (S03) | OK | F-S23-2 (S23) | (b) S01, S05, S06, S08, S18 |
| F-S09-1 (S09) | OK (S27 if it adopts the shared helper) | F-S24-1 (S24) | **(a) → S06**; (b) S04, S06, S11 prose |
| F-S02-1 (S02+S03) | (b) S10; doc gap A3 (S01) | F-S24-2 (S24) | (b) S23, S25 |
| F-S02-2 (S02) | (b) S10 | F-S25-1 (S25) | OK |
| F-S14-1 (S14) | OK | F-S25-2 (S25) | OK |
| F-S13-1 (S13) | OK | F-S26-1 (S26) | (b) S24 (Zeitwerk) |
| F-S13-2 (S13) | OK | F-S26-2 (S26) | OK |
| F-S16-1 (S16) | OK | F-S28-1 (S28) | OK |
| F-S29-1 (S29) | OK (S08 test named) | F-S28-2 (S28) | OK |
| F-S29-2 (S29) | **(a) → co-own S26**; (b) S26, S08 | F-S27-1 (S27) | (b) S06, S07, S01 |
| F-S27-2 (S27) | OK (cross-row line named) | F-S12-1 (S12) | OK |
| F-S12-2 (S12+S25) | OK | | |

---

## 3. Cross-subsystem notes not carried forward

Every "Cross-subsystem notes" bullet of S01–S29 was compared against §2 and §4 by text search plus reading. Notes not
listed below are carried, either into an F-entry or into a §4 bullet.

### 3a. Not carried, or carried only as evidence with no action

| # | Report | Note (brief) | Class | Evidence / owner |
|---|---|---|---|---|
| A1 | S04 | "CLAUDE.md §6 'calls exactly eight endpoints': SyncGrant also calls `POST /v1/devices` and `GET /v1/devices/whoami` … `/v1/nodes` stands for three routes" | **(i) genuine.** A §4 stale-prose line (S30/S04). CLAUDE.md is loaded every session, and an exact count that is wrong is the claim class §15 warns about. Not an F-entry. | `CLAUDE.md:165-167` lists eight. `sync_grant.rb:42-43` posts `/v1/devices` and gets `/v1/devices/whoami`. grep "eight endpoints" in AUDIT.md finds 0. The fix must be net-zero lines (M14). |
| A2 | S10 | "CLAUDE.md §14d (last bullet) — the FetchError→banner setter list omits GerberArchive" | **(ii)** → F-S10-1's scope. It lists `current.rb:10-13` (AUDIT:269) but not CLAUDE.md. | `CLAUDE.md:938-940` names Readme, RepoCard, GerberSets and ThreeMfManifest. The setters in `app/` are `gerber_sets.rb:52`, `readme.rb:97`, `repo_card.rb:89`, `three_mf_manifest.rb:102` and `thumbnail_map.rb:58`. F-S10-1 moves ThreeMfManifest's arm into ContentRead and adds GerberArchive's. |
| A3 | S02 | "`subtree.rb:17-18`'s 'so undelete has the full set to revive' is the premise Opportunity 1 corrects (keep the walk, narrow its consumers)" | **(ii)** → F-S02-1's scope (S01's file). §4 carries only the `subtree_test.rb:41-48` fixture half (AUDIT:§4 S02→S01). | `subtree.rb:17-18`: "TOMBSTONES ARE INCLUDED … so `undelete` has the full set to revive." After F-S02-1, membership is `trash_root_node_id`, so the second clause is false. |
| A4 | S01, S27 | "`test/services/library_broadcast_test.rb:22-35`: stale comments about `SYNC_ENGINE` and `engine_wanted?`" | **(ii)** → F-S27-1's comment sweep. §4's engine-prose bullet lists the *service* (`library_broadcast.rb:3-35`), not the test. | `library_broadcast_test.rb:22-33` also cites `CHUNK_REMOTE_TOKEN` (retired in Arc C) and `pin_file_layer_backend`, which F-S27-1 retires. |
| A5 | S21 | "`importer_controller.js:131-132` navigates away right after 'skipped N', the same lost-feedback shape as the uploader" | **(i) minor.** Append to §4's S21 bullet (AUDIT:750), which carries the uploader and the `postJSON` duplicate but not this. Owner S07. | `importer_controller.js:131-132`: `this.setStatus("Done — imported …, skipped … (already present).")`, then immediately `window.location.href = this.created.model_url`. |
| A6 | S06, note 4 (part) | "`project_intake.rb:599-602` says inbox order decides which files a capped run files, but both caps are all-or-nothing" | **(ii)** → ride-along in F-S06-1. That entry rewrites the one place order does matter: `inbox[filings.size..]` after a FetchError (AUDIT:322). | `:599-602` vs `:266-273` (`refused = … inbox_total > cap`, then `move: !refused` for the whole user) and `:320-326` (`move: inbox <= cap` per project). |
| A7 | S08 | "`enqueue.rb`'s caller list omits `Public::FilesController#enqueue_geometry`" | **(ii)** → F-S08-1's prose step, or whichever of F-S08-1/F-S21-2 lands last (I29). §4 carries only the `V1::CommitsController` half. | `enqueue.rb:65-67` lists "three in `FilesController`, `V1::CommitsController`, `Projects::UploadsController`, …" and omits `Public::FilesController`. |
| A8 | S06, note 3 (part) | IN lists over the whole subtree (`project_intake.rb:579,669`) vs the listing's SQLite cap (`project_folder_listing.rb:41`, "bounds the IN (...) list on SQLite") | **(ii)** This is the same product decision §4 carries (AUDIT:703). It is not material on its own (unmeasured). | Code as described. |
| A9 | S01 | The remedy for `info: nil` on a sync-server conflict: "Finding the node by the node_id the upload began with" | **(ii)** §4 carries the defect (AUDIT:750) without the remedy. | — |
| A10 | S14 | `hidden_dir?` (`project_folder_listing.rb:343`) as the one definition behind narrowing "deliverable" | **(ii)** §4 carries the defect (the S14 bullet). | — |
| A11 | S23 | "`missing_backfill.rb:80` is the live reason" for `index_nodes_on_user_id`'s exemption | **(ii)** §4 carries only the stale `Sync::Tree` citation. This is the replacement reason for the same comment edit. | `architecture_invariants_test.rb:1254` cites `Sync::Tree.call`. `missing_backfill.rb:80` pages `nodes` with `find_in_batches`, and F-S08-1 keeps that batching. |

**Correctly dropped (iii):**

- S06 note 5 (part): the three bulk attach writers name the unique index differently. Style only.
- S12: near-identical `sidecarMessage` functions in `../tinkerex-addons`. Outside this repo.
- S13: the "refusal FIRST" rule restated in prose (`projects_controller.rb:648-651`, `repo_card.rb:64-77`,
  `release_snapshot.rb:86-88`). S13 itself rejected the LocalRepo-or-Refusal type, with reasons (S13.md, rejected item 2).
- S17: the landing's "a find_by and a COUNT" cost. Informational only: the landing exists only with `DEMO_ACCOUNT_EMAIL`, and
  F-S17-1 already states the chunk_remote button change.
- S25: `tinkerex_storage*` names are also spelled in `docker-compose*.yml`. Compose prefixes volumes with the project name
  (`docker-compose.yml:73-74` declares `tinkerex_storage: {}` with no `name:`), and `ops/backup-db.sh` targets Kamal containers
  only (`container_for`, `:191-205`). The backup table never reads the compose spelling.
- S28: `docs/superpowers/plans/2026-10-16-landing-format-wall.md:1445`. A historical plan in S30's skipped corpus.

### 3b. Carried into §4, but the named recipient never received the note

- **AUDIT:698 (S05 → S03/S05): "An S3 listing is not a snapshot … Handed to S03's reviewer."**
  - S03 never saw it: S03 was dispatched (AUDIT:800) before S05 was harvested (AUDIT:803), and reports/S03.md does not
    mention it (grep for snapshot/ghost/`create_or_revive`: none).
  - The mechanism reads true at HEAD. `s3_observer.rb:510` takes the identity from the listing; `hash_for` returns it with no
    read (`reconciler.rb:769-771`); `create_or_revive!` cannot match a NULL-path trash tombstone (`reconciler.rb:536-537`). So
    an object listed and then trashed in the web becomes a new live node.
  - **Class (i).** Both files are S05's ("`app/services/library/{…,s3_observer,reconciler,…}`", AUDIT:48), so the owner is
    S05. The race is unprobed. Neither F-S02-1 nor F-S03-1 changes this path.
- **AUDIT:714 (S09 → S08/S10/S18): "a `geometry` build can be requested for ANY extension … Candidate for S08's owner".**
  - S08 never saw it: S08 was harvested (AUDIT:805) before S09 (AUDIT:807).
  - The code reads as described: `files_controller.rb#geometry` (`:445-485`) has no `MEASURABLE_EXTS` check, and
    `Registry.render` passes `kind:` only to renderers that declare it (`registry.rb:162-168`).
  - **Class (i), low.** Its natural owner is now S33, in review; S33's boundary owns `FilePreview::MEASURABLE_EXTS` and
    `Registry::RENDERERS` (AUDIT:214).
- **AUDIT:711 (S03 → S06, unverified): a project folder comes back via a leftover marker.** S06 was harvested (AUDIT:804)
  before S03 (AUDIT:806). The case becomes moot once F-S03-1 step 1 deletes markers. **(ii).**

---

## 4. Recommended resolutions (proposed AUDIT.md text — not applied)

**§2 entry edits**

- **E1, F-S24-1, Validation (a) (AUDIT:560).** Replace with: "(a) behavioural order through the chunk_remote vehicle. Seed the
  node rows DiscoveryOrderTest gets from the reconcile: `Projects/` + `Projects/Desk Lamp/` + `bracket.stl`, no project row.
  Run `Maker::LibrarySweepJob.perform_now(user_id:)`. Assert BOTH that no model is keyed on the folder AND that
  `bracket.stl` sits under `models/` with its own model (`["bracket"]`). Once F-S07-1 has landed, the first assertion cannot
  fail on order, because the claim is positional. Each mutation must therefore be shown red on the SECOND assertion: move
  ModelIntakeJob first; put ProjectIntakeJob before ProjectDiscoveryJob."

  Add to F-S24-1's Dependency: "F-S07-1's prose edits fall inside this entry's rewrite: `scan_job.rb:239-249,320-333`,
  `recurring.yml:162-166`, `project-intake.md:134-146` and `model-intake.md:88-98,205-211`. If both are accepted, F-S07-1
  makes only the truth fix and this entry rewrites those paragraphs."

  Append to §5 (AUDIT:790): "Validation collision, resolved in F-S24-1 (a): the swallow assertion (S24.md:139) becomes
  order-independent under F-S07-1."
- **E4, F-S21-2.** Add "Dependency: after F-S21-1. Both rewrite `Projects::UploadsController#create`, its demo cap, its
  `rescue_from` block and `#enqueue_preview`. Afterwards the `NotFound` arm and the refusal table serve the build-log door
  alone." Add to F-S21-1: "Lands before F-S21-2."
- **E5, F-S03-1.** Add "Dependency: after F-S03-2, because a folder restore reaches `#restored_stat` once per member. Step 2
  only with or after F-S02-1's column (see §5)."
- **E6, F-S23-2.** Add "Dependency: after F-S23-1. `schema_map_test.rb:87-100` is retired by F-S23-1's drawn-XOR-listed
  rule, so release 2 deletes the `maker_file_attachments.version_id` NOT_EDGES entry instead of narrowing a test; both
  entries edit CLAUDE.md §5 (`CLAUDE.md:149`). Preview half: drop `index_maker_previews_on_user_id_and_status` after
  F-S08-1/F-S08-2, re-running the status-query grep then; the `Maker::Preview.ready` scope deletion moves into F-S08-2.
  Lineage: this index was the 2026-08-19 audit's carried observation under F-39, gated on F-14
  (`docs/AUDIT-2026-08-19.md:56,1006,1638`); F-14 landed in `bd28c77b`."
- **E7, F-S08-2, Smallest scope.** Prepend to the model step: "delete the unused `scope :ready` (`preview.rb:30`). This entry
  changes what `ready` means; F-S23-2 then drops only the index."
- **E8, F-S24-1.** Add: "If the optional ChangelogSync sweep enqueue is taken, it lands after F-S04-1. It hooks the
  once-per-pull point (`#nudge_project_intake`, `changelog_sync.rb:121`) and states its stance on `full_resync`, which must
  not feed the nudge (`changelog_sync.rb:58-59`, project-intake.md)."
- **E9.** F-S29-2 scope (4) (AUDIT:638) becomes "delete the script (its two `ci.yml` steps are removed by F-S26-2, §5)".
  F-S26-2 gains: "The resvg-step removal lands with or after F-S29-2 step (1), the CI presence test, so there is no window
  with neither the step-summary warning nor a red gate."
- **E10, F-S27-1, Validation.** Add: "If F-S24-1 lands first, re-point the named mutation to `LibrarySweepJob`'s gate test.
  F-S24-1 moves or deletes three of the six de-pinned tests (`model_intake_job_test.rb:12`, `project_discovery_job_test.rb:16,
  92`). Preferred order: this entry before F-S24-1."
- **E11, F-S09-1, Validation (2).** Add: "use the shared Turbo-Back helper in `test/system/support/web_helpers.rb` (S27's
  file) that F-S22-1 also uses. Whichever lands first creates it."
- **E12, F-S10-2, Dependency (AUDIT:281).** Replace with: "independent of F-S10-1 in code. F-S10-1 keeps
  `GerberArchive.for`/`ThreeMfManifest.for` as the entry points `viewer_for` calls." Add to Validation: "the new public tests
  live in `public_file_view_test.rb` (S22 by tie-break); include S14's second mutation (`url: ->(_) { nil }` → the new zip
  test and `:99` red)."
- **E14, F-S10-1, Smallest scope.** Add: "CLAUDE.md §14d's setter list (`CLAUDE.md:938-940`). The ThreeMfManifest arm moves
  into ContentRead and GerberArchive gains one. Net-zero lines."
- **E15, F-S02-1, Smallest scope.** Add: "rewrite `subtree.rb:17-18` (S01's file). The walk keeps tombstones so none is left
  live by omission; membership is `trash_root_node_id`, not the walk." Also add: "if F-S23-1 has landed, its rule enforces
  the EDGES line."
- **E22, F-S06-1, Smallest scope.** Add: "correct `project_intake.rb:599-602`. Both caps are all-or-nothing (`:266-273`,
  `:320-326`); order matters only for the FetchError abort this entry rewrites."
- **E23, F-S27-1, Smallest scope.** Name `library_broadcast_test.rb:22-33` among the comments to fix.
- **E24, F-S08-1, Smallest scope.** Extend the prose step to `enqueue.rb:65-67`'s caller list. Coordinate with F-S21-2,
  which merges the two upload-door callers.
- **E27, F-S01-1, Validation.** Add: "if F-S26-2's conservative option lands, the static initializer-wiring pin is the only
  guard of `config/initializers/library_backend_check.rb`, so it is required."
- **E28, F-S19-1, Risks.** Pick one remedy for `inventory_transaction_test.rb:57`: scope the new validation `on: :create`
  (S18), or edit the test (current text). Record why.
- **E29, F-S26-1, Risks.** Add: "`lib/ci/leg_runs.rb` is under `autoload_lib`. Define `Ci::LegRuns`, or add `ci` to the
  ignore list in `config/application.rb:24` (S24)."
- **E30, F-S24-1, Smallest scope.** Add the stale prose it falsifies:
  - `tools/addons_controller.rb:550` and `addons_controller_test.rb:1057` (S11);
  - `remote_changelog_pull_job.rb:23` (S04);
  - `shared/_where_files_come_from.html.erb:9-10` (S06);
  - `project-intake.md:427`.

  Also delete the callerless `Maker::ProjectIntakeJob.nudge` (`project_intake_job.rb:86`; §4 AUDIT:704), since this entry
  already rewrites that file.
- **E31, F-X-1, Smallest scope.** Replace "`file_layer/{chunk_remote,share,s3}.rb` signatures" with: "`device:` on all three
  adapters (`share.rb:317`, `s3.rb:395`, `chunk_remote.rb:325`); `broadcast:` exists only on `chunk_remote.rb:378`."
- **E32, F-S11-1, optional step.** Name the two views that must change: `files/_meta.html.erb:16-17` (S10) and
  `projects/_generated_group.html.erb:49` (S15).
- **Coordination lines (2b).** Add one line per (b) entry, in the form "Coordination: rows … own files …", using the 2b table.

**§5 edits**

- **E2, append to AUDIT:779:**

  > "SUPERSEDED TOO: F-S03-1's tombstone set. reports/S03.md:94 keeps `Subtree.node_ids` for the S3 cascade's `update_all`
  > (`s3.rb:568-569`), which turns scan tombstones into trash tombstones exactly as F-S02-1 (a)/(c) does on Share. F-S02-1
  > narrows that UPDATE to live rows (reports/S02.md:63), and both adapters follow F-S02-1.
  >
  > 'ONE SLICE' REFINED to two consistent slices:
  > - (A) No migration. F-S03-1 step 1 with a live-rows-only object set AND tombstone UPDATE, plus F-S02-1's no-migration
  >   `.present` cascade on Share.
  > - (B) Migration. The `trash_root_node_id` column on both adapters, plus F-S03-1 step 2 (S3 folder restore reading the
  >   column).
  >
  > F-S03-1 step 2 never ships before (B): its existence-at-key membership (S03.md:88) reproduces defect (b) on S3. F-S03-2
  > lands before step 2."
- **E3, replace the first sentence of AUDIT:780 with:**

  > "S05 (S05.md:123) and S23 (S23.md:346) rejected an explicit tombstone-KIND column. S03 rejected 'an explicit
  > tombstone-kind or `trash_root_id` column' BY NAME (S03.md:205), arguing that root-relative keys make the entry's
  > LOCATION derivable. That does not answer MEMBERSHIP (which rows a given delete moved), and defect (b) needs membership;
  > so F-S02-1's column stands over S03's rejection."
- **E9b, append to AUDIT:793:** "Order: F-S29-2 step (1) before the resvg steps leave `ci.yml`. F-S29-2's scope no longer
  lists those lines."
- **Residues of the co-signs:**
  - After AUDIT:782: S14's second mutation and the S22 test-file ownership.
  - After AUDIT:787: the `on: :create`-vs-test-edit choice, now pinned in F-S19-1 (E28).

**§4 edits**

- **E16, AUDIT:742.** Replace the clause after the semicolon with:

  > "`SINGLE_LIBRARY_BACKENDS` (`registration.rb:24`: every account indexes one library) and `demo_reset.rb:75` (the reset
  > rebuilds through the port's byte write and empties its trash) are DIFFERENT facts that coincide on {share, s3}. §14b's
  > 'agreement across three samples is not identity' applies. Keep two declarations, both fed by F-S01-1's resolved name."
- **E17, AUDIT:692.** Append: "S14 considered and rejected one shared chain partial; it contradicts the recorded per-page
  decision at `files/show.html.erb:103-108` (S14.md, rejected list)."
- **E18, AUDIT:698.** Replace "Handed to S03's reviewer" with:

  > "NOT ASSESSED. S03 was dispatched (AUDIT:800) before S05 was harvested (AUDIT:803). Owner S05 (`s3_observer.rb`,
  > `reconciler.rb`). The mechanism reads true at HEAD: `s3_observer.rb:510`; `reconciler.rb:769-771`, `:536-537`. Probe with
  > FakeS3 (list → adapter delete → reconcile) before filing it as a defect."
- **E19, AUDIT:714.** Append: "S08 was harvested (AUDIT:805) before S09 (AUDIT:807) and never assessed this. It is now S33's
  (vocabulary row; owns `MEASURABLE_EXTS` and `Registry::RENDERERS`)."
- **E20, new stale-prose line (S04 → S30):**

  > "`CLAUDE.md:165-167` says ChunkRemote 'calls exactly eight endpoints'. SyncGrant also calls `POST /v1/devices` and
  > `GET /v1/devices/whoami` (`sync_grant.rb:42-43`), and `/v1/nodes` is three routes. Fix with net-zero lines (ceiling)."
- **E21, append to the S21 bullet (AUDIT:750):** "(→ S07) `importer_controller.js:131-132` shows 'Done — imported N,
  skipped M (already present).' and navigates away in the same tick. It is the uploader's lost-feedback shape."

**§1 edits**

- **E25.**
  - Assign the new files listed in 2c to their rows.
  - Give each `docs/invariants/*.md` an editing owner:
    - `project-intake.md` → S06;
    - `model-intake.md` → S07;
    - `files-preview.md` → S08 (shared with S10 and S22);
    - `measure-view.md` → S09;
    - `addons.md` → S11;
    - `git-editing.md` → S13;
    - `design-system.md` → S20;
    - `deploy-secrets.md` and `backup-restore.md` → S25.
  - Reassign or co-own F-S24-1 (S06) and F-S29-2 (S26 + S29), as in 2a.
  - Add a coordination line to F-X-1 naming S02, S03, S04 and S26.

**§6 lines (for the coordinator's final priorities)**

- **E13, shared constraint.**

  > "CLAUDE.md has 1,360 lines and `MAX_LINES = 1_360` (`test/docs_hygiene_test.rb:71`). Seven entries edit it: F-S01-1
  > (§14a `:641`, `:651`), F-X-1 (§14a `:489`), F-S23-1 (optional) and F-S23-2 (§5 `:149`), F-S24-2 (§4 `:112`, §14e
  > `:1028`), F-S26-1 (§15 `:1272`, §13) and F-S10-1 (§14d `:938`). Each must be net ≤ 0 lines on its own and lower
  > `MAX_LINES` in the same commit (the ratchet banks nothing). Merge them one at a time, because they all edit one constant."
- **E26, harness first.**

  > "Land F-S27-1 and the first step of F-S27-2 (`test_helper.rb` + `public_fixture.rb`) before the entries that add
  > integration tests. Those tests then get the reset by construction and use `sign_in_web!` instead of adding raw sites."
- **Order constraints:**

  | Order | Pair |
  |---|---|
  | F-S07-1 → F-S24-1 | M1 |
  | F-S04-1 → F-S24-1 | M6 |
  | F-S21-1 → F-S21-2 | M4 |
  | F-S03-2 → F-S03-1 | M5 |
  | Slice A → Slice B | M2 |
  | F-S23-1 → F-S23-2 | M3 |
  | F-S08-1 → F-S08-2 → F-S23-2's preview half | M8 |
  | F-S29-2 step (1) → F-S26-2's resvg-step removal | M7 |
  | F-S27-1 → F-S24-1 | M9 |

---

## What I could not check

- **Nothing was executed.** No test, gate, EXPLAIN plan, FakeS3 probe or mutation was run. Every red/green claim above,
  including the latency assertion in M1 and the race in 3b, is read from code, not observed.
- **Batch-5 rows (S32 bundle snapshot, S33 file-type vocabulary, S34 page stylesheets) were still in review** and have no
  findings yet. I could not check overlap with them. Likely contact points:
  - S33 with F-S10-1/F-S10-2's `FilePreview`/`EXT` symbols, F-S08-2's renderer set, and the 3b geometry-kind note;
  - S34 with F-S09-1's `preview.css:234-248` state derivation and F-S20-1's container-query pattern;
  - S32 with F-S11-1's `#states` order, which the snapshot's `gallery.js` workaround reads.
- **Other audit-pass reports** (coverage, schema, materiality, priority) were deliberately not read. Any disagreement with
  them is unreconciled.
- **Line ranges taken from the entries.** I re-opened the repo lines named in this report, but not every range in every
  F-entry's scope. Co-location judgments for unopened ranges rely on the entries' own citations.
- **Net line deltas.** The net CLAUDE.md line change of each entry's planned edit cannot be known before it is drafted (M14).
- **F-S19-1's inputs on the v1 path.** I did not check whether any of the five inputs reaches an `ArgumentError` there (I24).
- **Sibling repos** (`tinkerex-sync`, `tinkerex-client`, `tinkerex-addons`) were not opened. Claims about them are the
  workers' own.
- **Opportunity scopes vs AUDIT entries.** I compared report scopes with their AUDIT.md entries only where a pair needed it
  (S02, S03, S06, S07, S13, S14, S18, S22, S23, S24), not for all 29 reports.
