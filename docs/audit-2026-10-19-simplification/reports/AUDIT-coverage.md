# Audit-the-audit: repository coverage
Tracked files: 1672. Mapped to a row: 1360 (review rows S01–S29; 25 of them sit in two rows with no tie-break). Covered by skip rows (S30/S31): 288 (S30 263, S31 25). Unmapped: 5.
Out of scope by the audit's own declaration: 19 (all `.keep` placeholders, which are also the only tracked files under `storage/`, `tmp/` and `log/`). 1360 + 288 + 5 + 19 = 1672.

How this was checked: `git ls-files` at HEAD 75124d67 (the tree is clean apart from the pre-existing untracked jpg). Every row's Boundary and Tests lists in AUDIT.md §1 were encoded as path patterns, including every EXCEPT and "owned by" clause. Each file was tested against every row, not just the first that matched.
- FilesController's split by action (S10/S13/S21) counts as covered. The three reviewers' line ranges together cover all 1,886 lines.
- Two explicit tie-breaks were honoured: `bundle_controller.js` (moved S11→S14 by the correction) and `test/services/file_layer/chunk_remote/upload_test.rb` (S21 says "wire half, S04").
- For (d), every path in a row's boundary was compared with that row's "Files read" section. Brace lists, "all N", greps and "test names of every other …" statements all count as mentions.

## (a) Unmapped tracked files

| File | Why no row matches | Natural owner | Opened by |
|---|---|---|---|
| `app/javascript/controllers/application.js` | S20's `controllers/{application,index,…}_controller.js` expands to `application_controller.js`, which does not exist | S20 | S20 (all) |
| `app/javascript/controllers/index.js` | same brace list (`index_controller.js`) | S20 | S20 (all) |
| `sidecar/boxes/LICENSE` | S12 lists 6 of the 8 tracked `sidecar/boxes` files | S12 | S12 (header) |
| `sidecar/boxes/README.md` | same | S12 | S12 (all) |
| `Gemfile.lock` | S24 lists `Gemfile` only | S24 | no owner. S07 and S25 grepped it for versions. It is a generated file. |

None of these is a real gap. The row that should own each of the first four opened it, and the fifth is a generated lockfile. Each needs only a correction to the boundary text.

## (b) Ownership overlaps (file → rows)

27 files fall in two rows. 2 have the explicit tie-breaks above. The other 25 do not.

**Code (8):**
- `app/views/files/viewers/_code.html.erb` → S10, S13. S10's EXCEPT list omits `viewers/_code`. Only S13 opened it.
- `app/views/files/viewers/{_gerber,_image,_kicanvas,_model3d,_pdf,_static}.html.erb` → S10, S22. S10's EXCEPT list names only `viewers/_measure`. Both rows opened them.
- `ci/ensure-resvg.sh` → S26 (`ci/**`) and S29 (named explicitly). Both opened it in full.

**Tests (17).** "Opened by" is taken from each claiming row's Files read.

