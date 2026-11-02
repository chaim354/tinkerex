# UX audit fixes — implementation plan

**Source:** `docs/superpowers/audits/2026-11-01-ux-ui-audit.md` (the audit; every finding below is
cited by its letter-number, e.g. B5). **Branch:** `claude/ux-audit-fixes`, in the main checkout.
**Method:** `.claude/commands/execute-plan.md` — tasks batched by FILE OWNERSHIP, run in parallel
where the file sets are disjoint, one capped quality review per task, bare `bin/ci` at the end.

Three waves. Wave 1 is seven area tasks with disjoint file sets. Wave 2 (the time sweep) and wave 3
(the terminology sweep) each touch files across every area, so they run alone, after wave 1.

## Rules every task follows

1. **Only edit the files your task owns** (listed per task), plus NEW test files named
   `test/integration/web/<area>_*_test.rb` / `test/system/<area>_*_test.rb` and new partials under
   view directories you own. If a fix needs a file outside your list, do NOT edit it: write down
   exactly what is needed and report it. Other implementers are editing the other files right now.
2. **Never** `git checkout`, `git stash`, `git reset`, `git commit`, or switch branches. Restore a
   mutation by editing the exact original text back with the Edit tool.
3. **Read before editing:** CLAUDE.md §14d (the maker web layer), §15, and
   `docs/invariants/design-system.md` in full. Each task names any further invariant file.
4. **Design-system rules that bind here:** one accent per screen, selection is ink; no emoji in the
   interface; breadcrumbs through `content_for :crumbs` with the page title last (rule 9); a
   component selector lives in `components.css` and nowhere else (page-specific selectors go in
   `pages/<area>.css`); the pinned class names are a contract (rule 12); a status carries its word
   (rule 13); on-demand panels are decided in `ProjectsController#show` (rule 14).
5. **Tests:** run ONLY your area's test files, never the bare suite, with your own database:
   `env LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) DATABASE_URL=sqlite3:storage/test_<slug>.sqlite3 PARALLEL_WORKERS=2 bin/rails test <files>`.
   Also run the hygiene tests that your change can trip: `test/css_hygiene_test.rb`,
   `test/stimulus_hygiene_test.rb`, `test/no_emoji_test.rb`,
   `test/integration/web/template_hygiene_test.rb`, `test/integration/web/cohesion_vocabulary_test.rb`,
   `test/integration/web/page_query_budget_test.rb`, `test/integration/web/back_link_test.rb`,
   `test/docs_hygiene_test.rb`, `test/install_docs_test.rb` where relevant; and `bin/rubocop <changed .rb files>`.
6. **Every new test that FORBIDS something gets mutation-checked**: break the code it guards,
   run it, paste the actual red output in your report, restore the exact original text, run green.
7. **A change that invalidates documented behaviour sweeps every file documenting it**, in the
   same task: grep for the old wording (comments, Help copy, docs/) and fix them all.
8. **Report:** files changed; each finding → what you did (or why not); product decisions you
   made; tests run with their counts; mutation outputs verbatim; anything that needs a file you do
   not own; anything you could not verify.
9. Error copy is for a maker, not an operator: name the thing and the next step, never a class
   name, a wire code, a MIME type or an env var (D10, D13, H).

## Shared decisions (so the tasks agree)

- **The place is "Library"**, never "Files" (A3). Wave 3 renames the h1/title/crumb roots; area
  tasks use "Library" in any copy they write now.
- **Sign in / Sign out**, never "Log in" (F4). **"Rescan library"** is the one name for the index
  pass; the intake pass is "filing" ("Loose files are filed on the next scan"), never "sweep".
- **Return-to-origin:** a mutation returns the user to the page they acted from (the pattern of
  `rename_move_landing` / `back_target_path`), never to a root.
- **Confirms** read "Verb named-object?" and add one sentence when the action is irreversible or
  wider than it looks ("Delete the folder catan and everything in it?").
- **Refusals re-render with errors and keep the input** (status 422), the way project details and
  model edit already do (B3). Under Turbo, re-render the page with the composer open and errors in
  it — never a redirect-with-alert that drops the text.
- **Timestamps:** leave `strftime` calls alone in wave 1 (wave 2 replaces them all with one helper).
- **Toast kinds:** notice = `flash-notice`, error = `flash-alert`; an error is never a `flash-notice`.

---

## Wave 1

### T1 — Shell: phone reach, the 1024 rail, toasts, the Upload button (A1, A2, A5, A6, A7, I "Unfocusable primary action", part of F1)

