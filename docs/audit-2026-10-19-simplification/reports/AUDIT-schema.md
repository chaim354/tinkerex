# AUDIT-schema — schema-completeness pass over AUDIT.md §1/§2

Pass: schema completeness (one of the five audit-the-audit passes, AUDIT-PASS-BRIEF.md).
Repo: /Users/charlesschwartz/Desktop/repos/tinkerex at HEAD 75124d67 (verified; `git status` shows only
the pre-existing `?? app/assets/images/landing/library.jpg`). Nothing under the repo was written or run.
Sibling repos were READ at their current local HEADs: tinkerex-sync b849e08, tinkerex-addons d3ab6fd,
tinkerex-client 399ccdb.

**AUDIT.md CHANGED UNDER THIS PASS.** It was 793 lines when I started and 822 when I finished (mtime
16:37): the coordinator added rows S32–S35 and a "Tie-breaks and boundary-text corrections" block to §1
after the coverage pass, plus two §7 log lines. §2–§5 kept their exact line counts (§2 is still 445
lines, 49 entries), so every §2 finding below applies to both versions; **AUDIT.md line numbers quoted
here are for the current 822-line file** (subtract 27 for the 793-line snapshot). The inventory check
(§4 below) was run against the 822-line file and covers S32–S35 too.

Legend: **S** = present-substantive, **V** = present-vague, **M** = missing. All repo citations were
opened at HEAD by me; I did not rely on the coordinator's verification notes.

---

## 1. Field table (49 entries × 13 fields)

Columns 1–8 are BRIEF.md's required schema; the last five are the coordinator-added fields.
AR = Authoritative row, CV = Coordinator verification, BR = blast radius, EF = effort, PD = priority/dependency.

| Entry | L | 1 Verdict¹ | 2 Evidence² | 3 Complexity | 4 Representation | 5 Scope | 6 Risks | 7 Validation | 8 Confidence | AR | CV | BR | EF | PD |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| F-S04-1 | 237 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S01-1 | 247 | S | S | S | S | S | S | **V** | S | S | S | S | S | **M** |
| F-S11-1 | 256 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S10-1 | 265 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S10-2 | 274 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S15-1 | 283 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S15-2 | 292 | S | S | S | S | S | S | S | S | S | S | S | S | **V** |
| F-S05-1 | 301 | S | S | S | S | S | S | S | S | S | S | S | S | **V** |
| F-S05-2 | 310 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S06-1 | 319 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S08-1 | 328 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S08-2 | 337 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S03-1 | 346 | S | S | S | S | S | S | S | S | S | S | S | S | S³ |
| F-S03-2 | 355 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S09-1 | 364 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S02-1 | 373 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S02-2 | 382 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S14-1 | 391 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S13-1 | 400 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S13-2 | 409 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S16-1 | 418 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S16-2 | 427 | S | S | S | S | S | S | S | S | S | S | S | S | **V** |
| F-S19-1 | 436 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S20-1 | 445 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S20-2 | 454 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-X-1 | 463 | S | S | S | S | S | S | **V** | S | **V** | S | **M** | S | **M** |
| F-S17-1 | 472 | S | S | S | S | S | S | S | S | S | S | S | S | **V** |
| F-S07-1 | 481 | S | S | S | S | S | S | S | S | S | S | S | S | **V** |
| F-S07-2 | 490 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S21-1 | 499 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S21-2 | 508 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S18-1 | 517 | S | S | S | S | S | S | S | S | S | S | S | S | **V** |
| F-S22-1 | 526 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S23-1 | 535 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S23-2 | 544 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S24-1 | 553 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S24-2 | 563 | S | S | S | S | **V**⁴ | S | S | S | S | S | S | S | S |
| F-S25-1 | 571 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S25-2 | 580 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S26-1 | 589 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S26-2 | 598 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S28-1 | 607 | S | S | S | S | S | S | **V** | S | S | S | S | S | S |
| F-S28-2 | 616 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S29-1 | 625 | S | S | S | S | S | S | S | S | S | S | S | S | **V** |
| F-S29-2 | 634 | S | S | S | S | S | S | S | S | S | S | S | S | S |
| F-S27-1 | 643 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S27-2 | 652 | S | S | S | S | S | S | S | S | S | S | S | S | **V** |
| F-S12-1 | 661 | S | S | S | S | S | S | S | S | S | S | S | S | **M** |
| F-S12-2 | 670 | S | S | S | S | S | S | S | S | S | S | S | S | **V** |

Notes on the table:
1. **Verdict.** No entry carries a literal "Verdict:" line. The verdict is carried by §2's "Confirmed
   opportunities" placement plus "Coordinator verification: CONFIRMED" ("FINAL … CONFIRMED" for F-X-1).
   That is unambiguous, so I scored it S on content. If you want the schema to read literally, add
   "Verdict: recommend" to the AR line of all 49 entries.
2. **Evidence.** Only F-S04-1 has a separate "Evidence:" line ("as above" plus the reachability
   note). The other 48 keep their file:line evidence inside "Coordinator verification". I scored that
   S on content. F-S11-1 anchors several claims on method names (`#upsert_file!`,
   `#latest_output_folder`) rather than line numbers, which still resolves.
3. F-S03-1's PD is present ("Priority: high") but contradicts §5. See §5 C-1.
4. F-S24-2 has **no "Smallest scope" line** (6 fields, not 7). Its file list is folded into
   "Proposed representation", and `config/cable.yml` (the file the `adapter: async` change edits) is
   implied but never named as a path.

**How I scored PD.** S means an explicit "Priority:" line or a stated ordering against another
finding. V means only an ownership or coordination remark, or an optional follow-on, with no priority.
M means nothing at all. Explicit "Priority:" lines exist on only **9 of 49** entries: F-S03-1,
F-S03-2, F-S02-1, F-S19-1, F-S23-2, F-S24-2, F-S25-1, F-S26-1, F-S28-1. §6 is still empty, so this
column is the coordinator's main to-do.

---

## 2. Citation check

I opened every repo file:line, line range, commit SHA and sibling-repo location cited in each entry's
Evidence / Coordinator-verification text, plus the line-numbered items in Scope and Validation. That
comes to about **410 citations: 409 resolve as claimed** (11 with small end- or start-line drift
that still points at the claimed code). There is **1 hard mismatch**, plus 2 scope items that
misdescribe what they point at and 3 count claims that are slightly off. The full per-entry ledger
is in Appendix A.

| Entry | Checked | Resolve | Mismatches / notes |
|---|---|---|---|
| F-S04-1 | 6 | 6 | sibling `TreeNode` (tree.rs:11) flat ✓; `prune_changelog` (gc.rs:202) has no caller ✓ |
| F-S01-1 | 9 | 9 | — |
| F-S11-1 | 9 | 9 | sibling boxes/gallery.js:167-169 ✓ |
| F-S10-1 | 8 | 8 | activesupport-8.1.3.1 cache.rb:1123 ✓ |
| F-S10-2 | 7 | 7 | view.html.erb:64-101: the chain ends :102 (drift 1) |
| F-S15-1 | 10 | 10 | `dirs_without_tiles` is :632-642 (cited :633-644, drift 1-2) |
| F-S15-2 | 15 | 15 | spec §10.9 = content-blocks-design.md §10 item 9, :234-241 |
| F-S05-1 | 4 | 4 | EXPLAIN plans not re-run (constraint) |
| F-S05-2 | 7 | 7 | 8 write sites counted exactly |
| F-S06-1 | 7 | 7 | exactly 6 hand-built `ProjectIntake::Result.new` in project_scan_button_test ✓ |
| F-S08-1 | 10 | 10 | — |
| F-S08-2 | 6 | 6 | **COUNT**: "15 literal "ready" checks" = 15 grep lines, but 3 are not checks (application_helper.rb:50 comment; files_controller.rb:486 and public/files_controller.rb:141 *emit* "ready"), so 12 comparisons. "5 `pending processing` literals across views/helpers/controllers" = 4 in views (_static:20, show:98, _thumb:28, _measure:172) + 1 in a **service** (enqueue.rb:95) |
| F-S03-1 | 15 | 15 | drift: `#undelete` cited :704-786 but ends :779 (:784-788 is `listing_prefix`); `#delete` cited :480-517 but :515-518 are the next method's header; share.rb:694-714 def ends :712 |
| F-S03-2 | 7 | 7 | aws-sdk-s3 1.229.0 (= Gemfile.lock) types.rb:3177-3179 ✓ |
| F-S09-1 | 13 | 13 | `showPoster` cited :141-150, method is :137-149 (drift 4) |
| F-S02-1 | 11 | 11 | "phase-2b plan" = docs/superpowers/plans/2026-07-16-file-layer-share-phase2b.md (found by grep; no path given) |
| F-S02-2 | 7 | 7 | — |
| F-S14-1 | 13 | 13 | all seven `hidden_*` filter sites ✓ |
| F-S13-1 | 11 | 11 | **AMBIGUOUS**: a bare "(`:103`)" follows a local_repo.rb cite and means local_repo.rb:103 (`full_status`); repo_commits_controller.rb:103 is an unrelated comment. Write `local_repo.rb:103` |
| F-S13-2 | 8 | 8 | 16 tests in commit_paths_test.rb ✓ |
| F-S16-1 | 6 | 6 | vendored bundle gates and dispatcher ✓ |
| F-S16-2 | 6 | 6 | sibling projects.js:424/:432 ✓ |
| F-S19-1 | 13 | 13 | — |
| F-S20-1 | 9 | 9 | "four commits" given without SHAs, so not checkable |
| F-S20-2 | 6 | 6 | — |
| F-X-1 | 11 | 11 | **SCOPE ITEM DOES NOT EXIST**: "the LibraryOutput tests that assert `broadcast: false`". No file under test/ mentions `broadcast:` (grep hits are prose only: cable_absent_test.rb:7, chunk_remote_journey_test.rb:330, attach_auto_move_test.rb:541/:631). Also, `broadcast:` is accepted ONLY by ChunkRemote#finalize_upload: share.rb:322 and s3.rb:400 are `def finalize_upload(_user, commit_id: nil, verify: true)`. So "drop both kwargs from the three adapters" is true for `device:` only |
| F-S17-1 | 7 | 7 | **SCOPE LABEL WRONG**: "optional prose in … `tinkerex.rake:41`". Line 41 is code, `email = ENV["DEMO_ACCOUNT_EMAIL"].to_s.strip.downcase` (a raw ENV read). The nearest prose is :36-38 |
| F-S07-1 | 5 | 5 | 11 scope line ranges all resolve |
| F-S07-2 | 10 | 10 | fdaa2660 exists; "the detach link left" detail not re-derived |
| F-S21-1 | 6 | 6 | projects_flow_test.rb:595-608: the test starts :597 (drift 2) |
| F-S21-2 | 12 | **11** | **MISMATCH (below)** |
| F-S18-1 | 8 | 8 | architecture_invariants_test.rb:957 matches only thematically (the passage is about NotImplementedError) |
| F-S22-1 | 8 | 8 | **COUNT**: "existing o3dv (11 cases)" but o3dv_test.rb has 12 `test "` blocks |
| F-S23-1 | 6 | 6 | 10 `node_id` + 11 `*_node_id` columns ✓ |
| F-S23-2 | 8 | 8 | — |
| F-S24-1 | 6 | 6 | solid_queue 1.7.0 `limits_concurrency(…, group:)` ✓ |
| F-S24-2 | 10 | 10 | INSTALL.md:383 "The derived databases must exist." ✓ |
| F-S25-1 | 9 | 9 | I re-ran the preflight-vs-test diff (comments and indentation stripped, process substitution): IDENTICAL |
| F-S25-2 | 10 | 10 | commit bodies 39c29535 / cb50a9f0 ✓ |
| F-S26-1 | 7 | 7 | — |
| F-S26-2 | 7 | 7 | activerecord-8.1.3.1 databases.rake:22/:553 ✓ |
| F-S28-1 | 7 | 7 | 8ec505c1 removed bin/split-status ✓ |
| F-S28-2 | 6 | 6 | — |
| F-S29-1 | 8 | 8 | — |
| F-S29-2 | 5 | 5 | **not checkable**: resvg-0.47.0's published caret ranges (no local cargo registry copy) |
| F-S27-1 | 7 | 7 | **COUNT**: "90 direct `FileLayer.current =` sites in 45 files". I count 89 non-comment lines in 45 files (92 including comments), within ±1. 158 resets exact |
| F-S27-2 | 9 | 9 | "23 private copies" / "13 suites" not re-derived |
| F-S12-1 | 8 | 8 | sibling fields.js:130/:136 and openscad.js:175 ✓ |
| F-S12-2 | 7 | 7 | no catalog .scad contains a needle ✓ |

