# Invariants — the web shell and design system (CLAUDE.md §14m)

§14d material for the web layer's styling and chrome. Read this before touching
`app/assets/stylesheets/`, `app/views/layouts/`, `app/helpers/shell_helper.rb`, the `theme` / `shell` /
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
   **A toggle button's pressed look is drawn once, by `.btn[aria-pressed="true"]`, from the state the
   button announces.** A new toggle sets `aria-pressed` and writes no CSS; a class alone draws
   nothing (the Gerber viewer's toggles set `active`, which no rule matched, until 2026-11-16). The
   rule sits after `.btn:hover`, which has its specificity. The same guard refuses a pressed
   selector in any other sheet, qualified or bare.

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
   surface `#ffffff`, a dimmed paper `#bfbbb2` in Graphite — because the ink is often the FILE's
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
   3.82 and Graphite 3.61, the card 4.21 and 3.58), which is why it is not redefined per theme.
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

7. **Theme state is a cookie (`theme` ∈ light|dark|system), rendered by `ShellHelper` into the first
   byte of HTML — never an inline script.** The CSP nonces `script-src`, and a pre-paint script is
   the thing not to add. `theme_controller.js` writes it with `path=/`, a one-year `max-age` and
   `samesite=lax`; the server trusts nothing beyond the enum. The choice is `settings/_theme`,
   rendered on the Settings page and in the strip's account menu; every instance re-renders on a
   change made in another (the `theme:change` broadcast). **The `rail` cookie retired with the rail
   (Shop manual slice 3): nothing reads or writes it, and no `body.rail--*` class exists**
   (`shell_layout_test.rb` sends both old values and finds the body unchanged).