**Owns:** `app/views/layouts/**`, `app/helpers/shell_helper.rb`, `app/assets/stylesheets/shell.css`,
`app/javascript/controllers/{toast,theme,rail,upload_pick,upload_forward,menu}_controller.js`,
`app/views/projects/_upload_control.html.erb`, `app/views/settings/_theme.html.erb`,
`public/icon.svg`, `public/icon.png`, `app/views/pwa/**`, `test/system/{shell,phone_topbar,topbar_upload,topbar_zip_upload,settings_theme}_test.rb`.

1. **A1 — a fifth tab, "More".** Under 720 px the tab bar gets a fifth item that opens a sheet
   (a `details.menu`-style popover anchored to the bar, or a bottom sheet) listing Inventory,
   Trash, Settings, Account, Help, the theme control and Sign out — every rail destination the
   four tabs do not carry. `ShellHelper#tabbar_links` stays the one source of the tab list; the
   More item lights when the current section is one of its members. Keyboard: the sheet is
   focusable, Escape closes it. Test at 375 px in a system test: each destination reachable.
2. **A2 — the 1024 icon rail.** At ≤1099 px the rail is icons only and the Collapse button does
   nothing. Make the button meaningful there: the `rail` cookie's "expanded" state overrides the
   container-query collapse (an explicit choice beats the width default), and the arrow points the
   way the rail will move in each state. Projects and pins in the icon rail show as a monogram
   tile (first letter, `title` = name) rather than vanishing. The Upload caption stays hidden.
3. **A5 — toasts.** Move `.flash-stack` so it never covers New ▾ / Upload (below the top bar at the
   right, or bottom-right — your call, say which). A notice's 6 s timer pauses on hover and on
   focus within; Escape dismisses the focused toast; an alert still stays until dismissed.
   `role`/`aria-live` stay as they are (tests assert the classes).
4. **A6 — theme control.** The rail button names the action, not the state ("Switch to dark" /
   "Switch to light" / "Use system theme" in a 3-step cycle, or an explicit menu — your call),
   and the Settings page has one control, not a lowercase "Theme: light" beside its own buttons;
   choosing on Settings updates the rail label at once.
5. **A7 — shell gaps.** The ⌘K hint is platform-aware (⌘K on Mac, Ctrl+K elsewhere, the way the
   calculator does it); Theme and Collapse get a `title` like their neighbours; the Upload folder
   choice on a folder-less page is re-asked each click rather than sticking silently
   (`upload_pick_controller.js:25,43`); replace the Rails scaffold red circle in `public/icon.svg`
   (and `.png`) with a plain Tinkerex mark (an ink "T" monogram on a paper square using the
   `--paper`/`--ink` colours is enough), and make the manifest's `theme_color` agree with the meta tag.
6. **Upload is a button.** `layouts/_topbar_upload.html.erb:44-79` and
   `projects/_upload_control.html.erb:27-51` render a `<label>` over a hidden input. Make the
   visible control a `<button type="button" class="upload-btn">` that opens the hidden input
   (`input.click()`), keeping every existing Stimulus target/action so the upload flows do not
   change; class names stay (rule 12). Verify with the existing `topbar_upload`/`uploader` system tests.
7. **F1 (shell half).** Add `users/registrations` (edit/update) to the Settings section in
   `ShellHelper::SECTIONS` so the Account page lights Settings. T6 adds the page's title and crumbs.

### T2 — Project edit area: the layout editor, Details, Publishing (B1, B2, C6, C10's instant deletes and "Add tab", "hero" and "YAML" copy, B3 publishing refusal, C10 "Project created" FetchError)

**Owns:** `app/javascript/controllers/layout_editor_controller.js`, `app/controllers/projects_controller.rb`,
`app/controllers/projects/{panels,layouts,unlisted_tokens}_controller.rb`, and these views under
`app/views/projects/`: `_edit_head`, `_edit_crumbs`, `_layout_bar`, `_layout_drawer`, `_form`,
`_publish`, `_preview_banner`, `_block_editor`, `_block_templates`, `_tab_slot`, `_panel_slot`,
`_panel_strip`, `edit`, `publishing`, `preview`, `new`; `test/system/{page_editor,page_tabs,page_blocks}_test.rb`.