| Test | Rows | Opened by |
|---|---|---|
| test/integration/v1/capability_gating_test.rb | S01, S18 | both |
| test/integration/web/files_git_marker_test.rb | S05, S10 | S05 (names only) |
| test/integration/web/files_rename_move_test.rb | S06, S10 | **neither; no report names it** |
| test/integration/web/repo_trash_pages_test.rb | S10, S13 | **neither** (only S27, as harness context) |
| test/integration/web/files_flow_test.rb | S10, S21 | both |
| test/integration/web/public_preview_test.rb | S08, S14 | both |
| test/integration/web/public_file_view_test.rb | S14, S22 | both |
| test/integration/web/page_query_budget_test.rb | S15, S27 (only S27's side says "(the budget mechanism)") | both |
| test/integration/web/account_settings_test.rb | S17, S20 | both (names only) |
| test/models/maker/build_log_body_migration_test.rb | S16, S23 | **neither; no report names it** |
| test/models/maker/note_body_migration_test.rb | S16, S23 | **neither; no report names it** |
| test/models/structural_orphan_test.rb | S17, S23 | both |
| test/models/tenant_cleanup_test.rb | S17, S23 | both |
| test/worker_budget_test.rb | S24, S27 | both |
| test/system/page_tabs_test.rb | S15, S20 | both |
| test/system/tray_layout_test.rb | S15, S20 | S20 (names only); filed under the wrong row (below) |
| test/system/tray_top_view_test.rb | S15, S20 | S20 (names only); filed under the wrong row |

**Where the test overlaps come from:**
- 13 of the 17 come from a name-prefix glob in one row's Tests line colliding with another row's explicit name. The globs are `v1/*`, `files_*`, `repo_*`, `public_*`, `account_*`, `*_migration`, `page_*` and `tray_*`.
- The other 4 are named explicitly by both rows: page_query_budget, structural_orphan, tenant_cleanup and worker_budget.

**Tests filed under the wrong row:** `test/system/{tray_layout,tray_top_view}_test.rb` (S15 + S20) and `test/system/plan_export_test.rb` (S09 only).
- All three drive the Box Generator bundle snapshot in `test/fixtures/addons/boxes/` through `FakeBoxesSidecar`; each file's header says so (e.g. `plan_export_test.rb:12-15`).
- They test nothing in S09, S15 or S20.
- S11, which owns the `box_*` tests, does not claim them.
- No reviewer went past a test-name scan of them.

## (c) Unowned or split subsystems

### C1. The addon bundle snapshot: `test/fixtures/addons/**` (23 files, 3,244 lines)

**What it contains:**
- `boxes/*.js`: 18 files, 2,710 lines. A client-side router over one mount (gallery, editor, show), tray layout and tray sync, a top-view plan, history and revisions, section folding, and plan/PDF/SVG/sheet export.
- `fixture/{dep,fixture,save}.js` (137 lines), `sdk-fixture/sdk.js` (360) and `manifests.json` (37).

**Why no reviewer owned it whole:**
- The `test/fixtures/**` catch-all maps it to S27 (the test-harness row). S27's reviewer opened only `boxes/boxes.js` 1-30, `fixture/save.js` 1-40 and `manifests.json`. The other 20 files were opened by no reviewer in this repo.
- S11 read four modules of the canonical copy in `../tinkerex-addons` instead.
- The 14 test files that point `ADDON_SOURCE_PATH` at this directory are spread over five rows:
  - S11: `box_revisions`, `box_save_folder`, `box_sections`, `addon_bundle`, `addon_sdk`, `new_menu` (both), `tools_gallery`, `addon_destination`
  - S09: `plan_export`
  - S10: system `file_menu`
  - S15 + S20: `tray_layout`, `tray_top_view`
  - S20: `template_hygiene`
- The only drift guard is upstream. `box_sections_test.rb:13-15` says nothing in this repo's CI catches drift, and `box_revisions_test.rb:12` names `bin/check-fixture-drift` in tinkerex-addons.

### C2. The file-type and role vocabulary (extension → role → renderer, viewer, filing and hero image)

It is about 30 extension tables, 8 role tables and 9 data migrations, spread over 7 rows:
- **S06:**
  - `Maker::FileAttachment::{ROLE_LABELS, ROLES, ROLE_BY_EXT, TEXT_ROLES, IMAGE_EXTS, INLINE_IMAGE_EXTS, PHOTO_EXTS, TEXT_EXTS, TEXT_EXTENSIONS, BACKUP_EXTS}`
  - `Maker::ProjectFolders::ROLE_FOLDERS`
  - `Maker::FilingRules::BEYOND_ROLE_BY_EXT`
  - `Maker::ProjectIntake::BOARD_LAYER_EXT`
- **S07:** `Maker::ModelIntake::{MODEL_ROLE, EXCLUDED_ROLES}`; `importer_controller.js` `IMAGE_EXT`, `MODEL_EXT`, `roleFor`.
- **S08:** `Maker::Previews::Registry::RENDERERS`, plus `EXTENSIONS` in nine renderers: `image_thumb`, `stl`, `pdf`, `text_thumb`, `svg`, `gerber_zip`, `three_mf`, `mesh`, `gerber`.
- **S09:** `EXTENSIONS` in `dxf`, `lbrn2`, `mage`.
- **S10:**
  - `FilePreview::{MEASURABLE_EXTS, KICANVAS_EXTS, GERBER_EXTS}` and `#preview_kind`
  - FilesController's re-exports and its type filter (`EXT_RE`, `MAX_EXTS`, `LIKE_EXT`)
  - `Maker::GerberArchive::EXT`, `Maker::ThreeMfManifest::EXT`
- **S15:** `Maker::ProjectKind::{HERO_ROLES, DEFAULT_HERO_ROLES, KICAD_EXTS}`.
- **S23:** the 9 role data migrations (`db/migrate/*rederive*roles*`, `*seed_*filing_rules*`) and their 9 tests.

**Why no reviewer owned it whole:**
- S06 owns `ROLE_BY_EXT` but was not given `docs/invariants/files-preview.md`. That is the file CLAUDE.md §14d points to ("Add an extension in `ROLE_BY_EXT` only"). S06's Files read names only `project-intake.md` among the invariants docs.
- The doc went to S08, S10 and S22, which own only consumers of the vocabulary.
- Four reviewers each met a slice and stopped at their row's edge:
  - S07.md:191-192: the importer's `roleFor` drift, judged "below the bar".
  - S08.md:259: deriving `RENDERERS` from `EXTENSIONS`, weighed within S08 only.
  - S09.md:72: the geometry dispatch and `MEASURABLE_EXTS`, which "lives in … (S08) and FilePreview (S10)".
  - S23.md:330-338 and :375: the role migrations exist only because `ROLE_BY_EXT` widens, and the desktop client's `guessRole` disagrees with it.

**Checked and not gaps:**
- The Gerber chain spans S08, S10, S22 and S29, but S29 read the S08, S10 (`gerber_archive`) and S22 pieces as call sites.
- Rich text: `TextOnlyRichText` is S16's; its users are Note (S10) plus BuildLogEntry and Release (S16).
- The demo account: the code is S17's. `db/seeds/demo/**` is filed under S23 but is data only, and S17 read its one consumer, `demo_reset.rb`.
- CSP: the policy is S24's and the report endpoint is S17's; both were read.
- `docs/superpowers/specs/2026-08-27-git-tracked-projects-{packwriter.rb,spike.sh}` are code inside the docs row that is skipped as "prose, not code". They are design spikes that nothing loads.

## (d) In-boundary files a row's reviewer never opened

### Code (app/, lib/, config/, bin/ and similar)

- **S20:**
  - `app/assets/stylesheets/pages/{files (152 lines), inventory (34), models (93), projects (364), public (97), search (35), tools (276)}.css` were opened by no reviewer at all.
  - `pages/preview.css` (409 lines) was not opened by S20. S09 (220-280) and S22 (150-250, 355-367) read parts of it as context. `preview.css:234-248` is where F-S09-1's `measure-view--ready` class takes effect.
  - `app/assets/stylesheets/{jspreadsheet,jsuites}.css` are vendored, jsDelivr-minified CSS (7 lines each). Nobody opened them, and they belong with S31's other vendored files.
  - In total, 1,460 lines of first-party CSS were never read by their owner. They contain 14 state-like selectors (preview 6, files 4, tools 3, public 1), the kind of state-in-CSS that F-S09-1 and F-S20-1 found elsewhere.
- **S27:** `test/fixtures/addons/**`: 20 of 23 files never opened (see C1). The 31 binary samples in `test/fixtures/files/*` were only listed, which is fine for binary samples.
- **S22:** the vendored bundles `vendor/javascript/{three.module,three.core,3MFLoader,OrbitControls,kicanvas,tracespace,fflate,jszip,jszip-buffer-chunk,buffer,process}.js` were not opened, `o3dv.js` got only targeted reads, and `public/o3dv/0.18.0/*` was only listed. These are third-party, so S31's skip rationale applies.
- **S26:** `ci/runners/setup-windows.ps1` (71 lines) was not opened; the reviewer says so. `setup-macos.sh` was read 1-25 of 51 and `ci/runners/README.md` 1-200 of 361.
- **S25:** `scripts/r2-cutover/{cors.json, r2.env.example}` are not mentioned. `{apply-cors,migrate-chunks,smoke}.sh` were only grepped, and `RUNBOOK.md` was read 1-40 of 248.
- **S23:**
  - 86 of the 93 `db/migrate/*` files were seen only through a listing and greps. That is acceptable for frozen history (CLAUDE.md §10), but the 9 role migrations belong to C2.
  - `db/{queue,cache,cable}_schema.rb` were only grepped, and `db/seeds/**` was only listed (it is data).
- **S15:** `app/views/projects/{new,edit}.html.erb` were not opened. They are 3 lines each, so this does not matter.
- **S10:** `app/views/files/viewers/_code.html.erb` was not opened, but S13 read it in full, so nothing was lost.
- **Every other row** (S01–S09, S11–S14, S16–S19, S21, S24, S28, S29) names every app, lib, config and bin file in its boundary.

### Tests the citing row never opened (117 files; lower priority)

- **S10 (28 of 38):**
  - `test/controllers/files_controller_preview_kind_test.rb`
  - `test/helpers/{files_helper,notes_helper}_test.rb`
  - `test/integration/web/{back_link,file_cell_payload,file_links,file_menu_wiring,file_page,files_git_marker,files_pagination,files_rename_move,folder_nav,inspector,library_unreachable,notes,page_nodes,pins,repo_trash_pages,trash_flow}_test.rb`
  - `test/models/maker/{file_link,note,pin}_test.rb`
  - `test/services/maker/gerber_sets_test.rb`
  - `test/system/{file_chooser,file_menu,files_layout,files_pages,files_selection}_test.rb`
- **S11 (18 of 26):**
  - `test/controllers/tools/{addon_params_controller,home_controller,library_folders}_test.rb`
  - `test/integration/web/{lazy_bundles,new_menu,tools_gallery}_test.rb`
  - `test/models/maker/addon_state_revision_test.rb`
  - `test/services/maker/addons/{check,host,permissions,service_proxy,source}_test.rb`
  - `test/system/{addon_bundle,addon_sdk,box_save_folder,box_sections,new_menu}_test.rb`
  - `test/tasks/addons_tasks_test.rb`
- **S06 (17 of 26):**
  - `test/integration/web/{attach_from_files,attach_model_bundle,files_rename_move,moved_reference_pages,project_attachments,settings_filing,where_files_come_from}_test.rb`
  - `test/models/maker/{file_attachment,file_attachment_uniqueness,filing_rule}_test.rb`
  - `test/services/maker/{attachment_reaper,filing_rules,library_folder,library_tree,move_node,project_folders}_test.rb`
  - `test/tasks/projects_sweep_pointers_test.rb`
- **S15 (16 of 25):**
  - `test/integration/web/{project_cover,project_repo_card,project_wiring,projects_flow}_test.rb`
  - `test/models/maker/{project,project_block}_test.rb`
  - `test/services/maker/{markdown,project_folder_listing,project_kind,project_photos,readme}_test.rb`
  - `test/system/{page_editor,project_scan_reload,readme_editor,tray_layout,tray_top_view}_test.rb`
- **S08 (13 of 29):**
  - `test/services/maker/previews/{embedded_thumbnail,gerber,gerber_zip,image_thumb,mesh,pdf,stl,svg,svg_rasterizer,three_mf}_test.rb`
  - `test/support/{gerber,mesh,three_mf}_fixture.rb`
  - S29 read the stl, gerber, gerber_zip and svg_rasterizer tests and `gerber_fixture.rb` as context.
- **S23 (11 of 18):** `test/models/maker/{build_log_body,delete_addon_parameters_file_rows,note_body,rederive_code_roles,rederive_document_roles,rederive_laser_roles,rederive_model_roles,rederive_roles,seed_bench_filing_rules,seed_image_filing_rules,seed_pcb_filing_rules}_migration_test.rb`. S23 grepped `test/` for them instead.
- **S13 (6 of 19):**
  - `test/integration/web/repo_trash_pages_test.rb`
  - `test/services/maker/git/local_repo_tags_test.rb`
  - `test/system/{code_theme,code_viewer,repo_browser,repo_history}_test.rb`
- **S09 (3 of 16):** `test/services/maker/previews/{lbrn_metadata,svg_path}_test.rb`, `test/system/plan_export_test.rb`.
- **S07 (2 of 21):** `test/integration/web/{models_import,models_pages}_test.rb`.
- **S16 (2 of 21):** `test/models/maker/{build_log_body,note_body}_migration_test.rb`.
- **S20 (1 of 26):** `test/no_emoji_test.rb`.
- **All other rows** name every cited test, or cover them with a blanket statement: S14 has "test names in every other S14 test file" and S18 has "names of every other test/integration/v1/maker/*_test.rb".

## Proposed new rows (S32+)

### S32 — Addon bundle fixture snapshot
- **Boundary:** `test/fixtures/addons/**` (23 files). Move `test/system/{tray_layout,tray_top_view,plan_export}_test.rb` here from S15, S20 and S09.
- **Read-only inputs:**
  - the canonical bundle in `../tinkerex-addons/addons/` and its `bin/check-fixture-drift`
  - `app/javascript/maker/addon_sdk.js` (S11)
  - `test/support/{fake_addon_source,fake_boxes_sidecar}.rb` (S11)
  - `docs/invariants/addons.md`, `docs/addon-api-v1.md`
- **Interfaces:**
  - the bundle entry point `mount(element, context)`
  - `@maker/addon-sdk`: the `host` live binding, `AddonError`, `ServiceError`
  - `manifests.json` (`entry`, `services`, `min_host`)
  - loading through `ADDON_SOURCE_PATH` → `Maker::Addons::Source::Local`
  - sidecar replies stubbed at `Maker::Addons::ServiceProxy` by `FakeBoxesSidecar`
- **Tests:**
  - `test/system/{box_revisions,box_save_folder,box_sections,tray_layout,tray_top_view,plan_export,addon_bundle,addon_sdk,new_menu,file_menu}_test.rb`
  - `test/integration/web/{template_hygiene,tools_gallery,new_menu}_test.rb`
  - `test/controllers/tools/addon_destination_test.rb`
- **Note:** the canonical code lives upstream, so any simplification of the bundle itself should be filed there. The question for this repo is the snapshot's shape and how it drifts, and a `skip` is a valid result.

### S33 — File-type and role vocabulary
- **Boundary:** split by symbol, the way FilesController is split by action: everything listed under C2. Read-only input: `docs/invariants/files-preview.md`.
- **Interfaces:**
  - `ROLE_BY_EXT` lookups and the stored `maker_file_attachments.role`
  - `Registry.renderer_for` and `FilePreview#preview_kind`
  - `ROLE_FOLDERS` filing and `HERO_ROLES`
  - the model-intake role exclusions
  - the type filter's `EXT_RE`
  - the client's `roleFor`
- **Tests:**
  - `test/models/maker/file_attachment_test.rb`
  - `test/services/maker/previews/{registry,renderer_contract}_test.rb`
  - `test/controllers/files_controller_preview_kind_test.rb`
  - `test/integration/web/files_type_filter_test.rb`
  - `test/services/maker/{filing_rules,project_folders,project_kind,model_intake_classify}_test.rb`
  - `test/system/importer_test.rb`
  - the 9 `test/models/maker/{rederive_*,seed_*_filing_rules}_migration_test.rb` files
- **Read first:** the rejections of deriving the stored role by S06 and S23 (AUDIT.md §5), plus S08.md:259, S07.md:191-192 and S09.md:72.

### S34 — Feature page stylesheets (optional, low priority)
Recording these files as a deliberate skip in §3 is an acceptable alternative to this row.
- **Boundary:** `app/assets/stylesheets/pages/{files,inventory,models,preview,projects,public,search,tools}.css` (1,460 lines). Move `app/assets/stylesheets/{jspreadsheet,jsuites}.css` to the S31 skip, since they are vendored.
- **Interfaces:**
  - the `@layer` order, and the rule that component selectors live only in `components.css` (`docs/invariants/design-system.md`)
  - the class names that templates use and the 52 addon-shared classes
  - the state classes that viewer controllers toggle, e.g. `measure-view--ready` at `preview.css:234-248`
- **Tests:** `test/css_hygiene_test.rb`, `test/integration/web/cohesion_vocabulary_test.rb`, and the system tests that assert layout (`files_layout`, `measure_*`, `shell`, `phone_topbar`).

## Verdict: has gaps
1. **Two subsystems no reviewer owned whole:** the addon bundle snapshot (C1, proposed as S32) and the file-type and role vocabulary (C2, proposed as S33).
2. **One broad boundary left unread:** S20's eight page stylesheets (1,460 lines). Either add S34 or record an explicit skip.
3. **25 overlaps with no tie-break:**
   - Four tests were opened by neither claiming row: `files_rename_move`, `repo_trash_pages`, `build_log_body_migration` and `note_body_migration`.
   - Three tests are filed under the wrong row: `tray_layout`, `tray_top_view` and `plan_export` belong with S32.
   - S10's EXCEPT list should also exclude the seven viewer partials, and `ci/ensure-resvg.sh` needs one owner.
4. **Five files miss the literal boundary text** (see (a)). These are text fixes only; nothing went unread.
5. **Bookkeeping:** `reports/S12.md`, `S27.md` and `S29.md` exist, but AUDIT.md §1 still marks those rows "in review (batch 4)". Harvest them before declaring the contract closed. Each of those reviewers opened the code in its boundary, except S27's addon fixtures.
