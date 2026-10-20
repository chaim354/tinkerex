# Coordinator's provisional priorities (drafted 2026-10-19 BEFORE reading the priority pass; reconciled afterwards into AUDIT.md §6)

Scoring rule (provisional): Impact 1–5 = what the change removes at HEAD (5 = a reachable data-facing or tenancy defect on a live deployment; 4 = a user-visible wrong answer or a gate that defines "green"/"deployable"; 3 = a reachable but narrow defect, a race, or a representation that has already drifted once; 2 = preventive/duplication with no shipped defect; 1 = housekeeping). Tier = impact × confidence, discounted by effort and blast radius, promoted when the finding UNLOCKS or GUARDS others.

## Dependency edges (X → Y = X lands first), with reasons
- F-S23-1 → F-S02-1, F-S16-2, F-S11-1 (guard-before-refactor: each adds a `*_id`/edge column — `nodes.trash_root_id`, the BOM unit move, the addon-file revision stamp — that `SchemaMap::EDGES` must classify; landing the completeness check first makes each later PR fail the map until it classifies its column).
- F-S26-1 → every later slice (guard: the three-leg run-count rule becomes mechanical before test churn starts).
- F-S27-1 → F-S27-2 (same file, `test/test_helper.rb`; the reset is trivial and removes the pollution class before the sign-in sweep).
- F-S02-1 ⟷ F-S03-1 ONE slice (§5); that slice also edits `TrashPurgeJob#purge_s3!` (S05's file — §4 note: it drives the S3 trash keyspace directly) and classifies `trash_root_id` in the map.
- F-S07-1 → F-S24-1 (§5: correctness first; the sequence job is then a latency representation) and F-S07-1 → F-S07-2 (attachment reconcile presumes positional claims).
- F-S08-1 → F-S08-2 (§2: the stall-heal must be reachable before `rebuilding` has a heal to use; consumers ~20).
- F-S10-1 → F-S10-2 (soft: the shared read door is what `viewer_for` should call; also F-S10-1 retires an anonymously reachable poisoning and should not wait).
- F-S19-1 → F-S16-2 (both touch `Maker::BomLine`; the ledger validation is the higher-impact change). CORRECTED while drafting: there is NO F-S19-1 → F-S18-1 edge — `InventoryTransaction.apply!` raises no `ArgumentError` (verified `inventory_transaction.rb:38-48`; a NaN delta 500s today per F-S19-1, and validation failures are `RecordInvalid` → 422 through their own rescue). F-S18-1's only prerequisite is the soft one its entry names: F-S01-1 moves the last `FileLayer.build` `ArgumentError` producer to boot.
- F-S01-1 → F-S17-1 (the host-refusal predicate consumes the resolved backend name) and F-S01-1 → S25's consumers (`Registration.validate!`, deploy hygiene read the one reading).
- F-X-1 and F-S11-1 both edit `Maker::Addons::LibraryOutput` → sequence (F-X-1 first: it deletes the phantom `addon_device` row creation that F-S11-1's stamping would otherwise be written around).
- F-S21-1 → F-S21-2 (same controller; delete the dead arm before restructuring refusals).
- F-S05-1 → F-S05-2 (same file; the index + query term is tiny and independent).
- F-S25-1 → F-S12-2 (same file, `test/deploy_hygiene_test.rb`: the shared walk restructures the test before the catalog block gains a rule).
- F-S25-2 → F-S24-2 (same file, `ops/backup-db.sh`: with one destination table, retiring the cable DB is a one-row delete).
- F-S26-2 + F-S29-2 ONE slice (§5; both remove `ci/ensure-resvg.sh`'s steps; the renderer-parity defect's guard shape is F-S29-2's hygiene test) — AFTER F-S26-1 (same `config/ci.rb`).
- MUST NOT land together: F-S02-1/F-S03-1 with anything else touching the adapters (F-S02-2, F-S03-2, F-S05-2) — blast radius; F-S27-2 (≈107 files) with any product change.

## Provisional tiers
P1 (do first; cheap guards or reachable data/tenancy defects): F-S26-1, F-S27-1, F-S23-1 (three guard PRs, parallel, disjoint files) · F-S19-1 (ledger + cross-tenant disclosure) · F-S02-1+F-S03-1 (trash entry model) · F-S04-1 (resync arm drops version on the primary deployment) · F-S10-1 (anonymous cache poisoning) · F-S25-1 (the silent-empty-deploy gate) · F-S08-1 (stalled previews never heal from web doors) · F-S07-1 (cap hole + chunk_remote race) · F-S16-1 (sheet edits never saved).
P2: F-S11-1 · F-S14-1 · F-S15-1 · F-S15-2 (owner's call on §10.9) · F-S09-1 · F-S22-1 · F-S21-1→F-S21-2 · F-S13-1/F-S13-2 · F-S16-2 · F-S18-1 · F-X-1 · F-S01-1 · F-S08-2 · F-S24-1 · F-S28-1 · F-S26-2+F-S29-2 · F-S12-1.
P3: F-S05-1 · F-S05-2 · F-S06-1 · F-S17-1 · F-S20-1 · F-S25-2 · F-S27-2 · F-S28-2 · F-S29-1 · F-S12-2 · F-S07-2 · F-S02-2 · F-S23-1-dependents.
P4 (defer/fold): F-S03-2 · F-S20-2 · F-S23-2 · F-S24-2.

## Best first slices (each one PR; disjoint files → parallel)
0. Guards: F-S26-1 (config/ci.rb), F-S27-1 (test_helper.rb), F-S23-1 (lib/schema_map + test) — three tiny PRs, land first.
1. Trash entry model: F-S02-1 + F-S03-1 + TrashPurgeJob's S3 driver + EDGES row. Gates: all three legs; FakeS3 asserts the WIRE key shape (§14e's inverse-encoding lesson); mutation-check the "non-NULL ⇒ trash" guard.
2. Ledger + tenancy: F-S19-1 (then F-S16-2 as a follow-up; F-S18-1 is unrelated and follows F-S01-1).
3. Primary-deployment mirror: F-S04-1 (chunk_remote leg is the proof).
4. Preview freshness: F-S08-1 (then F-S08-2) and, separately, F-S10-1 (then F-S10-2).
5. Model catalog correctness: F-S07-1 (then F-S24-1, F-S07-2).
6. Deploy gate: F-S25-1.

## Defects to fix independently of any simplification (from §4; one-line or ticket-sized)
Share#write mkdir_p outside begin (S02) · FilesController#rescan drops q (S10) · layout_editor 40-block count (S15) · editor_controller.js parse-before-ok (S13) · uploader reload after partial failure (S21) · production.rb ADDON_SOURCE_PATH default (S24) · puma on_booted (S24) · SyncGrant mints before whoami (S18) · account deletion never deprovisions the sync library (S17) · geometry build for any extension (S09) · public .gbrjob N+1 (S14) · .git internals in Recent on chunk_remote (S20) · spool per checkout (S28) · zero-byte files on chunk_remote (S04) · Tools::LibraryFolders guard gap (S11) · EntryPhotosController#destroy scope (S16) · relocate :in_working_tree 500 (S06) · CI renderer parity (S26, with slice F-S26-2+F-S29-2) · the demo-reset destructive switch (S17, owner's call).