8. **The shell is a strip of four places — Library, Projects, Tools, Inventory, always all four —
   over a left column, and `ShellHelper#sidebar_current` alone decides what is lit: AT MOST ONE place
   and AT MOST ONE column row** (Shop manual spec §7 and §11.2). It answers one key (`[:folder, id]`,
   `[:project, id]`, `[:low_stock]`, `[:settings, :tags]`, …); the place is DERIVED from the key
   (`ShellHelper::PLACES`, `sidebar_place`), and the strip, the phone tab bar and the column all read
   that one answer (`place_aria`, `row_aria`). A lit place is weight 800 over a 3px ink underline with
   `aria-current="page"`; a current row is weight 800 with a 6px accent square. **Home, Search,
   Settings and Help light no place**: Home is the wordmark's (`/`, which keeps the `[:home]` key,
   the `home` `SECTIONS` entry and the route — it was Recent, a place of its own, until slice 3),
   and the account menu holds Settings and Help, whose pages light their rows in their own columns.
   `shell_section` maps `controller_path`'s FIRST segment — or, for a `SECTIONS` entry holding a `/`,
   the whole path (`users/registrations` is a Settings page) — and a new web controller needs a
   `SECTIONS` entry or its pages light nothing and get no column. **The 3D models view
   (`files/models`), the model pages and Trash light Library** and their own rows in its column; this
   reversed the old exception under which the 3D models view lit a place of its own
   (`models_redirects_test.rb`). In the Library the lit row is the folder on screen — the deepest crumb
   (`@crumbs`, which FilesController#index and #show both build; a file's page lights its folder),
   else the library root. A project lights its row among the eight listed (`sidebar_projects`), or
   All projects when it is older; the Projects index lights the filter applied (All, Archived, a
   kind). **The column is a slot**: a page supplies its own with `content_for :column`, and otherwise
   its section's default renders (`layouts/column/_<name>`, `ShellHelper::COLUMNS`); a section with
   none (Search) gets no column and no Contents button. Every default row is a real link, and every
   list in it is ONE query whatever it holds (`page_query_budget_test.rb`). Home's column is the
   page's sections as in-page links, then Pinned (the pinned folders and the pinned tools, the
   calculator's row opening its modal, each tool row keeping its right-click Unpin);
   `shell_layout_test.rb` holds every in-page link to an element the page carries, and walks every
   kind of page for two lit places, two current rows, or a tab bar that disagrees with the strip.
   **The layout never reads the addon registry**, so the Tools column lists the gallery and the
   pinned tools, which the user row holds (docs/invariants/addons.md). **Narrower than the screens**:
   from 960px the column sits beside the page; below it is a sheet the strip's Contents button opens
   (`shell_controller.js`: fixed, so opening it moves nothing; focus moves in, and Escape, the scrim
   or the button closes it and hands focus back). Below 720px the four places move to the phone tab
   bar, which is exactly the four (the More tab retired with the rail), Search becomes an icon linking
   to `/search`, and Add shows only its "+". **The strip's Add creates in `FolderDestination`'s
   folder, set by the action that renders a folder** and by nothing else, never from session or user
   state (the current project it replaced is guarded out by `architecture_invariants_test.rb`). A page
   with none asks with the folder chooser (`upload_pick_controller.js`) rather than guess one.
9. **Breadcrumbs render at the head of `main` as the caps path (`.page-path`) through
   `content_for :crumbs`**, with the page title as the fallback; they left the top bar with it, and
   page-level actions stay in the page's `.page-head`, so the strip carries no per-page control. **The
   strip's one Add holds what Upload and New ▾ held** — "Upload…", New folder, Text file, Project, the
   tools that make something (a lazy frame, so no render reads the registry), Inventory item — on
   every signed-in page, an outlined button; only its destination (rule 8) varies, and its menu says
   where things land. **"Upload…" clicks the hidden Upload BUTTON beside the menu
   (`upload_forward_controller.js#open`), never the file input. Upload is a
   `<button type="button" class="upload-btn">` beside its hidden input, never a `<label>` over it**
   (UX audit I: a label cannot take focus, so keyboard users could not upload; the keyboard reaches it
   through the menu item, itself a button): with a folder, `upload-forward#choose` opens the input;
   without one, `upload-pick#pick` asks for a folder on EVERY click, starting from the last one chosen.
   An input-targeted click skips the ask and uploads to the library root unasked. **Hide only the
   button, never `.topbar-upload`** (named for the top bar it was built in), which sits OUTSIDE the
   menu and also holds the chunk flow's `.upload-status`: a closed `<details>` hides everything but its
   summary, and the progress must show while an upload runs, so it hangs under the strip's rule at
   the right, where it neither moves the strip nor pushes the account button off a phone
   (`phone_strip_test.rb`). **Search keeps ⌘K and gains `/`** (spec §11.5): both focus the strip's box,
   `/` only when focus is not taking typing and no grid owns the keys, and `aria-keyshortcuts` names
   all three. **The crumb root of every Library page (a folder, a file, the 3D models view, a model,
   Trash) reads Library, the strip's word for the place, never "Files"** (UX audit A3); a
   parent-named button in a page head is not a third way up, and where a back control legitimately
   remains (a foot link) it reads "Back to NAME".
10. **Only `.flash-stack > .flash` floats.** `projects/_tasks` renders an inline
    `p.flash-alert.task-error` and two forms render `div.form-errors.flash-alert`; they must stay
    inline, so the fixed positioning lives on the stack container, not on the class. **The stack sits
    bottom-right (above the tab bar on a phone), clear of the strip's Add and account button** (UX
    audit A5). A notice
    pauses while hovered or focused and resumes with at least 2 s left; Escape dismisses the focused
    toast; an alert stays until dismissed; any `[data-toast-target=item]` appended later (the layout
    editor's, the uploader's) is handled by `toast_controller.js` (`shell_toast_test.rb`). An error
    is always a `flash-alert`, never a `flash-notice` wearing the word "Done" (UX audit B2).
    **Every notice and alert is one grammar: verb first, past tense, the object named, a full stop**
    ("Deleted the note.", never "Note deleted."), in the verb of the button that caused it
    ("Unlink" answers "Unlinked lid.stl."). `notice_grammar_test.rb` refuses the noun-first shape
    and a missing full stop in every `notice:`/`alert:` literal under app/controllers and app/views.
11. **No page scrolls sideways at 375px** (`test/system/shell_test.rb`), and neither does the strip,
    the column's open sheet or the tab bar on any section's page (spec §10's width guard, the same
    file). Tables drop columns
    through the `col-*` classes `files/_list.html.erb` carries; anything that must keep its width
    (code, diffs, the Measure stage, the spreadsheet, a recipe table) scrolls inside its own
    `overflow-x: auto` container; long names get `overflow-wrap: anywhere`. **`anywhere`, never
    `break-word`**: only `anywhere` lowers the MIN-CONTENT width a flex line or a table column is
    sized by, and a name is routinely one unbroken run (an underscore is no line-break opportunity).
    `.page-head h1` and `.breadcrumb` carry it for every page; `.btn` stays nowrap, and a button
    whose label interpolates a name takes `.btn-name`, which wraps. `test/system/narrow_names_test.rb`
    measures an 80-character underscore name on the file page, the project page, a release row,
    the Attach picker and a recipe table, against `clientWidth` (CI's Linux Chrome draws a 15px
    scrollbar).

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