**The one hard mismatch, F-S21-2.**
- The entry claims: "both writable adapters' `write` raise `NotFound` for single-file conditions
  (Share: over `MAX_BYTES` `:101`, …)".
- share.rb:100-101 actually reads `size = File.size(path)` and
  `raise NotFound, "file exceeds #{MAX_BYTES} bytes" if size > MAX_BYTES`. That is inside **Share#read**
  (`live_node!` at :90), not write.
- The write-side oversize refusal is `read_capped!` at **share.rb:829-831**, called from `write` at :256.
- The claim is true; the line is wrong. Replace `:101` with `:829-831 (read_capped!, from write :256)`.

**Scope files.** Every existing file named in a "Smallest scope" field exists at HEAD (I checked each
basename against `git ls-files`). The files proposed as NEW are absent, as intended:
`app/services/maker/content_read.rb`, `app/jobs/maker/library_sweep_job.rb`,
`lib/tinkerex/deploy_secrets.rb`, `lib/ci/leg_runs.rb` (the directory `lib/ci/` does not exist), and
`test/ops_backup_table_test.rb` (named in Validation). The only scope item that is not a real target
is F-X-1's non-existent `broadcast: false` tests.

---

## 3. Validation check

The rule: the Validation field must name at least one EXISTING test (file or locatable test name),
and at least one NEW check with a stated MUTATION that turns it red (§15).

**Totals:** PASS 45, PARTIAL 3, FAIL 1.

| Entry | Existing test(s) named (I verified each exists) | NEW check + mutation stated? | Verdict |
|---|---|---|---|
| F-S04-1 | changelog_sync_test.rb:145 (resync test) | yes (3 mutations; (b)-(f) detailed in the report) | PASS |
| F-S01-1 | factory_test.rb, library_backend_required_test.rb, library_backend_check_test.rb | **no**: "each with a named mutation" names none | **PARTIAL** |
| F-S11-1 | described only ("destination/revise/origin"). I located addon_destination_test.rb, addons_controller_test.rb:578-603, addon_origin_test.rb | yes (4) | PASS (name the files) |
| F-S10-1 | described only ("parser-nil cache tests"). I located gerber_archive_test.rb:259, three_mf_manifest_test.rb:310 | yes (2) | PASS (name the files) |
| F-S10-2 | gerber_preview, public_file_view, files_flow, files_controller_preview_kind, page_query_budget | yes | PASS |
| F-S15-1 | project_attachments_test.rb:711, project_page, page_nodes, page_query_budget | yes (4) | PASS |
| F-S15-2 | project_blocks_test.rb:166, project_tabs_test.rb:167 | yes | PASS |
| F-S05-1 | described only. reconciler_test.rb is named in Scope | yes (2) | PASS (name the file) |
| F-S05-2 | reconciler_test.rb, s3_observer_test.rb | yes (4) | PASS |
| F-S06-1 | project_intake, project_folder_intake, project_upload_attach, project_scan_button, project_intake_job | yes | PASS |
| F-S08-1 | enqueue_test, inspector_test.rb:110, maker_page_thumbnails, thumbnail_map, missing_backfill, previews_renderer_revision | yes (3) | PASS |
| F-S08-2 | enqueue_test:93, thumbnail_map_test:244, lbrn_geometry_test:215, previews_renderer_revision_test:96-97 | yes (2) | PASS |
| F-S03-1 | s3_test, adapter_mutation_contract, s3_write_test, s3_library_test, trash_purge_job_test | yes (4) | PASS |
| F-S03-2 | s3_test, object_identity_test | yes (5) | PASS |
| F-S09-1 | measure_print_test.rb:2678/:2809/:3117; recipe gerber_test.rb:331 | yes (3) | PASS |
| F-S02-1 | share_test, share_trash_test, adapter_mutation_contract, s3_test | yes (2) | PASS |
| F-S02-2 | share_test (move), mutation and write contracts | yes (3) | PASS |
| F-S14-1 | public_project, public_bundle, bom_csv, page_query_budget | yes (5) | PASS |
| F-S13-1 | repo_edit_flow_test, local_repo_test, system repo_staging, repo_editor | yes (2) | PASS |
| F-S13-2 | commit_paths_test (16), repo_edit_flow, repo_staging | yes | PASS |
| F-S16-1 | sheet_grid_test.rb:50 | yes (3) | PASS |
| F-S16-2 | project_bom_test.rb:229-234 | yes (1 explicit; the rest "named per test") | PASS |
| F-S19-1 | inventory_test, inventory_transaction_test, behavioral_edges, structural_orphan, v1 inventory_items_test | yes (3) | PASS |
| F-S20-1 | shell_test :23/:47/:80/:107, shell_layout_test :93/:127/:217, landing, phone_topbar, css_hygiene | yes (3) | PASS |
| F-S20-2 | where_files_come_from_test, help_page_test | yes (2) | PASS |
| F-X-1 | described only ("existing upload tests"); chunk_remote/upload_test.rb is in Scope | **no**: it states "nothing goes red" | **PARTIAL** |
| F-S17-1 | demo_session_test.rb:133, demo_reset_test.rb:163 (+ landing, demo_reset_job, tinkerex_tasks) | yes | PASS |
| F-S07-1 | model_intake_test, project_adoptions_test.rb:351, scan_job_test DiscoveryOrderTest (:594), prune test | yes (3+) | PASS |
| F-S07-2 | model_intake, model_intake_classify, models_catalog, model_folder, project_adoptions | yes (several) | PASS |
| F-S21-1 | project_folder_intake, topbar_upload_test:66, system topbar_upload, project_upload_attach_test:80-88, demo_guards_test:236-262, entry_photos | yes (2) | PASS |
| F-S21-2 | upload_batch_test (11 tests), project_upload_attach_test:44-78, demo_guards_test:202-262, files_flow, s3_write_test:70-90 | yes (3) | PASS |
| F-S18-1 | described only ("every existing v1 422 test"), in test/integration/v1 | yes | PASS (name one file) |
| F-S22-1 | o3dv_test (12 tests, not 11), files_flow, models_flow, public_file_view, lazy_bundles | yes (3+) | PASS |
| F-S23-1 | schema_map_test, structural_orphan_test | yes (5) | PASS |
| F-S23-2 | v1 file_attachments/projects/items tests, legacy_columns_dropped_test, SchemaMapTest | yes (2) | PASS |
| F-S24-1 | scan_job_test (DiscoveryOrderTest/IntakeOrderTest), concurrency_limits_test, recurring_schedule_test, boot_scan_test | yes (4) | PASS |
| F-S24-2 | cable_absent_test, schema_map_test | yes | PASS |
| F-S25-1 | deploy_hygiene_test :690/:733/:747/:871/:879 | yes (2) | PASS |
| F-S25-2 | **none can exist** (§14i: nothing in bin/ci covers ops/) | yes (2) | **PARTIAL (structural)** |
| F-S26-1 | ci_hygiene_test:134-155, importmap_audit_test:109, bin_sync_server_test:67 | yes (3) | PASS |
| F-S26-2 | ci_hygiene_test :134-155/:168/:188 | yes (3) | PASS |
| F-S28-1 | **none in the field** ("`git grep` … ; bare `bin/ci`") | **none in the field** (Scope carries one) | **FAIL** |
| F-S28-2 | log_cli_test.rb (9 anchors, all resolve) | yes (3) | PASS |
| F-S29-1 | gerber_test.rb's existing cases | yes (2) | PASS |
| F-S29-2 | svg_rasterizer_test, gerber_test, stl_test | yes (6) | PASS |
| F-S27-1 | fresh_share_library_cleanup_test.rb:81-89 | yes (2) | PASS |
| F-S27-2 | attach_from_files_test:44-49/:89-98, public_project_test:28-37 | yes | PASS |
| F-S12-1 | boxes tests/test_api.py `test_generators_shape` (:18), openscad schema/coerce tests | yes (2) | PASS (pytest, not in bin/ci; the entry says so) |
| F-S12-2 | deploy_hygiene_test.rb catalog block :491-518 + the kept Python tests | yes | PASS |

