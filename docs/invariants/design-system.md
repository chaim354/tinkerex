# Invariants — the web shell and design system (CLAUDE.md §14m)

§14d material for the web layer's styling and chrome. Read this before touching
`app/assets/stylesheets/`, `app/views/layouts/`, `app/helpers/shell_helper.rb`, the `theme` / `rail` /
`toast` Stimulus controllers, any template's class names, or which panels `ProjectsController#show`
renders (rule 14). Spec:
`docs/superpowers/specs/2026-09-03-web-shell-and-design-system-design.md`; the story is the arc that
landed it (§11).

## The cascade

1. **`application.css` opens with `@layer tokens, base, components, shell, pages;` and every rule of
   ours sits in one of those layers.** The first `@layer` statement the browser meets fixes the order
   for the document, so the statement must be the first rule of the first sheet the layout links.
   **The `hidden` attribute is authoritative once, in `@layer base`** (`[hidden]:not([hidden="until-found"])
   { display: none !important; }`, which beats every later layer and the unlayered vendor sheet), so
   a component gives itself any `display` it likes and never restates `[hidden]`; `css_hygiene_test.rb`
   refuses a restatement (F-S34-2 deleted seven, and found the YAML drawer that lacked one).
2. **`vendor-overrides.css` is the ONE unlayered sheet, linked last.** An unlayered rule outranks
   every layered one, which is why the Lexxy / CodeMirror / spreadsheet skins have to live outside
   the layers to beat those libraries' own unlayered CSS — and why nothing else may. The CodeMirror
   editors follow the theme as everything else does, through tokens, and a switch repaints an open
   editor: `vendor-overrides.css` paints their chrome with UNSCOPED token rules (CodeMirror's view
   always runs its light base-theme variant, so a rule scoped to one theme leaves that variant's
   literals in the other), and `lib/codemirror_theme.js` adds one `HighlightStyle` whose colours
   are `var(--code-*)` (exported from the ONE vendored bundle, §14d). Nothing is chosen at mount;
   `oneDark` is gone (2026-10-21). `test/system/code_theme_test.rb` pins both themes and a live
   switch.
3. **A component selector is defined in `components.css` and nowhere else.** The list is
   `COMPONENT_SELECTORS` in `test/css_hygiene_test.rb`. A page sheet under `pages/` may qualify a
   component inside a container (`.files-grid .thumb`) but never redeclares the bare selector. The
   pre-2026-09 sheets defined `.btn` twice (blue, then grey) and the later file won, so `.btn`
   rendered grey everywhere and `.btn.primary` blue. Guard: `test/css_hygiene_test.rb`, which also
   refuses the three deleted sheets coming back and pins the layout's link order.

## Tokens and themes

4. **Every colour is a token on `:root`, declared there first**; `[data-theme="dark"]` and
   `@media (prefers-color-scheme: dark) { [data-theme="system"] }` redefine the same set. **Light
   ("Paper") is the default and what an absent or junk cookie means** (since the 2026-10-08
   redesign; it was dark before). The default lives in four places that must agree:
   `ShellHelper#ui_theme`, `theme_controller.js#current`, `lib/ui_theme.js#darkThemeActive`
   and the PWA manifest. A colour whose only definition sits inside a theme block never applies in
   the other state.
