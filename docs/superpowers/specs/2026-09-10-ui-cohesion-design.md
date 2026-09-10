# UI cohesion sweep — design

Date: 2026-09-10. Branch: `claude/ux-ui-cohesion-4oaw9c`. Status: audit complete, plan proposed,
awaiting approval before implementation.

The design system landed on 2026-09-07 (`95ae66b`, spec `2026-09-03-web-shell-and-design-system-design.md`)
and **356 commits across 49 merged PRs have landed on top of it since** — stages 2, 3 and 4 (home,
project hub, inventory, BOM, tags, search, settings, publishing, releases, following, the public
surface, connections), the gerber and 3D viewers, then folder panels, the page editor, content
blocks, tabs and the slice table. Each arc was internally consistent. None of them re-checked the
whole. This spec is that check.

**The design system itself is not the problem and this spec does not relitigate it.** The layer
order holds, every colour is a token, the three theme states all resolve, no page scrolls sideways,
and there is exactly one inline `style=` in the entire view tree. What drifted is how the *pages*
spend that system: the accent is overspent, one layout contract is violated by two pages, one
vocabulary is rendered three ways, and the empty state has three implementations and one hole.

## 1. How this was measured

A dev server on the `share` backend with a seeded library (5 projects, 33 nodes, 3 models, 3
inventory items, 6 build-log entries), driven by Chromium at 1440×900 and 390×844 in all three
theme states. 16 routes screenshotted; computed styles read out of the DOM rather than inferred
from the sheets. Every count below is measured, not estimated. Scripts and captures are in the
session scratchpad; the reproducible parts are named per finding.

Two things I initially read as bugs and then disproved, recorded because the next reader will see
the same screenshots (§14e — checking beats reasoning):

- **The rail is not stuck in a hover state.** The `Projects` link renders `--raised` on every
  captured page because Playwright's virtual pointer parks where the sign-in click left it. The
  hover chain confirmed a genuine `:hover`; `aria-current` was correct throughout. The harness now
  moves the pointer to the far corner before each capture.
- **The phone tab bar is not rendered inline mid-page.** It is `position: fixed; bottom: 0; z-index: 30`,
  measured at `top: 792` in an 844px viewport. `fullPage: true` stitches fixed elements at their
  viewport offset; that is a capture artifact.

## 2. Findings

Ordered by how much each one costs the feeling of cohesion, not by effort.

### 2.1 The accent is overspent, and the component does it, not the pages

`components.css:16` welds the uploader into the primary rule:

```css
.btn.primary, .upload-btn span, input[type="submit"].primary { background: var(--accent); … }
```

`.upload-btn span` is in the accent group **unconditionally** — there is no way for a page to ask
for a neutral uploader. Every upload control in the app is therefore the loudest thing on its page
by construction.

Measured accent-filled controls (`backgroundColor === rgb(240,165,58)`) per page:

| page | accent controls |
|---|---|
| `/projects/desk-lamp` | **10** |
| `/` | 3 |
| `/files`, `/models`, `/projects`, `/inventory` | 2 |
| `/settings`, `/search`, `/trash`, `/tools` | 1 |

Seven of the project page's ten read **“Upload & attach”** — one in the Files panel and one per
build-log entry. The accent is the app's only strong signal and on its most important page it
marks a repeated row-level action, so nothing reads as *the* thing to do.

### 2.2 `.page-head` centres the middle child when a page passes three

`.page-head` is `display: flex; justify-content: space-between`. With two children (title, actions)
that reads title-left / actions-right, which is what 14 of 16 pages do. Two pages pass three direct
children, and `space-between` puts the middle one in the centre of the page:

- `/models` → `H1 | A.btn primary | A.btn` — **the primary action “Import model” floats mid-page**,
  “Shelves” sits far right, and the sort select wraps to a second row beneath it.
- `/u/:handle/:slug` → `DIV.page-title | P.public-byline | DIV.bundle` — the byline centres.

This is one mechanism, not two page bugs. `.page-head` has an unwritten two-slot contract that
nothing enforces.

### 2.3 One vocabulary, three pill components, two typefaces, three capitalisations

| component | type | casing |
|---|---|---|
| `.chip` (toolbar filters) | 12px **mono** | as written |
| `.tag-chip` (tags) | 11px **mono** | `lowercase` |
| `.badge` (status, kind) | 11px **sans** | `capitalize` |

