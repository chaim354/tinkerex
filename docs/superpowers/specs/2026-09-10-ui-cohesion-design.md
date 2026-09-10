# UI cohesion sweep — design

Date: 2026-09-10. Branches: `claude/ux-ui-cohesion-4oaw9c` (audit + slice 0),
`claude/ui-ux-audit-plan-38ea13` (slice 1). Status: audit and first-run walkthrough complete;
**slices 0, 1 and 2 LANDED** (2026-09-10); slices 3–5 proposed, 5 blocked on §4.

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

## 0. Handoff — start here

**Slices 0, 1 and 2 have landed (§5). Slices 3–5 are unstarted and this document is their brief.**
Read §2 for the findings, §5 for the slices, and this section for what earlier sessions learned the
hard way about verifying work in this repo.

### What to pick up next

Slice 3 (one empty state, one count, one pill vocabulary) is next, and it is the biggest of the
five: ~20 views, two helpers, and the `/tools` first-run state the spec calls the single largest
intuitiveness win in the sweep. Slices are ordered by what each costs the feeling of
cohesion, and each is independently shippable.

### Two questions still open, both for the user — do not guess

1. **§4 / finding 2.12** — should `/settings/suppliers`, `/settings/locations` and
   `/settings/shelves` keep lighting the section they *serve* (Inventory, Models) rather than
   Settings? Three options are laid out in §4. Slices 1–4 do not depend on the answer; slice 5 does.
2. **Finding 1A.5 (one photo, two panels)** and **1A.6 (five panels, four files)** need a product
   decision about what a folder panel is *for* before they can be fixed well. They are listed under
   slice 5 but the shape of the fix is not settled.

### What CANNOT be verified in a cloud container, and must be run on a real runner

This matters more than it sounds: the last session's suite was green over a live 500 twice.

| leg | status here | why |
|---|---|---|
| `test` (share) | runs | — |
| `test-s3` | suite runs; the `bin/ci` wrapper fails | wrapper fails identically on a clean tree |
| `test-chunk-remote` | **cannot run** | needs `../tinkerex-sync` checked out |
| `system` | **cannot run** | chromedriver 147 vs Chrome 153; no matching pair available |
| `setup` | not run | local-only gate |

**ALL SIX OF THOSE RAN GREEN ON A REAL BOX ON 2026-09-10** (slice 1's session, an M-series Mac
with Chrome 152 — Selenium Manager fetches its own chromedriver, so the version pair that blocked
the container is not a property of this repo). Bare `bin/ci`: seven gates, **4217 / 4217 / 4217**
identical run counts across share / s3 / chunk_remote, 32 / 33 / 8 skips, `system` 297 runs. The
table above is a description of ONE sandbox, not of the suite — if you are on hardware, run the
gates rather than inheriting the excuse. `test-chunk-remote` needs `TINKEREX_SYNC_DIR` when you are
in a worktree, and failed ONCE inside a full `bin/ci` pass while passing standalone twice either
side of it, which reads as boot contention rather than a defect.

**34 suite failures pre-date this work and are the container, not the code.** It runs as **root**,
so `chmod 000` fixtures stay readable and every scanner unreadable-directory test fails; it has none
of the thumbnailer binaries (`vipsthumbnail`, `resvg`, `pdftoppm`, `stl-thumbnailer`), so every
preview test fails; and `public/addons` is absent, so the addon suites fail. **Capture that baseline
before you start** and diff against it rather than reading a raw failure count:

```sh
bin/rails test 2>&1 | grep -oE '^[A-Za-z0-9_:]+#test_[^ []*' | sort -u > /tmp/baseline.txt
# ... do the work ...
bin/rails test 2>&1 | grep -oE '^[A-Za-z0-9_:]+#test_[^ []*' | sort -u > /tmp/now.txt
comm -23 /tmp/now.txt /tmp/baseline.txt      # empty means you broke nothing
```

The failure COUNT varies run to run (the addon suites are order-dependent under the sandbox);
the failing NAMES do not. Diff names, never counts.

### How to run the app here

The share backend, a fresh library and a seeded user, then drive it with Playwright against
`/opt/pw-browsers/chromium` — Selenium cannot be used (see the table above), but Playwright can:

```sh
export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) RAILS_MAX_THREADS=16
bin/rails db:prepare && bin/rails server -p 3000 -b 127.0.0.1
```

