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

**Charles at the bench.** Self-hosts on Unraid; the NAS share is the library. Saves straight from
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
| 1.1 | When I make a folder under `Projects/` on the NAS and start saving into it, I want it to become a project by itself, so that I never fill in a form to start work. | `rough` | Works on scan (≤ 15 min on share, `config/recurring.yml:24`). Zero feedback: no flash, no "new" marker, a log line only (code: `app/jobs/maker/project_discovery_job.rb:38`). Slug and folder name can disagree forever (`project_discovery.rb:66,69`). Cap 50 per run. |
| 1.2 | When I am at the browser with an idea, I want New project to mint the folder on the NAS and make it the current project, so that the next LightBurn save lands in it. | `rough` | Mints `Projects/<slug>` (`project.rb:144-152`). Does not set current (`projects_controller.rb:251-259`). No status field on the form, so planning/active/paused/done are unreachable — share: all 9 projects read "planning". A failed mkdir still says "Project created." (`projects_controller.rb:346-350`). |
| 1.3 | When I keep laser work in `designs/` and CNC in `cnc/`, I want to say "this folder is a project" without moving it, so that my NAS layout stays mine. | `missing` | Only direct children of `Projects/` are adopted (`project_discovery.rb:112-116`). seed: `designs/tray` silently became a **Model** through the seeded `*` shelf (`shelf.rb:24`). No adopt door; no folder rename or move from the web. share: ~20% of files live outside `Projects/`. |
| 1.4 | When I clone a firmware repo into `Projects/`, I want the project page to show its README, commits and history and never re-file its files, so that a git project stays a git project. | `rough` | Adopted; files correctly never filed (`attach_to_project.rb:192`). But a project whose **root is the repo** gets no README card and no Commits/History links — the card exists only for a repo *inside* the folder (`_file_tree_section.html.erb:50-58`; `collect_dirs` never flags the root). seed: jewelry-box. share: all three real repos are project roots. The page still says "Loose files are filed on the next sweep" (`_attachments.html.erb:95`). |
| 1.5 | When the app creates a project, moves a file or picks a cover for me, I want to see that it did, so that I trust it with my folders. | `missing` | Discovery, the scheduled sweep and current-project switches report only to the log (`project_intake_job.rb:120-141`, `current_project_controller.rb:6-15`). Filing feedback covers a name collision only (`project_folder_intake.rb:103-107`). |
| 1.6 | When I rename a project or finish it, I want folder, URL and page to stay in step, and "done" to be a state I can set. | `rough` | Rename never renames the folder or the slug (`project.rb:202-203`). Archive doubles as the undocumented "not a project" dismissal (`docs/invariants/project-intake.md:20-28`). |

## T2. Each file type: made in a program, saved to the share, worked with on the web, and back

Every row shares one story: *When I save X from a program onto the share, I want the app to show
it right, let me do the web thing for it, and hand me back to the program — and when I save
again, catch up.*

| # | type | tag | what works / what does not |
|---|---|---|---|
| 2.1 | LightBurn `.lbrn2` | `works` | Embedded thumbnail, Measure view, laser-settings panel, print to scale, SVG export (`files_controller.rb:1538`, `files/_measure.html.erb`). `.lbrn` (v1) has no role → `other/` (`file_attachment.rb:66`). |
| 2.2 | `.svg` `.dxf` | `works` | Thumbnails, Measure, print, export. The **box generator writes SVG onto the share** — the one true write-back (`tools/addons_controller.rb:520-536` → `library_output.rb:120-123`). SVG cannot be edited as text (`git-editing.md:485-501`). |
| 2.3 | `.ai` | `missing` | No role, no thumbnail, no page: "No inline preview." Filed to `other/`. share: 25 files. |
| 2.4 | MillMage `.mage` | `rough` | Full page — Measure and a CNC operations panel (`show.html.erb:334-336`) — but no `ROLE_BY_EXT` entry, so filed to `other/`. |
| 2.5 | `.stl` `.3mf` `.step` `.obj` and 15 more (`VIEWABLE_3D_EXTS`) | `works` | Thumbnails, lazy 3D viewer, bounding dims, 3MF slicer colours and units; the OpenSCAD tool writes 3MF back. No measuring. `3dm` `amf` `fcstd` open in the browser with no thumbnail (`registry.rb:36-42`). |
| 2.6 | OpenSCAD `.scad` | `rough` | Code view; editable in the browser **only inside a git repo** (`files_controller.rb:444`); the OpenSCAD tool reads it and writes 3MF. |
| 2.7 | firmware `.ino` `.cpp` `.h` `.yml` | `works` in repos | Code view, edit, commit, history, restore. `json`/`txt` file to `docs/` while `yml` files to `code/` (`file_attachment.rb:80-124`). |
| 2.8 | KiCad + Gerbers | `rough` | Gerber single, zip and `.gbrjob` render as a board; KiCanvas for KiCad. KiCad files **cannot have a filing rule** (`EXT_RE`, `files-preview.md:41-50`) → `other/`; a Gerber zip files to `archives/`, not `pcb/` (`files-preview.md:143-148`). |
| 2.9 | photos, PDF, README | `rough` | Image inline, PDF in the browser's viewer. A README shows as **source** on its file page and is rendered nowhere on a private project page except inside a sub-folder repo card. |
| 2.10 | any file: back to the program | `missing` | The file page shows Name/Size/Type/Modified (`show.html.erb:47-66`), never the library path, never a reveal or open hand-off; actions are Download, Delete, Back. |
| 2.11 | any file: I saved it again | `rough` | Up to 15 min blind plus render time; the file page never refreshes itself (`thumbs_controller.js` runs only on grids); Rescan guesses a 6 s reload (`scanreload_controller.js:16-23`). |
| 2.12 | any file: I exported from the web | `rough` | Every export — Measure SVG, print sheet, sheet CSV, BOM CSV — is a browser download; nothing lands on the share. |
| 2.13 | any text file: I edited on the web | `rough` | Git repos only, ≤ 200 KB; on share and s3 the save overwrites with git as the only undo (`git-editing.md:28-45`); the thumbnail and page stay stale after Save. |