5. **EVERY THUMBNAIL IS INK ON PAPER, AND THE CARD TAKES ITS COLOUR FROM THE THEME BY MULTIPLY
   (2026-10-21).** Every render keeps a PURE-WHITE ground — ours paint
   `Maker::Previews::Palette::PAPER`, and LightBurn's and MillMage's own embedded thumbnails (22 of
   22 real catan files) and a PDF's page arrive on white — and every surface that shows one
   (`.thumb`, `.render-card`, `.landing-tile`, `.generator-preview`) is `isolation: isolate` with
   its image `mix-blend-mode: multiply` onto `--thumb-stage`, so the white becomes the card and ink
   stays ink, without a stored pixel being edited. **The card is LIGHT IN BOTH THEMES** — Paper's
   surface `#fcfbf8`, a dimmed paper `#bfbbb2` in Graphite — because the ink is often the FILE's
   colour (a LightBurn black or blue layer, a DXF's ACI 7, a plain SVG), which reads on no dark
   ground (LightBurn blue is 1.96:1 on Graphite's page) and no renderer may recolour. Measured on
   the Graphite card: 9.6:1 against the page (white was ~19:1, brighter than the text), black ink
   11:1, LightBurn blue 6.7:1, red 3.4:1. `--thumb-ink`, what the app paints on the card itself
   (the type label, the spinner, the failed mark), flips with it: 6.5:1 and 5.6:1. Four things not
   to undo. **A render's ground is white, never a stage colour baked in** — the card would multiply
   it a second time. **An image never paints the card itself**: a new surface takes `.render-card`
   or the `.thumb` pair, and `.project-hero-render` drops the hero image's own background for that
   reason. **A PHOTO opts out** (`.thumb.photo`: normal blend on `--photo-stage`), because a photo
   is not ink and Graphite's matte is near-black. **The Measure stage is this card in both themes**,
   for the same reason as the tiles (it draws the file's layer colours), ringed by a box-shadow and
   never a border, because the Measure tests derive mm-per-pixel from its width. Meshes are drawn
   in ONE material, `--model-material` `#7f7b73` (held equal to `Palette::MATERIAL` by
   `palette_test.rb`): it clears 3:1 on all four grounds it meets (the viewer's `--raised` in Paper
   3.44 and Graphite 3.61, the card 4.18 and 3.58), which is why it is not redefined per theme.
   **Drawing colours stay literal**: Measure's layer strokes and the hover/selected pair (pinned by
   computed style in the Measure system tests), the tray top-view fills, LightBurn swatches.
   `test/system/preview_stage_test.rb` pins the card, the isolation, the blend, the photo's
   opt-out and the Measure stage in both themes.
6. **A token flip is a review question.** Migrating a light-only rule verbatim can break it: `color:
   #fff` over `var(--fg)` was readable when `--fg` was near-black. Pair literals with the ink token
   (`--accent-ink`, which is near-black in the dark theme) or drop the copy in favour of the
   component.

**THE VIEWERS FOLLOW THE THEME, AND AN OPEN ONE REPAINTS ON A SWITCH (2026-10-21).** Where the
colour is CSS (the Gerber viewer's `--fg` on `--raised`, Measure's chrome, the code viewers, the
workbook grid's `.spreadsheet-grid` skin, the frames) that is the cascade's doing. The 3D viewer's renderer takes a colour, not a style, so it
reads its ground from the stage's computed `--raised` and repaints through a `data-theme`
MutationObserver plus the OS scheme query, released with the engine; "Use this view as preview"
photographs on white, never on the theme's ground, so a saved view multiplies onto the card like
every render (`o3dv_test.rb`). KiCanvas is the one viewer that takes its theme as a NAME, through a
preference it loads ONCE, at import (`kc:prefs:theme`): `kicanvas_controller.js` writes `kicad`
under Paper and `witchhazel` under Graphite before the import, and the cost is stated — a switch,
or a Turbo visit after one, shows the schematic in its page's theme until the next full load
(`kicanvas_test.rb`). The print sheet and the SVG export are NOT viewers and never follow the
theme: black on white, at true scale (measure-view.md).

## The shell

7. **Theme and rail state are cookies (`theme` ∈ light|dark|system, `rail` ∈ expanded|collapsed),
   rendered by `ShellHelper` into the first byte of HTML — never an inline script.** The CSP nonces
   `script-src`, and a pre-paint script is the thing not to add. The JS writes them with `path=/`,
   a one-year `max-age` and `samesite=lax`; the server trusts nothing beyond the enum.
8. **The sidebar lights exactly one link, and `ShellHelper#sidebar_current` alone decides which.**
   The first place is **Recent** (`/`, a clock icon), and it keeps the `[:home]` key, the `home`
   `SECTIONS` entry and the route: slice 6 changed its label and icon in the sidebar and the phone
   tab bar, never the key the lit test reads.
   `rail_section` still maps `controller_path`'s FIRST segment (a new web controller needs a
   `SECTIONS` entry or its pages light nothing), and `sidebar_current` refines it: the deepest
   pinned folder on the breadcrumb (the Files page's or a file page's — both set `@crumbs`) beats
   Library, a listed project's own link beats All projects, and an unlisted one lights All
   projects. **The Library's 3D models view (`files/models`, slice 5) lights the 3D models place,
   not Library**, although its first segment is `files`: `sidebar_current`'s files arm checks
   `controller_path == "files/models"` before the pin walk. The phone tab bar has no place of its
   own for it, so it lights Library for `[:models]`, on the view and on the model pages
   (`models/*`, which `SECTIONS` still maps to 3D models); `models_redirects_test.rb` pins both
   lights on the view. `SECTIONS`' `models` entry no longer names `shelves`, so `settings/shelves`
   lights Settings. The sidebar and the phone tab bar both read `sidebar_current`;
   `shell_layout_test.rb` pins one lit link per page. **Collapsed (or below 1100px) the project
   and pin links are hidden**, so `sidebar_family_lit?` marks their visible parent — Library for a
   pin, All projects for a project — with `.rail-family-lit`, a CLASS and not a second
   aria-current, which shell.css draws only in the icon rail. **The icon rail is ONE container query
   on `.rail`** (`@container rail`): the collapse cookie and the ≤1099px media query each set only
   the grid track, so both triggers draw one rule block, and nothing outside the rail can match it
   (its unscoped viewport copy hid the sign-in card's wordmark). The rail's width must stay the grid
   track's, a length, because inline-size containment stops its content from sizing it
   (`css_hygiene_test.rb`, `shell_test.rb`). **The top bar's Upload and New ▾
   create in `FolderDestination`'s folder, set by the action that renders a folder** and by nothing
   else, never from session or user state (the current project it replaced is guarded out by
   `architecture_invariants_test.rb`). A page with none asks with the folder chooser
   (`upload_pick_controller.js`) rather than guess one.
9. **Breadcrumbs render in the top bar through `content_for :crumbs`**, with the page title as the
   fallback; page-level actions stay in the page's `.page-head`, so the top bar carries no
   per-page control. Its New ▾ and Upload are on every signed-in page; only their destination
   (rule 8) and Upload's weight (rule 13) vary. **On a phone (below 720px) they are one "+"**: the
   upload label hides and the New menu's phone-only "Upload…" item (`upload_forward_controller.js`)
   clicks that LABEL, never the file input and never through a `<label for>`. On a page with no
   folder the label's click is what `upload_pick_controller.js` intercepts to ask for a folder, and
   an input-targeted click is the one it lets through, so either shortcut uploads to the library
   root unasked. Hide only the label, never `.topbar-upload`, which also holds the chunk flow's
   `.upload-status` progress text.
10. **Only `.flash-stack > .flash` floats.** `projects/_tasks` renders an inline
    `p.flash-alert.task-error` and two forms render `div.form-errors.flash-alert`; they must stay
    inline, so the fixed positioning lives on the stack container, not on the class.
11. **No page scrolls sideways at 375px** (`test/system/shell_test.rb`). Tables drop columns
    through the `col-*` classes `files/_list.html.erb` carries; anything that must keep its width
    (code, diffs, the Measure stage, the spreadsheet) scrolls inside its own `overflow-x: auto`
    container; long names get `overflow-wrap: anywhere`.

**THE PAGE'S `<head>` IS ONE PARTIAL, `layouts/_head`, AND `layouts/turbo_rails/frame` IS THIS APP'S
OWN, NOT AN ACCIDENTAL SHADOW OF THE GEM'S (2026-10-21).** turbo-rails applies `turbo_rails/frame` to
every frame request, and the gem's copy carries only the CSRF tags. Turbo records a frame navigation
promoted to a page visit (`data-turbo-action="advance"`, the model page's pane) only when the
response's `data-turbo-track` head elements match the page's, so with the gem's layout the URL
advanced while Turbo's `lastRenderedLocation` stayed behind, and every later snapshot was filed under
the wrong address (Back showed the wrong pane). Deleting the override as redundant brings that back;
`model_stage_test.rb` compares the two heads and `model_page_test.rb` walks Back through them. A
stylesheet or script tag goes in `_head`, never in either layout, or the two heads diverge again.
`css_hygiene_test.rb` reads the link order from `_head`.

## Contracts a restyle may not break

12. **Class names are a contract: restyle, never rename.** The selectors the tests pin (spec §10),
    `main.container` / `.container-wide` (the addon host page opts in), `.flash-notice` /
    `.flash-alert`, and the 52 classes the addon bundles in `chaim354/tinkerex-addons` build their
    own markup with (`addons.md`'s host contract; the list is in spec §10). Fonts are self-hosted under `app/assets/fonts` with the OFL text beside
    them because `font_src` is `:self`; `@font-face` `url()`s are relative to `application.css`'s
    logical path and Propshaft fingerprints them (`shell_layout_test.rb` fetches each).

13. **The accent is spent once per screen; selection is ink.** `--accent` fills the one primary
    action. On the Library, Recent and a project hub that is the top bar's Upload. The Library and
    the hub show a folder and say so through `FolderDestination`'s `primary`, and Upload names where
    it saves. Recent shows none, so it calls `upload_primary!`, **which changes Upload's weight and
    never its destination**: Upload there still asks with the chooser. It is a flag of its own
    because a `Destination` with a nil `node_id` would mean the library ROOT, not "ask". Everywhere
    else Upload is a quiet `.btn`. No secondary control
    is allowed the accent now. A project hub's second accent is its Save publishing, because the hub
    is the one page the 2026-09-10 cohesion spec's decision 3 allows two; `accent_spend_test.rb`
    pins every page. Links, selected chips, toggles, tabs, the file-chooser selection and the active
    rail item use `--fg`. Status carries its word, never colour alone (`.flash::before`, badge
    labels). Text on an accent fill is
    `--accent-ink` (near-black in the dark theme), never a literal white. `components.css` and
    `shell.css` name tokens, never colour literals (`css_hygiene_test.rb`); drawing colours stay
    literal in `pages/` (rule 5). No emoji draws anything: `css_hygiene_test.rb` refuses a
    pictograph (U+1F300–U+1FAFF) in a stylesheet's `content`, and `test/no_emoji_test.rb` refuses
    one in templates, helpers, controllers and scripts; a glyph helper (`rail_icon`,
    `folder_glyph`) or a word stands in. Labels stay Plex Sans and mono stays for data (the 2026-09-10
    cohesion decisions 4 and 5). Text selection (`::selection`) and the code editor's selection and
    active-line tints are browser text affordances, not UI selection state, and keep accent tints.
    The values are the Tinkerex Design System artifact.

The library search that the top bar drives (`FilesController#index`, `?q=`) is flat, whole-library
and case-insensitive; its `LIKE` carries `ESCAPE '\'` because SQLite has no default escape
character and `sanitize_sql_like` alone is inert there — measured, and the same rule `LIKE_EXT`
already records. Guards: `files_search_test.rb`, `page_query_budget_test.rb`.

## The project hub

14. **On-demand panels are decided in `ProjectsController#show`, never in
    `Maker::ProjectKind.layout_for` or its `Layout`.** The layout is shared with the public page, its
    feed, its bundle and its BOM CSV through `Maker::PublicProject#layout`, so "empty means absent"
    put there would change what a visitor sees and what the downloads carry; the public page already
    omits an empty panel in each of its own partials. `ProjectsController::ON_DEMAND` names the
    panels that leave the maker's normal page while they hold no row (Build log, Tasks, BOM, Wiring,
    Releases, Sheets, Calculations), and `panel_has_rows?` answers from data `#show` already loaded,
    so the decision costs no query. Three things not to undo. **A panel the maker hid stays hidden**: the
    layout's `visible?` is asked first, so neither `?add=` nor the add menu can bring it back. **The
    editor shows every panel**: `@editing` skips all of this, so an empty panel can still be
    arranged. **"+ Add panel" is per-visit and persists nothing**: `?add=<key>` opens that one
    panel, empty and with its composer, for this request only (a key that is not a String naming a
    visible on-demand panel is ignored, never a 500). Once it holds a row it stays on its own. There
    is no new key in the stored `panels` JSON, so `Maker::LayoutDocument`'s Save has nothing to carry
    or lose, and a maker who opens a panel and adds nothing finds it gone on the next visit, which is
    what "on demand" means.

## The front door

15. **Signed out, `/` has two answers and demo mode picks; signed in it is Recent.** On the public
    demo's box (`Tinkerex::Landing.enabled?`, which is `Tinkerex::Demo.enabled?`) it is the marketing
    landing; anywhere else it is the plain sign-in card, because a self-hosted box has nobody to pitch
    to and the landing's one action IS the demo. `config/routes.rb` declares three roots in this
    order: the landing (`landing_root`, a request-time constraint on demo mode, written as a nested
    `constraints` block because a callable `constraints:` option on the route REPLACES the enclosing
    `unauthenticated` and sends a signed-in user to the landing, which 500s), the card
    (`unauthenticated_root`), then `root` — any other order and a visitor meets the wrong door
    (`test/integration/web/landing_test.rb`). `LandingsController` stands on `ActionController::Base`,
    never on `ApplicationController` with a skip (`architecture_invariants_test.rb`'s default-deny),
    and outside `Public::` because its demo button's CSRF token writes the session. The accent is Try
    the demo while `Tinkerex::Demo.available?`, else Install — exactly once either way (rule 13; the Try the demo state in
    `accent_spend_test.rb`, both states in `landing_test.rb`). `/users/sign_in` is the plain card everywhere. **The wall's twelve tiles
    are the app's own renders** of twelve files of the owner's `catan` project, which `db/seeds/demo`
    holds whole (the seed's 70 MB budget is that decision, `demo_reset_test.rb`), written by `bin/rails landing:wall`
    (`Tinkerex::Landing`, which refuses rather than skips); **the four feature crops are the app
    photographed** by `script/landing/capture_crops.rb`, the demo banner removed and nothing else
    touched. Retake both when the renderers or the pages move; never draw or edit them.
    `test/system/landing_test.rb` reads the computed width, every tile's load and the 375px overflow,
    which a request test cannot see.