**Park the pointer before every screenshot** (`page.mouse.move(w-4, h-4)`) or the rail link under
it renders lit and reads as a stuck active state — that cost a false finding. And do not read
`fullPage` captures for the position of anything `fixed` or `sticky`: they are stitched at scroll
offset, which put the phone tab bar in the middle of the page and cost another.

### The two failure shapes this repo keeps producing, both hit again in slice 0

1. **A green suite over something that never worked.** `.auth-main` had never applied; the handle
   `pattern` had never validated; the multi-file form 500'd while ten tests passed. In each case the
   test asked the code, not the browser. **Drive the real request, and read the computed value.**
2. **A test pinned to storage rather than behaviour.** Ten assertions read
   `session[:current_project_id]` and went red when the pointer moved to a column, while the feature
   worked perfectly. Assert what the user gets.

Every guard added in slice 0 was mutation-checked (13 mutations). Keep doing that — §15 requires it,
and it caught a rescue that was too wide within a minute of being written.

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

## 1A. The first-run walkthrough (2026-09-10, added after the static audit)

The audit above measured a *seeded* library. This section is a second pass that did what a maker
does: signed up on a **completely empty install** (fresh database, empty share directory) as
`jess@workshop.test`, created **Shop Stool** — a plywood stool with 3D-printed foot caps — uploaded
a DXF, an STL, a README and a build photo, wrote a build-log entry, claimed a handle, published,
and opened the result signed-out as a visitor would.

Most of the flow works, and some of it is genuinely good (§1C). But the walkthrough found defects
the static audit could not, because they only exist in motion — and one of them is a dead end on
the very first screen.

### 1A.1 A new maker is told to do the thing they just did — BLOCKER

Signing up creates the account (`id=1, confirmed_at=nil, confirmation_token` present) and then
redirects to `/users/sign_in` carrying:

> **You need to sign in or sign up before continuing.**

Devise's registration sets a "confirmation link sent" notice and redirects to root; root is gated,
so `authenticate_user!` **replaces** that notice with its own. The user is never told an email was
sent, never told to confirm, and is looking at a message describing the step they have just
completed. They learn the truth only by failing a login, which finally says *"You have to confirm
your email address before continuing."*

On a self-hosted box with no SMTP configured — the product's primary deployment — the maker is
simply stuck, with no explanation anywhere in the UI.

### 1A.2 The auth card has never rendered at its designed width — HIGH

`shell.css` defines `.auth-main { max-width: 440px; padding-top: 48px }`, and the layout applies it.
It has never taken effect. Both rules sit in `@layer shell`, so specificity decides, and
`main.container` (0,1,1) outranks `.auth-main` (0,1,0):

| property | designed | actually computed |
|---|---|---|
| `max-width` | 440px | **1360px** |
| `padding-top` | 48px | **20px** |

Measured on `/users/sign_up` at 1440px. The sign-in and sign-up cards — the first screens of the
product — stretch the full content width. The static audit missed this because it read the sheet
and believed it; only the computed style shows it.

### 1A.3 Files upload one at a time — HIGH

A maker's project folder is a dozen files. The project's uploader and the library's uploader take
**one**:

| uploader | `multiple`? |
|---|---|
| `projects/_upload_control.html.erb:31` | no |
| `files/index.html.erb:83` | no |
| `models/new.html.erb:13` | **yes** |

So the app already knows how to accept a batch — the model importer does it — and the two uploaders
a maker actually lives in do not. Uploading four files meant opening the picker four times.

### 1A.4 "Uploads land here" outlives its own storage — HIGH

`session[:current_project_id]` (`concerns/current_project.rb:23`) is the whole persistence. The rail
card says *"Uploads and tool output land here"* and the creation flash says *"Current project: Shop
Stool — uploads and tool output land there."* Sign out and back in — done in this walkthrough — and
the rail reads **None**. The promise is scoped to a browser session; uploads then land at the
library root instead of the project folder, silently.

### 1A.5 One photo, two panels — HIGH

`stool-dryfit.jpg` (`node ef56ab3e…`) renders **twice** on both the private and the public page: in
the `images` folder panel as *"JPG stool-dryfit.jpg"*, and again in the `Photos` panel as *"IMG"*
with no filename. Same node id, two panels, two labels, two tile treatments. A maker cannot tell
whether they uploaded it twice.

