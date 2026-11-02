# UX and UI audit — usability and inconsistent interfaces

**Date:** 2026-11-01 · **Tree:** `main` at `c20431bb` · **Status:** findings only, nothing changed.

## How this was done

Two passes, then a merge.

1. **Static read.** Five parallel reads covered every template, page stylesheet, Stimulus controller and web controller, sliced as Files/Library, Projects, Models/Inventory/Recent/Help, Settings/Auth/Tools/Public, plus a whole-app census (every button, confirm, flash, title, empty state, label, heading, fixed width and term). Rules in `docs/invariants/design-system.md` were treated as deliberate and not flagged (one accent per screen, selection is ink, no emoji in the interface, Upload and New in the top bar, breadcrumbs via `content_for :crumbs`).
2. **Live walkthrough.** A `share` deployment on its own database (`storage/audit_dev.sqlite3`) and a scratch library built from `db/seeds/demo` plus one fixture file of every viewer type, a git-repo project, an empty project and an archived one; then projects, tasks, build log, BOM, wiring, a release, a sheet, a calculation, content blocks, inventory with suppliers and locations, tags, notes, pins, print runs, a device, a second account and a trashed file were seeded. Every page type was opened at 1440×900, the shell at 1024×768 and 375×812, a dark-theme pass, the delete and restore flows, the right-click menu, the composers, the signed-out pages and a failed sign-in.

Each finding is tagged **[live]** (seen in the browser) or **[static]** (from the read, with the file and line). Severity: **High** = blocks or misleads a task, or risks the user's work; **Medium** = friction or a visible inconsistency on a main page; **Low** = polish.

