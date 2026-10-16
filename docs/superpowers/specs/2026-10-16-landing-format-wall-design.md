# The landing, second pass: a format wall on tinkerex.com, a plain sign-in everywhere else

**Date:** 2026-10-16 · **Replaces:** the landing of tinkerex#372 (PR #405) · **Status:** design
approved in conversation; this file is the spec the implementation plan is written from.

## Why

The owner, on the live page: *"the whole thing is bad, it's just some screenshots."* Measured on
tinkerex.com the same day: the page lays out cleanly (no console errors, no sideways scroll at 375,
1024 or 1440), but its whole case is three 1280×800 window captures shown about 300 px wide. At that size
no interface in them is readable, and nothing on the page shows the one thing Tinkerex does that a
file browser does not — every LightBurn, STEP, Gerber and MillMage file gets a picture. It also
greets the owner's own Unraid boxes with "Install it yourself" whenever a session expires, because
the same view is `/` on every deployment.

## Decisions (made with the owner, 2026-10-16)

| question | answer |
|---|---|
| Who is the page for | **tinkerex.com only.** A self-hosted box shows a plain sign-in. |
| The one main action (the accent) | **Try the demo.** Log in becomes a nav link; Install is quiet. |
| Shape | **A format wall**: real previews of twelve files from the owner's `catan` project in the hero, then how it works, feature rows with tight crops, a self-hosting band, a closing call to action. |
| Feature rows | **All four**, the box generator included. Tools must exist on the demo for that row to be true — a follow-up, §7. |

## 1. Where it shows, and how `/` is routed