### 1A.6 Five panels, four files, two thousand pixels — HIGH

The published page renders `Files`, `design`, `images`, `models` and `Photos` as five full-width
panels, each holding **one** tile in its top-left corner with ~1100px of empty space beside it.
Measured height of the finished public page: **2059px desktop, 1988px phone** — roughly two and a
half screens to show four files and one log entry. The folder-panel idea is right; one panel per
folder regardless of how little it holds is not.

### 1A.7 The hero photo is letterboxed in white — HIGH (desktop only)

A 4:3 photo on the public page sits on `--thumb-stage: #ffffff` in a much wider stage, producing
~345px of pure white either side on a dark page. §14m rule 5 makes that stage white deliberately,
and it is right for the opaque rendered PNGs it was written for — but a user's *photo* is not one of
those, and this is the largest element on the maker's shared page. At 390px the stage matches the
image (366×275 in 366×298) and the problem does not occur.

### 1A.8 Smaller things the walkthrough turned up

- **`Add entry` labels two different controls in one panel** — the `<summary>` that opens the
  build-log composer, and the submit that saves it, 150px apart.
- **The handle field's `pattern` is invalid and does nothing.** `[a-z0-9][a-z0-9-]{0,30}[a-z0-9]`
  throws in the browser: `pattern` compiles with the **`v`** flag, where a literal `-` in a class
  must be escaped. Chrome logs *"Invalid character class"* and **skips validation entirely**. Two
  views carry it — `projects/_publish.html.erb:44` and `users/registrations/edit.html.erb:50`.
  `[a-z0-9\-]` compiles and matches. The server-side validation is unaffected, so this costs
  inline feedback, not safety.
- **Eight panels on a brand-new project** — Files, Build log, Tasks, Bill of materials, Wiring,
  Releases, Sheets, Publish. The new-project form says Type *"presets which panels this project's
  page shows"*, but `Mixed` shows all of them, so a plywood stool gets a **Wiring** panel.
- **The project-created toast clips the page-head actions.** Measured: the two-line flash is 59px
  tall (y 12–71) over an actions row at y 64–88 — a 7px visual overlap on the first view of every
  new project. `elementFromPoint` confirms every button still receives its click, so this is
  cosmetic, not blocking.
- **First-run Home is four dashed boxes**, and its banner says *"Pick one from the rail"* when the
  rail renders **no** project picker until a project exists (measured: `.current-project` count 0).
- **An `unsupported` preview is indistinguishable from a pending one** — a white tile with an
  extension label, permanently, with no explanation. This walkthrough ran on a box with none of the
  thumbnailer binaries installed (`vipsthumbnail`, `resvg`, `pdftoppm`, `stl-thumbnailer` all
  absent), so all four previews resolved `status=unsupported`. That is *this sandbox*, not a product
  defect — but it is also an entirely plausible self-host state, and the app never says a word about
  it. The blank tiles in the walkthrough screenshots are that, not a rendering bug.
- **The build-log composer opens a 13-button rich-text toolbar** including *Insert a table*, with
  row and column editing, for "what I did in the workshop today".
- **The public page repeats itself** — breadcrumb, `h1` and README heading all say "Shop Stool" in
  the first 250px, and the project description and the README's first line say the same sentence
  twice in different words.
- **The maker's internal status is public** — a visitor sees the `Active` badge.

### 1B. Corrections to my own first reading

Recorded because the screenshots are kept and the next reader will see the same things (§14e):

- **Creating a project does not sign you out.** My harness clicked `input[type=submit]`, which
  matched the rail's *Sign out* `button_to` first in DOM order.
- **The build-log editor is not always open.** The 60-control toolbar dump came from querying
  hidden DOM inside a closed `<details>`; measured, the panel is 42px tall with 2 visible controls.
  Phase 1's fix is working.
- **The blank tiles are a missing-binary sandbox, not a broken preview pipeline** (above).
- **The rail and top bar appearing mid-page** in full-page phone captures is `fullPage` stitching
  `position: fixed`/`sticky` elements at their scroll offset, as already recorded in §1.

### 1C. What worked, and should not be disturbed

- **Auto-filing is the best thing in the product.** Four uploaded files sorted themselves into
  `design/`, `images/` and `models/` within seconds, the README stayed at the project root and
  rendered inline as formatted Markdown. It needed no instruction and no configuration.