Suggested text for the four that are not PASS:
- **F-S01-1.** Copy the four mutations from reports/S01.md:98-101:
  - (a) `configured` returns `raw` unvalidated → red.
  - (b) revert `boot!` to `required_in_production!` + `check!` → the unknown-in-production case goes red.
  - (c) restore the initializer's two old calls → the static wiring pin goes red.
  - (d) drop an arm from `FileLayer.build`'s `case` → the NAMES-vs-factory test goes red.
- **F-X-1.** "NEW: a web `begin_upload`/`finalize_upload` on chunk_remote, and an addon save, leave
  `Device.count` unchanged. Mutation: restore `device: web_device` / `addon_device(user)` → red."
  This turns "nothing can see a reader-less kwarg" into a check on the side effect the entry
  actually complains about (a `devices` row minted for nothing).
- **F-S28-1.** Move the guard from Scope into Validation: "Existing: test/ci_hygiene_test.rb:562 (its
  `bin/*` surface stays non-empty). NEW: no tracked file except bin/log (and test/) names Kaneo's write
  endpoints `/api/task`, `/api/label`, `/api/comment`; non-vacuous because it also asserts bin/log
  matches. Mutation: restore bin/migrate-record → red."
- **F-S25-2.** Name test/deploy_hygiene_test.rb as the existing pattern the new
  `test/ops_backup_table_test.rb` copies (it already reads the merged config through
  `Kamal::Configuration.create_from`). State the absence of an existing gate as the finding itself.

---

## 4. Inventory check (§1)

**Field presence.** S01–S29 each carry Boundary / Interfaces / Tests / Status. The exceptions:
- **S23** (L155): no "Interfaces/call sites" line. It has "Review question for this row" instead.
  Suggested line: "Interfaces/call sites: `SchemaMap::EDGES` / `#problems` / `#edges`, read by
  `StructuralOrphanTest`, `TenantCleanupTest`, `rake schema_map` and the stale-page test; `db/schema.rb`
  as the input every model reads."
- **S30, S31** (skip rows; also S35, added later): Boundary + Status only, with no Interfaces and no
  Tests. That is acceptable for skips only if you say so in §1's header, which currently implies every
  row carries the four lines.
- **S27** (L179) Tests: "n/a (the harness itself)" is vague. Its own boundary holds guard tests:
  test/worker_budget_test.rb, page_query_budget_test.rb, and test/fresh_share_library_cleanup_test.rb
  (which F-S27-1's validation uses).
- **S26** Tests: "the four guard tests above…" is self-referential but sufficient.

**Status terminal.** S01–S31 are all terminal (29 recommend, 2 skip). In the current file, **S32, S33
and S34 are "in review (batch 5)", which is non-terminal**; they were added during this pass. S35 is
skip. §6 must wait for batch 5, or record it as pending.

**Row ↔ entry bidirectionality** (parsed programmatically):
- Every finding ID named in a row's Status exists in §2 (none dangling).
- Every §2 entry's Authoritative row lists that ID, **except F-X-1**. It has no "Authoritative row:"
  line ("Raised by: S20 … Authoritative owner proposed: S01"), its heading says "owner S01", and **no
  row's Status lists F-X-1**. S01's says "(1 finding, F-S01-1)".
  - Fix: S01 Status becomes "recommend (2 findings, F-S01-1, F-X-1)".
  - Fix: F-X-1's first line becomes "Authoritative row: S01 (call sites S21, S11, S20)".
- The finding totals agree: 48 row-owned entries + F-X-1 = 49.
- Co-owner rows whose Status does not mention the shared finding (informational, not errors):
  - S19 for F-S16-2's `InventoryItem` hook.
  - S06 for F-S07-1's public reader.
  - S03 for F-S02-1's same-slice S3 change.
  - S05/S06/S07 for F-S24-1's step jobs.
  - S25 for F-S12-2's Ruby test.
  - S11/S20/S21 for F-X-1's call sites.
  - S29/S26 for the ensure-resvg split.
- **No §2 entry names a skip row** as its Authoritative row.

**§3 is empty** ("rows whose review cleared nothing…" with no rows under it), while S30, S31 and S35
have Status skip and §7 says "2 explicit skips (S30, S31)". Either list them in §3 or delete §3.

---

## 5. Consistency check

**Confidence vs evidence**

| ID | Entry text | Inconsistency |
|---|---|---|
| CF-1 | F-S02-1: "Confidence: high that (a)-(c) are live defects" | The same entry heads its complexity "(traced, not run; no test puts a tombstone inside a later-deleted folder)". Suggest "high on the mechanism (traced statement by statement); unreproduced". |
| CF-2 | F-S14-1: "high on (a)-(d)" | The entry heads them "(traced, not reproduced)". Same fix. |
| CF-3 | F-S03-1: "high that (a)-(c) are real and reachable on the deployed s3 backend" | They were traced through FakeS3. Reachability on the deployed SeaweedFS (markers listed as directories; COPY answering InvalidArgument) was not probed. Suggest "high through FakeS3's wire model; unprobed on the live bucket". |

Borderline but internally acknowledged, so no change needed:
- F-S22-1 says "high on … the mechanism of (b)/(c)" while marking them "read from the engine, not
  driven". Its validation already says to run (1)-(3) first.
- F-S07-1 says "high" with "the chunk_remote race is reasoned". The cap hole that carries the
  finding is deterministic.

**Effort vs scope**

| ID | Stated effort | Assessment |
|---|---|---|
| EF-1 | F-S27-1 "Effort: trivial" | Understated; suggest "small". The scope is test_helper (~5 lines) plus a new harness guard test, deleting 6 pin lines, the README, and "fix the ~16 now-false comments" across files, plus timing the s3 leg before and after. |
| EF-2 | F-S29-2 "Effort: small" | Understated; suggest "small-medium". The 5-step ordered scope includes a CI image rebuild and redeploy, a PNG byte comparison between old and new images, and possible THUMBNAIL_REVISION bumps. |
| EF-3 | F-S08-1 "Effort: small" | Borderline; suggest "small-medium". It touches 6 files owned by 3 rows (enqueue.rb, thumbnail_map.rb, missing_backfill.rb, files_controller.rb at two sites, public/files_controller.rb, measure-view.md) plus 3 new request tests. |
| — | F-S23-2 "Effort: small" | Accurate per release, but it is a two-release change. Say "small ×2 releases". |

**Priority/dependency vs §5 (and §4)**
- **C-1, F-S03-1.** §5 says F-S03-1 and F-S02-1 "must land as one slice", and that F-S03-1's undelete
  membership rule is SUPERSEDED by F-S02-1's recorded membership. F-S03-1's entry never mentions
  F-S02-1 or §5. Its Proposed representation and Scope still say undelete "revives top-down as Share
  does" / "mirroring `share.rb:694-714`", which is exactly the existence-at-rebuilt-key inference §5
  supersedes. Add "Superseded in part by F-S02-1 (§5): membership comes from `trash_root(_node)_id`;
  same slice" to its AR line and its Priority.
- **C-2, F-S02-1.** Its own S23 verdict (1) renames the column to `trash_root_node_id`. The title,
  the Proposed representation, the coordinator note and §5 all still say `trash_root_id`. Pick one
  name across all four places.
- **C-3, F-S10-2.** §5 records S14's refinement: the zip-archive arm should drop a nil URL
  (`.compact`/`filter_map`) so files-preview.md:222-227's "absent layer on both arms or on neither"
  holds for all three arms. F-S10-2's Proposed representation and Validation do not carry it.
- **C-4, F-S10-1.** §4's S14 note says the anonymous public file page can trigger the poisoning,
  "Raises F-S10-1's priority". F-S10-1 has no priority line and no reciprocal "land before F-S10-2"
  (F-S10-2 states that dependency).
- **C-5, F-S19-1 / F-S16-2.** §5 counts S18's Opportunity 1 under these two entries. §4 records two
  S18 refinements the entries contradict:
  - F-S19-1 needs `on: :create` so the immutability test keeps raising ReadOnlyRecord. The entry's
    Risks instead proposes rewriting inventory_transaction_test.rb:57.
  - F-S16-2: §4 says "the owner picks the shape" (S18's reader override vs S16's callback). The
    entry says the reader override was "weighed and rejected".
  Reconcile both texts, and credit S18 in each entry.
- **C-6, F-S29-2 / F-S26-2.** §5 (and the new §1 tie-break) give the two `ci.yml` steps to F-S26-2
  and the script to F-S29-2. F-S29-2's Scope step (4) still deletes `ci.yml:218-219,231-232`.
  F-S26-2 has no pointer to F-S29-2/§5, and its "keep as a manual Mac helper" option contradicts
  §5's "F-S29-2 deletes the script".
- **C-7, F-S07-1.** F-S07-2 ("Dependency: F-S07-1 first") and F-S24-1 ("Dependency: after F-S07-1")
  both depend on it, but F-S07-1 has no "prerequisite for F-S07-2 and F-S24-1" note.
- **C-8, F-S09-1.** F-S22-1 says "Sibling of F-S09-1 (share the Turbo-Back test helper)", and the
  helper (test/system/support/web_helpers.rb) is only in F-S22-1's Scope. F-S09-1's new test (2)
  needs the same helper, but F-S09-1 has no reciprocal note.
- **C-9, §4.** Two items are stale against §5:
  - "(S01 + S06 reports, CONVERGENT, candidate cross-cutting finding — owner to be fixed after S07/S24
    report)" is resolved per §5 into F-S07-1 and F-S24-1.
  - "(S01 report) Three recurring jobs carry the inverse gate … Candidate for S05/S06/S07" is now
    F-S24-1.
  Mark both "RESOLVED → F-S07-1 / F-S24-1".