## T3. Files connect to each other

| # | story | tag | evidence / friction |
|---|---|---|---|
| 3.1 | When a tool generates a file (box → SVG), I want the file to know which tool state made it and the state to list its outputs, so that I can regenerate. | `works` | Generated group and "Edit in tool" (`_generated_group.html.erb`, `Maker::AddonOrigin`). The revision that wrote the file is not recorded; a renamed output leaves a stale row (`library_output.rb:88-97`). |
| 3.2 | When one file is exported from another (`.lbrn2` → SVG, STEP → STL → 3MF, KiCad → Gerber zip), I want them kept as one lineage, so that I open the source, not the export. | `missing` | No stored file↔file edge exists. The three computed ones: `.gbrjob` → layers, zip → members, README links (all by name, per request). |
| 3.3 | When I photograph a cut or a print, I want the photo attached to the file or the step it shows. | `rough` | A photo attaches to a build-log entry only (`entry_photos_controller.rb:15-17`); never to a file, never to a print run (`maker_print_runs` has no node column). |
| 3.4 | When my README links files and images, I want the links to work wherever I read it. | `rough` | Resolved on the public page and in the repo card (`readme.rb:71-77`); the private file page shows source. |
| 3.5 | When I search, I want notes, README text and folder paths found, not only file names. | `missing` | `search_controller.rb:29-60`: `nodes.name`, project name/description, model title, inventory name, tag name. Notes, log entries, addon names, paths: unsearchable. |
| 3.6 | When a catalogued model is used in a project, I want the project to show it and its prints. | `missing` | No model↔project edge; print runs hang off Models only (`print_run.rb:12`). |
| 3.7 | A BOM line points at a design file; a release records every file's version. | `built-unused` | Both exist (`bom_line.rb:22`, `release_file.rb`); share: 0 rows of either. Release downloads are current bytes with a "changed" badge, not snapshots. |

## T4. Organised, low friction, everything in one place

| # | story | tag | evidence / friction |
|---|---|---|---|
| 4.1 | When I drop files at a project root, I want them filed into subfolders I chose, and told when it happened. | `rough` | The sweep works (seed: `design/`, `docs/`). Silent. A working tree is never filed while the caption promises it. |
| 4.2 | When I change a filing rule, I want existing files re-filed. | `missing` | Rules apply to root files only, on their next arrival (`project_intake.rb:292`); a rule change touches nothing already placed. |
| 4.3 | When I open Settings → Filing, I want "laser files go to `laser/`", not 130 extension rows. | `rough` | One row per extension (seed screenshot). Rules are per user, never per project (`filing_rule.rb:12,27`). |
| 4.4 | When I open the app, I want to see what changed on the NAS since I last looked, per project. | `rough` | Home shows eight recent files library-wide; a project shows no "new since". |
| 4.5 | When I set a current project, I want it obvious and driving uploads, tool output and new files. | `works` | Drives uploads and tool output (`current_project.rb:62-78`); nothing sets it automatically; a switch gives no confirmation. |
| 4.6 | When I point a fresh install at the same NAS, I want my notes, tasks, log, box parameters, releases and tags to come back. | `missing` | All database rows keyed by node ids a fresh install re-mints (`reconciler.rb:547,606`). Only projects and models re-derive from the folders. **Deferred to its own spec** (stage 4 decision D2). |
| 4.7 | When a screenshot or a Printables zip lands at the library root, I want a one-step "this belongs to project X". | `rough` | Attach and relocate exist on the project page only; the Files page has no "file into project" action. share: loose screenshots at the root. |
| 4.8 | When a repo carries build output, I want it out of my library. | `rough` | Dot-prefixed dirs (`.pio`) are hidden by `Node.visible_entries` but still indexed and counted; `build/`, `node_modules/`, `__pycache__/` are not hidden at all. share: ~440 `.o/.d/.a` files. |

