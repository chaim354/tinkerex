# Shop manual: one look for the whole app — design

**Date:** 2026-11-18 · **Status:** direction, screens and roadmap approved in conversation; the six
proposals in §11 stand as written until Charles says otherwise; awaiting spec review

## 1. Goal

Every signed-in and public page takes one look, "Shop manual": a white page, black rules, a
typewriter face for data, and a red numbered callout on each figure, so a project reads like the
manual for the thing being built. The look lands first and changes no behaviour. Nine behaviours
the screens also show (§9) follow as their own slices.

**Slice 1 (§8) is built, in the same pull request as this spec. Nothing after it is.**

## 2. Where the designs are

| what | where |
|---|---|
| The screens, drawn at 1440 px | `.superpowers/shop-manual-redesign/screens/` in the main checkout. Git-ignored, so a worktree does not have it: read it from the main checkout |
| The same screens, as Charles reviewed them | his Design canvas, `https://claude.ai/artifact/3MA3SJcsz7Rv7KUSYuvRHQ` (private) |
| The roadmap as prose | his doc, `https://claude.ai/artifact/L9eRcDZpmb3Z7L9v88fmDP` (private). This spec repeats all of it |

Each screen is three things: `<name>.html` (plain HTML, every value inline, so it can be grepped
for a size or a gap), `png/<name>.png` (the render), and for a page taller than 1800 px,
`png/<name>-partNofM.png` slices that read at full size. The HTML loads its two fonts from Google
Fonts, which the app itself must never do (§5).

| screen | page | restyles |
|---|---|---|
| `home` | `/`, today "Recent" | `home/` |
| `library-tiles`, `library-rows` | a Library folder, both views | `files/index`, `_grid`, `_list` |
| `file` | one file's page | `files/show` and its partials |
| `projects` | the Projects index | `projects/index`, `_card` |
| `project-everything` | the catan project with all 60 files shown singly: numbered, not yet stacked | `projects/show` and its panel partials |
| `project-organized` | the same project as it should end up: stacks, the tidy-up list, the index of files | the same, after §9 |
| `project-electronics`, `project-repository`, `project-spreadsheets` | three other kinds of project | the same |
| `project-editor` | the page-layout editor | `_layout_bar`, `_panel_strip`, `_layout_drawer` |
| `inventory`, `inventory-item` | Inventory and one item | `inventory_items/` |
| `models` | the Library's 3D models view | `files/models` |
| `tools`, `search`, `trash`, `settings`, `help` | as named | their view folders |
| `welcome`, `sign-in` | the first-run choice and the sign-in card | `welcome/`, `users/` |
| `public-project`, `public-explore` | a published project and Explore | `public/` |

In the screens the catan file names and previews, the facts about `hex tiles.lbrn2`, the Desk Lamp
README line and the Gerber file names are real. Every other name, count, person and date is sample.

## 3. Decided

- Shop manual is the look everywhere. No second "creative" Library view: rows and tiles only.
- A strip of four places replaces the rail: Library, Projects, Tools, Inventory.
- Every project panel defaults to half width, files included. Full width stays for the overview,
  the tidy-up list, the README, a repository's card and the index of files. A repository's card is
  not a panel of its own (§4).
- Half panels pack into two columns, shortest column first, as `masonry_controller.js` does today.
- The public page is the published view; the signed-in page keeps every working panel.

## 4. Not designed, and what waits on it

| gap | waits |
|---|---|
| The dark theme. Every screen is black on white | slice 4. Until then Graphite keeps today's colours and takes the new type |
| Anything narrower than 1440 px. The 220 px column cannot sit beside a 375 px page | slice 3 does not start until the strip and the column are drawn at phone width |
| A repository at half width. The card renders inside the Files panel (`projects/_attachments`) and a folder panel (`projects/_folder_panel`), and slice 5 makes both half. `ProjectKind`'s own comment calls half a column the width where the browser view stops being usable. One reading of §3: a panel stays full while it holds a repository. `Layout#repo_ids` already names the folder panels that are working trees | slice 5 |

## 5. Tokens and type

The token names stay; rule 4 of `docs/invariants/design-system.md` already makes colour a token.