On `/projects` the same taxonomy renders twice, 200px apart: the filter chip says `Laser cutting`
in mono, the card badge says `Laser Cutting` in sans. On `/models` the filter chip says `Wanted`
while the badge on the card beside it says `Want To Print` — `text-transform: capitalize` applied
to `want_to_print.titleize`. Same state, two labels, one screen.

### 2.4 Empty states: three implementations, one redundancy, one hole

- `.empty` is defined in `components.css` and then **duplicated verbatim** in two page sheets:
  `pages/projects.css:23` `.projects-empty` and `pages/models.css:72` `.models-empty` carry the
  identical four declarations. This slips past `css_hygiene_test.rb` because the guard forbids
  *redeclaring* a component selector, not copying it under a new name.
- `class="empty muted"` appears **16 times** (`components.css:332`); `.empty` already sets
  `color: var(--fg-muted)`, so `.muted` is inert on every one.
- The only variant is a 40px dashed box, so one-line “nothing yet” cases are forced into it and
  then overridden back down — `pages/settings.css:37` does exactly that
  (`.filing-card .empty { padding: 4px 0; text-align: left; border: 0; }`). Suppliers, Locations
  and Tags put that 40px box inside an `<li>`.
- **`/tools` renders no empty state at all.** With no addons installed the page is a title and
  1000px of void. It is the worst first-run surface in the app.

### 2.5 Four list pages, four anatomies

| | filter | count | sort | primary action |
|---|---|---|---|---|
| Files | `TYPE` label + select + mono “Show dot-files” button | `3 items`, **left** of the view toggle | `Sort` label + two selects | right |
| Models | chips | — | one select, **wrapped to row 2** | **centred** (§2.2) |
| Projects | chips | — | — | right |
| Inventory | chips | `3 items`, **far right** | one select | right |

The Files toolbar labels its own two controls inconsistently — `TYPE` is uppercase mono, `Sort` is
sentence-case sans, side by side. The item count sits at opposite ends of the toolbar on Files and
Inventory. Two pages filter with a `<select>`, two with chips.

### 2.6 Home is built from a private vocabulary

`.home-section` + `.section-head` (`pages/home.css:13-16`) duplicate `.panel` + `.panel-head` at a
different size (h2 15px vs 14px) and with no surface or border — so the app's front door is the one
page that does not look like the app. Its `.page-actions` are three links: **“New project”,
“Tools”, and “Files” — and the accent one is “Files”**, a rail destination rather than an action,
sitting 200px from the rail's own Files link.

### 2.7 Counts are written eight ways

`3 items` · `4 files` · `6 entries` · `Folders 1` · `1 of 3 tasks done` · `LOOSE (4)` ·
`Low stock (1)` · `0 shelves` — different words, different placements, different typefaces.

### 2.8 Mono is doing chrome work

Mono leaf elements inside `main`: **22** on the project page, **20** on inventory, 12 on home, 9 on
files. Mono is currently the label font, the chip font, the count font, the group-head font, the
date font, the path font and one button's font (“Show dot-files”). On `/search` it renders the
project *description* — prose in a monospace face. When a typeface means everything it distinguishes
nothing.

### 2.9 The type scale has twelve steps below 24px

10, 11, 11.5, 12, 13, 14, 15, 16, 18, 20, 22, 24 — with 11px used 42× and 12px 91×, and a single
stray 11.5px. Adjacent sizes that differ by one pixel read as misalignment rather than hierarchy.

### 2.10 The project page has four panel-header layouts

Files (title + path + view toggle + three links + a button), Tasks (title alone), Publish (title +
a right-aligned link), Build log (title, then its button on the *next* line). Inside the build log,
each of six entries repeats a red “Delete” link, an “Add existing photo” link and an accent
“Upload & attach” button — three action treatments per row, 18 controls in one panel.

### 2.11 Search asks the same question in two boxes

The top bar's “Search everything” is deliberately always blank (`_topbar.html.erb` documents why —
it must not echo `@q`, which three controllers name for different things). The consequence is that
searching from the top bar lands you on a page where the box you typed in is empty and your query
has moved to a second box below it. Result rows carry no icon or thumbnail, so they do not resemble
the things they point at.

### 2.12 Three pages' URL says one section and the nav says another

