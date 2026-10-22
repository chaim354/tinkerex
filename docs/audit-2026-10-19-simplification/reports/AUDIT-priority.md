# AUDIT-priority — dependency-aware priority ranking (audit-the-audit pass 5 of 5)

Repo `/Users/charlesschwartz/Desktop/repos/tinkerex` @ `75124d67` (main), read-only; this file is the only thing written.
Inputs: AUDIT.md §1–§5 (49 findings: 48 row findings + F-X-1), reports/S01–S29.md, and the tree at HEAD.
Every edge, effort or tier judgement that rests on code was re-checked at HEAD (file:line given). Nothing was
executed, so every "red today" / "reachable" claim below is read, not run. The coordinator decides; this recommends.

---

## 0. Summary

- Tiers under the rule in §2.1: **14 P1 · 14 P2 · 10 P3 · 11 P4** (= 49).
- **Five first slices. No two touch the same file, so they can open in parallel** (§3):
  - S-1 suite honesty: F-S26-1 + F-S27-1 + F-S27-2 step 1
  - S-2 trash, delete side: F-S03-1 step 1 + F-S02-1's no-migration step
  - S-3 ledger integrity and tenancy: F-S19-1
  - S-4 preview reliability: F-S08-1 + F-S10-1
  - S-5 catalog claims: F-S07-1
- **Recorded sequencing, re-checked** (§1.5):
  - F-S07-1 → F-S24-1 holds. But once F-S07-1 lands, F-S24-1's planned order test (a) can never fail.
  - "F-S02-1 + F-S03-1 is one slice" is true only for the membership and undelete half. Both raw reports say the delete halves can ship first, alone.
  - F-S10-1 → F-S10-2 is a preference, not a dependency.
  - F-S26-1 and F-S26-2 are better sequenced than bundled.
  - `ci/ensure-resvg.sh` must not be deleted before its two `ci.yml` steps are removed.
  - The renderer-parity fix follows F-S29-2's guards; it does not land with them.
  - F-S12-1 needs two PRs, one image each.
- **Two constraints the audit did not record:**
  - CLAUDE.md sits exactly at its line limit: 1,360 lines against `MAX_LINES = 1_360` (`test/docs_hygiene_test.rb:71`). Every slice that edits CLAUDE.md must therefore add no net lines.
  - Parallel local `bin/ci` runs in different worktrees kill each other's sync server. The chunk_remote leg uses port 3002 by default and runs `lsof -ti tcp:$PORT | xargs kill -9` (`config/ci.rb:149,157`).

---

## 1. Dependency graph

Notation used throughout:
- **T1** (the delete side, no migration):
  - F-S03-1 step 1: S3 folder delete moves live rows and directory markers, and writes root-relative trash keys.
  - F-S02-1's no-migration step: the Share and S3 cascades touch live rows only; Share's `revive_subtree!` skips rows that kept a path or own a `.trash/<id>` entry.
- **T2** (the undelete side, with a migration):
  - F-S02-1's recorded membership column, `nodes.trash_root_node_id` (S23's name), with its backfill.
  - Share and S3 undelete driven by that column.
  - F-S03-1 step 2: S3 folder undelete with top-down revive and compensation, plus cleanup.

### 1.1 Hard edges — X must land before Y

| # | Edge | Reason | Evidence |
|---|---|---|---|
| H1 | F-S07-1 → F-S07-2 | F-S07-2 replaces insert-only `attach_all` with a reconcile that DELETES rows outside the desired set computed over UNCLAIMED keys. Without positional claims, an unadopted `Projects/<x>` is "unclaimed" before adoption and "claimed" after, so the reconcile attaches and then deletes the same rows across ticks. Both edit `model_intake.rb`. | `model_intake.rb:136-138` (correctness delegated to ScanJob order), `:145-150` (only claims that exist), `:155-173` (insert-only); `project_discovery.rb:58` (cap 50), `:188` (`adoptable` private); F-S07-2's own "Dependency: F-S07-1 first" |
| H2 | F-S07-1 → F-S24-1 | After F-S07-1, F-S24-1's STEPS order matters for latency only. Both touch `app/jobs/library/scan_job.rb` and `config/recurring.yml`. **Correction:** F-S24-1's test (a) (reports/S24.md:139) asserts that no model's `auto_node_id`/`folder_node_id` is the `Desk Lamp` folder, with the mutation "move ModelIntakeJob first in STEPS". After F-S07-1, `Desk Lamp` (a direct child of `Projects/` passing `adoptable_name?`) is claimed by position in every order, so that mutation stays green — §15's vacuous-guard shape. Re-point (a) at what order still decides after F-S07-1: the same-run catalogue or the discovery→intake filing. | `scan_job_test.rb:661-687` (the ported case; `assert_nil swallowed` at `:673`); `:682` (`["bracket"]` same-run catalogue); `:623` (`panel.svg` filed under `design/`); `project_discovery.rb:162`; F-S07-1's own note that DiscoveryOrderTest's swallow assertion stops being order-sensitive |
| H3 | F-S08-1 → F-S08-2 | The stall set is one literal inside `Enqueue.call`, and every read door returns before reaching it for a coordinate-current row. A `rebuilding` row is coordinate-current by construction (same version, new revision stamped), so its stall heal is reachable only through F-S08-1's door predicate. Both edit `enqueue.rb` and both file controllers. Recommendation: F-S08-1 names the in-flight set once, so F-S08-2 adds a single token. | `enqueue.rb:95-98` (`%w[pending processing]`, early return); `files_controller.rb:1230-1238` (`current_thumbnail`), `:479-483` (`#geometry` enqueues only `if preview.nil?`); `public/files_controller.rb:158-170` |
| H4 | T1 → T2 | T2's S3 restore reads the root-relative entry key that T1 starts writing. T2's backfill classifies trash rows, which T1 stops polluting with converted scan tombstones. | today's key `s3.rb:545-546` (`.trash/<root id>/<file's full storage_path>`); cascades `share.rb:423`, `s3.rb:532,568`; reports/S03.md:84 ("This step can ship alone"); reports/S02.md:65 ("A no-migration first step exists") |
| H5 | `ci.yml` resvg steps removed ≤ `git rm ci/ensure-resvg.sh` | The two `run: ci/ensure-resvg.sh` steps are the script's only callers. Deleting the script first fails the `test` and `test-s3` jobs. Either F-S26-2 removes the steps first, or F-S29-2 removes them in its own PR. | `ci.yml:219,232`; repo-wide grep: no test references the script |
| H6 | F-S29-2's guards → the §4 renderer-parity fix | Guard before refactor. F-S29-2's presence test exempts Mesh because the CI image has no F3D. The parity fix adds F3D and pdfium-WASM to the runner image, then drops that exemption and widens the pin assertion. These are two separate image rebuilds. | `ci/runner/Dockerfile:165-168` (pdfium-cli v0.2.0 native) vs `Dockerfile:116-120` (v0.11.0 WASM); AUDIT.md:737 |
| H7 | F-S04-1 → (a) the §4 S04 "cursor ahead of a restored server" fix; (b) tinkerex-sync scheduling `prune_changelog` | Both make `full_resync` reachable, and the resync arm is the broken one. Fixing (a) first would route a restored deployment straight into it. | `changelog_sync.rb:149-152` (`gapped?`), `:166` (resync upsert with no version); reports/S04.md:101; AUDIT.md:660 |
| H8 | F-S01-1 → its consumers | These consume the one reading (and its name list) F-S01-1 introduces: F-S17-1's optional `Demo.validate!`; S17's `Registration.validate!` (`registration.rb:47` reads ENV raw); S25's `LIBRARY_BACKEND_REQUIRED` key set (a hand copy; its comment says build "has no constant to reuse"). **Caveat:** Registration deliberately keys on the OPERATOR's value, and the guard refuses to print a second message for one typo. So pass the resolved name in as an argument; never call a raising reader from a second initializer. | `registration.rb:35-56`; `deploy_hygiene_test.rb:805-814`; `library_backend_check.rb:107-114`; AUDIT.md:715,735 |
| H9 | F-S05-1 → F-S05-2 (or one PR) | Both edit the dir-revive block. | `reconciler.rb:600-610` (lookup at `:605`, `@dir_ids` write after it) |
| H10 | F-S21-1 → F-S21-2 (or one PR, F-S21-1 first inside it) | Both rewrite `Projects::UploadsController#create`. F-S21-2 also changes the return shape of `write_batch`, which both controllers destructure. | `uploads_controller.rb:47-63` (destructures at `:55`); `upload_batch.rb:24-28,67`; `files_controller.rb:820` |

### 1.2 Soft edges — should land before (otherwise rework, or a weaker guard; not a correctness break)