- **C-10, F-S26-2 → F-S01-1.** F-S26-2 says "the split already misled one reader in THIS audit
  (F-S01-1's validation note assumed CI does a development boot)". That claim lives only in
  reports/S01.md:85, not in the AUDIT.md entry. F-S01-1's new test (c) (a static initializer pin)
  already supplies what F-S26-2 asks for. Say so in F-S26-2, or add one line to F-S01-1: "dev-boot
  validation comes from test (c), not from `db:test:prepare` (see F-S26-2)".
- **C-11, F-S26-1 Risks.** The new `lib/ci/leg_runs.rb` sits under Zeitwerk's lib root
  (config/application.rb:24 ignores only assets/tasks/generators/library_backend.rb; there are no
  custom inflections), so it must define `Ci::LegRuns`. The entry calls it `LegRuns.parse`. CI
  eager-loads (config/environments/test.rb:40, `config.eager_load = ENV["CI"].present?`), so a
  top-level `LegRuns` there is a Zeitwerk::NameError in CI. F-S25-1 records the identical risk for
  its own new lib file; F-S26-1 should too.

---

## 6. Gap list (by entry)

| Entry | Field | Gap | Suggested text |
|---|---|---|---|
| F-S04-1 | PD | none | "Priority: low-medium (resync is unreachable until tinkerex-sync schedules `prune_changelog`, gc.rs:202, which has no caller); no dependency; land before any prune is scheduled." |
| F-S01-1 | Validation | mutations not stated | the four from S01.md:98-101 (see §3) |
| F-S01-1 | PD | none | "Prerequisite for F-S17-1's optional `Demo.validate!` and F-S18-1's boot-time move of the `FileLayer.build` producer." |
| F-S11-1 | PD | none | "No dependency (additive migration); independent of F-S23-2." |
| F-S11-1 | Validation | existing tests described, not named | name addon_destination_test.rb, addons_controller_test.rb:578-603, addon_origin_test.rb |
| F-S10-1 | PD | none (§4 raises it) | "Priority: raised: an anonymous public GET can poison the owner's cache (§4, S14 note). Land before F-S10-2." |
| F-S10-1 | Validation | existing tests described | name gerber_archive_test.rb:259, three_mf_manifest_test.rb:310 |
| F-S10-2 | Representation/Validation | §5 S14 refinement missing | "zip-archive arm drops a nil URL (`filter_map`) like the other two layer arms" + a public-zip assertion |
| F-S15-1 | PD | none | "Sibling of F-S14-1 (same painted-set drift, different files); independent." |
| F-S15-2 | PD | V (decision note only) | add "Priority: medium; needs the owner's yes to revise spec §10.9" |
| F-S05-1 | PD | V (ownership only) | "Land before or with F-S05-2 (both touch reconciler.rb:605)." |
| F-S05-1 | Validation | existing tests described | name test/services/library/reconciler_test.rb |
| F-S06-1 | PD | none | "Independent; coordinate with F-S24-1, which edits ProjectIntakeJob." |
| F-S08-2 | Evidence | count wording | "12 `status == "ready"` comparisons (+2 emitters, 1 comment); 4 `%w[pending processing]` in views + 1 in enqueue.rb:95" |
| F-S03-1 | AR / Representation / PD | §5 amendment absent; superseded mechanism still described | see C-1 |
| F-S03-1 | Confidence | "high … reachable on the deployed s3 backend" vs traced-only | see CF-3 |
| F-S09-1 | PD | none | "Sibling of F-S22-1: share test/system/support/web_helpers.rb's Turbo-Back helper; whichever lands first adds it." |
| F-S02-1 | Representation | column name conflicts with its own S23 verdict | adopt `trash_root_node_id` throughout (title, representation, coordinator note, §5) |
| F-S02-1 | Confidence | "high … live defects" vs "traced, not run" | see CF-1 |
| F-S14-1 | Confidence | "high on (a)-(d)" vs "traced, not reproduced" | see CF-2 |
| F-S13-1 | Evidence | ambiguous ":103" | write `local_repo.rb:103` |
| F-S13-1 / F-S13-2 | PD | none | "Independent of each other (different files)." |
| F-S16-1 | PD | none | "Owner decision first (persist sorts/drags, or disable them); otherwise independent." |
| F-S16-2 | PD | V | "Needs S19's agreement (inventory_item.rb); credit S18's co-sign; owner picks reader-override vs callback (§4)." See C-5 |
| F-S19-1 | Risks | §4/S18 `on: :create` refinement not reconciled | "validate `delta` `on: :create` so the immutability test at :57 keeps raising ReadOnlyRecord (S18)", or state why the test edit is preferred |
| F-S20-1 / F-S20-2 | PD | none | "Independent; low/medium." |
| F-X-1 | AR | no "Authoritative row:" line ("proposed") | "Authoritative row: S01 (call sites S21, S11, S20)" + add F-X-1 to S01's Status |
| F-X-1 | Scope | non-existent "LibraryOutput tests that assert `broadcast: false`"; `broadcast:` exists only on ChunkRemote | strike the test item; "drop `device:` from all three `begin_upload`s and `broadcast:` from ChunkRemote#finalize_upload" |
| F-X-1 | Validation | no red-turning check | the `Device.count` test (§3) |
| F-X-1 | BR | missing | "Blast radius: the port signature (3 adapters) + 2 callers + ApplicationController + CLAUDE.md §14a." |
| F-X-1 | PD | missing | "Priority: low; no dependency." |
| F-S17-1 | Scope | `tinkerex.rake:41` is code, not prose | "tinkerex.rake:41 (the demo_email lambda's raw ENV read) / :36-38 prose" |
| F-S17-1 | PD | V | "Follow-on depends on F-S01-1; the main change needs the owner's direction call." |
| F-S07-1 | PD | V | "Prerequisite for F-S07-2 and F-S24-1." |
| F-S21-1 / F-S21-2 | PD | none | "Both rewrite projects/uploads_controller.rb: land F-S21-1 first (one-target controller), or together." |
| F-S21-2 | Evidence | share.rb:101 is Share#read | `share.rb:829-831` (`read_capped!`, from write :256) |
| F-S18-1 | PD | V | "After F-S01-1 the `FileLayer.build` producer moves to boot; independent otherwise." |
| F-S18-1 | Validation | existing tests described | name one, e.g. test/integration/v1/maker/inventory_items_test.rb |
| F-S22-1 | Validation | count | "o3dv (12 cases)" |
| F-S23-1 | PD | none | "Land before or with F-S02-1 (its new node-id column must be drawn; F-S02-1's S23 verdict (3))." |
| F-S24-2 | Scope | no Smallest-scope field | "Smallest scope: config/cable.yml (production → `adapter: async`); config/database.yml :116-119, :132-135; delete db/cable_schema.rb; Gemfile:50; lib/schema_map.rb SOURCES/LAYOUT + regenerate; INSTALL.md :268-269/:383; CLAUDE.md §4; optional ops/backup-db.sh:229." |
| F-S25-2 | PD | none | "Independent of F-S25-1; medium." |
| F-S25-2 | Validation | no existing test (structural) | see §3 |
| F-S26-1 | Risks | Zeitwerk constant for lib/ci/leg_runs.rb | see C-11 |
| F-S26-2 | PD / Scope | no pointer to F-S29-2 / §5 split | "Owns the two ci.yml steps; F-S29-2 owns the script (§5)" |
| F-S28-1 | Validation | no existing test, no mutation in the field | see §3 |
| F-S28-2 | PD | none | "Independent of F-S28-1; medium (outage-path record loss)." |
| F-S29-1 | PD | V | "S08 decides whether exit 3 maps to Unsupported; otherwise independent." |
| F-S29-2 | Scope | still deletes the ci.yml steps §5 gives to F-S26-2 | drop `ci.yml:218-219,231-232` from step (4) and point to F-S26-2 |
| F-S29-2 | Effort | understated | see EF-2 |
| F-S27-1 | PD | none | "Land early: F-S17-1's new test assigns `FileLayer.current = FileLayer::ChunkRemote.new` directly, which is exactly the leak this fixes. F-X-1/F-S18-1's stub-adapter tests likewise." |
| F-S27-1 | Effort | understated | see EF-1 |
| F-S27-2 | PD | V | add a priority |
| F-S12-1 | PD | none | "Independent of F-S12-2; needs both sidecar images republished; low." |
| F-S12-2 | PD | V | "Coordinate with S25 (deploy_hygiene_test.rb); low." |
| §1 S01 / F-X-1 | Status | F-X-1 is unlisted | "recommend (2 findings, F-S01-1, F-X-1)" |
| §1 S23 | Interfaces | missing | see §4 |
| §1 S27 | Tests | "n/a" | see §4 |
| §1 S32–S34 | Status | non-terminal (batch 5) | resolve before §6 |
| §3 | — | empty despite 3 skip rows | list S30, S31, S35, or drop the section |
| §4 | — | two stale "candidate" items | see C-9 |

**Count summary (49 entries, 13 fields each):**
- Fully complete (all 13 fields S): **18**. They are F-S10-2, F-S05-2, F-S08-1, F-S08-2, F-S03-1,
  F-S03-2, F-S02-1, F-S02-2, F-S14-1, F-S19-1, F-S07-2, F-S22-1, F-S23-2, F-S24-1, F-S25-1, F-S26-1,
  F-S26-2, F-S29-2. Three of these (F-S03-1, F-S02-1, F-S14-1) still carry consistency issues from §5.
- At least one vague field: **13**. Eleven are vague-only: F-S15-2, F-S05-1, F-S16-2, F-S17-1,
  F-S07-1, F-S18-1, F-S29-1, F-S27-2, F-S12-2, F-S24-2, F-S28-1. Two also have a missing field:
  F-S01-1 and F-X-1.
- At least one missing field: **20**. In 19 of them the missing field is PD alone; F-X-1 is missing
  both BR and PD.
- At least one citation mismatch: **1 hard** (F-S21-2). Also 2 mis-described scope items (F-X-1,
  F-S17-1) and 3 count claims slightly off (F-S08-2, F-S22-1, F-S27-1 within ±1).
- Validation: **1 FAIL** (F-S28-1), **3 PARTIAL** (F-S01-1, F-X-1, F-S25-2), 45 PASS. Four of the
  PASSes (F-S11-1, F-S10-1, F-S05-1, F-S18-1) name their existing tests only by description; I located
  each by grep and give the file names in §3.

---

## What I could not check

- **Nothing was executed.** No tests, rails, ruby or sqlite3, so every "RED today" and every
  "mutation reddens X" claim is unverified; I checked only that the named tests exist and that the
  cited code supports the mechanism. That includes F-S06-1's "deleting :849 reddens only the
  board-zip test" and F-S05-1's EXPLAIN plans (the reviewer's and coordinator's in-memory sqlite runs
  were not repeated).
- **F-S29-2**: resvg-0.47.0's published Cargo.toml caret ranges (`tiny-skia = "0.12.0"`,
  `usvg = "0.47.0"`). There is no local cargo registry copy and I fetched nothing from the network.