12. **Class names are a contract: restyle, never rename.** The selectors the tests pin,
    `main.container` / `.container-wide` (the addon host page opts in), `.flash-notice` /
    `.flash-alert`, and the **101 classes the addon bundles in `chaim354/tinkerex-addons` build their
    own markup with: `test/fixtures/addon_host_classes.txt`**, whose header says how it was scanned
    (every bundle on that repo's `main`, 2026-11-19). The bundles ship no stylesheet, so a class
    renamed or left unstyled here breaks a tool in another repository with nothing red in this one;
    `css_hygiene_test.rb` fails when a listed class is no longer named by any sheet, and when the boxes
    snapshot under `test/fixtures/addons` uses a styled class the list lacks. Re-scan when the bundles
    grow a class. (The count was "52" in one doc and "53" in another, both pointing at a spec deleted
    on 2026-11-10; the scan found 101, all 53 among them.) Fonts are self-hosted under
    `app/assets/fonts` with the OFL text beside them because `font_src` is `:self`; `@font-face`
    `url()`s are relative to `application.css`'s logical path and Propshaft fingerprints them
    (`shell_layout_test.rb` fetches each).

13. **Red marks and never fills a control; the one primary action is ink** (the Shop manual's
    proposal 1, 2026-11-19; until then the accent filled the primary). `--accent` draws a figure
    number (`.fig-num`), the current row's square, a selected figure's outline, a warning word or
    flag (the flag `.badge`s: a failed print, low stock, changed since a release) and the focus ring,
    and never a control's fill. **The one primary action per screen is an INK fill** (`.btn.primary`:
    `--fg` with `--bg` text); every other button is outlined in ink. On the Library, Recent and a
    project hub the primary is the top bar's Upload. The Library and
    the hub show a folder and say so through `FolderDestination`'s `primary`, and Upload names where
    it saves. Recent shows none, so it calls `upload_primary!`, **which changes Upload's weight and
    never its destination**: Upload there still asks with the chooser. It is a flag of its own
    because a `Destination` with a nil `node_id` would mean the library ROOT, not "ask". Everywhere
    else Upload is a quiet `.btn`. No secondary control
    is filled. The project hub is the one page the 2026-09-10 cohesion spec's
    decision 3 allows two, and since 2026-10-26 it spends one (Upload): its second, Save publishing,
    moved with the Publish panel to the edit area's Publishing tab. Each of that area's three tabs
    (Details, Publishing, Page layout) spends it on its own Save, with Upload quiet on all three
    (`ProjectsController#show` passes `primary:` false in edit mode, and the YAML drawer's Apply is
    a quiet `.btn`). `accent_spend_test.rb` pins every page by RESOLVED background: exactly its ink
    primaries, and no control anywhere filled with the accent. **Selection is ink too**: a filter
    chip is underlined in ink, a pressed toggle, a segmented control's lit part, the chosen tag and
    the file-chooser selection are filled with it, and tabs and the lit rail item use `--fg`. A lit
    part SAYS it is lit (`aria-pressed`, `aria-current`, `aria-selected`), which is how the guard
    tells a selection from a second primary. Status carries its word, never colour alone
    (`.flash::before`, badge labels, a flag's word). Text on an accent fill is
    `--accent-ink` (near-black in the dark theme), never a literal white; `.fig-num` follows it.
    `components.css` and `shell.css` name tokens, never colour literals (`css_hygiene_test.rb`, a
    data: URI's `%23` included: the select chevron is a token, `--select-chevron`, redefined per
    theme); drawing colours stay literal in `pages/` (rule 5). No emoji draws anything: `css_hygiene_test.rb` refuses a
    pictograph (U+1F300–U+1FAFF) in a stylesheet's `content`, and `test/no_emoji_test.rb` refuses
    one in templates, helpers, controllers and scripts; a glyph helper (`rail_icon`,
    `folder_glyph`) or a word stands in. Data is no exception: an addon manifest's emoji `icon` is
    never drawn, the Tools gallery shows a monogram tile instead (`tools/home/_addon_mark`), and
    `tools_gallery_test.rb` reads the rendered gallery, since no source scan can see a manifest.
    **Words are the UI face (`--font-ui`, Libre Franklin) and mono (`--font-mono`, Courier Prime) is
    for data and for the caps label** — crumbs, table heads, group heads, plate heads and a field's
    label, mono 700 12px (11 over a field), tracked .08em, uppercase (Shop manual spec §5; the
    2026-09-10 cohesion decision 4 kept labels in the UI face until 2026-11-19). Text selection (`::selection`) and the code
    editor's selection and active-line tints are browser text affordances, not UI selection state,
    and keep accent tints. The light values are the Shop manual spec's
    (`docs/superpowers/specs/2026-11-18-shop-manual-redesign-design.md` §5); Graphite's are still
    the Tinkerex Design System artifact's.

**Every timestamp is `ApplicationHelper#time_at`, in the app's one zone (`config.time_zone`, from `TIME_ZONE`), and its three styles are the whole vocabulary** — `:absolute` `2026-11-01 22:09`, `:date`, `:relative` "10 minutes ago" — always a `<time datetime>`, with the full time and zone in `title` (a Date has no more to show); no template calls `strftime`, `to_fs(` or `time_ago_in_words`, and the History panel prints the server's `at_label`, never `toLocaleString()` (UX audit D1, `time_format_test.rb`).

The Files page's own search (`FilesController#index`, `?q=`; the strip's box drives `/search`) is
flat, whole-library
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
    what "on demand" means. **A panel the KIND's preset hides while it holds rows is named under the
    stats line, never redrawn** ("Also in this project: Bill of materials (3 lines) · 1 release",
    2026-11-02, `Maker::ProjectHiddenRows`): one COUNT per such panel, because #show skips a hidden
    panel's loads (in the editor too, so the line's editor link lands on a ghosted, EMPTY panel whose
    rows appear after Show and Save). A panel the MAKER hid is not named and still costs no query —
    they hid it themselves, in the layout editor — and the stats line counts only panels on the page. Every panel's composer
    is a `details.composer` in its `.panel-head`, opened by "Add…", its submit naming the thing and
    never `primary`.