| # | Edge | Why it matters | Evidence |
|---|---|---|---|
| E1 | F-S26-1 → every other slice | Once it lands, the gate checks each later slice's "identical run counts" itself. It also fixes the close-out file every slice follows, which names a non-existent `test-share` gate and demands identical assertion counts — assertions always differ. Until S-1 merges, the other slices must compare RUN counts by hand. | `config/ci.rb:276-278` (runs gates, compares nothing); `.claude/commands/finish-branch.md:28-30`; `execute-plan.md:85-87` |
| E2 | F-S27-1 → F-S24-1, and → slices whose tests assign `FileLayer.current` (F-S17-1 test (a), F-S18-1, T1/T2, F-S07-1) | The six `pin_file_layer_backend("share")` calls F-S27-1 deletes sit in the gate tests F-S24-1 moves. | `model_intake_job_test.rb:13,42`; `project_discovery_job_test.rb:17,37,54,93`; `test_helper.rb:233-257` |
| E3 | F-S27-2 step 1 → F-S19-1's test (c) | "The poster's item page does not contain the foreign name" passes vacuously if the web sign-in silently failed. Assert 200 first, or use the verifying helper. | `test/support/public_fixture.rb:100-102` (checks nothing); F-S27-2 |
| E4 | F-S23-1 → T2; F-S23-1 → F-S23-2 release 2 | `trash_root_node_id` is a new `*_id` column that nothing forces into EDGES today. Later, NOT_EDGES's "names a column that does not exist" check forces the `maker_file_attachments.version_id` entry out when F-S23-2 drops that column. | `lib/schema_map.rb:25-32` (the stated hole), `:104` (EDGES) |
| E5 | F-S03-2 → T2 (or fold its `for_reported` half into T2) | T2's S3 folder undelete calls `restored_stat` once per revived object. That is exactly the site F-S03-2 hardens against a quoted-empty ETag. | `s3.rb:999-1006` |
| E6 | F-S01-1 → F-S26-2, if F-S26-2 takes the conservative `RAILS_ENV=test` direction | Local `bin/ci`'s development boot inside `db:test:prepare` is today the only `bin/ci` path that runs the boot-guard initializer. F-S01-1's `boot!` unit tests and static wiring pin replace it. In the same change, derive `bin_sync_server_test`'s literal key assertions from `CHUNK_REMOTE_REQUIRED`; otherwise the "knob added that bin/sync-server does not emit" check F-S26-2 describes disappears on both sides. | `config/initializers/library_backend_check.rb:20-21`; `test/bin_sync_server_test.rb:115-118`; `lib/library_backend_check.rb:90` |
| E7 | F-S10-1 → F-S10-2 | Preference only (see §1.5). | — |
| E8 | F-S08-1, F-S08-2 → F-S23-2's index half | Recheck that neither adds a per-user status query. None exists at HEAD. | `preview.rb:30` (the unused `scope :ready` is the only one); `missing_backfill.rb:89-90` keys on `(kind, node_id)` |
| E9 | F-S09-1 ⟷ F-S22-1 | They share one Turbo-Back system-test helper; whichever lands first creates it. No test calls `go_back` today (grep). | §5 AUDIT.md:761; F-S22-1's scope (`test/system/support/web_helpers.rb`) |
| E10 | F-S04-1 → F-S24-1's optional "enqueue the sweep from ChangelogSync" | Both edit the apply/nudge path in `changelog_sync.rb`. | F-S04-1 risk (d); F-S24-1 proposal |
| E11 | F-S26-1 → F-S26-2 | Sequence them (see §1.5). | — |
| E12 | T2 → F-S02-2's *alternative* shape | That alternative lifts `revive_subtree!`'s walk into a shared walk, and T2 rewrites it. F-S02-2's primary proposal (`rebase_descendants!`) has no edge. | `share.rb:694-712` |

Checked with no edge found: no finding relies on the kwargs F-X-1 deletes. The only call sites are
`files_controller.rb:922-925` and `library_output.rb:193-195,210-211`. `files_controller.rb:950` passes neither kwarg.
No finding changes a `Capabilities` flag.

### 1.3 Must land together (one PR)

- **T2:** the column, both undeletes, and a backend-agnostic folder delete+restore case in `adapter_mutation_contract.rb` — the missing case that hid defect (c) (AUDIT.md:683).
  - Splitting it leaves S3 inferring membership from existence, which §5 records as reproducing defect (b), or adds a column one adapter ignores.
- **T1:** both adapters' cascades narrow to live rows in the same PR.
  - Narrow each adapter's own UPDATE, never `Subtree.node_ids` (see F-S02-1's risks).
  - Shipping one adapter alone recreates the "one condition, two answers" split that §14a warns about.
- **F-S26-2's two halves:** remove `RAILS_ENV: test` from `ci.yml:222,235,252,280` and settle the environment in `config/ci.rb` in one commit.
  - Otherwise CI and local runs boot differently for that PR.
- Recommended, not required:
  - F-S21-1 + F-S21-2 (H10).
  - F-S09-1 + F-S22-1 (E9).
  - F-S05-1's migration + S04's missing `(user_id, current_version_id)` index (AUDIT.md:660; `chunk_remote.rb:386`) — both are new `nodes` indexes.

### 1.4 Must NOT land together

| Pair | Why |
|---|---|
| F-S07-1 + F-S07-2 | F-S07-2 reverses a recorded decision (`model-intake.md:177-192`) and deletes rows unattended on its first run, which must be measured first. F-S07-1 is a small, safe correctness fix. |
| F-S08-1 + F-S08-2 | About 14 files of status vocabulary plus a v1 mapping, versus a cheap heal. |
| F-S23-2 release 1 + release 2 | The repo's two-release retirement shape. |
| F-S12-1 boxes half + openscad half | `bin/publish-sidecar` takes exactly one name (`bin/publish-sidecar:30-31`); one image per slice. |
| F-S29-2's `--locked` half + any gate- or test-only slice | It needs a CI-runner image rebuild and a production image with a PNG-byte comparison, and possibly a THUMBNAIL_REVISION bump. |
| F-S03-1's ORIGINAL undelete membership rule (existence at the rebuilt key) + anything | Superseded (§5); it reproduces defect (b). |
| F-S19-1 + F-S16-2 | Keep the tenancy fix minimal and fast. F-S16-2 adds a data migration and needs a shape decision. |
| T2 + F-S02-2 | Both rewrite share.rb's directory walks, and F-S02-2 has no live door. |
| F-S10-2 + F-S08-2 | Both rewrite `files/show.html.erb`, `public/files/view.html.erb` and both file controllers. |
| F-S27-2's sweep (c)/(d) + any feature slice | About 100 test files. |

### 1.5 Recorded sequencing claims — verdicts

| Claim (where recorded) | Verdict | Evidence |
|---|---|---|
| F-S07-1 → F-S24-1 (§5 AUDIT.md:763; F-S24-1 entry) | **CONFIRMED**, with a correction to F-S24-1's validation. | H2 |
| F-S02-1 + F-S03-1 as one trash-entry slice (§5 AUDIT.md:752) | **PARTLY.** Holds for membership + undelete (T2). The delete halves should ship first (T1). §5's supersession covers only F-S03-1's undelete membership rule. | reports/S03.md:84; reports/S02.md:65; delete-side lines `share.rb:423`, `s3.rb:532,545,568` |
| F-S08-1 → F-S08-2 (both entries) | **CONFIRMED.** | H3 |
| F-S10-1 before F-S10-2 (F-S10-2 entry: "so the shared door is what viewer_for calls") | **CORRECTED — preference, not dependency.** F-S10-1 keeps `GerberArchive.for(user:, node:)` and `ThreeMfManifest.for(user:, node:)` and leaves call sites unchanged, so `viewer_for` calls the same methods either way. The two touch no common file and can run in parallel. Do F-S10-1 first only because it is the defect. | `gerber_archive.rb:83`, `three_mf_manifest.rb:86`; calls at `files_controller.rb:537-546`, `public/files_controller.rb:57-60` |
| F-S26-1 + F-S26-2 "land together"; F-S26-2/F-S29-2/parity "together" (entries; §5 AUDIT.md:766) | **PARTLY.** F-S26-1 and F-S26-2 do share four gate command strings. But F-S26-2 also changes `ci.yml`, and its direction "needs one measured CI run first", so land F-S26-1 first. F-S29-2's only coupling to them is H5. The parity fix follows F-S29-2's guards (H6), not with them. | `config/ci.rb:77-93,208-212,237-241`; `ci.yml:218-222,231-235,252-254,280` |
| F-S01-1 feeding the S17/S25 consumers (§4 AUDIT.md:715,735) | **CONFIRMED** (H8), with the Registration caveat. | H8 |
| F-S05-1 first or with F-S05-2 (F-S05-2 entry) | **CONFIRMED.** | H9 |
| F-S07-1 → F-S07-2 (F-S07-2 entry) | **CONFIRMED.** | H1 |
| F-S09-1 / F-S22-1 share one helper (§5 :761) | **CONFIRMED.** | E9 |
| F-S14-1 and F-S15-1 touch different files (F-S14-1 entry) | **CONFIRMED independent.** | `repo_subtree_ids` has one caller (`projects_controller.rb:404`); `public_project.rb:342` walks its own tree |
| F-S18-1's producer "moves to boot" after F-S01-1 (F-S18-1 entry) | **CONFIRMED.** No order needed, provided F-S18-1's test stubs the adapter rather than relying on ENV. | `file_layer.rb:203` |
| F-S23-2 "recheck F-S08-1/2 for status queries" | **CONFIRMED clean at HEAD.** | E8 |
| F-S23-1 "F-S02-1's column would pass every guard undrawn" | **CONFIRMED** → E4. | `schema_map.rb:25-32` |
| F-S12-1 "publish both images" | **CORRECTED** for this repo's slice rule: two PRs. | `bin/publish-sidecar:30-31` |
| F-X-1 "drop both kwargs from the port and the three adapters" | Scope detail only: `broadcast:` exists on chunk_remote alone, `device:` on all three `begin_upload`s. No effect on ranking. | `chunk_remote.rb:325,378`; `share.rb:317,322`; `s3.rb:395,400` |
| F-S27-2 "sequence (c)/(d) as their own change" | **CONFIRMED.** | 129 raw `post user_session_path` sites in 107 test files (grep) |

