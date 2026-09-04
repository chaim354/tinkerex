# Web shell and design system, phase 1 — design

Date: 2026-09-03. Branch: `claude/ui-ux-rework-458036`. Status: approved in brainstorming, awaiting
the implementation plan.

Phase 1 of the UI/UX rework: a new application shell, a real token and component system, and every
page restyled with its controls tidied. Phase 2 (what the app is organised around: a home page,
how Files, Models and Projects relate) is a separate spec and is deliberately not designed here.

## 1. Why

The web layer is twelve server-rendered pages sharing one 920px centred column and a flat text-link
top bar. Measured on 2026-09-03 against a seeded library at desktop and phone widths:

- The shell is the weakest part. Five text links, the current-project switcher as a raw `<select>`,
  the email as plain text, no active state. On a 375px phone the top bar overflows off-screen and
  every table scrolls the page sideways.
- Wide screens are mostly empty: content sits in a narrow column, while addon pages opt into a
  1360px one, so the page jumps width between routes.
- The Files page buries the list: a view toggle, breadcrumb, type filter, dot-file toggle, a large
  dashed upload panel, a rescan link and a sort form all stack above the first file.
- Buttons have no single vocabulary. `.btn` is defined in `application.css` (blue fill) and again in
  `projects.css` (grey outline), and the later file wins, so `.btn` renders grey everywhere and
  `.btn.primary` blue. Destructive actions are red text links; every project tile carries one.
- Empty and loading states are bare: white thumbnail boxes for small vector files, unstyled
  Devise defaults for sign-in, and a `favicon.ico` 404 on every request. (A black rectangle seen
  on the model page during the audit was the seeded cover image itself, not a defect.)
- Editors are always open: the build log and file notes show a full rich-text toolbar with nothing
  to write.

Styling is four plain CSS files (941 lines) with a handful of colour tokens, no component system, no
dark theme and no responsive navigation.

## 2. Decisions (settled in brainstorming — do not relitigate without new information)

1. **Scope: shell and design system first, structure second.** Routes, controllers and the data
   model stay as they are, with one exception (the Files name search, §9). Phase 2 owns the home
   page and the information architecture.
2. **Direction: "Bench", with "Studio"'s current-project card.** Chosen from three mocked
   treatments. Dark by default like a machine controller's screen, one amber accent, monospace
   numerals wherever a number lives, a narrow left rail, compact density, thin rules instead of
   cards — plus the current project promoted to a card at the top of the rail, because it is where
   uploads and tool output land and today's UI hides that in a select.
3. **Plain CSS, no build step.** Custom properties and cascade layers served by Propshaft. Tailwind
   was rejected (rewrites every template's class list, adds a build step to the image and CI, and
   the addon bundles could not use it); an off-the-shelf framework was rejected (generic, and a
   dark amber identity would be overrides all the way down).
4. **Every class the tests and the addon bundles pin stays, restyled underneath.** The rework
   changes what a class looks like, never what it is called (§10).
5. **Dark is the default theme.** Light and system-following are one toggle away.
6. **A library name search is in scope**, as the one piece of new functionality, because the top
   bar's search field must not be decoration.
7. **IBM Plex Sans and IBM Plex Mono, self-hosted.** The CSP admits only same-origin fonts, and a
   self-hostable app must not call Google Fonts. SIL OFL 1.1, which is permissive for bundling (§9
   of CLAUDE.md); the licence text ships beside the files.

## 3. Scope

In: the layout and shell; tokens, base styles and the component vocabulary; every page under
`app/views/` restyled and its controls tidied (files, projects, models, shelves, tools gallery and
addon host page, trash, sheets, repo commit and history, Devise auth); the classes the addon
bundles share; the third-party editor skins (Lexxy, CodeMirror, the spreadsheet grid) themed by
tokens; the Files name search; the favicon, theme colour and manifest colours.

Out: the home page and any change to what pages exist or how they relate; inventory, BOM,
supplier, location, collection and tag screens (`tinkerex#126`); the thumbnail renderers and the
preview stack's payloads (`docs/invariants/measure-view.md`, `files-preview.md`); the addon bundles
themselves (`chaim354/tinkerex-addons`); the v1 API; any per-row data the pages do not already load
(for example file counts on project cards, which would need new queries the query-budget guard
would have to absorb).