1. **B1 — never lose a draft.** The layout editor tracks dirtiness; when dirty, `beforeunload`
   and `turbo:before-visit` ask before leaving (one confirm: "Leave the page layout without
   saving?"); Done and Cancel use the same guard. A server-side refusal must NOT reload the saved
   layout over the draft (`panels_controller.rb:72-74`): keep the draft in the DOM and show the error.
2. **B2 — errors are alerts.** `toast()` (lines ~635-647) takes a kind; every "Not saved…",
   "did not load", cap and 20 KB message renders `flash flash-alert` (no "Done" word), notices stay
   `flash-notice`. Alerts persist until dismissed, like the shell's.
3. **C6 — the three tabs agree.** Submit labels "Save changes" / "Save publishing" / "Save layout";
   Cancel is the same element and class on all three; "Done" means "back to the project" and is
   guarded when dirty (B1). Say in a line what "Remove cover" does (it clears the override; the
   automatic cover returns on Save).
4. **C10 (editor part).** Deleting a block or a tab confirms ("Delete the tab NAME and its N
   panels?" / "Delete this block?"); "Add tab"'s disabled reason is visible text, not `title` only;
   tab separators are also reachable by keyboard (an arrow-key or button alternative to drag).
5. **Copy.** `_form.html.erb:70-71`: no "hero" ("which file its page shows first" or similar);
   `_layout_bar.html.erb:46`: no "YAML"; `_publish.html.erb:108`: not "The link IS the credential"
   ("Anyone with this link can open the page. Making a new link stops the old one working.").
6. **B3 — publishing refusal** (`projects_controller.rb:580`): re-render the Publishing tab with
   errors and the typed values. **C10:** `projects_controller.rb:741` can print
   `FileLayer::FetchError` text into "Project created" — say "The library could not be reached;
   the project folder was not created yet" and keep the class name out of the flash.

### T3 — Project hub and its panels (C1–C5, C7–C10, B3 readme/releases/BOM/connections, B5 BOM Remove, B7 hub notices, I hub inputs, C2 README images)

**Owns:** everything under `app/views/projects/` not owned by T2 or T1 (`show`, `index`, `_card`,
`_hero`, `_page_intro`, `_attachments`, `_attachment_group`, `_file_rows`, `_file_tile`,
`_file_tree_section`, `_folder_panel`, `_generated_group`, `_bom`, `_bom_lines`, `_build_log`,
`_log_entry`, `_photos`, `_releases`, `_wiring`, `_tasks`, `_task`, `_sheets`, `_models`,
`_schematics`, `_calculations`, `_calculation_rows`, `_readme_card`, `_readme_editor`,
`_repo_card`, `_repo_browser`, `_move_conflict`, `_panel_body`, `_panel_groups`,
`attachments/**`, `boms/**`, `models/**`, `sheets/**`), `app/controllers/projects/**` except T2's,
`app/services/maker/project_kind.rb`, `app/services/maker/readme.rb`, `app/helpers/projects_helper.rb`,
`app/assets/stylesheets/pages/projects.css`, `app/javascript/controllers/{readme,tabs,masonry,commitgroup}_controller.js`,
`test/integration/web/project_*_test.rb`, `test/system/{readme_editor,projects_models_pages,project_scan_reload,repo_browser}_test.rb`.
Read `docs/invariants/project-intake.md` before touching anything about filing or Loose.

1. **C1 — hidden data is findable.** When a preset hides a panel (`project_kind.rb:97`) that
   holds rows (BOM lines, releases, sheets, wiring), the hub shows one line under the stats —
   "Also in this project: Bill of materials (3 lines) · 1 release · 1 sheet" — each a link to the
   panel's own page where one exists (`/projects/:slug/bom`, the sheet page) or to the layout
   editor's Show control otherwise. The stats line counts only what the page shows. Decide in
   `ProjectsController#show`'s data, render in the view (rule 14) — the controller file is T2's, so
   put the query in a helper or a small service you own and report the one-line wiring T2 must add
   if you cannot avoid it.
2. **C2 — README images on the hub.** `Maker::Readme` (or whatever resolves relative links) emits
   `src="/files/<id>"` (the HTML page) for images; emit the blob/download URL the public page uses.
   Test: a README with `![x](docs/plate.svg)` renders an `<img src>` that is not a `/files/<id>` page.
3. **C3 — Loose.** When a loose file cannot be filed because the destination exists, say so on the
   row ("design/harbor-number-v4.svg already exists — rename one to file it") instead of promising
   the next pass; a README is not listed as loose. No "sweep" in copy ("filed on the next scan").
4. **C4/C5 — composers and deletes.** One composer pattern for BOM, Wiring, Releases, Tasks,
   Sheets, Build log: `details.composer` with opener "Add …" and a submit that names the thing
   ("Add line", "Add connection", "Add release", "Add task", "Add sheet", "Add entry"), no repeated
   opener label on the submit, and the accent only on the panel's primary when it is the page's
   one accent (it is not — the hub's accent is Upload; composers use `.btn`). Destructive controls
   are one shape: `linkbtn danger small` "Remove"/"Delete" with a confirm naming the object
   (`_models.html.erb:32` Detach gets `danger`). `+ Add panel → Bill of materials` renders the
   composer when the panel is empty (`_bom.html.erb`/`_bom_lines.html.erb`).
5. **B3 — refusals keep input:** readmes (`readmes_controller.rb:40-55`, including stale content —
   show the conflict and keep the draft), releases (`releases_controller.rb:34,38`), BOM lines
   (`bom_lines_controller.rb:25,39-46`), connections (`connections_controller.rb:16`). 422
   re-render with the composer open and errors inside it.
6. **B5 — BOM "Remove"** confirms ("Remove PART from the bill of materials?"). **B7:** renaming a
   sheet and updating a task set a notice; `render_tasks` shows "Task added."; button verb matches
   notice verb (print log is T5's; here: releases, connections "Unlink" ↔ "Unlinked X.", sheets).
7. **C7 — hub copy.** "Scan folder" → "Rescan library" (its flash already says the library is
   scanned; `scans_controller.rb`); "Not a project" → "Stop treating this folder as a project" (or
   "Unregister project"); the "New" badge shows only when the status is new, and every status
   renders a badge; the stats line counts only shown panels (see 1).
8. **C8 — List view keeps actions; photos open.** `_file_rows.html.erb` gets the actions column
   (Detach / Move into project); build-log photos are links to the file page (or open the image).
9. **C9 — the two pickers** (`attachments/new`, `models/new`): rows show folder path and a
   thumbnail where one exists; one visible label on the search box; breadcrumbs instead of the
   foot "← Back to project"; "Attach" says it moves the file ("Attach and move into PROJECT") when it will.
10. **C10 (panels) and I.** Wiring row inputs get labels (visually hidden is fine) and the four
    inputs save as one form per table or with an unsaved warning; Tiles/List/Browser and Full/Half
    toggles expose `aria-pressed`; Schematics gets a `.panel-head`; Sort by Status follows the
    lifecycle order; the tag filter's "All" reads "All tags"; placeholder-only inputs
    (`_build_log:23`, `_releases:157`, `_sheets:11`, `_tasks:68`) get labels; "Delete task?"
    names the task.

### T4a — Library pages, Trash, repo commits, search, tags (B5 folder delete, B6, D2 views/CSS, D4, D5, D6 views, D7, D8 copy, D9, D10, D11, I thumbnail-link names, J 375 row actions)

**Owns:** `app/views/files/**` EXCEPT `app/views/files/models/**`; `app/views/trash/**`,
`app/views/repo_commits/**`, `app/views/repo_histories/**`, `app/views/search/**`, `app/views/tags/**`,
`app/views/shared/**`; `app/controllers/{files,trash,repo_commits,repo_histories,search,tags,library_browse,notes}_controller.rb`,
`app/controllers/files/**`; `app/helpers/{files,library_folder,notes,tags}_helper.rb`;
`app/assets/stylesheets/components.css`, `app/assets/stylesheets/pages/{files,preview,search}.css`;
`test/integration/web/{file,files,folder,inspector,notes,trash,search,repo}_*_test.rb`.
Read `docs/invariants/files-preview.md` and `docs/invariants/git-editing.md` first.

1. **B6 — return to origin.** `files_controller.rb:1001-1005` (delete) returns to the folder the
   file was in, keeping the list's query (sort, filter, search) via the referer the way
   `rename_move_landing` does; the notice is "Deleted NAME. It is in Trash." with Trash linked if
   the flash partial can carry a link (it cannot today — if you add `flash[:notice_link]` or
   similar, the partial is T1's: report the exact change). Restore (`trash_controller.rb:99-102`)
   returns to Trash with "Restored NAME to FOLDER." naming the folder.
2. **B5 — folder delete** confirm says "Delete the folder NAME and everything in it?"
   (`_list.html.erb:94-95`, and the grid/context-menu equivalents in views you own).
3. **D2 — actions in the open.** "Details" (the inspector) has a visible control on the row and
   the grid card (an icon button is fine), grid cards get the same actions as rows; the row-action
   `opacity: 0` rule (`components.css:294-296`) becomes `opacity: 1` on `:focus-within` and on
   coarse pointers (`@media (hover: none)`), hover-reveal only where hover exists; Trash's Restore
   is visible. At 375 px Download/Delete on adjacent rows no longer touch (spacing or a single
   menu button on narrow widths).
4. **D4 — no MIME types.** The metadata panel's TYPE uses `file_type_label(node)`; the raw MIME
   never prints.
5. **D5 — page-head order.** Download · Back · Delete (destructive last, as the menu and inspector
   do); the viewer posters do not add a second "Download NAME" when the head has one; "New text
   file" lives in New ▾ only (or the head only — pick one).
6. **D6 — history copy.** On a file inside a working tree, the "keeps no history" sentence does
   not render (git history is the history); the commit page's Commit submit carries the accent
   (`repo_commits/show.html.erb:127-128` vs `pages/preview.css:76-81`); the message field gets a
   label, the path checkboxes `<label for>`.
7. **D7 — Trash.** KIND shows "Folder"/"File type" like the list; rows show the original folder;
   Restore is visible (3).
8. **D8 — viewer copy** in views you own: "Reset view" everywhere ("Fit" on Gerber may stay if
   it fits); "Material 0 mm" hides when unknown; no "Click …" instructions ("Choose …"); a README
   file page offers a rendered view (if the renderer is a one-line reuse of `Maker::Readme`; else report).
9. **D9 — New text file** says where it goes: `shared/folder_field` (or the breadcrumb of the
   target folder) on `files/text_files/new.html.erb`; the NotFound refusal re-renders with the
   folder field.
10. **D10 — raw adapter messages** at `files_controller.rb:169, 690, 791, 1099` and
    `text_files_controller.rb:35-38`: map `FetchError` → "The library is not reachable right now;
    try again in a moment", `UnsupportedOperation` → its message only if it is already written
    for a user (the clobber one is), else "That name is taken here" / "cannot be moved here".
11. **D11 / I.** Search results and tag pages show the folder under the name; group titles say
    "3D models"; the tag page subtitle counts things by kind, and its empty state links to the
    Library; "Tags" crumb links `settings_tags_path`; every thumbnail link has an accessible name
    (`aria-label` = the file name) — rows, grid, gallery tiles.

### T4b — Library Stimulus controllers (B4, B5 History Restore, B8, D2 menu a11y, D8 thumb timeout, H "+ New Folder")

**Owns:** `app/javascript/controllers/{filemenu,history,editor,thumbs,uploader,zip_upload,scanreload,fileopen,filebrowser,filechooser,selection,diffview,codeview,importer,copy,thumbfallback,sheet,spreadsheet,image_zoom,measure,modelviewer,modelstage,gerber,kicanvas}_controller.js`,
`app/javascript/lib/**`, `test/system/{file_menu,files_selection,file_chooser,repo_history,repo_editor,repo_staging,uploader,importer,thumb_spinner}_test.rb`.
Read `docs/invariants/git-editing.md` (history and restore) first.

1. **B5 — History Restore confirms** (`history_controller.js:168-170, 245-277`): "Restore the
   version from DATE? This replaces the current file and any unsaved edit." before the POST.
2. **B4 — the editor says when a save fails.** `editor_controller.js:106-132` catches network
   errors and non-JSON/HTML answers: status reads "Not saved — NETWORK/413/500 in a sentence",
   `flash-alert` style; a dirty editor warns on `beforeunload`/`turbo:before-visit`; the stale
   answer offers "Reload" as a button and says the draft will be lost.
3. **D2 — the context menu is a menu.** `filemenu_controller.js:50-156`: `role="menu"`,
   `role="menuitem"`, focus moves into the menu on open, Up/Down/Home/End move, Enter/Space
   activate, Escape closes and returns focus to the row; Shift+F10 and the ContextMenu key open it.
4. **B8 — upload feedback.** `.upload-status` is `aria-live="polite"` (set in JS if the markup is
   not yours); failures read as a sentence ("Upload failed: NAME was refused — FOLDER already has a
   file with that name" when the response says so, else "Upload failed; try again"), not raw
   `e.message` in muted text; `zip_upload`/share-s3 uploads show "Uploading NAME…" while the form
   submits; `scanreload_controller.js:75-77` says "Still scanning…" instead of an empty element.
5. **D8 — thumbs:** after the poll timeout say "Preview is taking longer than usual" rather than
   "Preview not supported" (`thumbs_controller.js:111-130`); keep the real unsupported state for
   a real `unsupported` status.
6. **importer_controller.js:125-126:** show the "imported N, skipped M" report (toast or status)
   before, or instead of, navigating away. **`lib/file_chooser.js:165,435`:** "＋ New Folder" →
   "+ New folder" (ASCII plus, sentence case).

### T5 — 3D models, inventory, Recent, Help (E1–E7, B3 print log/adjust stock/suppliers/locations, B7 print-log notice, A4/F8 back buttons, A7 `/help`, H Help copy)

**Owns:** `app/views/models/**`, `app/views/files/models/**`, `app/views/inventory_items/**`,
`app/views/suppliers/**`, `app/views/locations/**`, `app/views/home/**`, `app/views/help/**`,
`app/views/calculations/**`; `app/controllers/{models,inventory_items,suppliers,locations,home,help,calculations}_controller.rb`,
`app/controllers/models/**`; `app/models/maker/{model,inventory_item,inventory_transaction,supplier,location}.rb`;
`app/helpers/{inventory,calculations}_helper.rb`; `app/assets/stylesheets/pages/{models,inventory,home}.css`;
`config/routes.rb` (you are the only wave-1 task allowed to edit routes — add only what suppliers/locations need);
`test/integration/web/{models,model,inventory,print_runs,home,help,suppliers,locations}_*_test.rb`,
`test/system/{model_page,home}_test.rb`. Read `docs/invariants/model-intake.md` first.

1. **E4 — adjust stock knows its direction** (`inventory_items/show.html.erb:51,55`, the
   controller's adjust action, `InventoryTransaction::REASONS`): "Consumed" subtracts the typed
   quantity, "Restocked" adds, "Adjusted" takes a signed value with the sign explained; "Initial"
   leaves the adjust dropdown (it belongs to creation). The ledger: "Change" not "Delta", reasons
   as labels ("Consumed"), the button "Apply", the explanation in plain words ("Stock changes are
   recorded here; the balance is the sum."). Keep the model's invariant that the balance is
   never edited directly. Test: consumed 3 from 10 → 7.
2. **B3 — refusals keep input:** adjust stock (`inventory_items_controller.rb:109`), print log
   (`models/print_runs_controller.rb:16`), suppliers (`suppliers_controller.rb:21`), locations
   (`locations_controller.rb:18`) re-render with errors (422).
3. **E5 — Suppliers and Locations are reachable and editable.** Inventory's page head links to
   both; the item form's empty Supplier/Location selects link "Add one" to the page; each gets
   rename (an `update` action — add the route) and a notes field (the column exists); counts link
   to the filtered inventory; titles use " — Tinkerex"; prose uses "—" not "--"; breadcrumbs
   "Inventory › Suppliers" replace the "Inventory" ghost button (A4/F8). Low-stock wording is
   "Low stock" everywhere (chip, list, item page, form label "Minimum quantity"); a new item with
   `min_quantity` 0 is not "Low".
4. **E1/E2 — model cards and status.** A card shows its extension(s) and folder beneath the name
   so three "tetra" cards can be told apart; a status badge appears only when the status is not
   the default, and every status word comes from `PRINT_STATUS_LABELS` (`models/edit.html.erb:27`
   builds its own); the filter chip reads the same label as the form ("Want to print").
5. **E3 — the model page and the index.** The stage shows the render (or the poster with one
   "View in 3D" button) instead of a blank box; "Remove from catalog" moves to a danger zone or
   `linkbtn danger` at the foot, not the head; the 3D models index's primary is "Add model" with
   two routes (from a library file / import a Printables zip) and the import page's title and
   button agree ("Import model" / "Import"); a filtered view that matches nothing says "No models
   match" with a "Clear filters" link (same for inventory `index.html.erb:55-56`).
6. **E6 — Recent's Needs attention.** "Log a print" opens the print log, not the instructions
   PDF (`home/index.html.erb:93`); the item name links to the item; a failed print can be
   dismissed (a `dismissed_at`-style flag or a 7-day window — your call, say which). Also
   `home/index.html.erb:29`: `help_path`, not "/help".
7. **E7 — model hero in dark.** `pages/models.css:29-30` must not paint `.model-hero-thumb` with
   `--raised` over `.thumb`'s stage; keep the thumbnail ink-on-paper (rule 5).
8. **B7:** print log "Delete" ↔ "Deleted the print." **Help:** replace "the Files page" with "the
   Library", "sweep" with "filed on the next scan", "Publish panel" with "the Publishing tab", add
   one paragraph each for Inventory (with Suppliers/Locations), Import model and the search
   shortcut; explain "shelf" once where it first appears.

### T6 — Settings, account, sign-in, devices (F1–F8, B3 shelves/groups/filing rules, B5 Remove admin, A4/F8 crumbs, I Devise headings)

**Owns:** `app/views/settings/**` EXCEPT `_theme.html.erb`; `app/views/users/**`;
`app/controllers/settings/**`, `app/controllers/users/**`, `app/controllers/settings_controller.rb`;
`config/locales/**`; `app/assets/stylesheets/pages/settings.css`;
`test/integration/web/{account,auth,devise,settings,shelf,users,devices,password}_*_test.rb`.

1. **F1 — the Account page is a Settings page.** `users/registrations/edit`: `content_for :title,
   "Account"`, crumbs "Settings › Account", one h1 "Account", sections as `.panel`s with h2s,
   fields at the settings width (not 1360 px), sentence-case hints, "Save changes", no foot "Back";
   saving returns to the Account page with a notice. (T1 lights Settings in the rail.)
2. **F2** — delete-account errors render in the Delete section, not under the update form
   (`Users::RegistrationsController#destroy` → render with the error scoped to that panel).
3. **F3 — one error style.** Settings and account forms use `.form-errors` (one list or one
   sentence, your call) — not Devise's `#error_explanation` and not redirect-with-toast. **B3:**
   shelves (`settings/shelves_controller.rb:23-25`), shelf groups (`shelf_groups_controller.rb:8-10`),
   filing rules (`filing_rules_controller.rb:22-25`) re-render with errors and the typed input.
4. **F4 — Sign in.** The auth cards say "Sign in" (heading, button, links); Devise strings in
   `config/locales/devise.en.yml` say "Signed in." / "Signed out." in the app's notice voice; the
   Remember-me checkbox has an associated label; every Devise page has `content_for :title` and
   an h1 (visually the card heading is fine).
5. **F5 — first run and recovery.** `registrations/closed.html.erb:4` and `new.html.erb:7` stop
   showing `REGISTRATION=open`, `bin/rails tinkerex:owner` and `SMTP_ADDRESS` to visitors: say
   "This server's administrator adds accounts" and nothing operational; a fresh install with no
   account shows a "Create the owner account" card instead of a sign-in form for nobody (use the
   existing first-account path in `lib/tinkerex/registration.rb` — read it, do not change it);
   `passwords/new` carries the same no-mail warning `confirmations/new` has and names the
   alternative ("an administrator can reset it under Settings › Users").
6. **F6 — Devices.** Open with what the page is for, then: "Signing a device out ends its access
   to this server. It can still sync files until it is removed from the sync server too." as a
   single honest note; the admin's view and the user's own show the same columns ("added" date,
   last used) and the same verb; **B5:** "Remove admin" confirms ("Remove admin from EMAIL?").
7. **F7 — Shelves.** The extension chips lose their per-chip red "Remove" text: show the chips as
   plain chips with a single "Edit extensions" control per shelf that reveals removable chips (each
   remove button's accessible name includes the extension), or an inline editable list — your
   call; "Remove shelf" and "Delete group" become "Remove shelf" / "Remove group"; the heading
   levels nest (group h2 → shelf h3).
8. **F8 — sub-pages.** Breadcrumbs ("Settings › Users") replace the "Settings" ghost buttons
   (rule 9) on every settings page; one field style (`.field > label`); the hub row and its facts
   both say "Users"; drop "Locked after too many wrong passwords." (it cannot happen); the scan
   refusal on `settings/library/show.html.erb:48-49` reads as a sentence for a maker ("The last
   scan stopped because it would have removed N of M files from the catalog. If that is right,
   raise the limit in LIBRARY_SCAN_MAX_DELETE_PCT or rescan after checking the folder.") — the
   env name may stay in a `<code>` on this operator page, but the raw message does not print.

### T7 — Tools and the public pages (G1–G4, H "asks for level N")

**Owns:** `app/views/tools/**`, `app/views/public/**`, `app/controllers/tools/**`,
`app/controllers/public/**`, `app/helpers/new_menu_helper.rb`,
`app/javascript/controllers/{addon,toolmenu}_controller.js`, `app/assets/stylesheets/pages/{tools,public}.css`,
`app/services/maker/addons/registry.rb` (copy only), `test/integration/web/{tools,addon,public,explore,new_menu}_*_test.rb`,
`test/system/{tool_pins,addon_bundle,addon_sdk,new_menu,public_bundle}_test.rb`.
Read `docs/invariants/addons.md` first and change nothing about the save door, the service proxy or the SDK.

1. **G1 — no emoji.** The gallery cards (`tools/home/index.html.erb:104,118`) and the addon page
   h1 (`tools/addons/show.html.erb:12`) stop drawing manifest emoji; draw a monogram tile (first
   letter of the name, CSS) or a fixed inline SVG glyph per addon id. The Generators addon's
   folder field "📁" is inside the addon bundle (another repo) — report it, do not chase it.
   `test/no_emoji_test.rb` cannot see manifest data: add a request test that the rendered gallery
   contains no emoji code points.
2. **G2 — pinning is visible.** Each card gets a pin toggle button (`aria-pressed`, "Pin to
   sidebar"/"Unpin") beside right-click; the hint sentence goes; rail pins keep right-click (the
   rail is T1's — report if a hint is wanted there).
3. **G3 — unavailable addons.** An unavailable addon's card is not a link (the card states the
   reason: "Needs the boxes service, which this server does not run."); `/tools/<id>` for one
   renders an `.empty` state with the same sentence instead of "Service request failed (404)";
   an addon whose bundle fails to import shows "Could not load NAME" with details in a
   collapsed `<details>`, and a visible loading state shows before `import()` resolves; the New ▾
   menu's tool items drop the trailing "…" (or every item gets it — pick one).
4. **G4 — public.** Explore says "Showing the 60 most recent" when it stops at 60 (or pages like
   the handle page); card cover links and build-log photo links get accessible names; the card
   title is h2 under the page's h1; 429 and 503 answer with a short HTML body ("Too many requests —
   try again in a minute" / "Not available right now"); titles use one separator (" — Tinkerex").
5. **Copy.** `registry.rb:54-55` "asks for level N, this host is level M" → "needs a newer
   Tinkerex than this server runs" (the numbers may follow in parentheses).

---

## Wave 2 — T8 — Time: one zone, one helper (D1, C10 dates, E3 "Added", F6 "added November 02, 2026", History `toLocaleString`)

Runs alone after wave 1. Owns every file.

1. `config.time_zone` is set from `TIME_ZONE` (an IANA name, documented in `docs/INSTALL.md` so
   `test/install_docs_test.rb` stays green), defaulting to the host's zone (`ENV["TZ"]` if it is a
   valid `ActiveSupport::TimeZone`, else the `/etc/localtime` symlink's `zoneinfo/…` suffix, else
   UTC). Record the new env in `docs/INSTALL.md` and the Kamal env where the three destinations
   set theirs (`config/deploy*.yml` — read `docs/invariants/deploy-secrets.md`; a time zone is not
   a secret). Verify: a `Node` mtime and a `Maker::Note` created at the same instant print the
   same wall-clock time.
2. One helper, `ApplicationHelper#time_at(time, style: :absolute | :date | :relative)`, rendering
   `<time datetime="ISO" title="full">…</time>`: absolute = `%Y-%m-%d %H:%M`, date = `%Y-%m-%d`,
   relative = "10 minutes ago" with the absolute in `title`. Every `strftime`, `to_fs`,
   `time_ago_in_words` and `%B %d, %Y` in `app/views/**` goes through it (grep them all; list the
   count before and after). The History panel (`history_controller.js`) prints the server's
   formatted label from the JSON instead of `toLocaleString()`.
3. Tests: a helper test for the three styles; the history JSON carries `at_label`; a grep test
   (`test/integration/web/time_format_test.rb`) that asserts `app/views/**` contains no `strftime`.

## Wave 3 — T9 — Terminology and copy (A3, A4 "Back" spellings, B7 notice grammar, H census, "3D models", separators)

Runs alone after wave 2. Owns every file. Scope is fixed by the audit's §H table:

1. **Library, not Files** — h1, `<title>`, the seven breadcrumb roots, Trash's back button, "Open
   in Files" → "Open in Library", Help. Update the tests that assert "Files" where it was the place.
2. **scan / filing** — "Rescan library" for the index pass everywhere ("Scan folder" is T3's);
   "sweep" → "filed on the next scan"; "index" as a verb → "scan"; "shelf" kept, explained once in Help.
3. **Notices in one grammar** — verb-first, past tense, named object, full stop: "Deleted X.",
   "Saved the README.", "Added the task." Change the 29 noun-first ones and the two bare ones;
   Devise strings are T6's. Update the tests that assert the old strings.
4. **"3D models"** for the catalog everywhere (search and tag groups, `models_controller:244`);
   **"Users"** for people; **" — Tinkerex"** as the only title separator; "—" for "--" in prose;
   "Edited in Tinkerex" capitalised.
5. **Back** — one spelling for a back control where one remains ("Back to PROJECT"), and
   breadcrumbs wherever the audit's A4 lists a parent-named ghost button that wave 1 left.

## Close-out

Bare `bin/ci` (from this checkout, `../tinkerex-sync` present). Live check on the audit server
(`http://audit.localhost:3100`, database `storage/audit_dev.sqlite3`) of: the phone More sheet,
the 1024 rail, delete/restore landing, History Restore confirm, Upload by keyboard, the adjust-stock
direction, the Account page, a laser project's "Also in this project" line, the Tools gallery
without emoji, one timestamp on each of notes/build log/Trash/file rows. Then `/finish-branch`
and `bin/log arc --from-pr <n>`.