- **The marketing landing is on exactly when demo mode is on — `Tinkerex::Demo.enabled?`
  (`DEMO_ACCOUNT_EMAIL` set).** The page's main action IS the demo, so a landing without one has
  nothing to lead with; and it costs no new setting, since `deploy_hygiene_test.rb` already pins
  that variable to the OVH destination alone and `docs/INSTALL.md` already documents it. Read per
  request, never memoized (the module's own rule: a test flips ENV between requests).
- **Signed out:** `/` on a demo deployment → `LandingsController#show`; on any other deployment →
  the plain sign-in card (`users/sessions#new`), as `unauthenticated_root` routes it today.
  **Signed in:** `/` is Recent everywhere, unchanged. Both unauthenticated roots stay declared
  before `root` (routes match in declaration order — rule 15's existing guard), the landing's
  first, behind a request-time constraint asking `Tinkerex::Demo.enabled?`.
- **`LandingsController` stands on `ActionController::Base`** (`layout "application"`), as
  `Public::BaseController` and `CspReportsController` do. `architecture_invariants_test.rb` requires
  every `ApplicationController` descendant to run `authenticate_user!` and says a genuinely public
  page stands outside that tree rather than skipping the callback. It is **not** in `Public::`
  either: the demo button is a `button_to` form, whose CSRF token writes the session, which
  `Public::` may never touch (§14d). (Corrected while planning; the first draft said
  `ApplicationController` with a skip, which that guard refuses.)
- **`/users/sign_in` is the plain auth card on every deployment.** The pitch, the masthead and the
  screenshots leave `users/sessions/new.html.erb`; the card gets back the brand mark every other
  auth card carries; its fields, its demo button (quiet, while the demo is available) and its one
  accent (Log in) are unchanged, so `auth_pages_test.rb` and `demo_session_test.rb`'s card
  assertions hold as they are.
- **The accent on the landing is Try the demo while `Tinkerex::Demo.available?`, else Install.**
  Mid-reset, or before `tinkerex:demo:setup` has run, the account is missing and `POST /demo`
  answers 404, so the button is not rendered (the card's existing rule) and Install takes the
  accent — the page always spends it exactly once (rule 13). `available?` costs the page one COUNT,
  as it already costs the sign-in page.

## 2. The page, top to bottom

Copy below is the copy to ship; the plan may tighten wording, not change claims.

1. **Nav.** The rail's `.brand` (mark + name) on the left; on the right three text links —
   **Install** (`docs/INSTALL.md` on GitHub), **Source** (the repository), **Log in**
   (`new_user_session_path`).
2. **Hero**, two columns from 900 px, one below it.
   - `h1`: *Every file your workshop makes, previewed.*
   - Lede: *Tinkerex indexes the folder your STL, STEP, LightBurn, DXF and Gerber files already live
     in, draws a preview of each (more than a hundred file types), and opens them in the browser,
     measured in millimetres. It runs on your own box, and your files stay plain files.*
   - **Try the demo** (`.btn.primary`, the accent) and **Install it yourself** (`.btn`). Under them,
     muted: *No sign-up. A shared account that resets every night.* — the demo button's own hint,
     reworded for a first-time reader; shown only with the button.
- **The wall:** twelve tiles, 4×3 from 900 px and 3×4 below, **all twelve files from one real
  project: the owner's `catan` project**, a laser-cut board-game set (decided 2026-10-16, replacing
  a generated sample per format). Six LightBurn files (hex tiles, number tokens, Longest Road
  cards, harbor tokens, building-cost cards, the game box), two SVGs, a DXF, a MillMage file, the
  robber as a 3MF and an STL. A caption under the wall says so. Each is an `<img>` of the app's own
  render on the white `--thumb-stage` (rule 5), the real extension in mono on a chip in the corner,
  and alt text saying what the file is ("A LightBurn file: the numbered tokens…"). Width and
  height on every `<img>`; above the fold, so not lazy. STEP, Gerber and PDF stay in the pitch's
  words but are not on the wall, because the project has none.
3. **How it works**, three numbered steps:
   1. *Point it at a folder* — A NAS share, an S3 bucket or a sync server. Nothing is imported or copied.
   2. *It keeps up on its own* — Save from LightBurn, a slicer or KiCad, and the file appears within minutes.
   3. *Open anything, anywhere* — Spin a model, measure a cut file, read a README, from any browser.
4. **Four feature rows**, text beside a crop, alternating sides from 900 px, crop under text below:
   - *A 3D viewer that speaks millimetres* — STL, 3MF, STEP and a dozen more open in the browser
     with their size on three axes. Crop: the file page's viewer and its dimensions.
   - *Cut files, measured* — LightBurn, SVG and DXF files show their real size and print at 1:1 to
     check against stock. Crop: the Measure view of a `.lbrn2`.
   - *A folder becomes a project* — Make a folder under Projects and it gets a page: its README,
     its files by kind, its git repository. Crop: a project page.
   - *Generate the next file* — Tools like the box generator save straight into your library, next
     to everything else. Crop: the box generator.
5. **Yours, on your box** — four short cells: *Your box* (Docker on Unraid, a Mac or Linux) ·
   *Plain files* (uninstall it and your folder is unchanged) · *No database to run* (SQLite out of
   the box) · *Apache-2.0* (open source).
6. **Closing:** *See it with real files* — the demo is the same app over a small sample library —
   with **Try the demo** and **Install guide** as quiet `.btn`s (the accent is already spent in the
   hero).
7. **Footer:** Tinkerex · Apache-2.0 · Source · Install guide · Log in.

`<title>` and the meta description move with the page. There is **no JavaScript** on it: plain
HTML and CSS, nothing for the CSP to nonce.

## 3. The sample library and the pictures

- **The owner's `catan` project is the sample library, whole.** `Projects/catan` from the share
  deployment (60 files, about 61 MB, its `.git` left out because a repository cannot be committed
  inside this one and the port refuses `.git` as a write destination) goes into
  **`db/seeds/demo/Projects/catan/`**. The demo a visitor clicks into, the wall's tiles and the
  feature crops are then the same real files, so the demo looks like the page that sent the visitor
  there (handoff §4 asked for exactly this). The rest of the seed (Desk Lamp, `Laser/`, `Models/`,
  `Welcome.md`) stays; `Welcome.md` gains a line pointing at `catan`. **Budget: 70 MB** —
  `demo_reset_test.rb`'s 200 KB ceiling is raised on the owner's word (2026-10-16: "all of it");
  it still catches a whole library committed by accident. The project's files are the owner's own
  except the robber, credited in `Projects/catan/models/CREDITS.md` to doghound678's CC-BY
  "Catan Robber" (Thingiverse 86225). The five screenshots were reviewed before publishing: boxes.py
  settings pages, nothing personal. No generator script and no separate photo.
- **The wall is rendered, never drawn.** A rake task (`landing:wall`) runs each wall file in the
  seed through `Maker::Previews::Registry` — the same renderer the library uses — and writes the PNG
  to `app/assets/images/landing/wall/<name>-<ext>.png`, at 256 px (twice the tile's largest displayed
  size). It **fails** on a file no renderer claims or one that renders nothing, rather than leaving a
  tile out, and writes nothing unless every tile rendered. It takes rake ARGUMENTS for its
  directories, never environment variables, because `install_docs_test.rb` would demand an
  INSTALL.md row for any variable `lib/tasks` reads. The renderers need their binaries
  (stl-thumbnailer, F3D, pdfium, resvg, vipsthumbnail, node), so the task runs inside the
  production image built for linux/amd64 (F3D ships no arm64 build); the plan names the recipe.
- **The four crops are the app, photographed.** From a local server over that seed, light theme, at
  device pixel ratio 2, each cropped to the part that makes its point (the robber in the 3D viewer
  with its dimensions; the hex tiles in the Measure view; the `catan` project page; the box
  generator's form and preview). JPEG, about 1120 px wide shown at 560. Below the fold, so
  `loading="lazy"`, with width and height. Never doctored; the view's comment says how to retake them.
- **The three current screenshots are deleted** (`app/assets/images/landing/{library,project,viewer}.jpg`).

## 4. Styling

`pages/landing.css` is rewritten; it stays the last page sheet the layout links, so
`css_hygiene_test.rb`'s two lists do not move. Everything design-system.md requires holds: rules in
`@layer pages`, tokens only (the thumb stage is the one literal-coloured surface and it is already a
token), no component selector redeclared (rule 3 — `.btn`, `.brand` are reused, qualified inside
`.landing` where needed), one accent (rule 13), no sideways scroll at 375 (rule 11, `minmax(0, 1fr)`
tracks as the current sheet already learned), light by default and the dark theme from the tokens.
The landing opts out of the 440 px auth column with `content_for :container_class` exactly as now.

## 5. Tests

- **`test/integration/web/landing_test.rb`, rewritten.** Demo mode on: `/` is the landing — nav,
  `h1`, twelve wall `<img>`s each with non-empty alt, four feature rows, the install and source
  links; the accent is Try the demo with the account present and Install with it absent (exactly one
  `.primary` either way). Demo mode off: `/` is the plain card and nothing of the landing. Both
  modes: `/users/sign_in` is the plain card with its brand; signed in, `/` is Recent.
- **`test/system/accent_spend_test.rb`** gains the landing (demo on).
- **`test/system/landing_test.rb`, rewritten.** At 1280: the wall sits beside the hero text and
  every tile has loaded (`naturalWidth > 0`); at 375: no sideways scroll and the wall below the
  text.
- **`test/integration/web/demo_session_test.rb`**: its `GET /` assertions follow the gate.
- **`landing:wall`** gets a test that it refuses an unrenderable file.
- **Mutation checks, each red then restored:** the constraint's `enabled?` negated; the two
  unauthenticated roots swapped below `root`; a second button given `.primary`; one wall `<img>`
  pointed at a missing asset (the system test's load check).

## 6. Docs

- **design-system.md rule 15 is rewritten** for the new front door: the landing exists only in demo
  mode and why; the plain card everywhere else; the accent's fallback to Install; the wall's tiles are
  renders from `landing:wall`, the crops photographs of the app, neither doctored.
- The view's header comment carries the same in short, plus how to retake the crops.

## 7. Out of scope, and what it depends on

- **Tools on the demo (follow-up, needs the owner's go-ahead to deploy OVH).** `config/deploy.ovh.yml`
  has no addons accessory, so the gallery on tinkerex.com is empty and the fourth feature row
  promises something the demo cannot show until one is booted there (handoff §4). Filed as open work
  when this lands; this branch does not touch OVH.
- **The GitHub links 404 until the repository is public** — the owner's flip (handoff §1). The page
  keeps them; they start working the moment the repository does.
- **A live, spinnable 3D tile** (the third approach considered) — later, as one tile inside this
  layout, if the page wants it.
- **Deploy.** This lands as a PR; OVH is deployed only on the owner's word
  (`kamal deploy -d ovh --skip-push --hosts 15.204.216.249` after `kamal build push`).