- **Sibling repos** were read at their current local HEADs (tinkerex-sync b849e08, tinkerex-addons
  d3ab6fd, tinkerex-client 399ccdb). If those checkouts moved since the reviewers read them, those
  three citations reflect today's checkout.
- **Not re-derived**: "four commits edited both copies together" (F-S20-1, no SHAs), "≥16 files
  re-explain" (F-S27-1), "23 private copies" / "13 suites" / "~6 assert the redirect" (F-S27-2),
  "~20 plan files" (F-S26-1), "~120 unverified sites", and the detach-link history behind fdaa2660
  (F-S07-2). Commit messages: subject lines checked for every cited SHA; bodies checked only for
  39c29535, cb50a9f0 and 8ec505c1's stat.
- **Report files** (reports/S*.md) were consulted only where an entry defers to them: S01.md's
  validation section and S26.md's note about S01. I did not audit the reports themselves.
- **S32–S34**: their batch-5 reviews were in flight, so any F-entries they produce are not covered here.
- **Operational note.** Early in this pass a `find /` of mine overran its timeout. To stop it I ran
  `pkill -x find`, which would also have terminated any other `find` process under this user at
  that moment (around 16:40). If a sibling pass saw a `find` die then, this was the cause. No repo
  file was touched.


---

## Appendix A — per-entry citation ledger (as checked at HEAD 75124d67)

### F-S04-1
- changelog_sync.rb:166 OK (`upsert(n, deleted: false)`, no version:) | :213-231 OK (`version ||= payload["version"]` :222, `@current_manifest` :230) | docs/sync-protocol.md §8.4 OK (:663-686, flat version_id/size/manifest) | changelog_sync_test.rb:148-150 OK (nested "version") | sibling ../tinkerex-sync (HEAD b849e08) services/tree.rs:11 TreeNode flat OK; `prune_changelog` (gc.rs:202) has no .rs caller OK. 6/6.
- scope files exist: changelog_sync.rb, changelog_sync_test.rb.
- validation: existing resync test (changelog_sync_test.rb:145 "a cursor below oldest_seq triggers a FULL RESYNC") + mutations named -> PASS (new tests (b)-(f) deferred to report, mutations listed).

### F-S01-1
- file_layer.rb:169 OK | :203 OK | library_backend_check.rb:107 OK | :126 OK (line inside required_in_production! def at :123) | initializer no-arg calls OK | lib/library_backend.rb:18 DEFAULT="chunk" OK; zero app/lib/config callers OK (comments + require only); 3 test call sites OK (uploader_test:49, upload_test:91, mutation_contract_test:96) | registration.rb:47 OK | commits 0fd8c8e0, 287ddac5 exist OK | scope config/application.rb:9-14,24 OK. 9/9.
- validation: existing factory_test.rb / library_backend_required_test.rb / library_backend_check_test.rb exist; mutations NOT stated in AUDIT ("each with a named mutation") -> PARTIAL; report S01.md:87-101 has them.

### F-S11-1
- library_output.rb#upsert_file! :113-117 OK, quoted comment at :107-108 OK (upper-case in source) | addon_state.rb:23 OK | addons_controller.rb#latest_output_folder :672, ORDER at :682 OK | destination_from_outputs rows.first :651-660 OK | #states :271-275 OK | docs/addon-api-v1.md:626-627 OK | files/_meta.html.erb:17 + projects/_generated_group.html.erb:49 print state.revision OK | addons_controller_test.rb:603 `[0, 0]` OK | sibling tinkerex-addons (HEAD d3ab6fd) addons/boxes/gallery.js:167-169 workaround comment OK. 9/9.
- scope files exist (library_output.rb, addon_state.rb, addons_controller.rb); "two doc lines" unnamed.
- validation: existing tests named generically ("destination/revise/origin") but locatable: test/controllers/tools/addon_destination_test.rb, addons_controller_test.rb:578-603 revise tests, test/services/maker/addon_origin_test.rb; 4 mutations stated -> PASS (suggest naming the files).

### F-S10-1
- gerber_archive.rb#for :83-91 / read :93-97 rescue-inside-fetch OK | three_mf_manifest.rb#for :86-94 / read :99-106 OK | activesupport-8.1.3.1 cache.rb:1123 `write(...) unless result.nil? && options[:skip_nil]` OK (mise gem dir) | production.rb:109 :solid_cache_store OK | test.rb:47 :null_store OK | addons/registry.rb:159-161 OK | GerberArchive no banner / ThreeMfManifest :102 banner OK | project_intake.rb:531-534 OK. 8/8. No `skip_nil` anywhere in app/lib/config OK.
- scope: gerber_archive.rb:83-97 OK, three_mf_manifest.rb:86-107 OK, current.rb:10-13 OK (setter list), files-preview.md:171,518 OK; content_read.rb is NEW (does not exist, as intended).
- validation: existing tests named generically ("parser-nil cache tests") but locatable: gerber_archive_test.rb:259, three_mf_manifest_test.rb:310 ("…read once per content token, nil included"); 2 mutations stated -> PASS (suggest naming the files).

### F-S10-2
- files_controller.rb#show :510 OK, :537-575 OK | public/files_controller.rb#view :46 OK, :57-74 OK | files/show.html.erb:119 + :147-148 OK | public/files/view.html.erb:73 + :82-83 OK | #show:522 provisional @kind + :539 override OK | file_preview.rb:1-4 OK | "no public zip/3MF test": public_file_view_test.rb has none; grep hits in public_project/public_bundle tests are the project-zip bundle, unrelated -> OK. 7/7.
- scope: files/show.html.erb:109-182 OK; public/files/view.html.erb:64-101 OK (chain ends :102, drift 1); files-preview.md:191,200 OK.
- validation: existing tests named (gerber_preview, public_file_view, files_flow, files_controller_preview_kind, page_query_budget) + mutation stated -> PASS.

### F-S15-1
- projects_controller.rb:196 OK | :633-644 dirs_without_tiles OK (def :632-642, drift 1) | union :402-406 OK | project_photos.rb:13 OK | @photo_rows :432 OK | _photos.html.erb:7-9 OK | _folder_panel.html.erb:25-29 OK | comment :626-631 OK | project_page_test.rb:146 repo? note OK | union :396-427 OK. 10/10.
- scope: comments :385-422 OK; project_folder_listing.rb#repo_subtree_ids (:230) single caller (:404) OK.
- validation: existing project_attachments/project_page/page_nodes/page_query_budget + 4 mutations -> PASS.

### F-S15-2
- layout_document.rb#merge:352 OK | :353-357 Publish note OK | :364 block cap OK | :371 dup-tab OK | :376 tab cap OK | from_draft :202-207 OK | panels_controller.rb :55 + held_by_browser :87-90 OK | layouts_controller.rb yaml :24-26 OK, parse :37-39 OK | layout_editor_controller.js :83-84 OK, :32-33 OK, :453 OK, :466 OK | spec 2026-09-09-content-blocks-design.md §10 item 9 (:234-241, "meet at the door" :240) OK. 15/15.
- scope files exist. validation: project_blocks_test.rb:166 + project_tabs_test.rb:167 exist; mutations stated -> PASS.

### F-S05-1
- reconciler.rb:536-537 OK | :605 OK | db/schema.rb:507 only storage_path index, partial deleted=false OK | architecture_invariants_test.rb:1289-1291 "Zero such pairs exist today" OK. 4/4. In-memory SQLite EXPLAIN plans NOT re-run (constraint).
- scope: reconciler.rb, db/schema.rb, test/services/library/reconciler_test.rb exist.
- validation: existing tests named generically (revive/move/kind-change/no-op-constancy) — locatable in reconciler_test.rb (named in scope); 2 mutations stated -> PASS (suggest naming the file in the validation field).

### F-S05-2
- reconciler.rb:59-65 mutable LiveRow OK | :717-727 "FIVE of them … Count them against the code" OK | 8 write sites (live.delete :163,:311,:449,:582,:672; live[...]= :450,:552,:618) OK | 3 LiveRow.new blocks :450,:552,:618 OK | @dir_ids :98,:595,:609 OK | parent_id_for :686 OK | commit 0a160454 OK. 7/7.
- scope: reconciler.rb only (exists). validation: reconciler/s3_observer tests (generic, locatable in test/services/library/) + NEW property test + 4 mutations -> PASS.

### F-S06-1
- project_intake.rb:32 Result OK (+ `initialize(conflict_folders: {}, **)` at :48) | #file_all :722-746 OK (method ends :747; tuple at :737/:746) | #place/dispatch :683-687 + :729 OK | Collision arm :849 + memo :874-878 OK | Result built 4x :428,:441,:455,:473 OK | project_folder_intake.rb#conflict_folder :203-206 OK | commit 521bfb30 OK. 7/7.
- scope: project_intake_test.rb:512 OK; project-intake.md:383-393 OK; project_scan_button_test.rb has exactly 6 ProjectIntake::Result.new (129,156,177,199,226,250) OK.
- validation: existing suites named + NEW + mutation -> PASS.

### F-S08-1
- enqueue.rb:91-98 OK | thumbnail_map.rb:140,:161 OK | files_controller.rb#current_thumbnail :1231-1234 OK | #geometry :479-483 OK | public enqueue_geometry :161-163 OK | missing_backfill.rb:89-109 OK | generate_preview_job.rb:65-70 OK, :90 OK | enqueue.rb:46-57 + measure-view.md:320-333 claims OK | commit c3bc2f57 OK. 10/10.
- scope: enqueue.rb:43-63 OK; other files exist. validation: named suites + NEW request tests + 3 mutations -> PASS.

### F-S08-2
- enqueue.rb:100-117 OK | files_controller.rb#geometry :479-492 OK (+ its "stale blob URL" comment :477-478) | public view enqueues at render (:74) OK | generate_preview_job.rb:90 OK | preview.rb STATUSES :19, no classification predicate OK | 4 commits d5c662c6/cc2340ff/5ce97ac0/f55a7f45 exist OK. 6/6 file:line.
- COUNT ACCURACY: "15 literal "ready" checks" = 15 grep lines in views/helpers/controllers, but 3 are not checks (application_helper.rb:50 is a comment; files_controller.rb:486 and public/files_controller.rb:141 EMIT "ready") -> 12 comparisons. "5 `pending processing` literals across views/helpers/controllers" -> 4 there (_static:20, show:98, _thumb:28, _measure:172) + 1 in a SERVICE (enqueue.rb:95). Totals right in spirit, location/kind wrong.
- scope: show.html.erb:188 OK; enqueue.rb:102-116 OK; measure-view.md:278-291 OK.
- validation pins all resolve: enqueue_test.rb:93, thumbnail_map_test.rb:244, lbrn_geometry_test.rb:215, previews_renderer_revision_test.rb:96/:97; NEW + 2 mutations -> PASS.