## T5. Publishing, with documentation and the files embedded and linked

| # | story | tag | evidence / friction |
|---|---|---|---|
| 5.1 | When I decide to publish, I want to preview the visitor's page first. | `missing` | A private project 404s on the public route, for its owner too (`public/base_controller.rb:33`). |
| 5.2 | When I flip to public, I want the URL and what became downloadable stated. | `rough` | Four clicks with a handle, about seven without; the flash is "Project updated." (`projects_controller.rb:265`); the whole visible folder becomes downloadable by ancestry (`public_project.rb:303-316`), unstated. The handle is claimed on the Account page and locked once anything is published (`user.rb:185-189`). |
| 5.3 | When I write the README, I want to do it in the app, from a template, and see it rendered on my own page. | `missing` | Editing only inside git (`files_controller.rb:535-538`); no render on the private page; root-only, case-sensitive six names (`readme.rb:37`). |
| 5.4 | When my README embeds photos and links files, I want them to render and open. | `rough` | Relative links resolve; absolute images are silently dropped to alt text (`markdown.rb:104-107`); an SVG image force-downloads and shows broken; heading ids are stripped so nothing deep-links. |
| 5.5 | When a visitor opens my project, I want the model in 3D, the board and the cut file viewable, not download links. | `missing` | `Public::FilesController#show` is bytes only; no public 3D, Measure or Gerber viewer; KiCanvas for the first KiCad file only (`public/projects/_schematics.html.erb:28`). |
| 5.6 | When I cut a release, I want visitors to get the files as they were. | `rough` | A release stores references and content tokens (`release_snapshot.rb:7-11`); downloads are the current bytes with a "changed" badge. |
| 5.7 | When someone lands on `/explore` or my handle page, I want a cover and a way around. | `rough` | No covers on public cards (`public/_project_card.html.erb`); the anonymous layout has no header, logo or nav. |
| 5.8 | When I share an unlisted link, I want to copy it and later revoke it. | `missing` | The token exists only inside an href and is never rotated (`project.rb:194-199`). |

## T6. A project view that fits the project

| # | story | tag | evidence / friction |
|---|---|---|---|
| 6.1 | When I open a laser project, I want the cut file, the photos and the settings first, not BOM, wiring and releases. | `rough` | Seven fixed panels on every project (`projects/show.html.erb:73-89`); four irrelevant to a laser project, each with an empty composer; the three task groups render at zero. |
| 6.2 | When I open a firmware + PCB project, I want README, board, schematic, commits and wiring at the top. | `rough` | Repo card only for sub-folder repos (see 1.4); no board render on the project page; schematics only for KiCad (`_schematics.html.erb:18-19`). |
| 6.3 | When I open a 3D-print project, I want the model as the hero and its print history. | `rough` | The page renders no hero at all — `cover_node_id` is shown only on cards (`_card.html.erb:8-15`); print runs live on Models. |
| 6.4 | I want to pin the important file or choose the hero. | `missing` | Files are peers sorted by name (`project_folder_listing.rb:215`); the chosen cover never reaches the page. |
| 6.5 | I want to hide, reorder or add panels per project, or pick a project type that presets them. | `missing` | Hard-coded order; no `kind`; no preference storage (`db/schema.rb` `maker_projects`). |
| 6.6 | I want a photo gallery on my own page. | `missing` | Exists on the public page only (`public/projects/_photos.html.erb`); the private page never calls it. |
| 6.7 | I want sections named for me, not folder names. | `by design` | The folder is the truth (stage 3 decision 1); an alias would be a table that fights it. |
| 6.8 | I want the list view to carry the same actions as tiles. | `rough` | `_file_rows.html.erb` emits no context-menu data, so right-click Download / Note / Open-in-tool vanish in list view. |

---

## Coverage

| theme | stories | works | rough | missing | other |
|---|---|---|---|---|---|
| T1 | 6 | 0 | 4 | 2 | |
| T2 | 13 | 4 | 7 | 2 | |
| T3 | 7 | 1 | 2 | 3 | 1 built-unused |
| T4 | 8 | 1 | 5 | 2 | |
| T5 | 8 | 0 | 4 | 4 | |
| T6 | 8 | 0 | 4 | 3 | 1 by design |
| **all** | **50** | **6** | **26** | **16** | **2** |

Which slice moves which story: the slice table in the stage 4 spec.