### 1.6 Shared-file hotspots (coordination only — no dependency)

| File | Findings that touch it | Note |
|---|---|---|
| `app/controllers/files_controller.rb` | F-S10-2 (`#show`), F-S08-1 (`#current_thumbnail` :1230, `#geometry` :445/:479), F-S08-2 (`#thumbnails`), F-S21-2 (`#create` :809, `#finalize_upload`, deletes `#enqueue_preview` :1244), F-X-1 (`#begin_upload` :922) | `#current_thumbnail` sits directly above `#enqueue_preview`, so S-4 and the upload slice will conflict textually (trivially) |
| `app/controllers/public/files_controller.rb` | F-S10-2 (`#view` :41-74), F-S08-1 (`#enqueue_geometry` :158-170), F-S08-2 (`#preview`) | |
| `app/services/file_layer/s3.rb`, `share.rb` | T1, T2, F-S03-2, F-S02-2, F-X-1 (one signature line each) | |
| `app/services/maker/addons/library_output.rb` | F-S11-1 (`upsert_file!` :113), F-X-1 (:194, :210-218) | `enqueue_preview` is already a public `module_function` (:26-27, :226), so F-S21-2 needs no edit here |
| `model_intake.rb`; `scan_job.rb` + `recurring.yml` + the three step jobs | F-S07-1, F-S07-2; F-S24-1, F-S27-1 (job tests) | H1, H2, E2 |
| `projects/uploads_controller.rb`, `concerns/upload_batch.rb` | F-S21-1, F-S21-2 | H10 |
| `projects/bom_lines_controller.rb` | F-S16-2 (`#create`), F-S19-1 (`#consume`) | Different actions; safe in parallel |
| `config/ci.rb`; `.github/workflows/ci.yml` | F-S26-1, F-S26-2; F-S26-2, F-S29-2 | E11, H5 |
| `test/test_helper.rb` | F-S27-1, F-S27-2 | Same slice (S-1) |
| `test/deploy_hygiene_test.rb` | F-S12-2 (:491-590), F-S25-1 (:591-760), F-S01-1's consumer (:796-830) | Disjoint blocks |
| `lib/schema_map.rb` + generated `docs/schema-map.html` | F-S23-1, F-S23-2, F-S24-2 (SOURCES :34-39), T2 (EDGES), F-S11-1 (new column → regeneration) | The generated page conflicts on every merge; regenerate after rebasing |
| `db/schema.rb` | F-S05-1, T2, F-S11-1, F-S16-2, F-S23-2 | The version line conflicts; regenerate after rebasing |
| `CLAUDE.md` (1,360 / `MAX_LINES` 1,360) | F-S26-1 (§13/§15, removes lines), F-S01-1 and F-X-1 (§14a), F-S24-2 (§4), F-S23-2 (§5), T2 (§14a's two-tombstone bullet) | Every edit must add no net lines. S-1 should LOWER the ceiling, as the ratchet comment asks ("Lowered rather than banked, which is the whole point of calling it a ratchet", `docs_hygiene_test.rb:39-40`). T2's new invariant should replace words, not add a bullet |
| `ops/backup-db.sh` | F-S25-2 (restructure), F-S24-2 (optional edit at :229) | F-S24-2 should skip its optional edit; `[ -f … ] \|\| continue` already tolerates the missing file |

### 1.7 Topological order (text)

1. **Wave 0 — enablers (S-1):** F-S26-1; then F-S27-1 → F-S27-2 step 1.
2. **Wave 1 — P1 defects, in parallel (no shared files):**
   - S-2 (T1), S-3 (F-S19-1), S-4 (F-S08-1 ∥ F-S10-1), S-5 (F-S07-1).
   - Then F-S15-2, F-S15-1, F-S09-1 + F-S22-1, F-S25-1, F-S23-1, F-S03-2.
3. **Wave 2:**
   - T2, after T1, F-S23-1 and F-S03-2.
   - F-S01-1 → its consumers (H8).
   - F-S21-1 → F-S21-2.
   - F-S04-1 → H7's two items.
   - F-S05-1; F-S13-2; F-S11-1; F-S14-1; F-S16-1; F-S28-1; F-S28-2; F-S12-2; F-S06-1; F-S13-1.
4. **Wave 3:** the P3 items; F-S29-2's presence-test half; F-S23-2's index half.
5. **Conditional — after a prerequisite or a decision:**
   - F-S08-2 (after F-S08-1).
   - F-S24-1 (after F-S07-1 and F-S27-1, with test (a) re-pointed).
   - F-S07-2 (after F-S07-1, a measurement, and the owner's sign-off).
   - F-S26-2 (after F-S26-1 and F-S01-1).
   - F-S29-2's `--locked` half → the parity fix.
   - F-S12-1 (two PRs).
   - F-S17-1 with the §4 demo safety note (owner).
   - F-S16-2 (owner picks the shape).
   - F-S02-2 (with the folder rename/move feature).
   - F-S05-2 (after F-S05-1).
   - Folds: F-S10-2, F-S20-2, F-S29-1.

---

## 2. Ranked table

### 2.1 Scoring rule (stated before applying it)

**Score = I + C + E + U + G.** Tiers: **P1 ≥ 5.0 · P2 4.0–4.5 · P3 3.0–3.5 · P4 ≤ 2.5.**

- **I — Impact, 1–5**, by the most severe thing the finding removes. Tags: RD reachable defect, LD latent defect, DATA user-data loss or corruption, SEC security/tenancy, OPS operator/deploy risk, GG guard gap, DUP duplicated decision (with "drifted" where a recorded bug exists), DEAD unread state.
  - 5 = reachable at HEAD on a deployed backend: user-data loss or corruption, a tenancy breach, or a deploy that can ship with an empty secret.
  - 4 = reachable at HEAD: a user-visible wrong or stuck result, a 500, or a silent wrong write; or a missing gate that lets the repo's own definition of "green" pass over a stated bug class on every PR.
  - 3 = a latent defect (needs an unscheduled path, an operator mistake, a crafted request or a rare race), or a duplicated decision whose copies have already drifted into a recorded bug.
  - 2 = a duplicated decision or dead state with no recorded drift.
  - 1 = cosmetic or documentation only.
- **C — Confidence:** high +1, medium-high +0.5, medium 0, medium-low −0.5, low −1.
  - This is the entry's own confidence in its defect/facts and its remedy, taking the lower of the two when it states both.
  - Statements about payoff, materiality, frequency, placement or naming are excluded; Impact already carries them.
  - Owner calls are excluded; G carries them.
  - Never raised above the entry's own words. Lowered (marked ↓) where my re-check found the evidence thin — once, for F-S24-1.
- **E — Effort:** S 0 · M −1 · L −2.
  - S = at most 3 production files with substantive change; no migration that rewrites existing rows' meaning; no CI-workflow or image change.
  - M = 4–8 substantive production files; or a migration that rewrites existing rows' meaning; or a substantive rewrite of a data-path verb; or a CI-workflow/runner-image change; or one image publish; or 20+ test files of churn.
  - L = more than 8 substantive production files; or more than one image publish; or a sibling-repo change; or a two-release retirement.
- **U — Unlocks:** +1 if the finding is a hard prerequisite of another finding's scope, or a guard that strengthens the validation of 3+ other findings (§1).
- **G — Gated:** −1 if an owner/product decision or a live-data measurement must come BEFORE the code.
- **Ties:**
  1. Unlocks more (soft edges count here).
  2. Retires a reachable defect.
  3. Smaller blast radius (production files).
  4. Any remaining tie stays in report order.
- **Groups:** a finding inside a recommended same-PR group is scheduled at the group's highest tier; its own score is still shown.

### 2.2 Table (all 49)

| # | ID | Finding (short) | I · what it removes | C (entry → used) | E | Blast radius / flags | Prereqs | Score | Tier |
|---|---|---|---|---|---|---|---|---|---|
| 1 | F-S26-1 | `bin/ci` compares the legs' run counts | 4 · GG: §15's definition of green is checked by nobody; the close-out doc is wrong | high → +1 | S | `config/ci.rb`, new `lib/ci/leg_runs.rb`, CLAUDE.md §13/§15 (net −), 2 command files · gate definition · no deploy · same added runs per leg | — (protects all: E1) | 6.0 | P1 |
| 2 | F-S07-1 | Catalogue honours discovery's positional claim | 4 · RD: permanent wrong auto models past the 50-folder cap on every backend; chunk_remote order race · DUP | high → +1 | S | 2 services + prose (`scan_job.rb`, `recurring.yml`, 2 invariant docs) · rows only · 3 legs | — · unlocks H1, H2 | 6.0 | P1 |
| 3 | F-S08-1 | One "does this row need a job?" predicate | 4 · RD: wedged previews never heal from any read door; backfill reports 0 · DUP | high → +1 | S | `enqueue`/`thumbnail_map`/`missing_backfill` + 3 door methods in 2 controllers · 3 legs | — · unlocks H3 | 6.0 | P1 |
| 4 | F-S03-1 | One S3 trash-entry shape | 5 · DATA/RD on the s3 deployment and OVH (R2): folders that cannot be deleted, deleted folders returning under new ids, restore dead end until purge | m-h → +0.5 | M (step 1: S) | `s3.rb` (+ s3_test) · FakeS3 runs on all legs · runtime: s3 + OVH | T1: none · T2: H4 | 5.5 | P1 |
| 5 | F-S02-1 | Record trash membership (`trash_root_node_id`) | 5 · DATA/RD on share (the real-data deployment): a restore 500s midway → orphaned node_ids; un-restorable listings; grace window re-stamped | m-h → +0.5 | M · MIG | migration + backfill, `share.rb`, `s3.rb`, schema-map EDGES (+ regeneration) · every DB gets the column | H4 (T1); E4, E5 | 5.5 | P1 |
| 6 | F-S19-1 | Ledger model owns what a postable row is | 5 · SEC/DATA: another tenant's project name/slug disclosed via the device API; immutable Infinity/NaN rows | m-h → +0.5 | S | model + web controller + `#consume` rescue (+ one-line view guard) · v1 WIRE: zero/non-finite delta → 422 · all destinations | E3 (for its test (c)) | 5.5 | P1 |
| 7 | F-S27-1 | Harness owns the `FileLayer` memo's lifetime | 3 · GG: two recorded leaks; ~90 hand-reset sites | high → +1 | S | `test_helper.rb`, probe test, 6 pin lines, README · test-only | — · protects E2 | 5.0 | P1 |
| 8 | F-S27-2 | Verifying web sign-in (step 1) | 3 · GG: negative tests that pass vacuously; 306 failures recorded once | high → +1 | S (sweep: M) | `test_helper.rb`, `public_fixture.rb` (13 suites) · test-only | — · protects E3 | 5.0 | P1 |
| 9 | F-S09-1 | Measure's phase has one owner | 4 · RD: double load; ✕ reopened by a late draw; dead Back snapshot (Reset throws TypeError) | high → +1 | S | `measure_controller.js` + system tests | E9 | 5.0 | P1 |
| 10 | F-S22-1 | 3D viewer lifecycle | 4 · RD: dead Back snapshot; the engine ignores every later request after a switch mid-import | high → +1 | S | `modelviewer_controller.js` + system tests + shared helper | E9 | 5.0 | P1 |
| 11 | F-S15-2 | Omitting a block/tab from the draft deletes it, inside `merge` | 4 · RD: Apply resurrects deleted blocks/tabs; Save refuses valid drafts; spurious "Publish moved" note | high → +1 | S | `layout_document.rb`, `panels_controller.rb` | — | 5.0 | P1 |
| 12 | F-S15-1 | One "which folders get no tiles" answer | 4 · RD: images in browsed repos never backfilled (lasting on chunk_remote); backfill budget spent on unpainted files | high (edit-mode semantics is an owner call, not confidence) → +1 | S | `projects_controller.rb`; deletes one `ProjectFolderListing` method | — | 5.0 | P1 |
| 13 | F-S10-1 | One bounded content-read door | 4 · RD: a cached nil disables the board viewer / 3MF units for up to 30 days, survives deploys, can be planted anonymously, can misfile a board zip · DUP (drifted) | high (placement/naming excluded) → +1 | S | new `content_read.rb` + 2 readers · cache namespace bump | — | 5.0 | P1 |
| 14 | F-S25-1 | One secret-site walk shared by preflight and test | 4 · GG/OPS: the gate against a silent-empty deploy has no test; drift recorded | high → +1 | S | `bin/secrets-preflight`, new lib file, `deploy_hygiene_test` · no deploy | — | 5.0 | P1 |
| 15 | F-S01-1 | One reading of LIBRARY_BACKEND | 3 · LD/OPS: an unknown value passes both guards then 500s every response · DUP (patched twice) | m-h → +0.5 | S | `library_backend_check.rb`, initializer, one line in `file_layer.rb`, delete `lib/library_backend.rb` (+2 lines in `application.rb`), CLAUDE.md §14a (net ≤ 0) · boot behaviour on every destination | — · unlocks H8 | 4.5 | P2 |
| 16 | F-S16-1 | Sheet autosave decided by comparison | 4 · RD/DATA: undo/sort/rename/resize lost while the label says "Saved" | m-h → +0.5 | S | `sheet_controller.js` + system tests | owner sub-choice (persist or disable sort/drag), not blocking | 4.5 | P2 |
| 17 | F-S14-1 | One "shown" answer for public pages | 4 · RD on anonymous pages: hidden folders' pictures on card/hero; renders queued for hidden/backup files; CSV paths | m-h → +0.5 | S | `public_project.rb` | owner's yes for the card change (land it last) | 4.5 | P2 |
| 18 | F-S11-1 | Stamp each addon file with its revision | 4 · RD: "Edit in Boxes" saves over the stale file in the old folder; wrong labels | m-h → +0.5 | S · MIG (additive) | migration + 3 files + 2 doc lines · states JSON order (bundles read `files[0]`) | — | 4.5 | P2 |
| 19 | F-S23-1 | NOT_EDGES completeness rule | 3 · GG: new `*_id` columns pass both derived guards; one live omission | high → +1 | S | `lib/schema_map.rb` + test + regeneration | — · before T2 (E4) | 4.0 | P2 |
| 20 | F-S04-1 | ChangelogSync parses replies into one NodeState | 3 · LD: resync drops version/size/manifest (unreachable until H7) | high → +1 | S | `changelog_sync.rb` + test · chunk_remote only | — · gates H7 | 4.0 | P2 |
| 21 | F-S13-2 | CommitPaths reads each path once | 3 · LD race: the index records a blob the commit did not; double I/O | high → +1 | S | `commit_paths.rb` | — | 4.0 | P2 |
| 22 | F-S28-2 | `bin/log` filing helper | 3 · RD during an outage: `close` loses its record; the spool names the wrong endpoint | medium (stated for payoff) → +1 | S | `bin/log` + test · dev tooling | — | 4.0 | P2 |
| 23 | F-S05-1 | Partial index for tombstone lookups | 3 · LD perf: quadratic first scan; overlapping scans past ~240k files | high → +1 | S · MIG (index) | migration + one query term + amend the `architecture_invariants_test` comment | — · H9 | 4.0 | P2 |
| 24 | F-S21-2 | The batch owns every per-file refusal | 4 · RD on share/s3: a reserved or oversize file mid-batch → "File not found." or a 500 after earlier files were written | medium (shape) → 0 | S | `upload_batch.rb` + 2 controllers | H10 | 4.0 | P2 |
| 25 | F-S28-1 | Delete `bin/migrate-record` | 3 · OPS: a second write door, with DELETE verbs, onto the canonical record | high → +1 | S (trivial) | one file deleted | — | 4.0 | P2 |
| 26 | F-S12-2 | One owner of catalogue admission rules | 3 · GG: the external-reference rule runs nowhere · DUP (drifted once) | medium (materiality) → +1 | S | `deploy_hygiene_test.rb` + 2 Python test files + docs · no image | — | 4.0 | P2 |
| 27 | F-S06-1 | ProjectIntake result as one row per file | 3 · DUP (recorded drift, 521bfb30); a fallback that masks a broken side channel | medium (payoff) → +1 | S | `project_intake.rb`, `project_folder_intake.rb`; 6 hand-built Results in tests | — | 4.0 | P2 |
| 28 | F-S13-1 | Commit box computes each row once | 3 · DUP (shipped drift once) + duplicate reads | m-h (the I/O estimate is payoff) → +1 | S | `local_repo.rb`, `repo_commits_controller.rb`, `show.html.erb` | — | 4.0 | P2 |
| 29 | F-S18-1 | Drop `rescue_from ArgumentError` from the v1 base | 3 · LD: bugs and misconfiguration answered 422 with internals, never reaching error tracking | m-h → +0.5 | S (trivial) | one line + one test · v1 WIRE: 422 → 500 on ArgumentError | — | 3.5 | P3 |
| 30 | F-S20-1 | Icon rail as one container query | 3 · RD (cosmetic): the sign-in card's wordmark is hidden below 1100px on every self-hosted front door (inferred, not observed) · DUP | m-h → +0.5 | S | `shell.css`, `landing.css` (+ comments, design-system.md) | — | 3.5 | P3 |
| 31 | F-S03-2 | One blank-ETag rule; FakeS3 returns LastModified | 2 · LD (needs a misbehaving store) + GG (the fake agrees with the code) | high (value excluded) → +1 | S | `object_identity.rb`, `s3.rb` (3 sites), `fake_s3.rb` | — · before T2 (E5) | 3.0 | P3 |
| 32 | F-S29-2 | One locked resvg pin; a CI presence gate | 3 · GG: missing renderers skip silently; unlocked rasteriser dependencies drift between image builds | medium (risk latency is payoff) → +1 | M · RIMG · PIMG · CIWF | 2 Dockerfiles, `ci.yml`, deletes the script, 2 tests, 1 doc · CI-runner rebuild · production image | H5; then H6 | 3.0 | P3 |
| 33 | F-S21-1 | Retire the unrouted project-upload arm | 2 · DUP: a second, unreachable door that disagrees with the reachable one | high (intent is not confidence) → +1 | S | `routes.rb`, `uploads_controller.rb`; ~10 tests deleted or ported | H10 | 3.0 | P3 (rides with F-S21-2 → P2) |
| 34 | F-S02-2 | A directory move rebases its descendants | 2 · LD: no door reaches it today (FOLDERS_NOT_YET); enables a blocked feature | medium (payoff) → +1 | S | `share.rb#move` | — · E12 | 3.0 | P3 |
| 35 | F-S17-1 | One demo admission predicate | 3 · LD: the demo door opens while the nightly reset refuses (needs a demo account on chunk_remote) | medium (direction is an owner call) → +1 | S | `demo_reset.rb`, `demo.rb`, `demo_sessions_controller.rb` | owner decision (G −1); H8 (optional part) | 3.0 | P3 |
| 36 | F-S20-2 | Help renders the shared partial | 2 · DUP (copy drifted twice) | medium (payoff) → +1 | S (trivial) | `help/show.html.erb` + test | — | 3.0 | P3 |
| 37 | F-S05-2 | Reconciler pass state has one owner | 2 · DUP / preventive (a missed site caught in review) | medium (payoff) → +1 | S | `reconciler.rb` | H9 | 3.0 | P3 |
| 38 | F-X-1 | Drop the dead port kwargs | 2 · DEAD: phantom device rows; a §14a rule that governs nothing | high → +1 | S (mechanical) | 3 adapter signatures, `files_controller.rb:922-925`, `library_output.rb`, `application_controller.rb`, CLAUDE.md §14a (net −) | — | 3.0 | P3 |
| 39 | F-S16-2 | A BOM stock line's unit lives in the model | 3 · RD: the shipped desktop composer stores its own unit; public table/CSV mislabel | m-h → +0.5 | M · MIG (rewrites units) | `bom_line.rb`, `inventory_item.rb`, `bom_lines_controller.rb` + data migration · v1 WIRE | shape decision (S16 callback vs S18 reader) | 2.5 | P4 |
| 40 | F-S29-1 | Make `render.mjs`'s exit codes true | 2 · RD: the failure text is node's crash report; a declared code is unreachable | medium (not executed) → 0 | S (trivial) | `render.mjs` + one assertion · production image content | — | 2.0 | P4 |
| 41 | F-S07-2 | Reconcile auto-model rows; retire Prune | 3 · RD: stale rows (a file in two models, ghost models, wrong bundles); a write lock every tick | medium (decision and measurement are G) → +1 | M | attachments controller, `model_intake.rb`, `model_intake_job.rb`; deletes `prune.rb` + rake task + test | H1; owner + measurement (G −1) | 2.0 | P4 |
| 42 | F-S08-2 | A `rebuilding` status + named predicates | 3 · RD (transient): Measure serves the old build; a lost rebuild never heals | medium (shape) → 0 | M | ~14 files (model, helper, 7 partials, 3 controllers, enqueue, job) | H3 | 2.0 | P4 |
| 43 | F-S25-2 | One backup-destination table | 3 · GG/OPS: a destination backed up but never pinged (it happened); a restore could target the wrong volume | medium (no harness) → 0 | M · OPS | `ops/backup-db.sh`, `bin/restore-db` (+3 optional); new static test; reinstall the crontab on the box | — | 2.0 | P4 |
| 44 | F-S24-2 | Retire the Solid Cable database | 2 · DEAD/OPS: a provisioned, migrated, backed-up store nothing reads | medium (payoff) → +1 | M · every destination | Gemfile(.lock), `cable.yml`, `database.yml`, `cable_schema.rb`, schema-map SOURCES/LAYOUT + regeneration, INSTALL.md, CLAUDE.md §4 | — | 2.0 | P4 |
| 45 | F-S10-2 | One typed Viewer for both file pages | 2 · DUP (no recorded drift; the public half is unpinned) | m-h → +0.5 | M | `file_preview.rb`, 2 controllers, 2 templates | E7; S14's agreement | 1.5 | P4 |
| 46 | F-S26-2 | CI gate jobs carry runner plumbing only | 2 · GG: local and CI boot differently under one gate name | medium (direction unmeasured) → 0 | M · CIWF | `ci.yml`, `config/ci.rb`, `ci_hygiene_test` (+ `bin_sync_server_test`, E6) | E11, E6; H5 | 1.0 | P4 |
| 47 | F-S24-1 | One post-catalogue sweep job | 2 · DUP / latency, once F-S07-1 has landed | medium → **m-l ↓ −0.5**: its test (a) is vacuous after its own prerequisite (H2) | M | new job + 3 jobs + `scan_job.rb` + `scans_controller.rb` + `recurring.yml` | H2, E2, E10 | 0.5 | P4 |
| 48 | F-S12-1 | Sidecar schemas send `param_groups` only | 2 · DUP/DEAD: a lossy flat key nobody reads | m-h → +0.5 | L · two image publishes · sibling read | 2 sidecars' app/schema + tests; two `bin/publish-sidecar` runs; re-grep tinkerex-addons | split into 2 PRs | 0.5 | P4 |
| 49 | F-S23-2 | Retire schema state nothing maintains | 2 · DEAD: `updated_seq`, `maker_file_attachments.version_id`, a readerless index | high → +1 | L (2 releases) · MIG · v1 WIRE | 2 migrations, `ignored_columns`, 3 v1 files, preview scope, prose (CLAUDE.md §5) | product question first (G −1); E4, E8 | 0 | P4 |

### 2.3 Step- and half-level scores (scored as their own smallest shippable step)

- **F-S03-1 step 1 and F-S02-1's no-migration step (together, T1):** 5 + 0.5 + 0 + 1 = **6.5** each. This is the first slice of both findings.
- **T2 on its own:** 5 + 0.5 − 1 + 0 = 4.5. It still inherits P1, because it completes two P1 findings and fixes S3's restore dead end, which makes §14a's "a refusal is recoverable — restore the folder, then the file" claim true on S3 for the first time.
- **F-S29-2's CI-only presence test alone:** 3 + 1 + 0 = **4.0 (P2)**.
  - Its `--locked` half: 2 + 1 − 1 = 2.0 (P4).
  - Land the presence test first, as the entry itself says, and check it is green on the live runner image.
- **F-S23-2's index half alone** (drop the two readerless indexes): 2 + 1 + 0 = **3.0 (P3)**. It can ride any later migration PR.
- **F-S27-2's sweep (c)/(d):** 2 + 1 − 1 = 2.0 (P4), as its own change.
- **F-S12-1, each half (one image each):** 2 + 0.5 − 1 = 1.5 (P4).
- **F-S10-1's in-place fallback** (move each rescue outside its own `fetch`; add GerberArchive's banner arm): same 5.0. Use it if the shared door is contested in review.

---

## 3. Best first slices

Rules applied to every slice:
- Bare `bin/ci` green on every gate.
- The three backend legs report identical run counts.
- Every new guard mutation-checked.
- No sibling-repo change and no sidecar image publish.
- The usual `../tinkerex-sync` checkout for `test-chunk-remote`.

### S-1 — Suite honesty: F-S26-1 + F-S27-1 + F-S27-2 step 1 (a)+(b)

**Order inside the slice:**
1. F-S26-1:
   - Add `lib/ci/leg_runs.rb` with its unit tests.
   - In `config/ci.rb`, tee `test` and `test-s3` under `set -uo pipefail`, repoint the chunk_remote leg's tee, and compare runs whenever two or more legs ran.
   - Fix `finish-branch.md:28-30` and `execute-plan.md:85-87`.
   - Trim CLAUDE.md §13/§15 and LOWER `MAX_LINES` to the new count.
2. F-S27-1:
   - Add an unconditional `FileLayer.reset!` to the shared teardown.
   - Delete `pin_file_layer_backend`, its two flags, the six calls, and the README advice that recommends it.
   - Leave the ~16 now-redundant comments for later; they sit in other rows' files.
3. F-S27-2 (a)+(b): add `sign_in_web!` to `test_helper.rb`, and make `PublicFixture#sign_in_as` delegate to it.

Why this order: the leg comparison exists before steps 2–3 add runs, so it checks them. Steps 2–3 are the likeliest to expose hidden failures, and they do so under a gate that already compares legs.

**Tests that prove it:**
- LegRuns unit tests (a)–(c), each with its mutation: parse assertions instead of runs; treat a missing summary as 0; take the first match.
- Once, end to end:
  - Add `TEST=test/models` to `test-s3`: the run must go red naming both counts.
  - Plant a failing test under `test`: the step must go red (tee swallows nothing).
- Harness probe: a directly assigned ChunkRemote is gone after teardown. Mutation: delete the reset line → this probe and `fresh_share_library_cleanup_test.rb:81-89` both go red.
- The six de-pinned job tests stay green. Mutation: swap their `use_fresh_share_library!` for a ChunkRemote assignment → red.
- `sign_in_web!` refuses an unconfirmed user, naming the email. Mutation: drop the assertion.
- Before/after: a wrong password turns `attach_from_files_test.rb:44-49,89-98` and `public_project_test.rb:28-37` red at the helper.
- `docs_hygiene_test` passes under the lowered ceiling.
- Bare `bin/ci`.

**Files:**
- `config/ci.rb`
- `lib/ci/leg_runs.rb` (new) + its test
- `test/test_helper.rb`; `test/support/public_fixture.rb`; one harness test
- `test/jobs/maker/{model_intake_job,project_discovery_job}_test.rb` (pin lines only)
- `test/system/README.md`
- `CLAUDE.md`; `test/docs_hygiene_test.rb`
- `.claude/commands/{finish-branch,execute-plan}.md`

**Owners to coordinate:** S26 (gates, commands, docs_hygiene); S27 (harness); S14 (`public_fixture.rb` is in its boundary); S06 and S07 (the job tests); S30 (CLAUDE.md prose).

**Why first:**
- No product code, no deploy.
- Every later slice's "green" then means §15's definition. Today only a person compares the legs, and the close-out file every slice loads names a non-existent gate and asks for equal assertion counts.
- Hidden order dependence surfaces once, centrally.

**Risks:**
- An unknown number of tests that pass today only via a leaked adapter or an anonymous session. If more than a handful turn red, split F-S27-1 into its own PR.
- Time the s3 leg before and after: F-S27-1 rebuilds an Aws client per test. Its snapshot variant costs nothing.

### S-2 — Trash, delete side (T1): F-S03-1 step 1 + F-S02-1's no-migration step

**Order inside the slice:**
1. In `S3#delete_directory!`:
   - The object set becomes `.present` file rows plus each directory's marker; check marker existence by HEAD.
   - Build each destination key root-relative, from the parent-edge walk.
   - Delete markers in phase 2.
   - Run the phase-3 UPDATE over `.present` ids only (`s3.rb:532,545-546,568`).
2. Run Share's cascade over `.present` ids only (`share.rb:423`).
3. Make `Share#revive_subtree!` skip rows that kept a path or own a `.trash/<id>` entry (`share.rb:694-712`).
4. Correct the false comments: `s3.rb:530-531` ("a descendant already tombstoned by a scan has a NULL path") and the phase-2 recovery claim. Fix the mislabelled fixture in `subtree_test.rb:41-48` (AUDIT.md:694).

Optional rider: §4's `Share#write` `mkdir_p` sitting outside `begin` (AUDIT.md:692).

**Tests that prove it:**
- New `s3_test` cases:
  - "a folder holding a file the scan tombstoned still deletes" — mutation: drop `.present`.
  - "a deleted folder stays deleted across a scan" — mutation: drop the markers.
  - "a nested folder's entry is root-relative".
- New `share_test` cases:
  - "a NAS-deleted file inside a later-deleted folder is never offered for restore" — mutation: drop `.present`.
  - "a folder delete does not re-stamp an older tombstone" — separate the times with `travel_to(3.days.ago)`; never compare at `.to_i`.
  - "restoring a folder after a replace does not 500 while the earlier entry exists" — mutation: drop the skip.
- Existing pins: the s3/share delete/undelete/cap suites, `adapter_mutation_contract.rb`, `share_trash_test`, and `trash_purge_job_test` (the purge groups by the first segment after `.trash/`, which is unchanged).
- Bare `bin/ci`. FakeS3 and tmp library roots run on every leg, so counts stay equal.

**Files:**
- `app/services/file_layer/{s3,share}.rb`
- `test/services/file_layer/{s3,share,subtree}_test.rb`

**Owners to coordinate:**
- S03 (key shape) and S02 (Share cascade and revive).
- S01 (the Subtree contract — do NOT narrow `Subtree.node_ids`).
- S05 (scan tombstones keep their paths; the observer reads markers as directories).
- S17 (DemoReset deletes through `S3#delete` on OVH, `demo_reset.rb:139-142`).

**Why first:**
- It retires live, data-facing defects on both deployed writable backends — share holds the real data, per the user's memory note — with no migration and no interface change.
- Read from the code, not observed: it also stops leftover markers from re-minting deleted app-made folders under new node_ids. That includes the public demo's nightly reset (`demo_reset.rb:139-142` → `s3.rb:532` excludes markers) and project folders that discovery would then treat as unclaimed (AUDIT.md:684).
- It is T2's prerequisite (H4).

### S-3 — Ledger integrity and tenancy: F-S19-1

**Order inside the slice:**
0. Write the v1 probes first and watch them fail at HEAD. Today `%w[Infinity -Infinity NaN 1e400 0]` answer 201, and an adjust naming another user's project stores that project id. §4 (AUDIT.md:725) asks for exactly one confirming request before the fix; the probe test is that request.
1. In the model, add `MAX_DELTA` and `numericality: { other_than: 0, in: -MAX_DELTA..MAX_DELTA }` on create, so the immutability test keeps raising `ReadOnlyRecord`.
2. Make `apply!` scope `project_id` to the item owner's projects and normalise `note` (`inventory_transaction.rb:38-46`; today `v1/maker/inventory_items_controller.rb:35-39` passes `project_id: params[:project_id]` raw).
3. In the web controller, delete `parse_delta`, `MAX_DELTA`, the REASONS re-check and the project lookup, and rescue `RecordInvalid` into the existing alert.
4. Make `Projects::BomLinesController#consume` rescue `RecordInvalid`.
5. Add a one-line read guard at `inventory_items/show.html.erb:88` (`t.project.user_id == @item.user_id`), so rows already written stop disclosing without waiting for the optional census. Fix the false model comment (`inventory_transaction.rb:10-19`, "renders as —").

**Tests that prove it:**
- Model tests for the five strings. Mutations: drop `in:`; drop `other_than: 0`.
- v1 tests: 422, ledger unchanged.
- v1 cross-tenant: 201 and a stored nil; then the poster's item page, asserted 200 FIRST (E3), does not contain the foreign name.
  - Mutation: drop `user_id: locked.user_id`.
  - Mutation: drop the view guard while a foreign row is pre-planted.
- Consuming a stock line with an Infinity quantity posts nothing.
- Update `inventory_transaction_test.rb:57` and the three "Enter a non-zero" flash patterns.
- Bare `bin/ci`.

**Files:**
- `app/models/maker/inventory_transaction.rb`
- `app/controllers/inventory_items_controller.rb`
- `app/controllers/projects/bom_lines_controller.rb` (`#consume` only)
- `app/views/inventory_items/show.html.erb`
- Tests under `test/models/maker/`, `test/integration/web/inventory_test.rb`, `test/integration/v1/maker/`

**Owners to coordinate:** S19 (model, web); S18 (v1 behaviour: a zero delta now answers 422 — check that tinkerex-client never sends one); S16 (`#consume`).

**Why first:** it is the only finding where any device-token holder can read another tenant's data, and it also stops permanent ledger corruption. It is small, and §4 asks for it on its own track ahead of any simplification work.

### S-4 — Preview reliability: F-S08-1 + F-S10-1

**Order inside the slice** (the files are disjoint; order matters for review only):
1. F-S10-1:
   - Add `Maker::ContentRead` and route both readers through it.
   - Rescue outside the cache.
   - Give GerberArchive the banner arm.
   - Bump both cache namespaces.
2. F-S08-1:
   - Add `Enqueue.needs_job?` with `retry_failed:`.
   - The doors that already hold a row ask it.
   - MissingBackfill loads the batch's rows.
   - Correct `enqueue.rb:43-67` and `measure-view.md:320-333`.
   - Name the in-flight set once, ready for F-S08-2 (H3).

**Tests that prove it:**
- F-S10-1, under a MemoryStore:
  - FetchError → nil plus banner; then the real answer, with a second read counted.
  - NotFound → nil without banner.
  - Mutations: put the rescue back inside the fetch; delete the banner line.
- F-S08-1 request tests, with a `processing` row stamped 3 days ago via `travel_to`:
  - The Files page and the file page re-enqueue it; MissingBackfill counts it.
  - A fresh `processing` row is not re-enqueued.
  - The inspector's "failed is never re-enqueued" test stays green.
  - Mutations: delete the stall line; drop `retry_failed: false` at `current_thumbnail`; drop the restamp.
- Bare `bin/ci`.

**Files:**
- `app/services/maker/{content_read (new),gerber_archive,three_mf_manifest}.rb`
- `app/models/current.rb` (prose)
- `app/services/maker/previews/{enqueue,thumbnail_map,missing_backfill}.rb`
- `app/controllers/files_controller.rb` (`#current_thumbnail`, `#geometry`)
- `app/controllers/public/files_controller.rb` (`#enqueue_geometry`)
- `docs/invariants/{files-preview,measure-view}.md`
- Tests

**Owners to coordinate:** S10 (readers, FilesController); S08 (pipeline); S14 (public controller); S09 (the Measure geometry door's doc); S06 (ProjectIntake still calls `GerberArchive.for`, unchanged).

**Why first:**
- Two reachable, user-visible defects on every backend: previews that never heal, and a cached nil that an anonymous visitor can plant (AUDIT.md:697).
- Each is small with a sharp mutation, and F-S08-1 unlocks F-S08-2.
- F-S10-1 is pulled forward from rank 13 because it shares the theme and no files.
- Expect a trivial textual conflict with the upload slice: `#current_thumbnail` (`files_controller.rb:1230`) sits directly above `#enqueue_preview` (`:1244`), which that slice deletes.

### S-5 — Catalogue claims: F-S07-1

**Order inside the slice:**
1. Add `ProjectDiscovery.positional_claims(user)` — public and uncapped — and define `adoptable` through it.
2. Make `ModelIntake.claimed_folders` include it.
3. Add the tests below; re-point DiscoveryOrderTest's swallow assertion and fix its two stale mutation comments.
4. Update prose: `model-intake.md`, `project-intake.md`, `scan_job.rb`, `recurring.yml`.

**Tests that prove it:**
- (a) A folder discovery will adopt is not catalogued before adoption. Mutation: drop the union.
- (b) A dot-folder under `Projects/` is still catalogued. Mutation: replace discovery's reader with a path test.
- (c) A capped discovery (`cap: 1`) leaves no auto model for the rest. Mutation: cap the reader.
- (d) The same through `Library::ScanJob` with `PROJECT_DISCOVERY_MAX=1`.
- Existing pins: claim/archived/import/prune and `project_adoptions_test:350-371`. `model_intake_defaults_test.rb:51,80-81` change on purpose.
- Bare `bin/ci`.

**Files:**
- `app/services/maker/{project_discovery,model_intake}.rb`
- `test/services/maker/model_intake*_test.rb`; `test/jobs/library/scan_job_test.rb`
- `docs/invariants/{model-intake,project-intake}.md`
- Prose only in `app/jobs/library/scan_job.rb` and `config/recurring.yml`

**Owners to coordinate:** S07 (catalogue); S06 (discovery's file); S05/S24 (the `scan_job.rb` and `recurring.yml` prose).

**Why first:**
- Two small edits close a deterministic correctness hole (the discovery cap, on every backend) and the chunk_remote ordering race.
- It is the hard prerequisite of F-S07-2 and F-S24-1, and must land before anyone writes F-S24-1's order test (H2).

### Running the five in parallel

- **Files:** no two slices touch the same file, so they can be opened together.
- **CLAUDE.md:** S-1 lowers the line ceiling. None of S-2–S-5 edits CLAUDE.md, but any later slice that does must add no net lines (§1.6).
- **Close-out:** until S-1 merges, the other slices must compare RUN counts by hand. Today's `finish-branch.md` asks for equal assertion counts, which never hold.
- **Local `bin/ci` in parallel worktrees:** give each worktree a distinct `SYNC_PORT`, because the chunk_remote leg kills whatever listens on the port (`config/ci.rb:149-157`). Also set `TINKEREX_SYNC_DIR`, per the user's memory note.
- **CI capacity:** CLAUDE.md §15 records four Linux runners (a dated measurement). Five PRs × seven jobs will queue; stagger the pushes.

**Next wave** (the rest of P1, then the head of P2):
- T2 — after S-2, with F-S23-1 and F-S03-2 landed or folded in.
- F-S09-1 + F-S22-1 — one viewer-lifecycle PR.
- F-S15-2 (plus §4's layout-editor JS fixes) and F-S15-1 — one project-page PR, or two.
- F-S25-1
- F-S01-1
- F-S21-1 + F-S21-2

---

## 4. Defects vs simplifications

### 4.1 The 49 findings

| Kind | Findings | When to fix, relative to the representation change |
|---|---|---|
| Defect-led; the representation change IS the minimal fix | F-S04-1, F-S01-1, F-S11-1, F-S15-1, F-S15-2, F-S08-1, F-S09-1, F-S14-1, F-S13-2, F-S16-1, F-S21-2, F-S22-1, F-S07-1, F-S18-1, F-S28-2, F-S29-1, F-S20-1 | **With** it — the smallest fix is the same size |
| Defect-led; a smaller first step retires the defect | F-S03-1 + F-S02-1 (T1 before T2); F-S10-1 (in-place fallback if the door is contested) | **Before** the full representation |
| Defect needing a decision or a prerequisite | F-S17-1 (owner, with §4's demo safety note); F-S16-2 (shape); F-S07-2 (after F-S07-1, after measuring); F-S08-2 (after F-S08-1) | **With** it, once unblocked |
| Security defect | F-S19-1 | **Before** any simplification in S16/S18/S19; it is already minimal |
| Guard gaps | F-S26-1, F-S27-1, F-S27-2, F-S25-1, F-S23-1, F-S12-2, F-S29-2 (presence half first), F-S03-2 (FakeS3 half), F-S26-2, F-S25-2 | **Independently** and early — they protect other slices |
| Pure simplifications (no live defect) | F-S10-2, F-S05-2, F-S06-1 and F-S13-1 (recorded drift, now masked), F-S20-2, F-X-1, F-S21-1, F-S23-2, F-S24-1, F-S24-2, F-S12-1, F-S28-1 (removes a hazard), F-S02-2 (enabler), F-S05-1 (perf; a defect only at scale) | By cost, or folded into neighbouring work |

### 4.2 §4 items that are defects or guard gaps (not simplifications)

Ranked on my I scale; AUDIT.md line numbers in parentheses.

| Item | Kind · I | Timing | Rides with |
|---|---|---|---|
| `FilesController#restore` overwrites uncommitted working-tree edits without warning (:700). Re-read at HEAD: `files_controller.rb:748-793` compares against disk only to refuse a no-op, then writes with `replace: true` | DATA · 4 | **Independently, early.** Compare against HEAD's blob and refuse or confirm; one door | — |
| Demo SAFETY NOTE: `DEMO_ACCOUNT_EMAIL` turns whatever account has that address into the nightly-wiped demo (:714) | OPS/DATA on misconfiguration · 4 | Owner decision | Decide together with F-S17-1 |
| `CHUNK_LOCAL_DIR` lying under the mounted volume is pinned by no suite (:735) | GG over a data-destroying misconfiguration · 3 | Independently | F-S25-1 (same test file) |
| node subprocess has no heap bound; under `SOLID_QUEUE_IN_PUMA` the OOM killer could pick Puma (:742) | OPS · 3 | Independently; one flag | — |
| `production.rb:178` defaults `ADDON_SOURCE_PATH`, so OVH's `/tools` says "configured but returned nothing" (:733) | RD on the public box · 3 | Independently; a one-line quick win | — |
| Zero-byte desktop-synced files unreadable on chunk_remote (:660; `chunk_remote.rb:151,191`) | RD on the base deployment · 3 | Independently | Could ride F-S04-1's PR |
| Cursor ahead of a restored sync server goes unnoticed (:660) | LD/OPS · 3 | **After** F-S04-1 (H7) | — |
| `ChunkRemote#finalize_upload` returns `info: nil` on a conflict, so the upload gets no preview, intake or notice (:723) | RD · 3 | Independently | — |
| `readmes_controller` has no NotFound arm, so it 500s inside chunk_remote's mirror lag (:700) | RD · 3 | Independently | — |
| `EntryPhotosController#destroy` destroys any of the user's attachments, then 500s (:702) | DATA (own rows; crafted request) · 3 | Independently; scope the find | — |
| `gerber.rb` writes layers as `layer.<ext>`, dropping the basename that identifies the layer (:742) | RD (board thumbnail shape) · 3 | Independently | — |
| `uploader_controller.js` reloads over its own failure message, discards the notice, has no busy guard (:723) | RD (client) · 3 | Independently | — |
| A geometry build can be requested for any extension, storing a PNG as `geometry` (:687) | RD · 3 | After F-S08-1 | — |
| LightBurn `i` flag mismatch draws bitmaps as cut contours (:688) | RD · 3 | Independently; needs a FORMAT_REVISION bump | — |
| S3 listing vs a concurrent web delete → ghost live node; can wedge scans on tiny libraries (:671; reasoned) | LD · 3 | After T1 | — |
| Spool lives per checkout, so records strand in worktrees (:739) | OPS · 3 | Independently | F-S28-2 |
| Desktop client sends role `"reference"` → 422 (:732) | RD in the sibling · 3 | tinkerex-client | — |
| Public "deliverable" is wider than "listable" for dot/build directories (:696) | Disclosure by UUID · 3 | Owner decision | — |
| §14a's restore claim is false on S3; the mutation contract has no folder-restore case (:683) | GG · 3 | — | **T2** |
| A leftover marker brings back a project folder under a new node_id (:684) | RD · 3 | — | **Fixed by T1** |
| Layout editor counts tab slots against the block cap; `stored_views`; tab-name lengths; YAML/view responses applied in arrival order (:667) | RD · 2–3 | — | **F-S15-2** |
| `measure_controller.js` paper preference reads/writes localStorage unguarded (:688) | RD · 2 | — | **F-S09-1** (same controller) |
| Public geometry redirect `expires_in 1.minute` (:680) | RD (transient) · 2 | — | **F-S08-2** |
| An oversize upload is reported as NotFound ("File not found.") (:723) | RD · 2 | — | **F-S21-2** |
| Real-spool guard is vacuous on CI's detached checkout (:739) | GG · 2 | — | **F-S28-2** |
| `repo_commits` accepts the `.git` marker as `root_id` (:700) | RD (crafted) · 2 | — | **F-S13-1** (same controller) |
| `DemoReset#purge_trash!`'s s3 arm (the OVH production path) is untested (:716) | GG · 3 | Independently; worth it before or with T1, since the reset deletes through `S3#delete` | — |
| Prefix-index guard never asserts its table set is non-empty (:738) | GG (§14e shape) · 2 | Independently; one line | — |
| Smaller one-liners: rescan drops `q`/`selected` (:664); `relocate` 500s on `:in_working_tree` (:674); `chosen_parent_node_id` lacks its `is_a?(String)` check (:661); Share `write`'s `mkdir_p` sits outside `begin` (:692); editor parses JSON before checking `res.ok` (:700); unmapped socket errors (:660); `RESERVED_HANDLES` misses `demo`/`pins` (:718); `model_owning` ignores `dismissed_at` (:720) | RD/GG · 1–2 | Independently | `mkdir_p` may ride T1; `model_owning` may ride F-S07-2 |

---

## 5. Deferrals — not scheduled in the next cycle

**Defer:**
- **F-S23-2.**
  - A product question comes first: are version-pinned attachments planned?
  - It needs two releases, changes the v1 JSON, and rebuilds the SQLite `nodes` table.
  - The payoff is hygiene.
  - Its index half (3.0) can ride any later migration.
- **F-S12-1.**
  - Two sidecar image publishes, and nothing reads the flat key.
  - Sidecar pytest is not in `bin/ci`, so verification is by hand.
  - It needs a fresh read of tinkerex-addons at implementation time.
  - When scheduled, split it into two PRs.
- **F-S24-1.**
  - After F-S07-1, what remains is representation and latency.
  - Medium effort across the scheduler, and only a live worker can prove the shared semaphore.
  - Its test (a) must be re-pointed first (H2).
- **F-S26-2.**
  - No shipped bug, and its direction needs a measured CI run.
  - Wait for F-S26-1 and F-S01-1 (E6, E11).
- **F-S07-2.**
  - Reverses a recorded decision (`model-intake.md:177-192`).
  - Its first run deletes rows on every live database, so measure the would-delete set read-only first (the 2026-09-02 precedent touched 2,441 rows).
  - Needs the owner's sign-off, and F-S07-1 first.
- **F-S08-2.** About 14 files to close a transient window. Do it after F-S08-1; fold §4's `expires_in` fix in.
- **F-S24-2.** Operational housekeeping that changes Gemfile and database topology on every destination. Needs a manual `db:prepare` check on Postgres.
- **F-S25-2.**
  - Shell scripts with no test harness, and a security-adjacent ping parser.
  - The crontab must be reinstalled on the box.
  - Its value depends on a stubbed rehearsal actually being run.
- **F-S16-2.**
  - The owner must first pick the shape: S16's callback + backfill, or S18's reader override.
  - It rewrites existing units with a data migration.
  - BOM usage was low in the last probe (see §6).
- **F-S27-2's sweep (c)/(d).** About 100 test files; its own change, after step 1.

**Fold — do not defer:**
- F-S10-2 → the next change to either file page, after F-S08-2's consumer step (§1.4).
- F-S20-2 → with F-S20-1.
- F-S29-1 → with F-S29-2 or the next Gerber change.
- F-S21-1 → inside F-S21-2's PR.

**Wait for a decision or a feature:**
- F-S17-1 → owner: shut the demo door on chunk_remote, or teach the reset to rebuild there. Decide it with §4's demo safety note.
- F-S02-2 → schedule with the folder rename/move feature that lifts FOLDERS_NOT_YET.
- F-S05-2 → the next Reconciler change, after F-S05-1.

---

## 6. What I could not check

- **Nothing was run** — no tests, no `bin/ci`, no requests, no SQL. Every "red today" and every reachability claim comes from reading the code and the entries. These were not driven:
  - F-S19-1's cross-tenant disclosure.
  - F-S03-1's folder resurrection on the s3 deployment, and the OVH demo-reset consequence I reasoned in S-2.
  - F-S10-1's cache poisoning.
  - F-S15-1's lasting effect on chunk_remote.
  - The restore-overwrites-edits defect in §4.2.
- **Re-verified at HEAD only the lines my edges, efforts and tiers rest on.** That is every file:line cited in §1–§3: `config/ci.rb`, `ci.yml`, `docs_hygiene_test.rb`, `scan_job_test.rb`, `model_intake.rb`, `project_discovery.rb`, `enqueue.rb`, `missing_backfill.rb`, `preview.rb`, both file controllers, `gerber_archive.rb`, `three_mf_manifest.rb`, `s3.rb`, `share.rb`, `upload_batch.rb`, `uploads_controller.rb`, `library_output.rb`, `application_controller.rb`, `inventory_transaction.rb`, the v1 inventory controller, `inventory_items/show.html.erb`, `library_backend_check.rb` + its initializer, `registration.rb`, `deploy_hygiene_test.rb`, `bin_sync_server_test.rb`, `schema_map.rb`, `structural_orphan_test.rb`, `test_helper.rb`, `public_fixture.rb`, `bin/publish-sidecar`, `bin/sync-server`, `demo_reset.rb`, both Dockerfiles, `bin/migrate-record`. The other citations inside the 49 entries were not re-checked; the schema pass covers those.
- **Sibling repos were not read.** Unknown:
  - whether tinkerex-sync plans to schedule `prune_changelog` (how urgent H7 is);
  - whether tinkerex-client can send a zero delta (F-S19-1's new v1 422) or reads preview status values (F-S08-2);
  - tinkerex-addons' readers for F-S12-1 and for `#states` order (F-S11-1).
- **Live deployments were not inspected.** Unknown:
  - data volumes (F-S05-1's scale; F-S07-2's would-delete set);
  - real feature usage — the user's memory note from the 2026-09-07 probe ("project layer unused") may be stale after the October redesign, and it was not used to discount the project-page, BOM or sheet findings;
  - whether the OVH demo already accumulates visitor-made empty folders;
  - the CI runner image's actual renderer set (the first run of F-S29-2's presence test).
- **Effort** is estimated from each entry's scope text and file counts, not from implementing anything. Test-churn counts are the entries'.
- **F-S26-2's "stronger" direction:** unknown whether GitHub CI can boot development without `master.key`.
- **Vendored JS engine behaviour** (the o3dv import guard, the jspreadsheet dispatcher) was not re-read; I relied on S16's and S22's verification.
- **The other four audit-the-audit passes were not consulted**, to stay independent. Any demotion they recommend is not reflected in these tiers.
- **The CI runner count** (four) is CLAUDE.md §15's dated measurement, not re-measured.