| token (light) | today | after |
|---|---|---|
| `--bg`, `--surface` | `#f4f2ed`, `#fcfbf8` | `#ffffff` |
| `--raised` | `#ebe8e1` | `#f4f4f1` |
| `--line` | `#dcd8cf` | `#c9ccd1` |
| `--line-strong`, `--fg` | `#878276`, `#1b1c19` | `#0f1113` |
| `--fg-muted` | `#5b5c55` | `#555b63` |
| `--accent` | `#c2410c` | `#d42a20` |
| `--font-ui` | IBM Plex Sans | Libre Franklin (400, 500, 600, 700, 800) |
| `--font-mono` | IBM Plex Mono | Courier Prime (400, 700 only) |
| `--radius-control`, `--radius-panel` | 3 px, 5 px | 2 px, 0 |

The screens use one more tint, `#fdf1ef`, behind a selected row and a search match: that is
`--accent-soft`, an `rgba` before slice 1. The status and code-viewer tokens are not drawn; they
keep their values, and every one clears 4.5:1 on white, on `--raised` and on `--accent-soft`. Nine
more are not in the table; slice 1 gave them these values:

- `--accent-text` is the accent itself, `#d42a20`: it clears 4.5:1 as text on its own (5.06 on
  white, 4.58 on `--accent-soft`, the lowest). `--accent-ink` stays white (5.06 on the accent).
- `--photo-stage`, `--thumb-stage` and `--thumb-ink` were literal copies of `--raised`,
  `--surface` and `--fg-muted`, and take the new values: `#f4f4f1`, `#ffffff`, `#555b63`.
- `--shadow-float`, `--shadow-toggle` and `--scrim` keep their alphas over the new ink.
- `--focus` stays `var(--accent)`, so every focus ring turns red with the accent: a mark, which
  proposal 1 allows.

`#f4f2ed` is spelled in eight files, not one: `application.css`, `ShellHelper#theme_color_hex`,
`pwa/manifest.json.erb`, `theme_controller.js`, the error pages `public/404.html`, `422.html` and
`500.html` (which also spell an ink, `#1f1d1a`, that is no token), and `public/icon.svg`, the app
icon's ground. `shell_layout_test.rb` asserts it as the theme colour. Two more of today's values are
literals:

- `--line-strong`'s `#878276`, in the select chevron's data URI (`components.css:92`). It stays in
  slice 1: a colour inside a data URI cannot follow the theme, and that grey reads on both
  grounds (3.83:1 on white, 4.47:1 on Graphite's surface), where ink would vanish in Graphite.
  Slice 2's select redraws it.
- `--fg`'s `#1b1c19`, in `public/icon.svg` (`shell_chrome_test.rb` asserts it) and as
  `Maker::Previews::Palette::INK`. `palette_test.rb` holds `INK` equal to Paper's `--fg`, so the new
  `--fg` moves it, and moving it re-renders every text thumbnail: `TextThumb`'s
  `THUMBNAIL_REVISION` goes up with it (§14h).

Both faces are OFL. They go under `app/assets/fonts` with their licence texts, as Plex does;
`font_src` is `:self, :data`, so a Google Fonts link is refused by the CSP. Material Symbols stays.
Plex Mono ships 400 and 500; Courier Prime has 400 and 700. Seven rules set mono at 500 today
(`.thumb-icon`, `.generic-thumb`, `.note-badge`, `.topbar-kbd`, `.commit-row-state`,
`.print-log .print-run strong`, `.calculator-card-keys kbd`) and render at 400. Slice 1 leaves the
declarations alone; the slice that restyles each one chooses its weight.

| role | today | screens |
|---|---|---|
| body | 400 14px/21px | 400 13.5px/1.4 |
| page title | 600 20px/26px | 800 56px/0.98, tracking -0.035em. 48 on a file, 44 on an item, 60 on a project |
| lead paragraph | none | 17px/1.45, at most 38em |
| section head | 600 16px/22px | 800 20px, a mono number before it, a 2 px ink rule under it, mono 13px note at right |
| caps label | none | mono 700 12px, tracking .08em, uppercase: crumbs, table heads, group heads, plate heads |
| data | mono 13px | mono 12.5px; 12px in a caption |
| table | | head = caps label, muted, 2 px ink rule; rows 35 px (45 for two lines), hairline between |

The caps label is mono. Rule 13 says labels stay in the UI face, so this changes that rule too
(§11.1).

## 6. Components

Restyled in place, names unchanged (rule 12): `.btn`, `.chip`, `.badge`, `.panel`, `.thumb`,
`.grid-card`, `.toolbar`, `.view-toggle`, `.breadcrumb`, `.page-head`, `table.files`, `dl.meta`,
`.tabs`, `.flash`, `.empty` and the rest of `COMPONENT_SELECTORS`.

| component | in the screens |
|---|---|
| button | 32 px high, 1.5 px ink border, 2 px radius, weight 700, white. The primary one is an ink fill with white text |
| field, select | 32 px (select 30), 1.5 px ink border, 2 px radius, caps label above |
| segmented control | 30 px, 1.5 px ink border, the pressed part ink-filled |
| chip | ink fill, white mono 700 11.5px caps. A flag is the same size, red text in a 1 px red border |
| panel | no box: the numbered section head, then the body |

Four are new, defined in `components.css` and added to `COMPONENT_SELECTORS` (rule 3). The class
names are proposals.

| new | what it is |
|---|---|
| `.fig-num` | a 22 px red disc, its number mono 700 at 56% of its size in `--accent-ink` (white in the light theme; rule 13 forbids a literal white). 24 and 26 px where a head carries it. A ring variant (18 px, 1.5 px red border, white, red letter) marks a callout inside a figure |
| `.plate` | a 2 px ink box holding a grid of figures. Head: caps label left, muted count right, 2 px ink rule. Grid: `repeat(auto-fill, minmax(168px, 1fr))`, gap 14 px 4 px. A figure: a 118 px white frame with a hairline border, the name at 600, mono muted facts under it |
| `.stack` | a figure that stands for several versions: 1 px ink border, two offset copies drawn behind it (`4px -4px` and `8px -8px`, each a white fill inside an ink line), the name at 800, a chip with the count |
| `.note-box` | a 1.5 px ink box whose label is an ink block reading NOTE in the caps style, then the sentence at 500. Not `.note`, which is taken: the file page's notes are `<article class="note">` (`files/show.html.erb:257`), styled in `pages/files.css:90`, and rule 3 would make that rule a violation |

An opened figure spans its plate: 1.5 px ink border on `--raised`. A selected figure takes a 2 px
red outline. The tidy-up list is a plate whose cells are numbered suggestions.

## 7. Shell

The strip: 50 px, 2 px ink rule under it. Wordmark (a `T` in a 24 px disc, then the name at 800
19px), the four places at 14px, then Search (290 px), Add, and a round account button. The lit
place is weight 800 with a 3 px ink underline and `aria-current="page"`.

The left column: 220 px, `--raised`, a hairline at its right. A find box where the page has one,
then caps-headed groups of 28 px rows. The current row is weight 800 with a 6 px red square before
it. Counts are mono and muted.

The page head: the crumbs as a caps path, the title, a lead sentence, then the page's buttons.

| today, in the rail or top bar | after |
|---|---|
| Recent | Home, behind the wordmark. Lights no place. Column: Today's sections, then Pinned |
| Library | a place. Column: the folder tree, then 3D models and Trash |
| 3D models, Trash | rows in the Library column; both light Library |
| pinned projects, All projects | Projects, a place. Column: filters on the index; on a project, its contents, then the projects |
| pinned folders, pinned tools | Pinned, in Home's column |
| Tools, the calculator | Tools, a place |
| Inventory | a place. Column: All items, Low or out, Needed by a project, then Places and Suppliers |
| Help, Settings, theme, Sign out | the account button's menu. Settings and Help keep their pages |
| crumbs in the top bar | the caps path in the page head |
| Upload and New ▾ | one Add. `FolderDestination` still decides where it creates |
| ⌘K | the Search box; ⌘K still focuses it |

## 8. Slices of the look

Each slice is a branch and a pull request. 1 to 3 land in order; 5 to 8 in any order after 3; 4
lands once the dark theme is drawn (§4).

| # | slice | touches | checked by |
|---|---|---|---|
| 0 | this spec, and the rule changes in §11 | docs only | Charles |
| 1 | tokens and fonts, light | the token block, `app/assets/fonts`, the `@font-face` rules, the eight files that spell `#f4f2ed` (and `icon.png`, `favicon.ico` rendered from the icon), `Palette::INK` and `TextThumb`'s revision (§5) | `css_hygiene_test`, `code_theme_test`, `settings_theme_test`, `shell_layout_test`, `shell_chrome_test`, `palette_test`, a contrast check on each changed pair |
| 2 | components | `components.css`, the four new ones, `COMPONENT_SELECTORS`, rule 13, the add-on class list (below), the select chevron (§5) | `css_hygiene_test`, `accent_spend_test` rewritten, `addon_bundle_test`, `addon_sdk_test` |
| 3 | shell | `shell.css`, `layouts/_rail`, `_topbar`, `_tabbar`, `ShellHelper`, `rail_controller.js`, rules 7 to 9 | `shell_test`, `shell_rail_test`, `phone_topbar_test`, `shell_more_sheet_test`, `shell_layout_test` (one lit link per page), `models_redirects_test`, `narrow_names_test`, rewritten with the rules |
| 4 | dark theme | the Graphite token set | `settings_theme_test`, `code_theme_test`, the viewers repainting |
| 5 | project page | `pages/projects.css`, the panel partials, `Maker::ProjectKind.default_width` | `project_kind_test`, `project_layout_editor_test`, `public_project_test`, `page_editor_test`, `page_query_budget_test` |
| 6 | Library and file page | `pages/files.css`, `pages/preview.css` | `files_layout_test`, `files_pages_test`, `files_selection_test`, `preview_stage_test` |
| 7 | other signed-in pages | home, inventory, models, tools, search, settings sheets | `home_test`, `model_page_test`, `tools_addon_page_test` |
| 8 | front door and public | `pages/public.css`, `pages/landing.css`, sign-in, welcome, help | `landing_test`, `onboarding_test`, `public_bundle_test` |

Slice 5 flips three defaults in `Maker::ProjectKind`: Files (`attachments`), Photos and folder
panels become half, as the screens draw them. A stored width still wins, and a layout Save writes
every panel's width, defaults included, on purpose (`Maker::LayoutDocument#column`). So only
projects whose layout was never saved re-flow: a project saved once in the editor keeps full Files,
Photos and folder panels, and its stored row cannot tell a chosen full from a default. Section
numbers follow the panel order the page already has and belong to slice 5. Figure numbers are
cited by steps, the index and the find box, so they need the server and wait for §9; until then a
figure carries no callout.

The add-on bundles in `chaim354/tinkerex-addons` build markup from this app's class names, so
slice 2 restyles them too. Neither count in the docs is the contract. `CLAUDE.md` §14m says 52.
`design-system.md` rule 12 says 53, which is the old list of 52 plus `folder-glyph`, and points at
"spec §10", a spec deleted on 2026-11-10 (`git show
9c65d143:docs/superpowers/specs/2026-09-03-web-shell-and-design-system-design.md`). A scan of the
bundles on their `main` finds about 96 classes this app styles: all 53, and more, such as
`box-saved-name`, `box-group-title`, `param-group-title`, `btn-sm`, `ghost` and `is-error`. Slice 2
starts by writing the real list down where rule 12 can point at it, then corrects both counts.

## 9. New behaviour, after the look

| behaviour | exists today | needs | size |
|---|---|---|---|
| version stacks | nothing | group by name: a version number, a copy number, "backup". A toggle per panel, and a way to pull one file out. Reused by the Library and Search | medium |
| figure numbers | nothing | number files by panel order, then file order (§11.3) | medium |
| tidy-up list | nothing | four checks: loose files, uncommitted repository changes, an export older than its source, a sheet that disagrees with a file. Stored dismissals | large |
| next step on Home and Projects | `Maker::Task.open` | the first open task per project in one query | small |
| To buy | `Maker::BomRollup#short`, per project | the shortfalls of every active project in one list | medium |
| folder tree in the Library | only in the choosers, through `library_children` | the same tree as the left column, remembering what is open | medium |
| grouped search | `/search`, where the top bar's box submits, already groups by kind: Files, Folders, Projects, 3D models, Notes, Inventory, Tags (`SearchController`) | stacks inside the Files group | small, once stacks exist |
| index of files, and the find box | nothing | every file with its figure number, filtered as you type | small |
| published view | the public page shares the working layout | choose the panels a visitor never sees, in `Maker::PublicProject#layout` | small to medium |

Stacks come first: figure numbers, the Library and Search build on them. The grouping test must
carry the catan names and keep "game box" and "game box 2" apart: they are different parts. Three
things the rule above does not settle yet, and the test needs:

- **Which names.** The demo seed holds 54 of catan's files (`db/seeds/demo/Projects/catan`). The
  screens' 60 add six `Screenshot 2024-…` files (five PNG, one STL) that the seed does not hold.
- **Which groups.** "25 of 60 in 9 stacks" does not follow from the rule as written. The loosest
  reading gives 24 files in 8 stacks, and stacks `docs/box.txt` with the `design/boxv*.svg` files;
  stacking only within one folder or one file type gives 18 to 20 in 7 or 8. So the rule must say
  whether a stack crosses folders and file types and which separators it folds, and the test must
  name the expected groups, not count them.
- **A copy number against a part number.** "game box 2" has the shape of Finder's copy number,
  which the rule groups, so the rule must say how a copy number differs from a part number.

(`design-system.md` still says the top bar drives the Files page's flat `?q=`. That line is stale.)

## 10. Guards

Every guard is broken once on purpose before it is trusted (`CLAUDE.md` §15).

| guard | forbids |
|---|---|
| component selectors | a plate, figure number, note box or stack styled outside `components.css` |
| one lit place | two places lit in the strip, or a column with two current rows |
| width at 375 px | sideways scroll on the strip, the column or a half-width plate. Rule 11's `shell_test.rb` and `narrow_names_test.rb` already refuse it for today's pages; this extends them |
| query budget | Home or Projects costing a query per project for the next step |
| stack grouping | the wrong groups on the catan names |

## 11. Proposals that change a rule or need a yes

1. **Rule 13, the accent.** Today the accent fills the one primary action. Proposed: red marks and
   never fills a control. It draws figure numbers, the current row's square, a selected figure's
   outline and a warning word. The one primary action per screen is an ink fill; every other
   button is outlined. `accent_spend_test` then counts ink primaries. Two more clauses of rule 13
   bear on it. "Labels stay Plex Sans and mono stays for data" goes, because §5 sets crumbs,
   table heads, group heads and plate heads in mono. "Text on an accent fill is `--accent-ink`"
   stays, and `.fig-num` follows it. Rule 15's landing fills Try the demo or Install with the
   accent; under this it becomes an ink fill, and `landing_test.rb` and `accent_spend_test.rb` pin
   both states.
2. **Rules 7 to 9, the shell.** Proposed: the `theme` cookie stays as it is and the `rail` cookie
   retires with the rail. `sidebar_current` still makes the only decision, now lighting at most
   one of four places and one column row; Home, Search, Settings and Help light no place. Crumbs
   leave the top bar for the page head, still through `content_for :crumbs`. This also reverses
   rule 8's one exception: the 3D models view lights Library, not a 3D models place
   (`models_redirects_test.rb` pins today's answer). Recent becomes Home in rules 8 and 15; the
   `[:home]` key and the route stay.
3. **Figure numbers are positional**, not stored. They shift when a file is added; they are for
   finding a file on the page, not for citing it elsewhere.
4. **Photos goes to half width** with the other file panels. The app defaults it to full today.
5. **Search keeps ⌘K and gains `/`.**
6. **The public page is the published view.** Already decided in §3. What it reaches is the open
   part: `Maker::PublicProject#layout` also feeds the public page's feed, its bundle and its BOM CSV
   (rule 14), so a panel left out there is left out of all four.

Proposals 1 and 2 block slices 2 and 3. Each is settled in the pull request that rewrites the rule.