## 4. Architecture

### 4.1 Stylesheets and the cascade

`app/assets/stylesheets/` becomes:

| file | layer | holds |
|---|---|---|
| `application.css` | `tokens`, `base` | the `@layer` order statement (first line of the first sheet), the token sets for both themes, `@font-face`, the reset, typography, links, focus, scrollbars |
| `components.css` | `components` | one definition of each component in §7 |
| `shell.css` | `shell` | rail, tab bar, top bar, content container, toast stack, responsive rules |
| `pages/files.css`, `pages/projects.css`, `pages/models.css`, `pages/tools.css`, `pages/preview.css` | `pages` | page-family rules that are not components: the files toolbar and tiles; project panels and timeline; model hero and tree; the tools gallery and the 52 addon-shared classes; the viewer, Measure, laser-settings, code, history and commit surfaces |
| `vendor-overrides.css` | (unlayered, linked last) | the Lexxy, CodeMirror and spreadsheet skins, expressed in tokens |

The order statement is `@layer tokens, base, components, shell, pages;`. Vendor sheets (`lexxy`,
`actiontext`, `jspreadsheet`, `jsuites`) stay separate `<link>`s and unlayered, which in the
cascade outranks every layered rule; that is why the overrides that must beat them are unlayered
too and linked after them. Nothing else in the app is unlayered.

`projects.css`, `models.css` and `notes.css` are deleted once their rules have moved. The layout
links each sheet with `stylesheet_link_tag` as today; Propshaft fingerprints them and rewrites the
`url()` references in `@font-face`.

**One definition per component.** A selector from the component vocabulary (§7) is defined in
`components.css` and nowhere else; a page sheet may add rules for its own page-specific classes
but never redeclare a component selector. Guarded (§12).

### 4.2 Fonts

`app/assets/fonts/`: `ibm-plex-sans-{400,500,600}.woff2`, `ibm-plex-sans-italic-400.woff2`,
`ibm-plex-mono-{400,500}.woff2` (Latin subset), plus `LICENSE-IBM-Plex.txt` (the OFL text, which
the licence requires to travel with the files). `font-display: swap`, with
`system-ui, -apple-system, "Segoe UI", sans-serif` and `ui-monospace, Menlo, monospace` as the
fallback stacks.

### 4.3 Stimulus

Three new controllers, all under `app/javascript/controllers/` so `pin_all_from` and
`test/stimulus_hygiene_test.rb` see them:

- `theme_controller.js` — the rail's theme button cycles dark → light → system, sets
  `document.documentElement.dataset.theme`, and writes the `theme` cookie (`SameSite=Lax`,
  one year, path `/`). No endpoint: the layout reads the cookie on the next request.
- `rail_controller.js` — the collapse button toggles the `rail` cookie (`expanded` / `collapsed`)
  and the `rail--collapsed` class on `<body>`; handles ⌘K / Ctrl-K by focusing the top-bar search
  field.
- `toast_controller.js` — removes a `.flash-notice` after six seconds; a `.flash-alert` stays until
  its close button is pressed. Respects `prefers-reduced-motion` (no slide, plain removal).

Collapsed composers (§8) use native `<details>`, not a controller.

### 4.4 Layout state lives in cookies, read server-side

Theme and rail state are rendered into the first byte of HTML (`html[data-theme]`,
`body.rail--collapsed`) from cookies, so there is no flash of the wrong theme and no inline script
(the CSP nonces `script-src`; an inline script is the thing to avoid adding). `data-turbo-permanent`
is not used on the rail: its active item changes per page, and a permanent element would freeze
it.

## 5. The shell

Body gets the class `app-shell` when a user is signed in. Signed-out pages (Devise) render without
the rail, on the same tokens, with the auth card centred.

```
body.app-shell
  aside.rail
    .brand                      mark + "Tinkerex", links to files_path
    .current-project            the card (5.1)
    nav.rail-nav > ul > li > a.rail-link[aria-current="page"]   Files · Models · Projects · Tools · Trash
    .rail-foot                  theme button, collapse button, email, Sign out
  .shell-main
    header.topbar               breadcrumb slot (5.3) · search form (5.3)
    .flash-stack                toasts (5.5)
    main.container[.container-wide]
  nav.tabbar                    phone only (5.4): the same five links as icons
```