**Not covered:** the `chunk_remote` presigned upload flow and anything only a sync server provides; the Box Generator and OpenSCAD addons (their services are not running here, which itself produced findings); actual file uploads; the marketing landing in demo mode; real touch hardware (touch behaviour is inferred from `hover: none` rules and iOS Safari's known `contextmenu` behaviour); screen-reader output.

**Reproduce:** the seeded server is still up at `http://audit.localhost:3100`; the accounts and their passwords are in the seed script in this session's scratchpad (`seed.rb`), not in this document. Stop it with `lsof -ti tcp:3100 | xargs kill`.

---

## The short version

The design system is holding where it is enforced: one accent per screen is true on every page checked, the component vocabulary is used almost everywhere, confirms exist on 35 of 39 delete controls, there are no `alert()` calls, no page scrolls sideways at 375 px, dark mode is token-driven and correct, and the public pages look like the same product as the signed-in app. The interface is in better shape than most apps of this size.

The problems cluster in four places that the tests do not reach:

- **What happens after the click.** Drafts and typed input are lost on several refusal paths, one restore has no confirm, errors can render as green "DONE" toasts, and delete or restore throws the user back to the library root.
- **Who can reach a control.** Phones have no route to Settings, Sign out, Trash or Inventory; the keyboard cannot reach Upload; a third of the Library's actions live behind right-click or hover.
- **Time.** Half the timestamps are in UTC and half in local time, in four different formats, so at 10 pm the app shows tomorrow's date in some places and today's in others.
- **One thing, several names.** Library/Files, scan/sweep/index/rescan, Log in/Sign in, Wanted/Want to print, Users/accounts, Delete/Remove/Detach/Unlink.

### Top fifteen, ranked by how often a user meets them and how much it costs

| # | Finding | Sev. | Seen |
|---|---|---|---|
| 1 | A phone has no way to Settings, Account, Sign out, Trash, Inventory, Help or the theme: the rail is `display:none` under 720 px and the tab bar carries four places | High | live |
| 2 | Half the timestamps are UTC, half local, in four formats; notes, build log, ledger, Trash, model "Added", inventory "Updated" and Devices "added" all read a day ahead in the evening | High | live |
| 3 | The page-layout editor drops a draft silently on Done, Cancel, a tab or any link, and shows its own errors as green "DONE" toasts | High | static |
| 4 | Refused saves throw away what was typed: README, releases, BOM lines, wiring, print log, adjust stock, suppliers, locations, shelves, publishing | High | static |
| 5 | History "Restore" overwrites a file with no confirm, while Trash's harmless Restore does confirm; BOM "Remove", "Remove admin" and "Back to automatic preview" have no confirm either | High | static (Trash side live) |
| 6 | Upload, the one accent action on the Library, Recent and the hub, is a `<label>` over a hidden input: it cannot take focus, so keyboard users cannot upload | High | static |
| 7 | Details, Add note and grid Delete exist only on right-click; row actions and Trash's Restore only on hover; pinning a tool is right-click only. None of it is reachable on iOS | Medium | live |
| 8 | A laser project's BOM, release and sheet exist and the stats line says "1 sheet", but no panel, no link and no "+ Add panel" show them; only the layout editor's "Show" does | Medium | live |
| 9 | Delete and Restore land on the Library root with no Undo, losing the folder, filter and search the user was in; the toast covers New and Upload | Medium | live |
| 10 | The Account page is the Devise card stretched across the shell: no title, no h1, Back goes to Recent, Save goes to Recent, nothing lit in the rail, errors under the wrong heading | Medium | live |
| 11 | "Library" in the rail opens a page titled "Files" with "Files" as the breadcrumb root, and Help says "Files page"; the recurring pass is scan, sweep, index and rescan | Medium | live |
| 12 | README images break on the maker's own hub (the `src` is the file page, not the blob) while the same README renders on the public page | Medium | live |
| 13 | Raw internals reach the user: MIME types in the metadata panel, "Service request failed (404)", `FileLayer::FetchError` in a flash, the scan refusal text, "The link IS the credential", "hero", "sweep", "YAML" | Medium | live + static |
| 14 | At 1024 px the rail becomes icons only: the project list and pinned folders vanish and the Collapse button does nothing | Medium | live |
| 15 | The 3D models view shows one card per model file, so one design appears three times as identical "tetra" cards, every auto-found model wears "Wanted", and the filter says "Wanted" where the form says "Want to print" | Medium | live |

### Where to start

Five changes that remove most of the high-severity rows cheaply:

1. One `Time.zone` for the app (or per user) and one date helper with two formats, absolute and relative, used everywhere a time is printed (rows 2 and the format table in §D).
2. A fifth tab, or a "More" sheet, on the phone bar carrying Settings, Account, Trash, Inventory and Sign out (row 1).
3. Make `.upload-btn` a `<button>` that opens the hidden input, with the same Stimulus hooks (row 6).
4. `beforeunload` in the layout editor, `flash-alert` for its errors, and re-render-with-errors in the twelve controllers that redirect on refusal (rows 3 and 4).
5. A confirm on History Restore and BOM Remove, and one return-to-origin rule for delete and restore (rows 5 and 9).

---

## A. Shell and navigation

**A1. Phones cannot reach Settings, Account, Sign out, Trash, Inventory, Help or the theme.** High · live. `app/assets/stylesheets/shell.css:181` hides `.rail` at 719 px and below; `app/views/layouts/_tabbar.html.erb` and `ShellHelper#tabbar_links` offer Recent, Library, Projects, Tools. No template in the app links to Settings or Sign out from a page body. Confirmed at 375 px: the only chrome is the top bar's search and "+" and the four tabs.

**A2. At 1024 px the project list and pins disappear.** Medium · live. The rail collapses to a 56 px icon column at ≤1099 px (`shell.css`, the `@container rail` block). The eight projects and the pinned folders have no icon, so they are simply gone at a common laptop width; the Upload caption ("Saves to …") hides too. The Collapse button is still drawn there but only flips a cookie with no visible effect, and its arrow points left in both states (`_rail.html.erb:121-128`).

**A3. One place, two names.** Medium · live. The rail and tab bar say **Library** (`_rail.html.erb:21`); the page's h1, `<title>` and the breadcrumb root on seven pages say **Files** (`files/index.html.erb:1,17`, `files/show.html.erb:11`, `files/models/index.html.erb:8`, `models/{new,edit,show}.html.erb:5`); Trash's back button is "← Back to Files"; the model page says "Open in Files"; Help says "the Files page" four times. Whole-app count: 115 "library", 14 "Files"-as-place. Pick one.

**A4. Going up a level works three ways.** Medium · live. 14 nested pages use top-bar breadcrumbs; 12 put a parent-named ghost button in the page head ("Settings", "Users", "Inventory": `settings/devices/index.html.erb:7`, `suppliers/index.html.erb:5`); two put "← Back to project" at the page foot (`projects/attachments/new.html.erb:33`, `projects/models/new.html.erb:28`); the addon page has neither. "Back" alone has seven spellings. Suppliers and Locations are reached from Settings yet their back button says "Inventory".

**A5. Toasts cover New and Upload, and an alert never leaves.** Medium · live. `.flash-stack` is fixed at the top right over the top bar's controls (`shell.css:134-137`); after a delete the notice sat over New ▾ and Upload. An alert stays until dismissed (`toast_controller.js:12-15`); a notice vanishes after 6 s however long it is, with no pause on hover or focus and no Escape.

**A6. The theme control names its state, not its action.** Low · live. The rail button reads "Theme: light" and cycles light → dark → system; "system" is never explained; after choosing on Settings the rail label is stale until the next page (`theme_controller.js:9-11`). Settings repeats a lowercase "Theme: light" beside its own Light/Dark/System buttons (`settings/_theme.html.erb:13`).

**A7. Small shell gaps.** Low. The search hint is hard-coded "⌘K" on every OS (`_topbar.html.erb:26`) while the calculator's hint is platform-aware; Theme and Collapse have `aria-label` but no `title`, unlike their neighbours; the Upload folder choice on a folder-less page sticks silently for later clicks (`upload_pick_controller.js:25,43`); `home/index.html.erb:29` hard-codes `"/help"`; the app icon is still the Rails scaffold's red circle (`public/icon.svg`) and the manifest's `theme_color` disagrees with the meta tag (`#fcfbf8` vs `#f4f2ed`).

## B. Protecting the user's work, and feedback after writes

**B1. The page-layout editor loses the draft without warning.** High · static. `layout_editor_controller.js` has no `beforeunload` or `turbo:before-visit` guard. Done (`_edit_head.html.erb:30`), Cancel (`_layout_bar.html.erb:50`), the Details/Publishing tabs and every rail link discard moves, block text (up to 20 KB), tabs, cover and description. "Done" sits beside Save and reads as "finish and keep". The spreadsheet does guard (`spreadsheet_controller.js:70-73`). A server-side refusal also reloads the saved layout (`projects/panels_controller.rb:72-74`).

**B2. Editor errors appear as green "DONE" toasts.** High · static. Every layout-editor message goes through `toast()` (`layout_editor_controller.js:635-647`), which builds `div.flash.flash-notice`; `components.css:465` prefixes that class with the word "Done". So "Not saved: a tab needs a name…" (line 604), "The preview … did not load" (189), the cap messages (251, 357) and the 20 KB refusal (341) all read "DONE Not saved: …". Rule 13 says a status carries its word; here the word is wrong.

**B3. Refusals throw away what was typed.** High · static. These redirect with an alert instead of re-rendering with errors: README (`projects/readmes_controller.rb:40-55`, including the stale-content case), releases (`releases_controller.rb:34,38`), BOM lines (`bom_lines_controller.rb:25,39-46`), connections (`connections_controller.rb:16`), print log (`models/print_runs_controller.rb:16`), adjust stock (`inventory_items_controller.rb:109`), suppliers (`suppliers_controller.rb:21`), locations (`locations_controller.rb:18`), shelves and groups (`settings/shelves_controller.rb:23-25`, `shelf_groups_controller.rb:8-10`, `filing_rules_controller.rb:22-25`), publishing (`projects_controller.rb:580`), commit ("Nothing selected", `repo_commits_controller.rb:67-71`). Project details, model edit, inventory item and Settings → Users re-render and keep input, so the app already has the right pattern.

**B4. The text editor's save failure is silent.** Medium · static. `editor_controller.js:106-132` has `try/finally` with no `catch`; a network error or an HTML 413/500 leaves "Saving…" forever. There is no unsaved-changes guard. The stale answer says "Reload to see the current version" (`text_save.rb:62`), which discards the edit.

**B5. Confirms are on the wrong actions.** High · static (Trash side live). History "Restore" (`history_controller.js:168-170, 245-277`) POSTs at once and reloads; `FilesController#restore` writes `replace: true` over the working copy and any editor text. Trash's harmless Restore asks "Restore X?" (`trash/index.html.erb:49-50`, confirmed live). Also unconfirmed: BOM "Remove" (`projects/_bom_lines.html.erb:76`, beside a Consume that does confirm), "Remove admin" (`settings/users/edit.html.erb:43`), "Back to automatic preview" (`files/viewers/_model3d.html.erb:55`). A folder delete asks only "Delete NAME?" though it takes the whole subtree (`files/_list.html.erb:94-95`).

**B6. Delete and Restore drop you at the root.** Medium · live. Deleting `dice robber holder.lbrn2` from inside `Projects/catan/laser` landed on the Library root with "Deleted dice robber holder.lbrn2." (`files_controller.rb:1001-1005`); restoring it from Trash landed on the root again with "Restored …" and no word on where it went (`trash_controller.rb:99-102`). The folder, filter and search are lost; there is no Undo although Trash is one click away. Rename and move return to where the user was (`rename_move_landing`), so the better pattern exists.

**B7. Silent or mismatched feedback.** Low · static. Renaming a sheet and updating a task set no notice (`projects/sheets_controller.rb:11,41`, `tasks_controller.rb:46`); under Turbo `render_tasks` drops notices so "Task added." never shows. Button verb ≠ notice verb: print log "Delete" → "Removed the print."; shelves "Delete group" → "Group X removed."; connections "Unlink X?" → "Link removed."; "Unarchive" → "Restored X.". Notices use two grammars, 38 verb-first ("Deleted X.") and 29 noun-first ("Note deleted."), plus 11 Devise "…successfully." strings and two bare ones ("Saved.", "Detached."). The importer's "imported N, skipped M" report is set and then navigated away from in the next line (`importer_controller.js:125-126`).

**B8. Upload gives no progress on share/s3.** Medium · static. `zip_upload_controller.js:28` just submits the form; only the chunk flow shows "Uploading x… (n of m)". `.upload-status` is not a live region; failures show the raw `e.message` in 12 px muted text (`uploader_controller.js:95-98`). A rescan's only signal is a 6 s notice; the poll element stays empty until a 60 s timeout (`scanreload_controller.js:75-77`).

## C. The project hub and its panels

**C1. Data the preset hides cannot be found.** Medium · live. `Maker::ProjectKind` hides `bom wiring releases sheets` for a laser project (`project_kind.rb:97`). The seeded catan has a 3-line BOM, a release and a sheet; the hub shows none of them, has no link to `/projects/catan/bom`, and shows no "+ Add panel" (hidden panels are excluded by rule 14). The stats line still says "1 sheet". The only route is Edit → Page layout → "Show" on a hidden strip, which nothing on the page points to. Either a hidden panel that holds rows should surface a link, or the stats line should not count it.

**C2. The README renders wrongly for its author.** Medium · live. Desk Lamp's README has `![…](docs/plate.svg)`; on the hub the image `src` is `/files/<id>` (the HTML page), so it shows as a broken image, while the link `[base.stl](models/base.stl)` resolves. The public page renders the same image correctly.

**C3. The Loose group contradicts itself.** Medium · live. On catan, `harbor-number-v4.svg` sits under "LOOSE (1)" with the note "Loose files are filed on the next sweep", but it never will be: `design/harbor-number-v4.svg` already exists, so the sweep refuses, and nothing says so. On Desk Lamp the README itself is listed under LOOSE with "a README stays here" in the same sentence. "Sweep" and "Shelves" are unexplained.

**C4. Five ways to add a row, eight ways to delete one.** Medium · static. Composers: `details.composer` in the head ("Add entry" → "Save entry"), composers at the foot (BOM, Wiring, Releases, with submits "Add line", "Add", "Create release"), a bare inline form (Tasks, "Add"), an inline head form (Sheets), a link to a picker page (Models, Files). Three composers repeat the opener's label on the submit against the rule `_build_log.html.erb:17-27` states. Destructive: `✕` with custom `.task-delete`, "Delete entry" as `menu-item danger`, "Remove" as `linkbtn danger small`, "Delete" as `linkbtn danger` (sheet), "Detach" as `btn small danger` (file) and as `btn small` with no danger (model, `_models.html.erb:32`). The flashes vary the same way. Only "Add line" (`_bom_lines.html.erb:156`) carries the accent, a second accent on the hub once its composer opens.

**C5. "+ Add panel → Bill of materials" opens a panel with no composer.** Medium · static. `_bom.html.erb:14,21` renders the heading and an "Open" button; the composer lives in `_bom_lines`, which is not rendered when empty. Rule 14 promises the composer.

**C6. The edit area's three tabs disagree.** Medium · live. Details: "Save changes" + Cancel (`linkbtn`) + Done. Publishing: "Save publishing" + Done. Page layout: "Save" + Cancel (`btn small`) + Reset + Done. "Done" never saves. The description and cover can be edited on two tabs under different rules (`show.html.erb:93-96` vs `_page_intro.html.erb:49-50`; `_form.html.erb:98-125` vs the layout tab), and "Remove cover" only clears the override so the automatic cover comes back after Save (`project.rb:183-185`).

**C7. Hub copy.** Medium · live. "Scan folder" scans the whole library (its flash says so); the Library calls the same thing "Rescan library". "Not a project" is the Danger-zone button for un-registering a project. "Presets which panels this project's page shows, and which file its hero prefers." uses "hero". The stats line counts panels that are not on the page ("0 of 0 tasks done · 0 sheets"). The project cards show a "New" badge on every project beside its status, and the planning status renders no badge at all (Desk Lamp's card: "New / Electronics & firmware", nothing else).

**C8. Panels lose actions in List view; photos are dead ends.** Medium · static. `_file_rows.html.erb:30-55` has no actions column, so "Linked from elsewhere" loses Detach and "Move into project" when the Files panel is switched to List. Build-log photos are `span.entry-photo`, not links, and the `entry_photo` DELETE route is used by no view (`_log_entry.html.erb:36-40`, `entry_photos_controller.rb:33-37`).

**C9. The "Attach existing" and "Add a model" pickers.** Medium · live. Both list bare names with no folder or thumbnail (three indistinguishable "tetra" rows on the model picker, forty file names on the other), each with its own "Attach" button, a search box with placeholder as its only label, no breadcrumb, and "← Back to project" at the bottom. "Attach" also *moves* the file into the project folder without saying so until the flash ("Attached X and moved it into Y").

**C10. Smaller hub items.** Low. The wiring table's four inputs per row have no labels and each row is its own form, so saving one row loses edits in the others (`_wiring.html.erb:43-82`); toggles (Tiles/List/Browser, Full/Half) expose state by class only while the calculator uses `aria-pressed`; tab separators can only be dragged; deleting a block or tab is instant; "Add tab" explains its disabled state only in `title`; the Schematics panel has a bare `<h2>` with no `.panel-head`; dates on the hub use four formats (§D); "Project created" can print `FileLayer::FetchError` (`projects_controller.rb:741`); Sort by "Status" is alphabetical, not lifecycle; the tag filter row's "All" sits beside "All types" and should read "All tags".

## D. Library, files and viewers

**D1. Three clocks, four formats.** High · live. Seeded at ~22:09 local, the app showed: file rows and the metadata panel `2026-11-01 22:09` (local, with `:06` seconds on the panel only); notes `2026-11-02 03:11`; build log `2026-11-01 03:11`; inventory ledger `2026-11-02 03:11`; Trash `2026-11-02 03:11`; model "Added" `2026-11-02`; inventory "Updated" `2026-11-02`; Devices "added November 02, 2026"; the file-page History `11/1/2026, 10:09:06 PM` (browser locale); the repo card "10 minutes ago". `config.time_zone` is unset, so every `strftime` on a Rails timestamp is UTC while the share's mtimes are local. Formats in use: `%Y-%m-%d %H:%M`, `%Y-%m-%d %H:%M:%S`, `%Y-%m-%d`, `%B %d, %Y`, `toLocaleString()`, relative.

**D2. Core actions are hidden behind right-click and hover.** Medium · live. The row's context menu holds Add note, Open, Details, Download, Delete (`filemenu_controller.js`); "Details" (the inspector) exists nowhere else on the page; grid cards have no visible actions at all; row actions are `opacity: 0` until hover (`components.css:294-296`), including Trash's only action. The menu is a `div` appended to `body` with no `role="menu"`, no focus move, no arrow keys, no focus return (`filemenu_controller.js:50-156`). At 375 px the row actions are visible, but Download and Delete stack so tightly that one row's Delete sits on the next row's Download.

**D3. Two sort controls and a library-wide type filter.** Low · live. The list has sortable column headers and a Sort/Ascending pair of selects that do the same thing (`index.html.erb:131-133,186-192` records this as a decision); the Type filter lists whole-library counts (".svg (27)") while showing a folder with 5 items.

**D4. The metadata panel leaks MIME types.** Medium · live. TYPE reads `application/octet-stream` for `.lbrn2`, `.mage`, `.gtl` and `.kicad_sch`, `model/x.stl-binary`, `application/vnd.ms-package.3dmanufacturing-3dmodel+xml` over three lines. The badge beside the title already says LBRN2.

**D5. Page-head order and duplicates.** Low · live. The file page's actions are Download · Delete · Back, so the destructive button sits between two safe ones, while the context menu and inspector deliberately put Delete last. The 3D, Gerber and layer posters add a second "Download NAME" button under the stage. "New text file" is both a page-head button and a New ▾ item.

**D6. Contradictory history copy.** Medium · live. On `main.c` the banner "No pending changes in firmware-blink — review & commit" sits above "This library keeps no history for this file; saving replaces it.", which sits above a History panel listing a commit. The commit page's "Commit" submit is `class: "primary"` inside `.editor-bar`, whose page-layer rule cancels the accent (`repo_commits/show.html.erb:127-128`, `pages/preview.css:76-81`), and the editor's Save is a class-less `<button>` (`editor_controller.js:96-98`). The commit form's message has only a placeholder and the path checkboxes have no `<label for>`.

**D7. Trash.** Medium · live. The KIND column shows the raw `file`/`dir` (`trash/index.html.erb:27,43`) where the Files list says "Type" and "Folder"; rows have no original location, so two deleted `README.md` cannot be told apart; the only action is hover-revealed.

**D8. Viewers.** Low · live. The Measure toolbar offers "Print all · Save sheet · Download SVG · Save SVG · Reset · ✕ Image", three of which are near-synonyms; "Reset" is "Reset view" on the 3D viewer and "Fit" on Gerber; the Laser-settings card prints "Material 0 mm"; several posters say "Click …", which reads oddly on touch; a slow render is labelled "Preview not supported" after ~80 s (`thumbs_controller.js:111-130`); the lbrn2 page opens Measure by default while SVG needs a click; a README opens as raw Markdown with no rendered view.

**D9. The New text file page does not say where the file will go.** Medium · static. `files/text_files/new.html.erb:6-14` has only a hidden `parent_node_id`, no breadcrumb and no folder field, and the NotFound refusal offers no way to pick another folder; the rename/move composer shows the destination with `shared/folder_field`.

**D10. Raw adapter messages.** Medium · static. `files_controller.rb:169` (`alert: e.message`), `:1099` ("can't be moved here: #{e.message}"), `:690,791` (FetchError text into the editor status), `text_files_controller.rb:35-38`; `trash_controller.rb:50` already documents why these are wire codes and avoids showing its own.

**D11. Search and tags.** Low · live. File results show the name and extension only, no folder, so duplicates are ambiguous; group titles say "Models" where the rail says "3D models" (`search_controller.rb:69`, `tags_controller.rb:15`); the tag page's subtitle is "1 thing" and its empty state "Nothing wears this tag yet." offers no next step; the "Tags" crumb is plain text though `settings_tags_path` exists.

## E. 3D models and inventory

**E1. One card per file.** Medium · live. `tetra.stl`, `tetra.obj` and `tetra.off` in one folder became three models titled "tetra" with identical cards; "Not in a project" holds "Tetra" and "cube" too. This is `docs/invariants/model-intake.md`'s rule, but the view gives no way to tell the cards apart (no extension, no folder on the card).

**E2. "Wanted" for everything.** Medium · live. The schema default is `want_to_print`, so every auto-found model wears "Wanted" and fills the Wanted chip. The filter chip says "Wanted"; the edit form's option says "Want to print" (`models/edit.html.erb:27` builds its options with `tr("_"," ").capitalize` instead of `PRINT_STATUS_LABELS`).

**E3. The model page is mostly an empty box.** Medium · live. The stage is a large blank grey rectangle until "View in 3D" is clicked; the print log is behind a Details tab; "Remove from catalog" is a full danger button in the head; "Added 2026-11-02" is UTC. The 3D models page's primary and empty state both push "Import model", a Printables-zip-only flow, though most models come from files already in the library; the import page says "Import model" and its button "Create model". A filtered view that matches nothing says "No models yet. Import your first one." with no clear-filters link (`files/models/index.html.erb:59-60`; inventory does the same at `inventory_items/index.html.erb:55-56`).

**E4. Adjust stock does not know which way it goes.** High · static. Picking "Consumed" and typing 3 adds 3 (`inventory_items/show.html.erb:51,55`; `REASONS` only labels the row). The dropdown also offers "Initial", which belongs to the new-item path. The ledger speaks bookkeeping: a "Delta" column, raw lowercase reasons, a "Post" button, "Posts an initial transaction; the balance is never edited directly."

**E5. Suppliers and Locations are orphans.** Medium · live. They are linked only from the Settings hub; the Inventory page and the item form's empty Location/Supplier dropdowns never point at them; they can only be added and removed (no rename, no notes field though the column exists, counts that are not links, no filter by either); their titles use " - Tinkerex" and their copy "--"; their back button says "Inventory". New items default to `min_quantity 0` and show "Low" at once; low-stock wording is "Low", "Low stock", "Low stock (n)", "Min", "min", "Minimum quantity".

**E6. Recent's "Needs attention".** Low · live. "tetra failed on 2026-10-24 on Prusa MK4." with the action "Log a print" opens the model page on the instructions PDF when one exists, not the print log (`home/index.html.erb:93`); a failed print stays for 30 days with no dismiss (`home_controller.rb:34-37`); the item name is plain text while the model name is a link.

**E7. The model hero in Graphite.** Medium · static, not verified live. `pages/models.css:29-30` paints `.model-hero-thumb` with `--raised`, which beats `.thumb`'s `--thumb-stage`; with the multiply blend a white-ground render would go to the card's dark colour (rule 5 says the card is light in both themes). The seeded model had no render ready, so this is from the cascade only.

## F. Settings, account and sign-in

**F1. The Account page is not a Settings page.** Medium · live. `/users/edit` renders the Devise card inside the shell: no `content_for :title` (tab and top bar read "Tinkerex"), no h1 (h2 "Your account", h2 "Your handle", h3 "Delete this account"), inputs stretched to the full 1360 px container, lowercase hint fragments, an "Update" button, a "Back" link to Recent at the foot, saves redirect to Recent, and nothing lit in the rail (`users/registrations` is not in `ShellHelper::SECTIONS`). Every `settings/*` sibling has a title, an h1, a "Settings" link and lights Settings.

**F2. Delete-account errors show under the update form.** Medium · static. `Users::RegistrationsController#destroy` re-renders `:edit`, so a wrong password or the last-admin refusal appears at the top under Devise's "1 error prohibited this user from being saved:" while the Delete section shows nothing.

**F3. Form errors are shown four ways.** Medium · static. Devise's `#error_explanation` list; `.form-errors` as one sentence (Users, user edit); `.form-errors.flash-alert` (Library folder); redirect plus toast, losing input (shelves, groups, filing rules).

**F4. Log in vs Sign in.** Low · live. The card says "Log in" (heading, button, links), the flash that follows says "Signed in successfully.", the rail says "Sign out", the Users page says "signed in 9 minutes ago". The Remember-me checkbox's accessible name is "1" (its label is not associated). The Devise pages have no h1 and no title.

**F5. First run and recovery.** Medium · static. A fresh self-host shows a Log in form for an account that does not exist; the only way forward is the 12 px "Sign up" link. `registrations/closed.html.erb:4` and `registrations/new.html.erb:7` tell visitors to set `REGISTRATION=open`, which boot refuses on share and s3, and show `bin/rails tinkerex:owner` and `SMTP_ADDRESS` to strangers. Password reset on a box with no mail promises an email that never comes and never mentions that an admin can reset it under Settings → Users (`passwords/new.html.erb` lacks the `MailSettings.deliverable?` warning that `confirmations/new` has).

**F6. Devices.** High · static. The page opens with "Signing one out ends its access to this server", then admits the device keeps syncing (the §14j gap), and offers no next step. The admin's view of a user's devices differs from the user's own (no "added" date, always "Sign out" instead of "Remove"). "added November 02, 2026" is the app's only long-form date.

**F7. Shelves is a wall of red.** Medium · live. Eleven shelf cards list every extension as a chip with its own red "Remove" text button (the code shelf has ~50), each whose accessible name lacks the extension; "Remove shelf" and "Delete group" name similar actions differently; the group h2 holds card h2s.

**F8. Settings sub-pages.** Low · live. No breadcrumbs (a "Settings" ghost button instead, rule 9); three field styles (`.field > label`, `.settings-add label > span` at 11 px, `label.field > span`); the hub row is "Users" but its facts say "accounts"; "Locked after too many wrong passwords." can no longer happen (`lock_strategy :none`); the raw scan refusal ("scan would tombstone N/M observable files… Set LIBRARY_SCAN_MAX_DELETE_PCT") prints on the Library folder page for any account (`settings/library/show.html.erb:48-49`).

## G. Tools and the public pages

**G1. Emoji are drawn in the Tools gallery and addon h1.** Medium · live. 📦 ✏️ 🧊 at 22 px on the cards (`tools/home/index.html.erb:104,118`) and in the page title (`tools/addons/show.html.erb:12`); the Generators addon's folder field shows 📁. Rule 13 forbids this in the interface and the rail already refuses to draw them; `no_emoji_test.rb` cannot see manifest data.

**G2. Pinning a tool is right-click only.** Medium · live. The sole affordance is the sentence "Right-click a tool to pin it to the sidebar"; rail pins have no hint and can only be unpinned by right-click; there is no visible pin control on a card.

**G3. Unavailable addons are still pages.** Medium · live. The greyed card says "Needs the boxes service, which this server doesn't run", yet `/tools/boxes` (and the rail pin) opens a page whose whole body is "Box Generator is unavailable: Service request failed (404)". An addon that fails to import shows plain text with the raw `e.message` (`addon_controller.js:101`) and there is no loading state before `import()` resolves. The New menu's tool items end in "…" while their siblings do not.

**G4. Public pages.** Low · live. Explore stops at 60 projects and reports 60 as the total (`explore_controller`, `public/explore/index.html.erb:14`) where the handle page pages; project-card cover links and build-log photo links have no accessible name; the card title is an h3 under an h1; 429 and 503 answer with empty bodies (`public/base_controller.rb`); titles use three separators ("Explore", "@owner", "… · Tinkerex" vs " — Tinkerex"). The compose page and the public project page themselves are clean.

## H. Copy and terminology census

| One thing | Names in use | Where the minority lives |
|---|---|---|
| The file area | Library (115) · Files (14) | h1, title, 7 breadcrumb roots, Trash back button, "Open in Files", Help |
| The recurring indexing pass | scan · sweep · index · rescan, plus "Rescan library" and "Scan folder" | `models/show:28`, `help:79`, `_attachments:229`, `settings/shelves:11`, `settings/library:34,58` |
| A project's type folders | shelf/shelves (25) · type folders (3) | `files/index:235`, `help:78`, `_where_files_come_from:50` |
| "catalog" | the model list · the file index | `models/show:28` vs `_library_unreachable:21`, `settings/users/edit:81` |
| 3D models | 3D models (14) · Models (3) · Import/Add/Create model | search and tag groups, `models_controller:244` |
| Destroying | Delete (43) · Remove (27) · Detach (8) · Unlink (6) · Archive (4) | see B7 for verb mismatches |
| Signing in | sign in (15) · Log in (5) · Login (1) | the auth cards and the landing |
| People | Users (page) · accounts (its facts and buttons) | `settings/show:31` |
| Print status | Wanted · Want to print | chip vs edit form |
| Low stock | Low · Low stock · Low stock (n) · Min · min · Minimum quantity | inventory index, show, chip, form |
| Separators | " — Tinkerex" (40) · " - Tinkerex" (2) · " · Tinkerex" (1); "--" in prose (3) | suppliers, locations, compose |

Internal words a user sees: "hero" (`projects/_form.html.erb:70-71`), "sweep" (hub, Help, Shelves), "YAML" (`_layout_bar.html.erb:46`), "The link IS the credential" (`_publish.html.erb:108`), "Tags can be verified where the library is a local folder." (`_releases.html.erb:155`), "Files are shown from the catalog" and "the sync server" (`_library_unreachable.html.erb:14,21`), "asks for level N, this host is level M" (`registry.rb:54-55`), "This deployment uploads through the two-phase flow." (`uploads_controller.rb:106`), the 501 JSON bodies that cite "spec §3.3" (`library_capabilities.rb:35-38`), `FileLayer::FetchError` in a flash. The product name is lowercased twice on the commit page ("Edited in tinkerex"). Help still sends people to a "Publish panel" that moved to the Publishing tab (`help/show.html.erb:84`) and never mentions Inventory, Suppliers, Locations, Import model or the search shortcut.

Capitalisation is consistently sentence case except "＋ New Folder" in `lib/file_chooser.js:165,435` (also a fullwidth plus). "Are you sure?" appears nowhere, which is good; 27 confirms are "Verb named-object?", one is the bare "Delete task?" (`_task.html.erb:12`), which names no task.

## I. Accessibility

- **Unfocusable primary action.** The top-bar Upload and the project upload control are `<label>`s over `hidden` inputs with no `tabindex` or key handler (`layouts/_topbar_upload.html.erb:44-79`, `projects/_upload_control.html.erb:27-51`).
- **Context menu.** No `role="menu"`, no focus management, no arrow keys, no focus return (`filemenu_controller.js:50-156`); keyboard users reach it only through Shift+F10 and then Tab through the page.
- **Links without names.** Every list-row thumbnail link is an `<a>` whose only content is an image with `alt=""` (seen in the accessibility tree as an unnamed link); public card covers and build-log photos likewise; a `.heic` gallery tile loses its name once its render arrives.
- **Placeholder-only inputs.** "Add a note…" (`files/show:218`), "What did you do?" (`_build_log:23`), "What changed?" (`_releases:157`, `repo_commits:126`), "New sheet…" (`_sheets:11`), "Add a task…" (`_tasks:68`), both picker search boxes, the note popover. No label at all: the four wiring inputs per row, the commit path checkboxes, the BOM target picker's select/chooser/text field (a label names only its first control, the radio).
- **State not exposed.** Tiles/List/Browser and Full/Half toggles use `.active` only; Explore's active chip is fill only; the print-run outcome is a bare ✓ or ✕ (rule 13 says status carries its word); "Copied" is not announced; the editor and sheet status spans are not live regions.
- **Headings.** The seven Devise pages start at h2 with no h1; Explore and the handle page go h1 → h3; the Account page's h3 is a sibling section of its h2s; the shelf-group heading is the same level as the panels under it.
- **Targets.** `.linkbtn.small` (12 px text) for Sign out and Remove on phones; the Library list's stacked Download/Delete at 375 px; the Remember-me checkbox named "1".

## J. Responsive

Confirmed at 375 px with no horizontal scroll: Recent, the Library list, a file page with the Measure stage and recipe card, the project hub, Inventory. Columns drop as designed and the Measure toolbar wraps. Noted:

- The Library list's Download/Delete stack so tightly that adjacent rows' targets touch.
- Inventory keeps "PART #" (all dashes) and wraps "2026-11-02" mid-date while dropping Location and Min.
- The file page's breadcrumb wraps to two lines and pushes "+" under it.
- Static risks, not measured: `.btn` is `white-space: nowrap` and holds filenames ("Download #{name}") and project names ("Back to #{name}"); `.page-head h1` has no `overflow-wrap` except on the project heads, so a long underscore filename or a long email (the user edit page's h1) can overflow; `pages/settings.css:32` `minmax(300px, 1fr)` has no query and leaves ~11 px at 375; the recipe table has nowrap headers and no `overflow-x` wrapper (`files/_lbrn_settings.html.erb:15-53`); release file paths and picker names lack `overflow-wrap: anywhere`.

## K. What is consistent and should be kept

- One accent per screen holds on every page opened, including the three edit tabs, the auth cards and the public pages; selection is ink everywhere.
- Breadcrumbs, `.page-head` + h1 and `<title>` are present on the 16 main signed-in pages; the shell lights exactly one rail link on every page checked.
- 35 of 39 delete controls confirm, all with the named object; no `alert()`/`prompt()`; no TODO, raw id or "§" reaches a template.
- The component vocabulary (`.btn`, `.field`, `.panel`, `.chip`, `.badge`, `.empty`, `dl.meta`, `details.menu`, `details.composer`) is used almost everywhere; the drift is in which variant, not in bespoke markup.
- Dark mode is correct on every page checked: tokens flip, renders stay ink-on-paper on the dimmed cards, the Measure stage and code editor repaint.
- The calculator, the tabs controller, the file chooser (focus, Escape, return) and the project hub's keyboard reordering are solid.
- The public pages read as the same product as the signed-in app, and the unlisted link, feed and bundle work.

---

## Appendix: pages opened live

Signed in: Recent; Library root, `Projects/catan`, `Projects/catan/laser` (list and grid); file pages for `.lbrn2`, `.svg`, `.stl`, `.pdf`, `.png`, `.txt`, `.md`, `.c` (in a repo, with History), `.dxf`, gerber `.zip`, `.kicad_sch`, `.mage`, `.3mf`, `.gtl`; the right-click menu, rename/move, "This came from…", "Add a note"; 3D models view, a model page, model edit, Import model; Projects index; the catan, Desk Lamp (unlisted, wiring, schematic), Audit Bench, firmware-blink (repo), Empty Project and archived hubs; project new, edit (Details), Page layout, Publishing, Preview; BOM page, sheet page, Attach a file, Add a model; Inventory index, item, new item, Suppliers, Locations; Tools, Box Generator, OpenSCAD, Generators, the calculator, the New ▾ menu; Trash, delete and restore flows; Search; a tag page; Help; Settings hub, Library folder, Shelves, Tags, Users, a user's admin page, Devices, Account. Public: Explore, `/u/owner`, the public catan page, a public file view, the unlisted Desk Lamp page, the compose page. Signed out: sign-in, a failed sign-in, sign-up, forgot password, resend confirmation. Dark theme: Recent, Library, a file page, the hub, a model page, Settings, Inventory, the editor. Widths: 1440×900 throughout, 1024×768 (Recent, Library, hub), 375×812 (Recent, Library, file page, hub, Inventory).
