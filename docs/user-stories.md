# User stories — the bench maker

**Date:** 2026-09-07 · **Persona:** 1 of the four in
`docs/superpowers/specs/2026-09-07-stage-4-bench-maker-design.md` (the others are stubs there) ·
**Scope:** the maker web app in this repo. The sync layer's stories are historical, in
`docs/user-stories-sync-2026-06.md`.

This is a **living document**. A slice that lands re-measures the tags of the stories it names
(the spec's slice table cites stories by the ids below, so **never renumber**; a story that is
withdrawn keeps its row and says so). The record (CLAUDE.md §11) carries the arcs; this file
carries what a maker is trying to do and how far the app gets.

## Honesty contract

| tag | meaning |
|---|---|
| `works` | exercised by code on `main`, confirmed on the seeded app or the share deployment |
| `rough` | works, with a named friction a maker will hit |
| `built-unused` | exists; zero real use measured on the share deployment on 2026-09-07 — find out why before investing |
| `missing` | no code |
| `by design` | deliberately not built; the reason is cited |

**Evidence prefixes.** `share:` the real library on the share deployment (3,232 live files, measured
2026-09-07). `seed:` a local library seeded to the same shape — a laser project whose folder is a
git repo, a firmware + PCB project, a 3D-print project, and `designs/`, `cnc/`, `laser/` outside
`Projects/`. `code:` a file and line from the 2026-09-07 audit.

---

## The persona

**The bench maker.** Self-hosts on Unraid; the NAS share is the library. Saves straight from
desktop programs onto the share and expects the app to notice within minutes.

| work | programs | on the share |
|---|---|---|
| laser, first | LightBurn, Illustrator, Inkscape | `.lbrn2` 77 · `.svg` 168 · `.dxf` 129 · `.ai` 25 |
| 3D printing | a slicer, Onshape/Fusion, Printables downloads | `.stl` 118 · `.3mf` 45 · `.step` 39 |
| CNC | MillMage | `.mage` 23 |
| electronics + firmware | PlatformIO/Arduino, ESPHome, KiCad | `.ino` 102 · `.cpp/.h/.hpp` ~950 · 3 git repos · Gerbers |
| docs, photos, notes | Markdown, screenshots, PDFs | `.md` 123 · `.png` 91 · `.pdf` 41 |

Uses the app as a **viewer over the NAS** and as a **box generator** (25 saved boxes, the last five
days before this was written). Nine projects exist, eight auto-created from folders, all still
"planning". Tasks, build log, BOM, inventory, print runs, releases and publishing are unused. A
fifth of the files live outside `Projects/`, in `designs/`, `old catan/`, `cnc/`, `laser/`,
`3d models/`, and as loose screenshots at the root.

Wants: **save, see it, measure it, generate the next file, keep it together, show it — with no
bookkeeping.**

---

## T1. A project comes into being