`/settings/suppliers` and `/settings/locations` light **Inventory**; `/settings/shelves` lights
**Models** (`ShellHelper::SECTIONS`). The comment there argues this deliberately — they light the
section they *serve*. The cost is real anyway: you click Settings, land on `/settings/suppliers`,
and the rail says you are in Inventory while Settings goes dark. The page's only head action is a
bare text link (“Inventory”) in the top-right corner, where every other page puts a button.

This one is a **decision to confirm, not a defect to fix** — see §4.

### 2.13 Verified sound — do not "fix" these

- All three theme states resolve correctly (`--bg`, `--surface`, `.rail` background probed under
  `dark`, `light` and `system`+`prefers-color-scheme: light`).
- No horizontal scroll on any of 16 routes at 1440px or 390px.
- 29 of 30 `method: :delete` actions carry a confirm.
- One inline `style=` in the whole view tree, and it is a computed LightBurn layer swatch.
- `.page-head` is present on every page that has an `<h1>`.

## 3. Decisions

1. **Restyle, never rename** (§14m rule 12). `.empty` alone is asserted on by 11 selector
   literals across 7 test files, and 52 class names are contractual to `chaim354/tinkerex-addons`. Every change below either adds a
   modifier, deletes a *duplicate*, or edits markup — none renames a component.
2. **Fix causes in `components.css`, not symptoms in pages.** §2.1 and §2.2 are single-rule fixes
   that correct many pages at once; that is the whole reason to have a component sheet.