- **The flashes are specific and honest** — *"Project created. Its folder is Projects/shop-stool"*,
  and on publishing, *"Everything in the project's folder, and every file attached to it, is now
  downloadable by anyone."* That last one tells the user exactly what they just agreed to.
- **Publish explains itself**: the panel states that public projects live at `/u/<handle>/<slug>`
  and offers the handle field inline, so claiming a handle is not a detour into Settings.
- **Visibility defaults to private**, and the three options carry one-line explanations.
- **Nothing scrolled sideways** at 390px at any point in the journey.
- The finished public page has the right *bones*: README, files, build log, and a bundle download.

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

### Slice 0 — The first five minutes — **LANDED 2026-09-10**

Five commits, `7fe83be`…`d0f9ab8`. What shipped, and the two things the work itself turned up:

- **The auth card** — `main.container.auth-main`, so the 440px column applies for the first time.
  Verified computed: 1360px → 440px, padding-top 20px → 48px.
- **The handle `pattern`** — `User::HANDLE_PATTERN` is now the one spelling and `HANDLE_RE` is
  built from it. Verified in a browser: the field refuses a single character and a trailing hyphen
  and accepts a hyphenated handle, with no console error.
- **Sign-up** — lands on the sign-in page so the confirmation notice survives, and a mail server
  that refuses the connection redirects with an honest message instead of a 500 over a committed
  account. `APP_HOST` replaces the scaffold's `example.com` in the confirmation link.
- **The current project** — a column on the user, with `remember_current_project` in Settings as
  the opt-out. Switching the setting carries the selection across the stores in both directions.
- **Both uploaders** — take a selection; one refusal no longer abandons the rest of the batch.
  Verified through the real form: *"Uploaded 4 files. Filed 3 files into design/, images/, and
  models/."*

**Two defects the work found that the walkthrough had not.** A *green suite over a 500*: the
rendered form's `multiple: true` adds a hidden empty-value companion, so the real `params[:file]`
was `["", <file>, …]` and the server called `#original_filename` on a String — every test POSTed a
Ruby array and could not see it (§14d, one attribute over). And the settings toggle shipped two
elements sharing one DOM id, because `hidden_field_tag` and `check_box_tag` both derive it from the
name; the label resolved to the hidden one. Both are fixed and pinned.

**One thing worth knowing about the auto-filing**, found while testing: uploading the same name in
two separate requests does **not** collide, because the intake sweep files the first into its
category folder in between and frees the root. Only a name repeated inside ONE selection refuses.

**Verification, honestly.** Every gate that can run in this sandbox is green and the full suite
shows no regression against a captured baseline. Three legs cannot run here and were not run:
`system` (chromedriver 147 against Chrome 153), `test-chunk-remote` (needs `../tinkerex-sync`), and
34 suite failures that pre-date this work are environmental — the container runs as **root**, so
`chmod 000` fixtures stay readable, and it has none of the thumbnailer binaries or addon bundles.
`bin/ci test-s3`'s wrapper fails identically on a clean tree; the s3 suite itself runs clean.

#### Original plan

### Slice 0 — The first five minutes

*Everything in §1A that stops a maker before they reach the rest of the product. This now outranks
slice 1: a centred button is a blemish; an account you cannot use is a lost user.*

- Carry the registration's confirmation notice through the redirect, so a new maker is told an email
  was sent and what to do next (§1A.1). Say something useful when no mailer is configured.
- Fix `.auth-main` so the auth card renders at its designed 440px — the fix is specificity, not a
  new rule: `main.container.auth-main`, or drop `.container` from that branch (§1A.2).
- Add `multiple` to the project and library uploaders (§1A.3).
- Escape the hyphen in both `pattern` attributes (§1A.8).
- Decide whether the current project should outlive the session (§1A.4). If it should stay
  session-scoped, the rail's copy has to stop promising otherwise.

**Touches** `users/registrations_controller` · `shell.css` · `projects/_upload_control` ·
`files/index` · `projects/_publish` · `users/registrations/edit` · `concerns/current_project`

### Slice 1 — Spend the accent once per page — **LANDED 2026-09-10**

`components.css`'s accent group now reads `.upload-btn.primary span`, so an uploader is loud only
when its page asks. Measured before and after, on a project with three build-log entries and a
claimed handle:

| route | before | after |
|---|---|---|
| `/` | `Files` | `New project` |
| `/projects/desk-lamp` | **7** — 4 × `Upload & attach`, `Save README`, `Add`, `Create release` | **2** — `Upload & attach`, `Save publishing` |
| `/files`, `/models`, `/projects`, `/inventory` | 1 each | unchanged |
| `/settings/{suppliers,locations,shelves}` | 1 each | unchanged — the audit's answer was "already right" |

**The audit's count of ten was exactly right and its itemisation was incomplete.** §2.1 said seven
of the ten read "Upload & attach" and did not name the other three; they are `Save README`,
`Add` (wiring) and `Create release`, each a `btn small primary` — **a panel's one action wearing the
page's colour**, which is §2.1's mistake one level up and not something removing `.upload-btn span`
would have touched. Slice 1 as written ("two rules in `components.css`") would have left the
project page at four. The three lost their `primary`; `Save publishing` keeps it, because decision 3
allows the project page two and those are the two it names.

**Home's accent moved rather than being removed.** It was on `Files` — a rail destination rendered
as the loudest control on the front door, 200px from the rail's own Files link — while `New project`,
the only thing a maker can DO from that row, was quiet. Slice 4 still reduces the row to one link.

**The guard is an exact table, not the ceiling the plan specified**, and the reason is worth
carrying: a ceiling ("at most two") is satisfied perfectly by an app with **no** accent at all, so
deleting `.btn.primary` outright would have left it green while the product lost its only strong
signal. It also cannot see an uploader that silently *loses* its opt-in — a new failure mode this
slice introduces, since `primary:` defaults to false and a call site can forget it. The table is
floor, ceiling and the record of what decision 3 resolved to, in one assertion.
`test/system/accent_spend_test.rb`, three mutations, each run and each restored — and one claim in
its own header was **wrong on first writing** (that `/` and `/files` redden under mutation 1; only
the project page does, because Home's hero renders no uploader without a current project). Corrected
against the measured output rather than left as plausible prose.

**Verification.** Bare `bin/ci`, seven gates, all green: 4217 / 4217 / 4217 identical run counts
across the three backend legs, `system` 297 runs / 0 failures. Nothing about this slice is
backend-dependent, and the counts confirm it.

#### Original plan

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

### Slice 2 — Make `.page-head`'s two-slot contract real — **LANDED 2026-09-10**

`/models` wraps its two links in `.page-actions`; the public project page's byline moves inside
`.page-title` and the bundle becomes the actions slot. Measured in a browser at 1400px, both heads
now lay out as two slots:

| page | slot 1 | slot 2 |
|---|---|---|
| `/models` | `h1` L212–277 | `.page-actions` L1187–1376 |
| `/u/:handle/:slug` | `.page-title` L44–344 (h1 + byline on one line) | `.page-actions bundle` L1149–1356 |

**§2.2's "the sort select wraps to a second row" did not reproduce and nothing was done about it.**
The select is already inside `form.toolbar`, and measured there its four children sit at T110 /
T114 / T125 — one row, no wrap, at the width the audit used. The most likely reading of the original
observation is that a three-child head spread by `space-between` made the toolbar beneath it *look*
like a wrapped second row of the head; with the head corrected the effect is gone. Recorded rather
than quietly dropped, because the plan's own bullet asked for a move that turned out to be
unnecessary — and a future reader comparing plan to diff would otherwise find a gap.

**One page sheet got smaller, per decision 6.** `.bundle` had declared `display: flex; flex-wrap:
wrap; align-items: center; gap: 8px` — a verbatim copy of `.page-actions`. Now that the div carries
both classes, only `margin-top` is its own.

**The guard rides the existing 45-page sweep** in `template_hygiene_test.rb` rather than naming
routes, so a page added to that list is covered with no edit. It asserts the **rendered DOM**: both
defects were structural in ERB whose `.page-head` class was correct on every one of them, so nothing
short of the built tree could tell a compliant head from a broken one. Mutation-checked both ways —
unwrapping the Models links reddens it (`3 slots, not 2 — ["h1", "a.btn primary", "a.btn"]`), and
raising the non-vacuity floor to 500 reddens it at the floor instead, confirming `seen` really
counts (**50 heads across 50 pages** — one per page, itself worth knowing).

**Verification.** Bare `bin/ci`, seven gates green, 4218 / 4218 / 4218 identical run counts.

#### Original plan


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