| # | story | tag | evidence / friction |
|---|---|---|---|
| 1.1 | When I make a folder under `Projects/` on the NAS and start saving into it, I want it to become a project by itself, so that I never fill in a form to start work. | `rough` | Works on scan (≤ 15 min on share). **S4-6:** discovery stamps `discovered_at` and a **New** badge sits on the card until the first open, on the index and on Home, on every backend; on chunk_remote the scan button runs discovery between the pull and the intake and names the folders it adopted (capped runs say "N of M"). Still rough: on share/s3 the scan is a background job, so no flash can name them, and slug and folder name can still disagree forever (`project_discovery.rb`). Cap 50 per run. |
| 1.2 | When I am at the browser with an idea, I want New project to mint the folder on the NAS and make it the current project, so that the next LightBurn save lands in it. | `works` | Mints `Projects/<slug>` (`project.rb`). **The "make it current" half was retired in slice 4 of the 2026-10-08 redesign:** new files land in the folder you're looking at, and a tool starts where it last saved. **S4-6:** the form carries status and (until slice 4) "make current" (default on), the flash names the folder it made or names the error class when it could not, and a non-default status is badged on the project page (`projects_controller.rb`, `projects/_form.html.erb`). |
| 1.3 | When I keep laser work in `designs/` and CNC in `cnc/`, I want to say "this folder is a project" without moving it, so that my NAS layout stays mine. | `rough` | **S4-6:** "Make this folder a project" in the Files page's folder menu adopts any folder in place (`Projects::AdoptionsController`, `autofile: false` so the maker's layout stays theirs), refusing `Projects/` itself, the root, a claimed folder, a `.git` or working-tree interior; the auto model the seeded shelf had made of it is removed in the same transaction, and deleting the project releases the folder to the catalog again. **F (2026-10-13):** a FILE can be renamed or moved to another folder from its page and the inspector (`FilesController#rename`/`#move`, both `Maker::MoveNode`). Still rough: no folder rename or move from the web — refused on purpose until `Share#move` rewrites a subtree's paths in one call — and the adoption door is on the Files page only (Home has no folder on it). share: ~20% of files live outside `Projects/`. |
| 1.4 | When I clone a firmware repo into `Projects/`, I want the project page to show its README, commits and history and never re-file its files, so that a git project stays a git project. | `rough` | Adopted; files correctly never filed (`attach_to_project.rb:192`). **S4-1:** a project whose root is the repo now gets the repository card, a `repo` badge and Commits/History in the Files head, and the caption says the sweep leaves its files alone (`ProjectFolderListing#root_repo?`, `projects/_attachments.html.erb`). Still rough: no "new" marker when discovery adopts it (S4-6) and build output is indexed (S4-2). |
| 1.5 | When the app creates a project, moves a file or picks a cover for me, I want to see that it did, so that I trust it with my folders. | `rough` | **S4-2** landed the filing half: the flash names moves and the project page shows the last sweep. **S4-6:** creation names its folder, every current-project switch confirms and names the destination (retired with the current project in slice 4 of the 2026-10-08 redesign: new files land in the folder you're looking at), the chunk_remote scan names what discovery created, and a discovered project wears **New** until opened. Still rough: cover selection is silent, and on share/s3 discovery reports only through the badge. |
| 1.6 | When I rename a project or finish it, I want folder, URL and page to stay in step, and "done" to be a state I can set. | `rough` | Rename never renames the folder or the slug (`project.rb`), deliberately, and the form now says so. **S4-6:** status is settable and badged, and "Not a project" is an explicit action with its own sentence beside Archive — one write, two sentences (`projects_controller.rb#destroy`, `dismiss=1`); a folder deleted in Finder is never re-minted behind the maker's back and the Files panel says so with a link to Trash. |

## T2. Each file type: made in a program, saved to the share, worked with on the web, and back

Every row shares one story: *When I save X from a program onto the share, I want the app to show
it right, let me do the web thing for it, and hand me back to the program — and when I save
again, catch up.*

| # | type | tag | what works / what does not |
|---|---|---|---|
| 2.1 | LightBurn `.lbrn2` | `works` | Embedded thumbnail, Measure view, laser-settings panel, print to scale, SVG export (`files_controller.rb:1538`, `files/_measure.html.erb`). **S4-2:** `.lbrn` (v1) files beside it as `laser` (`ROLE_BY_EXT`). |
| 2.2 | `.svg` `.dxf` | `works` | Thumbnails, Measure, print, export. The **box generator writes SVG onto the share** — the one true write-back (`tools/addons_controller.rb:520-536` → `library_output.rb:120-123`). SVG cannot be edited as text (`git-editing.md:485-501`). |
| 2.3 | `.ai` | `rough` | **S4-2:** role `vector` → files into `design/`; a thumbnail through pdfium when the bytes are a PDF (`Maker::Previews::Pdf`, registered by name, retracted by content). Still rough: an `.ai` saved without PDF compatibility has no preview, and there is no in-browser vector view. share: 25 files. |
| 2.4 | MillMage `.mage` | `works` | **S4-2:** role `cnc_design` → `cnc/` (`ROLE_BY_EXT`, `ROLE_FOLDERS`), beside the Measure view and the CNC operations panel it already had; existing attachments re-derived by migration `20260907120100`. |
| 2.5 | `.stl` `.3mf` `.step` `.obj` and 15 more (`VIEWABLE_3D_EXTS`) | `works` | Thumbnails, lazy 3D viewer, bounding dims, 3MF slicer colours and units; the OpenSCAD tool writes 3MF back. No measuring. `3dm` `amf` `fcstd` open in the browser with no thumbnail (`registry.rb:36-42`). |
| 2.6 | OpenSCAD `.scad` | `rough` | Code view; editable in the browser **only inside a git repo** (`files_controller.rb:444`); the OpenSCAD tool reads it and writes 3MF. |
| 2.7 | firmware `.ino` `.cpp` `.h` `.yml` | `works` in repos | Code view, edit, commit, history, restore. `json`/`txt` file to `docs/` while `yml` files to `code/` (`file_attachment.rb:80-124`). |
| 2.8 | KiCad + Gerbers | `rough` | Gerber single, zip and `.gbrjob` render as a board; KiCanvas for KiCad. **S4-2:** `kicad_sch`/`kicad_pcb` carry a filing rule (`Maker::FilingRule::KEY_RE`) and file into `pcb/`; a zip the Gerber reader recognises as a board files into the maker's own layer folder, `pcb/` by default (`ProjectIntake#board_folder_for`). Still rough: their ROLE stays `other`, so the type filter offers no KiCad chip and never will (`EXT_RE`). |
| 2.9 | photos, PDF, README | `rough` | Image inline, PDF in the browser's viewer. **S4-1:** the project-root README renders on the private project page for every project (`projects/_readme_card.html.erb`, `_repo_card` for a root repo). Still rough: the README's own file page shows source, and README links resolve only on the project and public pages. |
| 2.10 | any file: back to the program | `rough` | **S4-3:** the file page's meta list carries the library path as a `Path` row with a Copy button (`FilesController#show` → `Maker::LibraryTree`, `copy_controller.js`), so the maker can find the file on the NAS from the browser. Still rough: opening it in the program is the OS's job — no reveal or open hand-off, by decision (spec §9). |
| 2.11 | any file: I saved it again | `rough` | **S4-3:** the file page polls its own pending preview and reloads once when it lands (`thumbs_controller.js` reload mode); both Rescan doors poll a real "scan finished" (`users.library_scanned_at`, `GET /files/scan_status`) instead of guessing six seconds. Still rough: up to 15 min blind before Rescan, and a refused scan (`UnsafeScan`) looks like a slow one to the browser. |
| 2.12 | any file: I exported from the web | `rough` | **S4-3:** Measure's SVG export and its print sheet have **Save to library** beside Download — the same bytes, through the existing two-door upload flow, into the source file's folder as `<base>-parts.svg` / `<base>-print.svg`, filed by the sweep and named in the readout. Still rough: the sheet CSV and the BOM CSV are downloads only. |
| 2.13 | any text file: I edited on the web | `rough` | Git repos only, ≤ 200 KB; on share and s3 the save overwrites with git as the only undo (`git-editing.md:28-45`). **S4-3:** a Save re-enqueues the preview after the bytes land, so the thumbnail catches up on its own. **S4-4** landed D3's exception for the project README only (`Projects::ReadmesController`, `docs/invariants/git-editing.md`'s Markdown-exception section); any other text file outside a repository is still refused, and widening that is a second door that needs its own slice. |