### 5.1 The current-project card

Keeps the existing `form_with url: current_project_path, method: :patch` and
`select_tag :project_id` (with the "— none —" option), because `current_project_topbar_test.rb`,
`box_revisions_test.rb` and `addon_bundle_test.rb` pin `form[action] select[name='project_id']`
and `.current-project select`. Visually: an amber-tinted card with the label CURRENT PROJECT, the
project name, and the line "Uploads and tool output land here"; the select is styled as the card's
control. With no current project the card reads "No current project" and the select offers the
list. With no projects at all the card is not rendered (the test "no selector when the user has no
projects" holds).

### 5.2 Active state

A layout helper `rail_section` maps `controller_path` to one of five keys: `files` (files,
library_browse, notes, repo_commits, repo_histories), `models` (models, models/*, shelves),
`projects` (projects, projects/*, current_project), `tools` (tools/*), `trash` (trash). The matching
link carries `aria-current="page"`; styling keys on the attribute, never on a parallel class.

### 5.3 The top bar

Left: the breadcrumb. Pages that already render `nav.breadcrumb` (Files, project show, sheet, model
show, repo pages) move it into `content_for :crumbs`; a page that provides none shows its
`content_for(:title)` minus the " — Tinkerex" suffix. Right: the search form —
`form[action=files_path][method=get]` with `input[type=search][name=q]`, placeholder "Search
files", value prefilled from `@q` on the Files page. Nothing else lives in the top bar; page-level
actions stay in each page's `.page-head`, which keeps template churn small.

### 5.4 Responsive behaviour

| width | rail | top bar |
|---|---|---|
| ≥ 1100px | 188px expanded, or 56px icon rail when the `rail` cookie says collapsed | breadcrumb + search field |
| 720–1099px | 56px icon rail regardless of the cookie; labels become `title` tooltips | same |
| < 720px | hidden; `nav.tabbar` fixed at the bottom with the five icons; the current project shows as a chip in the top bar | breadcrumb; search collapses to an icon that reveals the field |

Tables get a class per column (`col-name`, `col-type`, `col-folder`, `col-size`, `col-version`,
`col-modified`, `col-actions`) and drop Modified, then Version, then Size below 720px, so the page
never scrolls sideways; wide content that must keep its width (the spreadsheet grid, code, diffs,
the Measure stage) scrolls inside its own `overflow-x: auto` container, as most already do.

### 5.5 Flash messages

The layout renders each flash as `.flash.flash-notice` / `.flash.flash-alert` inside `.flash-stack`
(fixed, top-right, stacked), with a close button, under `toast_controller`. The classes are kept
because four system tests assert on them. The fixed positioning is scoped to `.flash-stack > .flash`
only: `projects/_tasks.html.erb` renders an inline `.flash-alert.task-error` inside the panel, and
it must stay inline.

### 5.6 Content width

`main.container` keeps its class (the addon host test pins `main.container` and
`main.container.container-wide`) and becomes fluid: `max-width: 1360px` with 24px padding.
`.container-wide` removes the max-width (full bleed) and is still opted into by `content_for
:container_class` from the addon page. The reading measure (`max-width: 72ch`) applies to prose
blocks — descriptions, notes, log entries, the shelves explanation — not to the page.

### 5.7 Theme

Three states on `html[data-theme]`: `dark` (default, also what an absent or unknown cookie
means), `light`, `system`. `:root` carries the complete dark set; `:root[data-theme="light"]`
redefines the tokens; `@media (prefers-color-scheme: light) { :root[data-theme="system"] { … } }`
redefines them again. Every component reads tokens only. `<meta name="color-scheme">` and
`<meta name="theme-color">` follow the attribute.

## 6. Tokens and type

Colour (dark, then the light derivation):

| token | dark | light | role |
|---|---|---|---|
| `--bg` | `#15181d` | `#f4f5f7` | page ground |
| `--surface` | `#1b1f25` | `#ffffff` | rail, top bar, panels, thumbnails |
| `--raised` | `#232830` | `#eceef2` | hovered rows, secondary buttons, menus |
| `--line` | `#2b313a` | `#dfe2e7` | rules and borders |
| `--line-strong` | `#3a424d` | `#c9ced6` | focused inputs' borders, table header rule |
| `--fg` | `#e4e7ec` | `#1a1e26` | text |
| `--fg-muted` | `#8a93a2` | `#626b78` | secondary text (4.5:1 on its ground in both themes) |
| `--accent` | `#f0a53a` | `#b8700a` | the one action colour, links, active states |
| `--accent-ink` | `#1a1408` | `#ffffff` | text on an accent fill |
| `--accent-soft` | `rgba(240,165,58,.10)` | `rgba(184,112,10,.10)` | the current-project card, active chips' tint |
| `--ok` | `#5cc186` | `#2f8f5b` | done, ready, success |
| `--danger` | `#ef6b5c` | `#c8413a` | destructive actions, failures |
| `--focus` | `--accent` | `--accent` | 2px focus ring, 2px offset, on every interactive element |

Semantic colour (ok, danger) is separate from the accent and never used as one. Layer colours in
the Measure view and LightBurn tables are the file's own and stay literal.

Spacing scale 4 / 8 / 12 / 16 / 24 / 32px. Radius 4px for controls, 6px for panels and tiles,
10px for dialogs and popovers. Shadows only on things that float: menus, popovers, dialogs, toasts.

Type: IBM Plex Sans at 13px/1.45 for interface text and 14px/1.55 for reading text (descriptions,
notes, log entries); scale 11 / 12 / 13 / 14 / 16 / 20 / 24. Group headers are 11px uppercase with
`.08em` tracking. IBM Plex Mono at one size smaller for every size, date, path, hash, version,
layer name, dimension and count, with `font-variant-numeric: tabular-nums`.

## 7. Component vocabulary (one definition each, in `components.css`)

- **Buttons.** `.btn` (raised surface, 1px line), `.btn.primary` (accent fill, accent ink),
  `.btn.danger` (transparent, danger text and border), `.btn.ghost` (transparent, no border),
  `.btn.small`, `.btn.icon` (square, for × and overflow). `.linkbtn` is the low-emphasis inline
  action (accent text, underline on hover) and `.linkbtn.danger` the same in danger; `.upload-btn
  span` shares `.btn.primary`'s rules. The two competing `.btn` definitions collapse into this one.
- **Inputs.** `input`, `select`, `textarea` inside `.app-shell` and `.auth-card` share one look:
  surface background, `--line` border, `--line-strong` on hover, focus ring, 32px tall for
  controls, mono for `.mono` inputs. `.field` (label above, hint below) and `.field-inline`.
- **Chips** (`.chip`, `.chip.active`, with the `.chip-x` inside), **segmented control**
  (`.view-toggle` and its `.toggle.active`), **toolbar** (`.toolbar`: one flex row, wraps on
  narrow screens, `.toolbar-spacer`), **breadcrumb** (`nav.breadcrumb`), **pager** (`.pager`).
- **Panel** (`.panel`, `.panel-head`, `.panel h2`, `.panel-actions`), **group header**
  (`.attachment-group-head` and the same look on `.tasks-group h3`, `.fgroup .gh`).
- **Table** (`table.files` and a generic `.table`): 36px rows, uppercase mono header cells, hover
  row tint, right-aligned `.num` cells in mono, `.row-actions` revealed on hover and always visible
  under `(hover: none)`.
- **Tile** (`.grid-card`, `.project-card`, `.attachment-tile`, `.addon-card`) and **thumbnail**
  (`.thumb`, `.thumb img`, `.thumb-icon`, `.thumb-spinner`, `.folder-thumb`, `.generic-thumb`): a
  surface-coloured stage with a 1px line, the format badge in the corner, the line-art thumbnail
  on the dark stage. The spinner and the unsupported badge keep their markup: `thumbs_controller`'s
  poll contract is unchanged.
- **Metadata strip** (`dl.meta`: a horizontal key/value strip in mono, wrapping on narrow screens),
  **badge** (`.badge` and the `mstatus-*`/`status-archived` variants), **note badge**.
- **Empty state** (`.empty`: an icon, one sentence, at most one action). The two distinct Files
  emptinesses ("No files yet" vs "No files match .dxf") are kept as two sentences.
- **Toast** (`.flash-stack > .flash`), **dialog** (`dialog.move-conflict` restyled as an inline
  banner as today; the file chooser overlay and dialog), **menu** (`.file-menu`), **popover**
  (`.note-popover`), **composer** (`details.composer > summary`: the collapsed editor).

## 8. Pages

Phase 1 changes what each page looks like and tidies its controls. It does not change routes,
controllers (except §9), form field names, or the wire shapes of the JSON endpoints the pages call.

- **Auth (`users/*`).** One `.auth-card`: brand mark, heading, labelled fields, the error list,
  a primary submit, the Devise links as a quiet list. Field names are Devise's and untouched.
- **Files index.** One `.toolbar` row: the type picker and active chips (`_ext_filter`, restyled),
  the dot-file toggle as a small switch-style chip, a `.toolbar-spacer`, the item or match count
  (with the truncation sentence when `@truncated`), `.view-toggle`, the sort selects (now shown in
  both views; the list keeps its sortable headers too), Upload as `.btn.primary`, and an overflow
  `details` menu holding Rescan (scannable only) and the current-project / library-root upload
  switch. The dashed `.uploader` panel is gone; both upload flows keep their exact markup (the
  `form_with` multipart form on port-writable backends, the `uploader` controller otherwise) inside
  the toolbar. When a project is current, a caption under the toolbar reads "Uploads go to Desk
  Lamp" with the "Upload to library root instead" link. Grid tiles: thumbnail stage, name, and a
  mono sub-line "2.35 KB · LBRN2" from `@info_by_node`; list rows: 40px thumbnail, mono size and
  date, per-column classes (§5.4). Pager restyled.
- **File show.** `.page-head`: name, a format badge, `.page-actions` on the right (addon origin,
  Download, Delete, Back). `dl.meta` as the strip. `.attach-to-project` kept (pinned) and restyled
  as chips plus a compact attach form. The preview panel is full width; the LightBurn settings panel
  sits beside it as today. The notes composer becomes `details.composer` with the summary "Add a
  note"; the list of notes follows. The repo banner, history panel and code editor are themed.
- **Projects index.** Tiles with the cover, the name, and the archived badge; the archived-count
  link becomes a quiet footer line.
- **Project show.** `.page-head.project-head`: name, badges, description at reading measure, and a
  `.project-stats` line built from what the page already loads (`@attachments.size`, the task
  counts by status from `@tasks`, `@entries.size`, `@sheets.size`) — no new queries. Actions: Set
  as current (accent outline), Edit, and Archive as `.btn.danger.small`. Panels: Files full width,
  then Tasks, Build log and Sheets in a two-column grid. Files tiles shrink to 96px and Detach
  becomes a corner icon button revealed on hover (always visible under `(hover: none)`), keeping
  its `button_to` and visible text for the tests. Tasks: the composer moves below the list; each
  row shows the title and the existing status buttons as a three-state mini segmented control,
  with delete as an icon button. Build log: `details.composer` ("Add entry"); entries as a timeline
  with the mono date on the left, the body at reading measure, photos in a small grid. Sheets: rows
  with the name and a mono row count, and the inline "New sheet" input.
- **Models index/show/new/edit, Shelves.** Toolbar as on Files; cards with the status badge over
  the cover; the hero poster gets a surface-coloured stage so a line-art cover reads on it, with
  the "View in 3D" button; the file tree, print settings, print log form and shelves list are
  themed. The import form gets a proper file field.
- **Tools gallery and addon host page.** `.addon-card` with the icon, title, description and
  permission line; unavailable addons keep their reason. The addon page keeps `page-head`,
  `page-subtitle`, `ul.addon-permissions` and the wide opt-in. The 52 shared classes (§10) are
  restyled in `pages/tools.css` with identical names.
- **Trash, sheet page, repo commit and history.** Themed; the sheet page's grid scrolls inside its
  own container; the commit page's groups and rows use the panel and table rules.
- **Small fixes.** `public/favicon.ico` (from `public/icon.png`), `<meta name="theme-color">`, the
  PWA manifest's `theme_color` / `background_color` from the dark tokens.

## 9. The library search

`FilesController#index` gains `@q = resolve_query` — `params[:q].to_s.strip.first(80).presence`.
When present the page is in flat mode (`@flat = @exts.any? || @q.present?`), the scope is
`current_user.nodes.present.visible_entries(@show_hidden)`, narrowed by `flat_ext_scope` when
types are active, and by `where("LOWER(name) LIKE ?", "%#{sanitize_sql_like(@q.downcase)}%")`
(`LOWER` because Postgres `LIKE` is case-sensitive and SQLite's is not, and the app is
adapter-agnostic). Ordering reuses `flat_order` when types are active and `name ASC` otherwise;
`FLAT_LIMIT` and `@truncated` apply exactly as for the type filter. `files_query_base` carries `q`,
so folder links, chips, the view toggle and the pager all keep the search. The empty state reads
"No files match “x”." The top-bar field is prefilled with `@q`. Query count: the flat branch already
does one count and one select; `q` adds no query.

## 10. Compatibility contracts

- **Pinned selectors stay.** From `grep` of `assert_select`/`find`/`has_css` over `test/` on
  2026-09-03 (top of the list): `.measure-dims`, `.filechooser-row`, `.attachment-group-head`,
  `.measure-view--ready`, `.folder-field-btn`, `.project-card`, `.model-name`, `.addon-card`,
  `.history-row`, `.attachment-tile`, `.attach-to-project`, `.measure-stage`, `.file-menu`,
  `.ext-picker`, `.measure-contour--marked`, `.sheets-panel`, `.model-viewer`, `.lbrn-settings`,
  `.filechooser`, `.attachments-missing`, `.truncated`, `.model-hero`, `.history-note`,
  `.files-grid`, `.file-tree-box`, `.file-name`, `.ext-filter`, `.ext-active`, `.box-topview`,
  `.addon-permissions`, `.picker-result`, `.model-print-settings`, `.measure-fallback`,
  `.flash-notice`, `.flash-alert`, `.filechooser-overlay`, `.attachment-group`, `.view-toggle`,
  `.current-project select`, `.current-project-badge`, `main.container`, `.container-wide`,
  `form[action=current_project_path] select[name=project_id]`. Every one keeps its name and its
  place in the DOM.
- **Addon-shared classes stay.** The bundles in `chaim354/tinkerex-addons` build markup with 52
  classes this app styles: `addon-params box-actions box-editor box-field box-field-label box-index
  box-noresults box-preview box-preview-status box-prior box-prior-hint box-prior-list
  box-saved-rail box-search box-side box-toc box-toc-all box-toc-count box-toc-head box-toc-list
  box-toc-title box-topview box-topview-actions box-topview-canvas box-topview-hint
  box-topview-summary btn flash flash-alert folder-field folder-field-btn generator-editor
  generator-params generator-picker-label generator-preview generator-save generator-side
  model-viewer model-viewer-bar model-viewer-dims model-viewer-stage muted page-actions page-head
  page-subtitle param-groups-head param-groups-title preview preview-image thumb-icon tools-grid
  tv-label`. All keep their names and keep answering; they are restyled in `pages/tools.css` and
  `components.css`. That is a cross-repo contract (`docs/invariants/addons.md`).
- **Stimulus.** Existing controller names are untouched. The three new ones exist as files, so
  `stimulus_hygiene_test` passes; `data-controller` is always a literal attribute value (never
  interpolated), for the reason `files/show.html.erb` records.
- **Templates.** No `%>` inside an ERB comment (`template_hygiene_test`); every `form_with`
  keeps its `scope:`/`model:` so field names do not change.
- **Query budgets.** `page_query_budget_test.rb` asserts constancy in N for nine pages; nothing in
  this design adds a per-row query, and the project stats line reads collections the page already
  loaded.
- **The CSP.** Fonts are same-origin; no inline scripts are added; styles stay `unsafe-inline`
  compatible with what the initializer already allows. The system tests' SEVERE console check
  covers every restyled page.

## 11. Error handling and degradation

- Without JavaScript: the rail renders expanded, the theme is whatever the cookie says, toasts
  stay until the next navigation, composers open by clicking the `<summary>`, search submits as a
  plain GET, the upload forms behave as they do today.
- Fonts failing to load fall to the system stacks; nothing is laid out on a font metric.
- An unknown or absent `theme`/`rail` cookie value is treated as the default (dark, expanded); the
  cookies are never trusted for anything but those two enum values.
- A search string is bounded (80 chars) and escaped with `sanitize_sql_like`; anything that does
  not match ends in the same empty state as a type filter with no matches.

## 12. Testing

- **Request tests.** The rail renders when signed in and not when signed out; exactly one
  `a.rail-link[aria-current="page"]` per page, and the right one for each of the five sections;
  `html[data-theme]` from the cookie, `dark` when absent or junk; `body.rail--collapsed` from the
  cookie; the top-bar search form and its `q` prefill; the Files `q` search (matches by name case-
  insensitively, combines with `ext`, forces flat mode, keeps `q` in `files_query_base`, truncates
  at `FLAT_LIMIT`, empty-state sentence); the project stats line's numbers.
- **System tests.** Rail collapse persists across a Turbo navigation and a reload; the theme
  button cycles and persists; a notice toast is gone after its timeout and an alert is not; ⌘K
  focuses the search; **no horizontal overflow at 375×812** on Files list (with a long file name),
  the project page, the file page and the tools gallery — `document.documentElement.scrollWidth
  <= window.innerWidth`, which fails against today's layout and is the guard for the phone bug;
  `assert_no_console_errors` on each restyled page.
- **CSS hygiene (unit).** Parses `app/assets/stylesheets/**/*.css` and asserts: the `@layer`
  order statement appears once, at the top of `application.css`; every rule outside
  `vendor-overrides.css` is inside a layer block; each component selector in §7 is declared in
  `components.css` and in no other sheet. Mutation-checked by adding a `.btn {}` to a page sheet
  (red) and removing the layer statement (red).
- **Fonts.** A request test asserts the stylesheet references fingerprinted `ibm-plex-*.woff2`
  paths and that each resolves with 200 through Propshaft.
- **Everything existing** stays green on all three backend legs (`bin/ci`), with identical run
  counts.

## 13. Risks

- **Lexxy inside a closed `<details>`.** The editor may size itself while hidden. Verified early in
  the plan; the fallback is an always-open composer on that page.
- **The spreadsheet grid in dark.** `jspreadsheet.css`/`jsuites.css` are third-party. Budget one
  pass of token overrides; if it does not come clean, the sheet page keeps a light "paper" island
  and the spec is amended to say so.
- **Addon bundles' own inline styles.** The bundles set some styles in JS (the OpenSCAD viewer
  canvas, generator previews). They keep working on the class contract; anything that looks wrong
  on the dark ground is a bundle change in the sibling repo, recorded, not fixed here.
- **Volume.** Fifty-four templates. Mitigated by the delivery order below: the shell and the
  restyle land first as a mostly CSS change, and the template-level tidying follows per page
  family, each PR fully green.

## 14. Delivery order (for the plan)

1. **Design system and shell.** Tokens, base, components, shell sheets and fonts; the three
   controllers; the layout (rail, card, top bar, toasts, theme and rail cookies, `rail_section`);
   auth pages; every existing class restyled in place; the `q` search (§9), because the top bar's
   field must work from the day it appears; the CSS hygiene test, layout request tests,
   theme/rail/toast system tests, the mobile overflow guard. The app looks new everywhere after
   this PR, with the old page controls still in their old places.
2. **Files.** The toolbar consolidation, tiles and list, the file page header, strip, composer.
3. **Projects, Models, Sheets.** Project head, stats, panels, tasks, timeline, composers; models
   index/show/new/edit and the poster fix; shelves; the sheet page.
4. **Tools, Trash, repo pages, polish.** Gallery and addon classes, trash, commit and history,
   vendor overrides, empty states, favicon and manifest, the §14d note in CLAUDE.md, deletion of
   the three old stylesheets.

Each step is its own branch and PR under the close-out rule in CLAUDE.md §15, recorded with
`bin/log arc --from-pr`.