**A PANEL'S VIEW BUTTONS SWITCH IT IN PLACE, AND THE DOOR STILL RENDERS NOTHING (2026-11-16).** A
press on the page posts `in_place` (`projects/_view_toggle`). `Projects::PanelsController#in_place`
then redirects to the page NAMING THE PANEL, and `ProjectsController#show` answers a request that
takes Turbo Streams with a `replace` of that panel's section, whose id is its layout key. Turbo
follows a form's redirect with the form's own Accept header, so one section is replaced and the
rest of the document stays the elements it was: another panel's browser keeps the folder it was in,
an open section stays open, the window does not move. The plain redirect it replaces made Turbo
visit the page again and redraw every panel. Five things not to undo. **The door never renders a
panel**: a panel needs everything `#show` loads, and a second copy of those loads is how a panel
would come back different from the page's own. **`panel` decides, never the Accept header alone**:
Turbo sends the stream type on EVERY form's redirect to this page. **A key the page cannot switch
gets the page** (unknown, hidden, a panel with no views, the editor), because a stream naming a
section the page does not hold changes nothing and says nothing. **A folder going into or out of
the browser redraws the Files panel too** (`files=1`): its Recently changed row leaves out a browsed
folder's files (`#dirs_without_tiles`). The switched panel's stream comes first, so its pressed
button, the only one marked `autofocus`, takes the focus; a page load marks none. **The editor's
copy of the buttons sends no `in_place`**: its slots hold a draft view, and a stream replacing the
panel under one would leave the two disagreeing. With no JavaScript the same form lands on the page
at the panel's anchor. `project_panels_test.rb` pins the wire; `test/system/panel_view_switch_test.rb`
pins what the page does with it.

## The front door

15. **Signed out, `/` has two answers and demo mode picks; signed in it is Home.** On the public
    demo's box (`Tinkerex::Landing.enabled?`, which is `Tinkerex::Demo.enabled?`) it is the marketing
    landing; anywhere else it is the plain sign-in card, because a self-hosted box has nobody to pitch
    to and the landing's one action IS the demo. `config/routes.rb` declares three roots in this
    order: the landing (`landing_root`, a request-time constraint on demo mode, written as a nested
    `constraints` block because a callable `constraints:` option on the route REPLACES the enclosing
    `unauthenticated` and sends a signed-in user to the landing, which 500s), the card
    (`unauthenticated_root`), then `root` — any other order and a visitor meets the wrong door
    (`test/integration/web/landing_test.rb`). `LandingsController` stands on `ActionController::Base`,
    never on `ApplicationController` with a skip (`architecture_invariants_test.rb`'s default-deny),
    and outside `Public::` because its demo button's CSRF token writes the session. The primary, an
    ink fill, is Try the demo while `Tinkerex::Demo.available?`, else Install — exactly once either way (rule 13; the Try the demo state in
    `accent_spend_test.rb`, both states in `landing_test.rb`). `/users/sign_in` is the plain card everywhere. **The wall's twelve tiles
    are the app's own renders** of twelve files of the owner's `catan` project, which `db/seeds/demo`
    holds whole (the seed's 70 MB budget is that decision, `demo_reset_test.rb`), written by `bin/rails landing:wall`
    (`Tinkerex::Landing`, which refuses rather than skips); **the four feature crops are the app
    photographed** by `script/landing/capture_crops.rb`, the demo banner removed and nothing else
    touched. Retake both when the renderers or the pages move; never draw or edit them.
    `test/system/landing_test.rb` reads the computed width, every tile's load and the 375px overflow,
    which a request test cannot see.
