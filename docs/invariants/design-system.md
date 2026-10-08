# Invariants — the web shell and design system (CLAUDE.md §14m)

§14d material for the web layer's styling and chrome. Read this before touching
`app/assets/stylesheets/`, `app/views/layouts/`, `app/helpers/shell_helper.rb`, the `theme` / `rail` /
`toast` Stimulus controllers, or any template's class names. Spec:
`docs/superpowers/specs/2026-09-03-web-shell-and-design-system-design.md`; the story is the arc that
landed it (§11).

## The cascade

1. **`application.css` opens with `@layer tokens, base, components, shell, pages;` and every rule of
   ours sits in one of those layers.** The first `@layer` statement the browser meets fixes the order
   for the document, so the statement must be the first rule of the first sheet the layout links.
2. **`vendor-overrides.css` is the ONE unlayered sheet, linked last.** An unlayered rule outranks
   every layered one, which is why the Lexxy / CodeMirror / spreadsheet skins have to live outside
   the layers to beat those libraries' own unlayered CSS — and why nothing else may. The CodeMirror
   editors are the one place the dark theme is a JS extension rather than CSS: `lib/codemirror_theme.js`
   adds `oneDark` (in the ONE vendored bundle, §14d) when `html[data-theme]` resolves dark, and
   `vendor-overrides.css` paints only the light editor, its `[data-theme="system"]` rules wrapped in
   `@media (prefers-color-scheme: light)` so CSS and JS ask the same question.
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
   `ShellHelper#ui_theme`, `theme_controller.js#current`, `lib/codemirror_theme.js#darkThemeActive`
   and the PWA manifest. A colour whose only definition sits inside a theme block never applies in
   the other state.
5. **Drawing colours stay literal**: Measure's layer strokes and the hover/selected pair (pinned by
   computed style in the Measure system tests), the tray top-view fills, LightBurn swatches, and the
   thumbnail stage. `--thumb-stage` is white in BOTH themes because rendered previews are opaque
   white PNGs — anything that paints onto that stage uses `--thumb-ink`, which does not flip
   either (the model file tree shipped light-on-white once for lack of one). A user's PHOTO is not
   a render and sits on `--photo-stage` (`.thumb.photo`), never letterboxed in white.
6. **A token flip is a review question.** Migrating a light-only rule verbatim can break it: `color:
   #fff` over `var(--fg)` was readable when `--fg` was near-black. Pair literals with the ink token
   (`--accent-ink`, which is near-black in the dark theme) or drop the copy in favour of the
   component.

## The shell

7. **Theme and rail state are cookies (`theme` ∈ light|dark|system, `rail` ∈ expanded|collapsed),
   rendered by `ShellHelper` into the first byte of HTML — never an inline script.** The CSP nonces
   `script-src`, and a pre-paint script is the thing not to add. The JS writes them with `path=/`,
   a one-year `max-age` and `samesite=lax`; the server trusts nothing beyond the enum.
8. **The sidebar lights exactly one link, and `ShellHelper#sidebar_current` alone decides which.**
   `rail_section` still maps `controller_path`'s FIRST segment (a new web controller needs a
   `SECTIONS` entry or its pages light nothing), and `sidebar_current` refines it: the deepest
   pinned folder on the Files breadcrumb beats Library, a listed project's own link beats All
   projects, and an unlisted one lights All projects. The sidebar and the phone tab bar both read
   it; `shell_layout_test.rb` pins one lit link per page.
9. **Breadcrumbs render in the top bar through `content_for :crumbs`**, with the page title as the
   fallback; page-level actions stay in the page's `.page-head`, so the top bar carries no
   per-page control.
10. **Only `.flash-stack > .flash` floats.** `projects/_tasks` renders an inline
    `p.flash-alert.task-error` and two forms render `div.form-errors.flash-alert`; they must stay
    inline, so the fixed positioning lives on the stack container, not on the class.
11. **No page scrolls sideways at 375px** (`test/system/shell_test.rb`). Tables drop columns
    through the `col-*` classes `files/_list.html.erb` carries; anything that must keep its width
    (code, diffs, the Measure stage, the spreadsheet) scrolls inside its own `overflow-x: auto`
    container; long names get `overflow-wrap: anywhere`.

## Contracts a restyle may not break

12. **Class names are a contract: restyle, never rename.** The selectors the tests pin (spec §10),
    `main.container` / `.container-wide` (the addon host page opts in), `.current-project select`
    (until slice 4 of the 2026-10-08 redesign retires the current project)
    and `form[action=current_project_path] select[name=project_id]` (the current-project card keeps
    the old switcher's form), `.flash-notice` / `.flash-alert`, and the 52 classes the addon bundles
    in `chaim354/tinkerex-addons` build their own markup with (`addons.md`'s host contract; the
    list is in spec §10). Fonts are self-hosted under `app/assets/fonts` with the OFL text beside
    them because `font_src` is `:self`; `@font-face` `url()`s are relative to `application.css`'s
    logical path and Propshaft fingerprints them (`shell_layout_test.rb` fetches each).

13. **The accent is spent once per screen; selection is ink.** `--accent` fills the one primary
    action and marks the current project (where that action lands); `.btn.outline` ("Set as
    current") is the one secondary control allowed it, because it acts on that destination. Links,
    selected chips,
    toggles, tabs, the file-chooser selection and the active rail item use `--fg`. Status carries
    its word, never colour alone (`.flash::before`, badge labels). Text on an accent fill is
    `--accent-ink` (near-black in the dark theme), never a literal white. `components.css` and
    `shell.css` name tokens, never colour literals (`css_hygiene_test.rb`); drawing colours stay
    literal in `pages/` (rule 5). Labels stay Plex Sans and mono stays for data (the 2026-09-10
    cohesion decisions 4 and 5). Text selection (`::selection`) and the code editor's selection and
    active-line tints are browser text affordances, not UI selection state, and keep accent tints.
    The values are the Tinkerex Design System artifact.

The library search that the top bar drives (`FilesController#index`, `?q=`) is flat, whole-library
and case-insensitive; its `LIKE` carries `ESCAPE '\'` because SQLite has no default escape
character and `sanitize_sql_like` alone is inert there — measured, and the same rule `LIKE_EXT`
already records. Guards: `files_search_test.rb`, `page_query_budget_test.rb`.