## T3. Files connect to each other

| # | story | tag | evidence / friction |
|---|---|---|---|
| 3.1 | When a tool generates a file (box → SVG), I want the file to know which tool state made it and the state to list its outputs, so that I can regenerate. | `works` | Generated group and "Edit in tool" (`_generated_group.html.erb`, `Maker::AddonOrigin`). The revision that wrote the file is not recorded; a renamed output leaves a stale row (`library_output.rb:88-97`). |
| 3.2 | When one file is exported from another (`.lbrn2` → SVG, STEP → STL → 3MF, KiCad → Gerber zip), I want them kept as one lineage, so that I open the source, not the export. | `rough` | **S4-8:** `maker_file_links` holds a `derived_from` edge — written automatically by Measure's Save-to-library and by an OpenSCAD save whose data names the `.scad` it read, and settable by hand from "This came from…" on any file page; both directions render in the file page's Connected panel, and a link dies with either end. Still rough: the three computed lineages (`.gbrjob` → layers, zip → members, README links) stay computed, and a slicer's export saved by hand from another program is a hand link. |
| 3.3 | When I photograph a cut or a print, I want the photo attached to the file or the step it shows. | `rough` | A photo attaches to a build-log entry (`entry_photos_controller.rb`). **S4-8:** `photo_of` attaches a picture to a FILE from that file's own page (images only, by role), and the picture's page says what it shows. Still rough: a print run has no node column, so a photo cannot attach to a print (`maker_print_runs`, out of this stage). |
| 3.4 | When my README links files and images, I want the links to work wherever I read it. | `rough` | Resolved on the public page and in the repo card (`readme.rb`); the private file page shows source. **S4-8** adds a stored file↔file edge and deliberately does not touch the computed README link resolution, which stays `Maker::Readme`'s. |
| 3.5 | When I search, I want notes, README text and folder paths found, not only file names. | `rough` | **S4-8:** a Notes group over `action_text_rich_texts.body` joined through `maker_notes` and scoped to live files, and a Folders group by name (S4-8). Still rough, each with its reason: README text is not searched — it is read through the port at request time with no index, so a per-project read per search fails §14a's local-first rule; folder PATHS are not searched — `storage_path` is share/s3's only, so a path match would answer differently per backend. |
| 3.6 | When a catalogued model is used in a project, I want the project to show it and its prints. | `missing` | No model↔project edge; print runs hang off Models only (`print_run.rb:12`). |
| 3.7 | A BOM line points at a design file; a release records every file's version. | `built-unused` | Both exist (`bom_line.rb:22`, `release_file.rb`); share: 0 rows of either. Release downloads are current bytes with a "changed" badge, not snapshots. |