3. **The accent means "the one action this page exists for."** One accent control per page, two
   where a page genuinely has two (the project page's publish + upload). Everything else is
   `.btn` or `.btn.ghost`.
4. **Mono means data** — paths, hashes, sizes, timestamps, quantities, IDs. Not labels, not chips,
   not headings, not prose.
5. **Labels come from a helper, not from `text-transform`.** `capitalize` cannot know that
   `want_to_print` should read “Want to print” and that the filter beside it should say the same
   word.
6. **No new page-level CSS.** Slices 1–4 should reduce the page sheets, not grow them.

## 4. One question for the user before slice 5

§2.12 is a genuine fork and I do not want to guess:

- **(a) Keep it.** Suppliers/Locations/Shelves stay under `/settings/*` and keep lighting the
  section they serve. Cheapest; the disorientation stays.
- **(b) Light Settings.** They keep their URLs and light the Settings link. One `SECTIONS` entry;
  `shell_layout_test.rb` pins the current map and would be updated.
- **(c) Move them to the sections they serve.** `/inventory/suppliers`, `/inventory/locations`,
  `/models/shelves`, leaving redirects. Most coherent, most work, touches routes.

Everything in slices 1–4 is independent of this answer.

## 5. The plan

Five slices, each independently shippable and independently revertible. Ordered so the loudest
wins land first.

### Slice 1 — Spend the accent once per page

*The single highest-yield change: it corrects ten pages by editing two rules.*

- `components.css`: remove `.upload-btn span` from the `.btn.primary` group so an uploader inherits
  the neutral `.btn` face; add `.upload-btn.primary span` for opt-in. The Files page's “Upload a
  file” and the project page's Files-panel upload opt in; the six build-log uploaders do not.
- Audit the remaining `.btn.primary` uses against decision 3: Home's page actions (§2.6), the
  Models head, `Add supplier` / `Add location`.
- **Guard:** a system test asserting at most two accent-filled controls per page across the main
  routes, mutation-checked by putting `.upload-btn span` back and confirming it goes red.

**Touches** `app/assets/stylesheets/components.css`, `app/views/files/index.html.erb`,
`app/views/projects/_attachments.html.erb`, `app/views/projects/_log_entry.html.erb`,
`app/views/home/index.html.erb`, plus the new guard.

### Slice 2 — Make `.page-head`'s two-slot contract real

- Wrap the loose children on `/models` and the public project page in the `.page-actions` /
  `.page-title` blocks every other page already uses.
- Move the Models sort select into the toolbar row with its filter chips, where the other three
  list pages keep theirs.
- **Guard:** `template_hygiene_test.rb` gains a rendered-DOM assertion that every `.page-head` has
  at most two element children. This is the §14e "a guard that scans a directory dies silently"
  shape, so it asserts the scanned set is non-empty first.

**Touches** `app/views/models/index.html.erb`, `app/views/public/projects/_page.html.erb`,
`test/integration/web/template_hygiene_test.rb`.

### Slice 3 — One empty state, one count, one pill vocabulary

- **Empty:** add `.empty.inline` (no border, left-aligned, 12px) to `components.css`. Delete
  `.projects-empty` and `.models-empty` from the page sheets and point both views at `.empty`
  (each is pinned by exactly one test — both updated in the same commit). Drop the inert `.muted`
  from all 16 `class="empty muted"` sites. Convert the `<li class="empty">` cases on Suppliers,
  Locations and Tags to `.empty.inline`, which lets `pages/settings.css:37`'s override be deleted.
- **Tools:** give `/tools` a real first-run state — what an addon is, and the link that installs
  one. This is the biggest single intuitiveness win in the sweep.
- **Counts:** one `count_label` helper; one placement (right end of the toolbar).
- **Pills:** `.chip` and `.badge` share `--font-ui` and sentence case. Drop
  `text-transform: capitalize` from `.badge`; labels come from a helper keyed on the enum, so the
  Models filter and the Models badge say the same word. `.tag-chip` keeps `lowercase` — a tag is
  user-entered and lowercasing it is a real normalisation, not a display trick.

**Touches** `components.css`, `pages/{projects,models,settings}.css`, ~20 views, two helpers,
`tools/home/index.html.erb`, and the two tests pinning the deleted classes.

### Slice 4 — One list-page anatomy, and Home rejoins the app

- Settle the toolbar order once — search, filters, spacer, count, sort, view toggle — and apply it
  to Files, Models, Projects and Inventory. Labels sentence case, or dropped where the control is
  self-evident. Give Projects the count and sort it lacks. Retire the mono face on
  “Show dot-files”.
- Home's `.home-section` / `.section-head` become `.panel` / `.panel-head`; delete both rules from
  `pages/home.css`. Home's page actions reduce to “New project”.
- Collapse the type scale to six tokens (`--text-xs` 11, `--text-sm` 12, `--text-md` 13,
  `--text-lg` 15, `--text-xl` 20, plus the display sizes) and kill the stray 11.5px.
- Retire mono from chrome per decision 4 — group heads, `.chip`, `.section-more`, and the search
  result snippet.

**Touches** four index views, `pages/home.css`, `pages/files.css`, `components.css`,
`application.css`, `search/index.html.erb`.

### Slice 5 — The project page, and the IA answer

- One panel-header shape: title, optional muted meta, actions right. Applied to all four panels.
- Build-log entries collapse to one row plus a `⋯` menu holding Delete / Add existing photo /
  Upload — 18 controls become 6 plus a menu, and the accent leaves the log entirely.
- Suppress zero-count task groups (`DOING (0)` renders today).
- Give the public project page's half-width panel a sibling or full width so the left column stops
  rendering as a hole.
- Apply the §4 answer.

**Touches** `app/views/projects/*`, `app/views/public/projects/*`, `pages/projects.css`, and —
only under answer (b) or (c) — `shell_helper.rb`, `routes.rb`, `shell_layout_test.rb`.

## 6. Testing

Each slice runs bare `bin/ci` — all seven gates, with the three backend legs (`test`, `test-s3`,
`test-chunk-remote`) reporting identical run counts (§15). CSS-only slices still need the full run:
`css_hygiene_test.rb` pins the layer order, the one-definition rule and the link order, and
`shell_layout_test.rb` fetches every fingerprinted font.

Per §15, **every guard added here is mutation-checked**: break the thing it guards, confirm red,
restore. The two new guards and their mutations are named in slices 1 and 2. The existing
`css_hygiene_test.rb` needs no change — but note it did *not* catch §2.4's duplicated `.empty`,
because copying a component's declarations under a new name is not redeclaring its selector.
Whether to widen it to catch declaration-level duplication is a question for slice 3's review, not
a decision taken here.

## 7. Risks

- **Slice 3 touches ~20 views for small edits.** Batched by file per `.claude/commands/execute-plan.md`.
- **The 52 addon-contract class names** (`docs/invariants/addons.md`) must survive every restyle.
  `.btn`, `.chip`, `.badge`, `.empty` and `.panel` are all on that list — all are restyled here,
  none renamed, which is exactly what the contract permits.
- **Collapsing the type scale is the one change that can look worse before it looks better.** It
  should land last within slice 4 and be reviewed against captures at both widths.
- **Slice 5 hides controls behind a menu.** Discoverability is the trade; the menu component
  (`details.menu`, already contractual) is the pattern the Files page uses for the same problem.