### F-S03-1
- s3.rb#delete :480-517 OK (method starts :480; :515-518 are the next method's header comments, drift ~5) | trash_key :842-844 OK | #delete_directory! :528-575 OK (ends ~:571) | :545-546 OK | :532 object set OK | mkdir marker :417, :425 OK | #undelete :704-786 OK-ish (method ends :779, drift 7; :784-788 is `listing_prefix`) | src_key = trash_key(node) :731, destination_vacant!(kind: "file") :761 OK | comment :721-724 OK | phase-2 claim :552-555 OK | share.rb revive_subtree! :694-714 OK (def :694-712) | no S3 folder-restore test (s3_test undelete titles :552-1655 are file-level) OK | adapter_mutation_contract.rb: no folder-restore case (only file restore :154 + orphan refusal :183) OK | trash_controller.rb:121-122 OK | race comment :700-703 OK. 15/15 (3 with end-line drift).
- scope helpers exist: trashable_file! :947 (no caller), "BOTH verbs refuse" :939, FakeS3#fault_after! fake_s3.rb:59.
- validation: named suites + 5 NEW each with mutation -> PASS.
- CONSISTENCY: entry text never mentions F-S02-1 or the §5 amendment; its Proposed representation still says undelete "revives top-down as Share does" / "mirroring share.rb:694-714" — the existence-at-rebuilt-key inference §5 declares SUPERSEDED by F-S02-1's recorded membership. Priority note lacks "same slice as F-S02-1".

### F-S03-2
- s3.rb#move :675-676 OK | #restored_stat :1002 + rescue :1004 OK | #store_identity :1120-1129 OK | b3741f76 exists; its comment ":1107 #restored_stat already take" OK | fake_s3.rb:205 OK | aws-sdk-s3 1.229.0 (= Gemfile.lock) types.rb:3177-3179 CopyObjectResult has :last_modified OK | move comment :669-673 OK. 7/7.
- scope: object_identity.rb, s3.rb ranges, fake_s3.rb:205, s3_test.rb:1080 (retag_copies!) all OK.
- validation: s3_test/object_identity_test named + 5 mutations -> PASS.

### F-S09-1
- measure_controller.js load :125-135 OK | connect :95-118 OK | showPoster :141-150 OK (method :137-149, drift 4) | draw --ready :235 OK | pages/preview.css:234-248 OK | restingStatus :695 OK | "display:none" prose :340-346, :742-746 OK, measure_print_test.rb:3110-3117 OK | gerber_controller.js :78-120 + :195-200 OK | modelviewer_controller.js :80-95 + :216-220 OK | ba5d6119 OK | application.js:2 turbo-rails, no turbo-cache-control in views OK. 13/13 (1 drift).
- scope: measure_controller.js. validation: measure_print_test.rb:2678, :2809, :3117 exist; gerber_test.rb:331 recipe exists; no `go_back` anywhere in test/ (confirmed) -> PASS.

### F-S02-1
- share.rb:422-424 cascade update_all OK | subtree.rb:17-18 OK | revive_subtree! :694-712 OK | trashed :81-82 OK | undelete parent-shape test :554-558 OK | reconciler.rb:161-162 scan tombstone keeps path OK | Node validates only node_id uniqueness (node.rb:6) -> storage_path index unvalidated OK | TrashController rescue_from NotFound :36 / UnsupportedOperation :59 / FetchError :65, no RecordNotUnique OK | trash_purge_job.rb:98-102 OK | ae996173 exists OK | s3.rb:530-532 OK. 11/11. ("phase-2b plan" cited without a path — not checked.)
- scope: share.rb, s3.rb, lib/schema_map.rb (EDGES), trash_controller.rb#restore_refusal_message (:114) exist; migration new.

### F-S02-2
- share.rb:499 OK | comment :440-452 OK | FOLDERS_NOT_YET comment+const :1013-1022 OK (:1014-1022) | subtree.rb:12-15 OK | share_test.rb:860-886 OK (test :860-884) | :not_a_file in attach_to_project.rb OK | s3 movable_file! :948 OK. 7/7.
- scope: share.rb#move, share_test.rb:860-886 exist. validation: share move/mutation/write-contract + NEW + 3 mutations -> PASS.

### F-S14-1
- project_folder_listing.rb:117,127 OK | permits? :456 / claimed? :473 (range :456-481) OK | hidden_file_ids :147-150 OK | hidden_dir_ids :154-157 OK | seven filters :123,:299,:313,:328,:342,:365,:381 all OK | comment :139-146 OK | thumbs :429-431 OK | permitted_cover_ids :491-513 (no layout read) OK | bundle_files :298 OK | bundle_path_for listing.row_for :315 OK | comment :294-296 contradicts :313 OK. 13/13.
- scope: public/projects/_page.html.erb:124-128 OK; docs/superpowers/specs/2026-09-08-folder-panels-design.md:61-64 OK.
- validation: public_project/public_bundle/bom_csv/page_query_budget + 5 NEW each with mutation -> PASS.

### F-S13-1
- repo_commits_controller.rb#show :28-37 OK | local_repo.rb:255-270 (row_for content read + HEAD lookup) OK | full_status :103 (= local_repo.rb:103, a bare ":103" after a local_repo cite — ambiguous; repo_commits_controller.rb:103 is an unrelated comment) OK | binary_paths :200-212 OK | reconcile :121-131 (+ @node_id_by_path :130) OK | node_ids_for :213 OK | #create :52-53 OK | committable_paths :151-153 OK | :45-50 OK | local_repo.rb:84-87 OK | git-editing.md:531-535 OK. 11/11.
- scope: local_repo.rb, repo_commits_controller.rb, repo_commits/show.html.erb, git-editing.md:585 OK.
- validation: repo_edit_flow_test.rb / local_repo_test.rb / system repo_staging, repo_editor + NEW + mutations -> PASS.

### F-S13-2
- commit_paths.rb#call :46-53 OK | stage leaf :91-92 OK | "ASKED ONCE" :86 (+ File.exist? :88 on every stage call) OK | refresh_index :158-166 OK | header :22-24 OK | git-editing.md:183-185 OK | comments :69-75, :106-108 OK | commit_paths_test.rb has 16 tests OK. 8/8 (spec "part 8 rule 3" not path-cited).
- scope: commit_paths.rb, commit_paths_test.rb, git-editing.md:609-610 OK. validation: PASS (16 cases + NEW + mutation).

### F-S16-1
- sheet_controller.js:77-81 five handlers OK | :58-76 no columnSorting/allowRenameColumn/columnResize/rowDrag OK | vendored jspreadsheet.js: `0!=…options.columnSorting` gates, one `.onevent` dispatcher, `ignoreEvents=!0` OK | payload :127-132 OK | label only in scheduleSave :104 OK | sheet_grid_test.rb has ONE test (:50, formula) OK. 6/6.
- scope: sheet_controller.js, test/system/sheet_grid_test.rb exist. validation: :50 formula test + 3 NEW + 3 mutations -> PASS.

### F-S16-2
- projects/bom_lines_controller.rb:37-42 OK | v1/maker/bom_lines_controller.rb:9-34 permits :unit (:31) OK | sibling tinkerex-client (HEAD 399ccdb) client/maker-app/src/projects.js:424 (unit for every kind) + :432 (stock id) OK | inventory_item.rb:25 only before_destroy OK | _bom_lines.html.erb:64 line.unit vs :74 item.unit OK | public _bom.html.erb:58 + bom_csv.rb:47 print line.unit OK. 6/6.
- scope files exist. validation: project_bom_test.rb:229-234 exists + one explicit mutation ("delete the door code without the callback"); other mutations "named per test" (deferred to report) -> PASS.

### F-S19-1
- inventory_transaction.rb:21 OK | :54-57 OK | inventory_items_controller.rb:123-138 OK | :104-107 OK | :109-114 OK | "field-for-field" comment :99 OK | v1/maker/inventory_items_controller.rb:33-41 OK | bom_line.rb:12 OK | 499ceddf OK | #show includes(:project) :51 OK | inventory_items/show.html.erb:88 OK | model comment :17 "renders as —" OK | inventory_transaction_test.rb:57 `update!(delta: 0)` OK. 13/13.
- scope files exist. validation: existing inventory/model/behavioral_edges/structural_orphan/v1 tests + NEW (a)-(d) with mutations -> PASS.

### F-S20-1
- shell.css:71-82 OK | :160-168 OK | :22-29 OK | pages/landing.css:17-21 OK | users/sessions/new.html.erb:2 OK + 5 sibling Devise views with .brand-name (confirmations/new, passwords/edit, passwords/new, registrations/closed, registrations/new) OK | no `.auth-card .brand-name` rule (only `.auth-card .brand` :146) OK | shell_helper.rb:99-101 OK | shell_test.rb:77-79 OK | design-system.md rule 8 (:55-77, mentions "Collapsed (or below 1100px)") OK. 9/9 ("four commits" not cited by SHA — not checkable).
- validation: shell_test/shell_layout_test/landing/phone_topbar/css_hygiene + NEW (a),(b) + 3 mutations -> PASS.

### F-S20-2
- help/show.html.erb:19-22 OK | inline copy :31-41 + :45-50 OK | partial :3-5 OK | 8124afbf touched the partial + library_folder_helper.rb + where_files_come_from_test.rb, not help/show OK | partial links "Library" (:34,:39) vs Help "Files" (:35,:39) OK | help_page_test.rb:83-106 + where_files_come_from_test.rb exist OK. 6/6.
- validation: where_files_come_from_test + rewritten help_page_test + 2 mutations -> PASS.