## T4. Organised, low friction, everything in one place

| # | story | tag | evidence / friction |
|---|---|---|---|
| 4.1 | When I drop files at a project root, I want them filed into subfolders I chose, and told when it happened. | `works` | **S4-2:** the eager flash names the file and the folder off `Result#plan` ("Filed plate.svg into design/."), a collision names the folder actually tried (`Result#conflict_folders`), and the project page's Files panel says what the last sweep filed and when (`last_swept_at`, `last_sweep_moves`, one writer). A working tree's caption stopped promising a sweep in S4-1. |
| 4.2 | When I change a filing rule, I want existing files re-filed. | `missing` | Rules apply to root files only, on their next arrival; a rule change touches nothing already placed. **Stays missing on purpose** (spec §9): re-filing already-placed files is a move the sweep must not make unasked, and the new per-folder settings page invites edits — so the page says a changed rule applies to files that arrive from now on. |
| 4.3 | When I open Settings → Filing, I want "laser files go to `laser/`", not 130 extension rows. | `rough` | **S4-2:** one card per folder, its extensions as chips with Remove, one add form per card; a project can switch automatic filing off (`maker_projects.autofile`, the sweep still attaches). Still rough: rules are per user, never per project (spec §9 defers that until this page shows whether one map is still too many). |
| 4.4 | When I open the app, I want to see what changed on the NAS since I last looked, per project. | `rough` | **Slice 6 of the 2026-10-08 redesign:** Recent (`/`) shows the 16 files changed most recently, library-wide, and a project's Files panel opens on a Recently changed row of its folder's 8 newest. Still rough: neither says what is new *since I last looked*. |
| 4.5 | When I set a current project, I want it obvious and driving uploads, tool output and new files. | `by design` | **Retired in slice 4 of the 2026-10-08 redesign:** new files land in the folder you're looking at, and a tool starts where it last saved. What it was until then: drives uploads and tool output (`current_project.rb`). **S4-6:** a switch confirms on every branch and names the destination (`CurrentProject#current_project_notice`); a switch that resolves to nothing is an alert that changes nothing; "make current" on the new-project form. Nothing sets it automatically, by design. |
| 4.6 | When I point a fresh install at the same NAS, I want my notes, tasks, log, box parameters, releases and tags to come back. | `missing` | All database rows keyed by node ids a fresh install re-mints (`reconciler.rb:547,606`). Only projects and models re-derive from the folders. **Deferred to its own spec** (stage 4 decision D2). |
| 4.7 | When a screenshot or a Printables zip lands at the library root, I want a one-step "this belongs to project X". | `rough` | Attach and relocate exist on the project page only. **S4-6:** a folder can become a project from the Files page in one click. **F (2026-10-13):** a loose file's page and inspector offer Move to folder, so it can be put into a project's folder from the browser, where the next sweep files it. Still rough: that is "pick the folder", two steps, not "this belongs to project X". share: loose screenshots at the root. |
| 4.8 | When a repo carries build output, I want it out of my library. | `rough` | Dot-prefixed dirs (`.pio`) hidden by `Node.visible_entries`. **S4-2:** `node_modules/` and `__pycache__/` join them (`Library::BuildOutput`), out of the folder view, the project panel, its counts and search; `build/` deliberately stays visible (a maker's own folder name). Still rough, by design: the files INSIDE remain indexed and appear in the flat by-extension view — the same recorded limit `.git` carries — and nothing is un-indexed (§14b). share: ~440 `.o/.d/.a` files. |

## T5. Publishing, with documentation and the files embedded and linked

| # | story | tag | evidence / friction |
|---|---|---|---|
| 5.1 | When I decide to publish, I want to preview the visitor's page first. | `works` | **S4-4:** `ProjectsController#preview` renders the visitor's page — the same `public/projects/_page.html.erb` the public route renders — for the owner at any visibility, inside the app shell behind a banner that says what is and is not reachable; the links are the visitor's, dead for a private project by decision. The public route still 404s a private project to everyone, its owner included (`project_preview_test.rb` asserts both in one file). |
| 5.2 | When I flip to public, I want the URL and what became downloadable stated. | `rough` | **S4-4:** one Publish panel at the foot of the project page (`projects/_publish.html.erb`, a `Publish` link in the head) states each visibility's meaning in a sentence, warns that the whole visible folder becomes downloadable, claims the handle inline and returns to the project, and the flash names the URL it made and who can now open it (`projects_controller.rb#publish_notice`); visibility and licence left the edit form so one question has one control. Still `rough`: the handle stays locked once anything is published (`user.rb`), a separate decision nothing here moves. |
| 5.3 | When I write the README, I want to do it in the app, from a template, and see it rendered on my own page. | `works` | **S4-1** landed the render half; **S4-4** the rest: the README card carries an editor for ANY project (`projects/_readme_editor.html.erb`, `Projects::ReadmesController` — a door that takes no node id and can write only the folder's own README), a template when there is none, CodeMirror from the one vendored bundle, and the no-history trade named on the editor on share/s3. Save redirects to the project page, so the rendered result is the payoff. Still root-only, six case-sensitive names (`readme.rb:37`), and a save compares the catalog's token (`tinkerex#276`). |
| 5.4 | When my README embeds photos and links files, I want them to render and open. | `rough` | Relative links resolve. **S4-4:** headings keep an anchor, namespaced `user-content-<slug>` so a README heading can never claim an app id (a `## Project Tasks` heading once took the tasks panel's Turbo target — measured), with in-document `#links` rewritten to match and duplicates suffixed (`markdown.rb#keep_heading_anchors`). Absolute images are still dropped to alt text and an SVG image still force-downloads — unchanged, not this slice's. |
| 5.5 | When a visitor opens my project, I want the model in 3D, the board and the cut file viewable, not download links. | `works` | **S4-5:** a public file page (`/u/:handle/:slug/files/:id/view`) renders the same eight viewer partials the maker's own page does (`app/views/files/viewers/`) — 3D, Measure read-only (print and SVG export kept, no Save), the Gerber stage with a job's published siblings, KiCanvas, images, PDF and source — over `Maker::PublicProject`, with an unlisted project's token on every URL; the public project page's file names link to it. The geometry poll never writes; the page enqueues one render when none is current. |
| 5.6 | When I cut a release, I want visitors to get the files as they were. | `rough` | A release stores references and content tokens (`release_snapshot.rb:7-11`); downloads are the current bytes with a "changed" badge. |
| 5.7 | When someone lands on `/explore` or my handle page, I want a cover and a way around. | `rough` | **S4-5:** the anonymous layout carries a header — the site name to `/explore`, the maker's handle on a project or file page (`layouts/_public_header`); `/u/:handle`'s cards show each project's cover as a ready thumbnail and the project page leads with its hero. Still `rough`: `/explore` keeps the placeholder by measurement — `ThumbnailMap` is per-user and `/explore` is one owner per card, so covers there need a per-owner map (a separate decision, not this slice's). |
| 5.8 | When I share an unlisted link, I want to copy it and later revoke it. | `works` | **S4-4:** the Publish panel shows the unlisted link with Copy, and New link mints a fresh token so the old one 404s at once (`Projects::UnlistedTokensController`, `publishing_test.rb` drives the public route with the old `k`). |

## T6. A project view that fits the project

| # | story | tag | evidence / friction |
|---|---|---|---|
| 6.1 | When I open a laser project, I want the cut file, the photos and the settings first, not BOM, wiring and releases. | `rough` | **S4-1:** an empty secondary panel is quiet. **Slice 6 of the 2026-10-08 redesign:** an empty Build log, Tasks, BOM, Wiring, Releases or Sheets is absent until it holds a row or "+ Add panel" opens it. **S4-7:** a laser project's page no longer carries BOM, Wiring, Releases or Sheets (`Maker::ProjectKind::PRESETS`), and the kind is suggested once, from the folder's own files, by discovery and adoption. Still rough: which file comes first *inside* the Files panel is still name order (`project_folder_listing.rb`), which is 6.4's other half. |
| 6.2 | When I open a firmware + PCB project, I want README, board, schematic, commits and wiring at the top. | `rough` | **S4-1:** the repository card, README and Commits render for a root-repo project, at the top of Files. **S4-7:** an electronics project lifts Schematics and Wiring above the build log (the story's own list), and a firmware repo is suggested `electronics` from its `.git` marker and its sources. Still rough: no board render on the project page; schematics are KiCad-only. |
| 6.3 | When I open a 3D-print project, I want the model as the hero and its print history. | `rough` | **S4-1:** the cover is the page's hero. **S4-7:** a `print` project's hero prefers a model over a photo (`Maker::ProjectKind.hero_roles`), so the model is the hero without anyone choosing one. Still rough: print history lives on Models. |
| 6.4 | I want to pin the important file or choose the hero. | `rough` | **S4-7:** the kind picks the hero's preferred role among the project's attachments, and a chosen `cover_node_id` still wins over it. Still missing: pinning a file to the top of the Files panel — files stay peers sorted by name (`project_folder_listing.rb`). |
| 6.5 | I want to hide, reorder or add panels per project, or pick a project type that presets them. | `works` | **S4-7:** `kind` with six values, suggested once from the folder at creation and editable on the form (never re-suggested: a later "this looks like a laser project" is a prompt, not a write); per-kind presets for order and visibility; per-project show/hide/reorder (the chooser this shipped with, `projects/_panel_chooser`, is retired); Reset removes the override; the visitor's page honours the same layout. **The page editor (2026-09-09):** edit mode is the project page itself — drag to reorder, hide, tiles/list/browser, Full/Half width and a title and intro per panel, all draft until Save (`projects/_panel_slot`, `layout_editor_controller.js`, `Projects::PanelsController`) — with a YAML drawer whose text is the shareable form of the layout and whose Apply merges pasted YAML into the draft (`Maker::LayoutDocument`). The visitor's page mirrors the widths, titles and intros too. **Content blocks (2026-09-09):** the page can hold the maker's own content as well as the app's — text (Markdown), link and image blocks added from the bar's Add block menu, arranged and sized by the same drag, and carried in the same YAML (`Maker::ProjectBlock`, `projects/_block_panel`, `projects/_block_editor`); the cover and the description are editable in place above the grid; and half-width panels pack without gaps on all three renders (`masonry_controller.js`). |
| 6.6 | I want a photo gallery on my own page. | `works` | **S4-1:** `projects/_photos.html.erb` over `Maker::ProjectPhotos.rows`, the one definition the public page uses too — folder images plus build-log photos, once each, by name. |
| 6.7 | I want sections named for me, not folder names. | `works` | **The page editor (2026-09-09):** a per-panel title on both pages (`panels["titles"]`, `ProjectsHelper#panel_title`, `Layout#title_for`). The folder is still the truth (stage 3 decision 1): the panel head keeps the real path under the heading, and the title is this page's label, never a library-wide rename. Was `by design` ("an alias would be a table that fights it"); the map on the project row is not that table. |
| 6.8 | I want the list view to carry the same actions as tiles. | `works` | **S4-1:** each list row carries `file_menu_data`, so right-click offers Add note / Open / Download / Edit-in-tool exactly as a tile does (`_file_rows.html.erb`). |

---

## Coverage

| theme | stories | works | rough | missing | other |
|---|---|---|---|---|---|
| T1 | 6 | 1 | 5 | 0 | |
| T2 | 13 | 5 | 8 | 0 | |
| T3 | 7 | 1 | 4 | 1 | 1 built-unused |
| T4 | 8 | 1 | 4 | 2 | 1 by design |
| T5 | 8 | 4 | 4 | 0 | |
| T6 | 8 | 4 | 4 | 0 | |
| **all** | **50** | **16** | **29** | **3** | **2** |

Re-counted 2026-10-13: 6.7 moved to `works` on 2026-09-09 (the page editor) and the table had kept it
under `by design`.

Re-measured after S4-1 (2026-09-07): 6.6 and 6.8 moved to `works`; 1.4, 2.9, 6.1, 6.2, 6.3 gained new evidence and stay `rough`; 5.3 gained its render half and stays `missing`.

Re-measured after S4-2 (2026-09-07): 2.4 and 4.1 moved to `works`; 2.3 moved from `missing` to `rough`; 2.8, 4.3, 4.8 gained new evidence and stay `rough`; 1.5 gained its filing half and stays `missing`; 4.2 stays `missing` by decision.

Re-measured after S4-4 (2026-09-07): 5.1, 5.3 and 5.8 moved to `works`; 5.2 and 5.4 gained new evidence and stay `rough`; 2.13 records why D3's exception is the README's only.

Re-measured after S4-5 (2026-09-07): 5.5 moved to `works`; 5.7 gained the header, the hero and covers on a maker's page and stays `rough`.

Re-measured after S4-6 (2026-09-07): 1.2 moved to `works`; 1.3 and 1.5 moved from `missing` to `rough`; 1.1, 1.6, 4.5 and 4.7 gained new evidence and keep their tags.

Re-measured after S4-7 (2026-09-07): 6.5 moved to `works`; 6.4 moved from `missing` to `rough`; 6.1, 6.2 and 6.3 gained new evidence and stay `rough`.

Re-measured after S4-3 (2026-09-07): 2.10 moved from `missing` to `rough` (the path is there; the hand-off is the OS's by decision); 2.11, 2.12, 2.13 gained new evidence and stay `rough`.

Re-measured after S4-8 (2026-09-07): 3.2 and 3.5 moved from `missing` to `rough`; 3.3 gained the file photo and stays `rough`; 3.4 is unchanged by design.

Re-measured after folder panels (2026-09-08): 6.5 stays `works` with new evidence — each subfolder of the project folder is its own panel (hide, move, and tiles/list/browser per panel, persisted per project), on the maker's page and mirrored for a visitor; 6.1–6.4 unchanged.

Re-measured after the page editor (2026-09-09): 6.5 stays `works` — an in-place edit mode on the project page (drag to reorder, hide, view, Full/Half width, title and intro per panel, draft until Save) with a YAML drawer whose text is the shareable layout; the visitor's page mirrors all of it.

Re-measured after content blocks (2026-09-09): 6.5 stays `works` with text, link and image blocks arranged by the editor, the page intro editable in place, and half-width panels packing without gaps.

Re-measured after slice 4 of the 2026-10-08 redesign (2026-10-09): the current project is retired, so 4.5 moved from `works` to `by design`; 1.2 (its "make it current" half) and 1.5 (the switch's confirmation) record the retirement and keep their tags.

Re-measured after slice 6 of the 2026-10-08 redesign (2026-10-09): 4.4 and 6.1 gained new evidence (Recent and a project's Recently changed row; panels that appear when they hold something) and stay `rough`.

Which slice moves which story: the slice table in the stage 4 spec.
