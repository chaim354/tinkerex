# Stage 3: the project as a publishable thing — design

Approved 2026-09-04 in conversation (decisions in §2 confirmed one by one; the design approved as
written). Stage 1 (PRs #307–#310) gave every page one visual system and a shell; stage 2
(PRs #311–#316, deployed as `bbd4a44`) gave the app its structure: Home, the project as the hub,
inventory, the bill of materials, tags and search, settings. Stage 3 makes a **project** something
you develop in, then publish, then let people follow — most projects here are hardware AND software.

## 1. Why

The project page is where the maker works, and it still fails them in specific ways: a repository
inside the project shows as one tile that links away; tool output (a generated box) is filed by its
extension and nothing says which tool made it; the panel is tiles only; the sections are a fixed
eleven-role vocabulary; and stray `.ptr` pointer stubs from the git-tracking arc sit in real
projects as "Other" junk. Beyond fixing that, nothing in the app lets a project be shown to anyone
else, and nothing ties a firmware tag to the BOM revision and design files it shipped with.

## 2. Decisions (confirmed)

1. **Sections are the project folder's real subfolders.** The page groups by what is on disk, and
   the one customisable thing is the **extension map** the intake sweep files by: per user,
   extension → subfolder, seeded from today's eleven roles (`Maker::ProjectFolders::ROLE_FOLDERS`
   becomes the seed, and `folder_for` reads the user's rules). "The folder is the truth" carried
   through; no second vocabulary to keep in step with the NAS.
2. **A public project lives at `/u/<handle>/<slug>`.** Users choose a handle the first time they
   publish (Settings → Account); slugs are unique per user. Works unchanged on a managed host; the
   URL is forever, so it is decided now.
3. **A release is a full snapshot with a changelog**: a git tag (or none), the BOM revision, every
   design file's version at that moment, and a changelog entry.
4. **Hardware + software features in stage 3**: a firmware repo surfaced in place; a wiring and
   pin-map table; KiCad previews rendered in the browser with **KiCanvas** (MIT; third-party
   notices ISC, CC0/MIT-like, OFL, Apache-2.0 — §9 satisfied; vendored as one build with one
   importmap pin, the CodeMirror pattern). Parts export and supplier links are out of stage 3.
5. **A public page renders the README and everything else**, under three visibilities: private,
   unlisted (a token link), public (discoverable by tag).
6. **Publishing is the same app, a sessionless `Public::` namespace** reusing the project partials
   and the port's delivery. Not a static export (a second rendering, stale after every edit), not
   a second app (everything twice).

## 3. Data

Five tables and three columns, all in this repo. Nothing here needs the sync server.

| table / column | holds |
|---|---|
| `maker_filing_rules(user_id, ext, folder)` | the extension map; unique `(user, ext)`; seeded from the eleven roles on first read |
| `maker_releases(user_id, project_id, version, git_tag, git_oid, bom_id, bom_revision, notes (rich text), published_at)` | a release |
| `maker_release_files(user_id, release_id, node_id, name, content_token, size)` | each design file as it was |
| `maker_connections(user_id, project_id, from_label, to_label, wire, note, position)` | the wiring table |
| `users.handle` (unique, nullable) | claimed at first publish |
| `maker_projects.visibility` (`private` default, `unlisted`, `public`), `maker_projects.unlisted_token`, `maker_projects.license` | publishing state |

**Versions on a release are exact on `chunk_remote`** (the sync server keeps versions, and
`content_token` is one) and **recorded on share and s3** (`content_token` is the content hash; the
backends are current-state only, §14a), where the page says "changed since this release" when the
current file's hash differs. A release never copies bytes.

## 4. The slices, in order

| slice | delivers | tables |
|---|---|---|
| S3-1 The project view | a list/tiles toggle; the folder as a collapsible tree whose sections are its subfolders, with repositories expandable in place; a **Generated** group for tool output (which tool, which saved item, which revision); `/settings/filing` for the extension map, which the sweep obeys; the `.ptr` sweep (`rake projects:sweep_pointers`) and a display rule hiding `*.ptr` | filing rules |
| S3-2 Firmware and schematics | a repository card: README rendered, latest commit, current tag, links to the commit and history pages; KiCanvas on the file page for `.kicad_sch` / `.kicad_pcb` (`bin/build-kicanvas`, one pin), and a Schematics section on the project page when such files exist | none |
| S3-3 Wiring | the connections table on the project page, edited inline, rendered publicly | connections |
| S3-4 Publishing | handle claiming; visibility and license on the project; `/u/:handle/:slug`, `/u/:handle`, `/explore` with tag chips over public projects; the README rendered from the folder (Markdown, raw HTML stripped) with relative links resolving to the project's files and images inline; downloads, BOM, build log, photos, wiring and schematics on the public page; unlisted links | handle, visibility, token, license |
| S3-5 Releases | create a release from the project page (pick a tag, it records the BOM revision and every design file's version, takes a changelog); a Releases section on both pages with downloads | releases, release files |
| S3-6 Following | the build log and releases as a feed per public project; a project bundle export (files, BOM as CSV, README) | none |

Each slice is one PR with its own plan, executed and reviewed the way stage 2's were
(`.claude/commands/execute-plan.md`), and each keeps the three backend legs at identical run counts.

## 5. S3-1 in detail: the project view

- **Two views, one panel.** `?view=list|tiles` on the project page, remembered the way the Files
  page remembers its view; the list is a `table.table` (name, section, size, modified, origin)
  with the same `col-*` drops; tiles are today's grid. The same `Maker::ProjectFolderListing`
  rows feed both.
- **The tree.** The panel groups by the folder's real subfolders: each section is a
  `details` (open by default; Backups closed) named after the subfolder, holding its files; a
  subfolder inside a subfolder nests; a working tree is a section too, expandable in place with its
  files and a link to its commit and history pages (the catalog holds a repo's files on every
  backend — only `.git`'s own contents are unobserved). Files at the folder root sit first, as
  "Loose" — the sweep's inbox. Linked (outside the folder) and Generated follow.
- **Generated.** A file with an addon origin (`Maker::AddonFile` → state → addon) is listed once, in
  a Generated group, with the tool's name, the saved item's title and revision, and "Open in
  <tool>"; it does not repeat in its section. The relation is read from `maker_addon_files`, one
  query for the page's node ids.
- **The extension map.** `/settings/filing` lists every rule (extension → subfolder) A→Z with
  inline add, edit and remove; `Maker::FilingRules.for(user)` seeds the eleven roles' map on first
  read and is what `Maker::ProjectFolders.folder_for(user, name)` consults, so the sweep files where
  the user said. An extension with no rule files into `other`. The totality guard in
  `project_folders_test.rb` (an unmapped role raises) becomes "an unmapped extension files into
  `other`", and the reserved names (`.trash`, `.maker-tmp-*`, `.git`) are refused as folder names
  through `Library::ReservedNames`.
- **Pointers.** `rake projects:sweep_pointers` deletes every `*.ptr` whose real file sits beside it
  under `Projects/` through the port (so it lands in the trash, not the void), reports what it did,
  and refuses to touch one without its real file; `Node` gains a display rule hiding `*.ptr` from
  the Files pages and the project panel, the way dot-files are hidden.

## 6. What stays invariant across stage 3

- A `Public::` controller never reads the session and never renders a private project; an
  unlisted one needs its token. Tenancy on every other door is `current_user`.
- Bytes never pass through Rails on s3 or chunk_remote (§15): public downloads use the port's
  delivery exactly as the Files page does.
- Markdown is rendered with raw HTML stripped; a README is the user's prose, never trusted markup.
- Every new page has a query budget (constancy in N) and joins the phone sweep; every form uses
  `form_with … scope:` and asserts its rendered field names; the design system's rules hold.
- Licences stay permissive (§9): KiCanvas is MIT and its notices ship beside the vendored build.
- Out of stage 3: anything needing the sync server's cooperation (old-version downloads on share,
  sharing between users), parts export and supplier links, KiCad rendering on the server.

**Releases (S3-5), the four rules the panels rest on.** A release records REFERENCES, never bytes, so
a download always delivers the CURRENT file through the existing blob / public file route and the
row says "changed since this release" when the token differs (`Maker::ReleaseFile#state_against` is
the one definition, shared by both panels). Each panel takes ONE `stat_all` over the union of the
node ids it shows, never one `stat` a row. A tag is verified against the picked repository only where
`capabilities.local_worktree?`, and recorded as typed everywhere else — never silently dropped. A
release is created and deleted, never edited: it describes a moment, and an editable one would
describe a moment that was never taken.