### F-X-1
- chunk_remote.rb:321-325 OK | :374-378 OK | share.rb:317 (+ :319 raise) OK | s3.rb:395-402 OK | files_controller.rb:922-925 OK | library_output.rb:193-194 + :210 OK | ApplicationController#web_device :63-67 OK | LibraryOutput#addon_device :216-218 OK | architecture_invariants_test.rb:1195 OK | chunk_upload.js:42-43 OK | upload_finalized.rb:4-9 OK. 11/11.
- SCOPE MISMATCH: "the LibraryOutput tests that assert `broadcast: false`" — no file under test/ mentions `broadcast:` at HEAD (grep); nothing to update. Also `broadcast:` is accepted only by ChunkRemote#finalize_upload — Share (:322) and S3 (:400) finalize_upload take no `broadcast:` — so "drop both kwargs from … the three adapters" is right for `device:` only. No test passes `device:` to begin_upload (grep: 0).
- scope: application_controller.rb:48,58-67 OK.
- validation: existing upload tests named generically (locatable: chunk_remote/upload_test.rb named in scope); mutation explicitly "nothing goes red" -> PARTIAL. Suggest: "NEW: a web begin_upload/finalize_upload on chunk_remote and an addon save leave `Device.count` unchanged (mutation: restore `device: web_device` / `addon_device(user)` -> red)".
- MISSING: blast radius; priority.

### F-S17-1
- demo.rb:48-50 (+ claim comment :47) OK | demo_sessions_controller.rb:28-46 OK | demo_reset.rb#refusal :68-88 port arm :75 OK | accounts_sharing_library :93-97 OK | chunk_remote.rb:55-56 syncable: true OK | _demo_banner.html.erb:12 OK | spec 2026-10-14-h-public-demo-design.md:64 OK. 7/7.
- scope: demo.rb:42-51 OK; demo_sessions_controller.rb:37-46 OK; demo_reset_job.rb:7-9 prose OK; tinkerex.rake:41 is CODE (an ENV read in the demo_email lambda), not prose — nearest prose is :36-38 (soft mismatch).
- validation: demo_session_test.rb:133 + demo_reset_test.rb:163 exist; NEW (a),(b) + mutations -> PASS.

### F-S07-1
- model_intake.rb:145-150 OK | comment :137-138 OK | project_discovery.rb MAX_PROJECTS :58 OK, `private_class_method :adoptable` :188 OK | model_intake_defaults_test.rb:22 (comment), :51, :81 OK | attach_all :152-172 (def :155) OK. 5/5 ("verified earlier" chunk_remote schedule: see F-S24-1 check).
- scope ranges all resolve: model_intake.rb:127-150, model-intake.md:88-98 & :205-211, project-intake.md:134-146, scan_job.rb:239-249 & :320-333, recurring.yml:162-166, scan_job_test.rb:378-397 & :643-660, model_intake_test.rb:98-104.
- validation: project_adoptions_test.rb:351 (range :350-371), DiscoveryOrderTest + NEW (a)-(d) with mutations -> PASS.

### F-S07-2
- model_intake.rb:152-172 insert-only OK | prune.rb:3-13 OK | model-intake.md:177-192 OK (:182 "no column saying which door wrote a row") | importer_controller.js:122 OK | models_controller.rb:130 OK | no view references model attachment paths (grep) OK | fdaa2660 exists (touched models/show.html.erb; the "detach link left" detail not re-derived) | Prune guard 3 :57-60 OK | one-file skip :28-32 OK | AttachToProject#model_owning :226-230 OK. 10/10.
- scope: model-intake.md:160-162 OK, model_folder.rb:18-19 OK, adoptions_controller.rb:203-218 OK (starts :203), models.rake:12-30 OK, model_intake_prune_test.rb exists.
- validation: named suites + NEW (a)-(h) with mutations -> PASS.

### F-S21-1
- routes.rb:257 OK | no `project_uploads_path` caller in app/ (only build_log_entry_uploads_path, _log_entry.html.erb:20) OK | branch methods attach_target :111 / project_of :119 / upload_parent :131 / role_for :137 OK | ordering invariant :69-80 OK | "stays, answering exactly as before" :97-99 OK | f275f0e3 OK. 6/6.
- scope: build-log route :307-310 OK; tests to delete all POST project_uploads_path: project_upload_attach_test.rb:22-35 (:27), :125-152 (:129,:136), :157-163 (:160); project_folder_intake_test.rb:192-205 (:195); projects_flow_test.rb:595-608 (test :597, post :605; drift 2); demo_guards_test.rb:252-255 (:254) OK; project-intake.md:69-75 & :497-503 OK.
- validation refs resolve: topbar_upload_test.rb:66, project_upload_attach_test.rb:80-88, demo_guards_test.rb:236-262, projects_flow_test.rb:581-593 (:582), projects_controller.rb:140 `if @listing.available?`, project_folder_intake_test.rb:210-219; NEW + mutations -> PASS.

### F-S21-2
- upload_batch.rb:54-64 rescue list OK | share.rb:732 (resolve_inside! escape) OK, :742 (leaf!) OK | **share.rb:101 MISMATCH**: entry says Share#write raises NotFound "over MAX_BYTES :101"; :99-102 is Share#READ's size cap (`size = File.size(path)`; `raise NotFound … if size > MAX_BYTES`). The write-side refusal is `read_capped!` :829-831 (called from write at :256) — claim true, line wrong. | FilesController "File not found." via rescue_from (:132) OK | Projects::UploadsController rescue_from only UnsupportedOperation :30 / FetchError :34 OK; ApplicationController has no rescue_from OK | concern calls enqueue_preview :51 OK | private copies files_controller.rb:1240-1251 (def :1244) + uploads_controller.rb:141-148 OK | library_output.rb:220-234 "THE ONE STAT-THEN-ENQUEUE" OK | `raise errors.first …` files_controller.rb:828 + uploads_controller.rb:63 OK. 11/12.
- validation: upload_batch_test.rb (11 tests, :76-82) + files_flow/s3_write/demo_guards ranges resolve; NEW (1)-(3) with mutations -> PASS.

### F-S18-1
- v1/base_controller.rb:37 OK, handler :44 renders e.message OK | commits 50e11933, 161d3b20, 9658a573 exist OK | no `enum`/`raise ArgumentError` in app/models or app/services/maker/previews OK | DevicesController#library_info :99-100 reads FileLayer.current OK | move_node.rb:58-64 OK | attach_to_project.rb:381-387 OK | architecture_invariants_test.rb:957 OK (thematic: "a controller rescue … laundering a real … MISCONFIGURATION"; the passage is about NotImplementedError) | only other ArgumentError rescue in app/controllers = inventory_items_controller.rb:136 (BigDecimal) OK. 8/8.
- validation: existing v1 422 tests (generic, test/integration/v1) + NEW assert_raises with stated mutation -> PASS.

### F-S22-1
- modelviewer_controller.js connect :35-40 OK | gerber_controller.js:83 rest() OK | :117-118 callbacks via fields OK | :93-97 per-load reassignment OK | teardown :56-65 OK | vendored o3dv.js: `Destroy(){this.RevokeObjectUrls(),this.importer=null}`, `this.inProgress||(…)`, LoadModelFromInputFiles removes+nulls progressDiv, `onImportStart:()=>{this.progressDiv.innerHTML=…}` all present OK | :51-55 comment OK | no `go_back` in test/ OK. 8/8 (+ af536baa exists).
- scope: o3dv_test.rb:147 `c.viewer` OK; files-preview.md:541-545 OK, :277 OK; test/system/support/web_helpers.rb exists.
- validation: o3dv ("11 cases" — o3dv_test.rb has 12 `test "` blocks at HEAD, minor count drift)/files_flow/models_flow/public_file_view/lazy_bundles + NEW (1)-(4) with mutations -> PASS.

### F-S23-1
- lib/schema_map.rb:104 EDGES OK | :25-32 hole stated OK | node-id columns: 10 `node_id` + 11 `*_node_id` in db/schema.rb OK | structural_orphan_test.rb:20/:28 derives from SchemaMap::EDGES OK | repo_node_id absent from schema_map.rb, written by release_snapshot.rb:51 OK | schema.rb:405 column exists OK. 6/6.
- scope: schema_map.rb :16, :46-48, :269 stale prose OK; schema_map_test.rb:87-100 OK; lib/tasks/schema_map.rake aborts on problems (:6-9) OK; docs/schema-map.html exists.
- validation: SchemaMapTest/StructuralOrphanTest + NEW (a),(b) + 4 more mutations -> PASS.

### F-S23-2
- `updated_seq`: zero readers/writers in app/lib/config, two comments only (reconciler.rb:40, project_intake.rb:568) OK; column+index schema.rb:502/:508 OK | v1/maker/file_attachments_controller.rb:33 permit OK | three JSON echoes (file_attachments :37, items :73, projects :56) OK | file_info.rb:4-8 OK | schema_map.rb:122-139 OK | schema_map_test.rb:87-100 OK | index_maker_previews_on_user_id_and_status schema.rb:318 OK | `Maker::Preview.ready` scope has no caller OK. 8/8.
- scope: project_intake.rb:566-568 OK; script/maker_smoke.py:161-164 OK; test/models/legacy_columns_dropped_test.rb exists.
- validation: named suites + 2 NEW with mutations -> PASS.

### F-S24-1
- scan_job.rb:96-98 OK; per-step wrappers :239-349 (discover :262, intake :313, models :342, class end :350) OK | recurring.yml:93-95 / :158-160 / :192-194 (`every 15 minutes` at :95/:160/:194) OK | queue.yml threads: 3 OK | gates project_intake_job.rb:50, model_intake_job.rb:31, project_discovery_job.rb:55 + chain_intake :80-87 (gate :81) OK | solid_queue 1.7.0 (= Gemfile.lock) concurrency_controls.rb:20 `limits_concurrency(key:, to:, group:, …)` OK | 2ce07c95, 8cb9ffbb exist OK. 6/6.
- scope: projects/scans_controller.rb, recurring.yml:75-194, project-intake.md:141-146 & :217-231, model-intake.md:91-93 & :205-211 exist/resolve.
- validation: named order/failure/recurring/boot tests + NEW (a)-(f) with mutations; test/jobs/concurrency_limits_test.rb exists -> PASS.

### F-S24-2
- Gemfile:50 OK | config/cable.yml production adapter solid_cable / writing: cable OK | database.yml :116-119 & :132-135 OK | db/cable_schema.rb exists OK | schema_map.rb SOURCES "cable" :38 OK | ops/backup-db.sh:229 OK | INSTALL.md:268-269 OK, :383 "The derived databases must exist." OK | application.rb:57 mount_path = nil OK | cable_absent_test.rb:18-20 OK | no broadcast_*/turbo_stream_from/ActionCable.server/createConsumer outside comments OK. 10/10.
- NO "Smallest scope" FIELD: the file list is folded into "Proposed representation" (config/cable.yml implied by "production `adapter: async`", never named as a path).
- validation: cable_absent_test/schema_map_test + NEW config assertion with mutation -> PASS.

### F-S25-1
- bin/secrets-preflight:70-120 vs deploy_hygiene_test.rb:639-688 — I re-ran the diff with comments+indentation stripped (process substitution, no files): IDENTICAL OK | "WIDEN BOTH TOGETHER" preflight:82 (test's twin wording :644-648) OK | e2fafea1 OK | no test runs the preflight (test mentions: comments :644,:648 + assertion message :725) OK | DESTINATIONS preflight:46, SECRETS_FILES test:591, pin :879 OK | preflight:27-31 OK | oracle :690-731 OK | ImportmapAudit (lib/importmap_audit.rb + bin/importmap-audit) and Tinkerex::Sidecars "THREE READERS, ONE ANSWER" (sidecars.rb:9) exist OK. 9/9.
- scope: preflight :44-46, :55-120; test :623-632 (`required_secret_keys`), :653-688 (`secret_key_names`) resolve.
- validation: :690/:733/:747/:871/:879 exist; NEW smoke + 2 mutations -> PASS.

### F-S25-2
- ops/backup-db.sh:40 arg case OK | :109-112 PING_* whitelist OK | container_for :191 OK | volume_for :208-216 OK | comment :98-105 OK | 39c29535 body line 51 "already DERIVES PING_<DEST>" OK | cb50a9f0 body "never pinged its monitor in either direction" OK | bin/restore-db:51-61 FILTER/VOLUME copy OK | destination set in bin/backup-db:31, bin/backup-status:70/:77, bin/backup-cron-install:45 OK | no test reads the scripts (only a comment in log_cli_test.rb:462) OK. 10/10.
- scope: backup-cron-install:194-204 ("THREE THINGS BY HAND" :202) OK; DEPLOY.md:673,:715 OK.
- validation: no existing test can exist (§14i: nothing in bin/ci covers ops/) -> existing-test half absent by necessity; NEW static test + rehearsal each with mutation -> PARTIAL (structural). Suggest naming test/deploy_hygiene_test.rb as the existing pattern the new test copies (it already reads the merged config via Kamal::Configuration.create_from).

### F-S26-1
- config/ci.rb:276-278 (file ends :278) OK | tee only in the chunk_remote leg :209/:212 OK | PIPESTATUS trap :138-145 OK | execute-plan.md:85-87 OK | finish-branch.md:28-30 (test-share named, test-chunk-remote omitted, "run/assertion counts") OK | finish-branch.md:96-101 describes an app/config/... allowlist while ci.yml:50-56 is now `'**'` minus docs/md -> stale, as claimed OK | ci_hygiene_test.rb:134-155 set equality OK. 7/7.
- validation: ci_hygiene_test.rb:134-155, importmap_audit_test.rb:109, bin_sync_server_test.rb:67 exist + 3 unit-test mutations + e2e -> PASS.

### F-S26-2
- ci.yml RAILS_ENV: test at :222,:235,:252,:280 OK | ensure-resvg only at :219,:232 (not before test-chunk-remote/system) OK | ci/runner/Dockerfile:162 resvg baked OK | ci.yml:254 SYNC_PORT OK | ci_hygiene_test.rb:140-146 counts bin/ci invocations only OK | activerecord-8.1.3.1 databases.rake:22 (`load_config: :environment`) + :553 (`prepare: :load_config`) OK | initializer `unless Rails.env.test?` OK. 7/7.
- scope/validation lines resolve: ci_hygiene_test.rb:134-155, :168 ("every ci.yml job refuses a pull request from a fork"), :188, :324 planted-fixture test. NEW + 3 mutations -> PASS.

### F-S28-1
- bin/migrate-record:4 header OK | plan docs/superpowers/plans/2026-08-31-forgejo-to-kaneo.md:2010 `git rm bin/migrate-record` (Task 21) OK | Delete arm :73, task delete :372, delete_project :451 OK | recovery prose :189-191 OK | `git grep migrate-record` = the plan only OK | 8ec505c1 removed bin/split-status (stat: 34 -) OK | ci_hygiene_test.rb:562 `Dir.glob("bin/*")` OK. 7/7.
- validation field: "`git grep -n migrate-record` returns only the plan; bare `bin/ci`" — no existing test file, no mutation -> FAIL (mitigated: the Smallest-scope field carries an optional Kaneo-write-door hygiene test WITH a mutation). Suggest moving it into Validation: "existing: test/ci_hygiene_test.rb:562 (bin/* surface stays non-empty); NEW: no tracked file except bin/log (and test/) names Kaneo's write endpoints /api/task, /api/label, /api/comment, non-vacuous by asserting bin/log matches (mutation: restore bin/migrate-record -> red)".

### F-S28-2
- bin/log:88 "ONE raise site" OK | Unreachable.new at :185,:189,:396,:411,:563 (five), `e.payload || …` merges :185,:411,:563 OK | 234abebd, 0aae5900, da5244f9 exist OK | close :587-603 no rescue OK | spool_dir :605 OK | :87-92 OK. 6/6.
- validation: log_cli_test.rb anchors :285,:355,:374,:398,:421,:582,:659,:783,:1264 all resolve (file is 1270 lines); NEW (a)-(c) with mutations -> PASS.

### F-S29-1
- render.mjs:35-41 exit-code header OK | :54-58 unreachable exit-3 arm OK | tracespace.mjs contains "File type not recognized" (1 hit) OK | usage guard :49-52 OK | gerber.rb:91 300-byte stderr RenderError OK | gerber_test.rb:212-213 stale mechanism comment OK | tools/stl-thumbnailer/src/main.rs exists OK | pdf.rb:49-63 policy OK. 8/8.
- scope: render.mjs:35-45 & :55-58; gerber_test.rb:212-220 OK. validation: existing gerber_test cases + NEW asserts with 2 mutations -> PASS.

### F-S29-2
- Dockerfile:107, ci/runner/Dockerfile:162, ci/ensure-resvg.sh:24 — three resvg 0.47.0 pins, none `--locked` OK | ci/runner/Dockerfile:175-181 `--locked` rule (stl-thumbnailer) OK | :141-142 "cannot disagree" claim OK | ci.yml:112-116 STL-never-ran note OK | adding-a-preview-format.md:24-27 OK (text at :25-28, drift 1). 5/5 checkable. NOT CHECKABLE: resvg-0.47.0's published Cargo.toml caret ranges (no local cargo registry copy; crates.io not fetched).
- scope: ci.yml:218-219, 231-232 OK. validation: available?-honesty tests + 3 hygiene + 3 presence mutations -> PASS.

### F-S27-1
- test_helper.rb:243-257 two-flag teardown OK | pin_file_layer_backend :233-241 OK; its 6 calls (model_intake_job_test.rb:13,:42; project_discovery_job_test.rb:17,:37,:54,:93), each followed by use_fresh_share_library! (spot-checked :13-14) OK | test/system/README.md:26-27 OK | :104-114 misplaced doc OK | :249-253 + :207-213 past leaks OK | 158 `FileLayer.reset!` calls in test/ = exact OK | "90 direct assignment sites in 45 files": I count 89 non-comment `FileLayer.current =` lines in 45 files (92 with comment lines) — within ±1, OK as a count. 7/7.
- validation: fresh_share_library_cleanup_test.rb:81-89 exists; NEW probe + 2 mutations -> PASS.

### F-S27-2
- `post user_session_path` 129 lines / 107 files OK | throttle `rate_limit to: 10, within: 3.minutes` (users/sessions_controller.rb:13) OK | test_helper.rb:56-64 (306 failures / 20 errors) OK | public_fixture.rb:100-102 unverifying sign_in_as OK | "three files record DEVIATION… `sign_in_as` is not defined in test_helper.rb": exact wording in 3 (settings_filing/settings_reference/settings_hub), 2 more say "does not exist" (shelves, models_catalog) OK | c80ea529 exists OK | cb50a9f0 body "NOT done, deliberately: … S39-1's 60-file sweep" OK | attach_from_files_test.rb:44-49 & :89-98, public_project_test.rb:28-37, settings_hub_test.rb:33-36 (passwordless other_user!) OK. 9/9 ("23 private copies", "13 suites" counts not re-derived).
- validation: NEW harness tests with mutation + before/after on 3 named existing tests -> PASS.

### F-S12-1
- boxes/app.py:387-391 OK | boxes/tests/test_api.py:316-321 F-62 pin ("2403 of the 5082 … 47%") OK | openscad/schema.py:22-26 both keys OK, :37 per-param group OK | openscad/app.py:190 grouped-only read OK | test/support/fake_boxes_sidecar.rb nests params in groups (:67-111) OK | sibling tinkerex-addons (d3ab6fd) addons/openscad/fields.js:130,:136 + openscad.js:175 OK | 6095b871 (BoxesClient deletion) exists OK | schema.py:1-5 stale BoxesClient claim OK. 8/8.
- scope: boxes/app.py:388-391, boxes test_api.py:316-370, openscad/app.py:60, openscad test_api.py:95-107, test_catalog.py:93, test_coerce.py:296 all resolve.
- validation: named pytest suites + NEW (a),(b) with mutations -> PASS (note: neither pytest suite runs in bin/ci; entry says so).

### F-S12-2
- deploy_hygiene_test.rb FORBIDDEN_LICENCE_TERMS :502 / forbidden_licence? :504 / CATALOG_GLOB :491 OK | test_catalog.py:14-31 + :54-55 OK | openscad test_api.py:49 mixed-case tuple without "lgpl" OK | no pytest/python step in config/ci.rb or ci.yml OK | external-reference rule only at test_catalog.py:77-84 (no Ruby test names the needles) OK | catalog/NOTICE carries the assembled-wrench lesson OK | assert-capabilities.sh + probe.scad exist OK. 7/7.
- scope: test_api.py:37-53 OK; openscad/README.md:156-167 (Dev section) OK; addons.md:53-71 & :67-68 OK; catalog/probe_plate.scad exists.
- validation: existing Ruby catalog block (deploy_hygiene_test.rb:491-518) + kept Python tests; NEW mutation (append `use <missing.scad>` / `import("x.stl")`) -> PASS.
