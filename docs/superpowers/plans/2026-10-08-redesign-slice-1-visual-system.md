# Redesign slice 1 — the visual system — Implementation Plan

> **For agentic workers:** in this repo, execute with **`.claude/commands/execute-plan.md`** (CLAUDE.md
> §15: batched by file, parallel where independent, one capped quality review per task). It
> overrides the generic superpowers subagent loop. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the redesign's visual system (Paper/Graphite themes, safety-orange accent spent
once, 14px type, ink selection, square stages) to today's page structure, with light as the
default theme.

**Architecture:** Restyle only, no structural change. Token **names** stay those in
`application.css`, so every page sheet keeps working; values change and a few tokens are added. The
theme default flips from dark to light in the four places that decide it (`ShellHelper`, the theme
controller, the CodeMirror theme switch, the PWA manifest). Components and the shell are restyled
rule by rule in place, keeping every class name and every comment's decision record. The 📁 emoji
becomes the rail's folder line icon.

**Tech Stack:** Rails 8, Propshaft, plain CSS cascade layers, Stimulus, Minitest (request and
system tests), headless Chrome for system tests.

**Spec:** `docs/superpowers/specs/2026-10-08-structural-redesign-design.md` (slice 1 of §11). The
visual source is the **Tinkerex Design System** artifact
(`https://claude.ai/artifact/GUSYE99yUak6g9TzwsXGVR`); every value this plan writes is copied here,
so the plan does not depend on opening it.

---

## Roadmap: the seven slices

Only slice 1 is planned in full here. Each later slice gets its own plan when it is next, written
against the code as it stands after the slices before it. They change the shell, the files
controller and the tools controller in ways a plan written today would have to guess at.

| slice | plan | spec section |
|---|---|---|
| 1. Visual system | **this document** | §2 (open questions, now answered), design system artifact |
| 2. Shell: places sidebar, top bar New and Upload, pins | written when slice 1 merges | §4, §9.1 (pins) |
| 3. Library inspector and workspace frame | after 2 | §5.1–5.3 |
| 4. Folder destinations (retire the current project) | after 3, plus the addons-repo check | §7, §8, §9.1 |
| 5. Models fold-in | after 3 | §5.4 |
| 6. Project hub defaults and Recent | after 2 | §6, §7 |
| 7. Inventory on demand and cleanup | after 4 | §7, §9.1 |

## Decisions this plan applies (answered 2026-10-08)

- **Light ("Paper") is the default theme.** An absent or junk `theme` cookie means `light`.
- **Safety orange** replaces amber: `#c2410c` (Paper) / `#ff7a33` (Graphite).
- **Library tiles are square, at least 160px wide.**
- **Mono means data** (UI-cohesion decision 4, 2026-09-10, kept): group heads, table headers, meta
  keys, badges and tag chips stay **Plex Sans**. Mono is for sizes, dates, paths, hashes and counts
  only. The design system artifact's `label` style is corrected to match.
- **The photo stage is styled, not yet applied.** `.thumb.photo` and `--photo-stage` land here;
  which tiles wear `.photo` (a user's photo, never a screenshot or a render) is decided with the
  inspector in slice 3, where the node's type is already resolved.
- **One pill vocabulary** (cohesion decision 5, kept): chips, tag chips and badges share
  `--font-ui` and the same casing rules. `text-transform: capitalize` stays gone, and `.tag-chip`
  keeps `lowercase`.

## Files

| file | change | task |
|---|---|---|
| `app/assets/stylesheets/application.css` | the token sets (Paper on `:root`, Graphite on `[data-theme="dark"]` and dark-resolving `system`), the base rules | 1 |
| `app/helpers/shell_helper.rb` | `THEMES` order, `ui_theme` default, `theme_color_hex`, `color_scheme_meta`; the new `folder_glyph` | 1, 4 |
| `app/javascript/controllers/theme_controller.js` | cycle order, metas, default | 1 |
| `app/javascript/lib/codemirror_theme.js` | `darkThemeActive` defaults to light | 1 |
| `app/assets/stylesheets/vendor-overrides.css` | comment, Lexxy link and focus colours | 1 |
| `app/views/pwa/manifest.json.erb` | theme and background colours | 1 |
| `test/integration/web/shell_layout_test.rb`, `test/integration/web/settings_hub_test.rb`, `test/system/shell_test.rb`, `test/system/settings_theme_test.rb`, `test/system/code_theme_test.rb` | the default-theme assertions | 1 |
| `test/css_hygiene_test.rb` | new guard: no colour literals in `components.css` or `shell.css` | 2 |
| `app/assets/stylesheets/components.css` | rule-by-rule restyle | 2 |
| `app/assets/stylesheets/shell.css` | rule-by-rule restyle | 3 |
| `app/assets/stylesheets/pages/files.css` | square 160px tiles, left-aligned sub-line | 4 |
| `app/views/files/_grid.html.erb`, `app/views/files/_list.html.erb`, `app/views/trash/index.html.erb`, `app/views/shared/_folder_field.html.erb` | 📁 → `folder_glyph` | 4 |
| `test/integration/web/folder_nav_test.rb` + five Files tests' stale `delete_prefix("📁 ")` | the glyph assertions | 4 |
| `docs/invariants/design-system.md` | rules 4, 5, 6 and a new rule on accent and selection | 5 |

**Dependencies:** Task 1 first (it defines the tokens the rest use). Tasks 2, 3 and 4 touch
disjoint files and can run **in parallel** after it. Task 4's CSS for `.folder-glyph` lives in
`components.css` (Task 2), so Task 4's view changes render unstyled until Task 2 lands, which is
harmless. Task 5 last.

**Branch:** `claude/redesign-slice-1`, cut from `claude/structural-redesign-spec` (which carries the
spec and this plan), or from `origin/main` once the spec PR has merged.

**Running tests:** a bare `bin/rails test` needs a library path or 187 tests error. Use
`LIBRARY_PATH=$(mktemp -d) bin/rails test <files>` for single files, and bare `bin/ci` for the
close-out.

---

### Task 1: Flip the default theme and install the tokens

**Files:**
- Modify: `app/assets/stylesheets/application.css` (the `@layer tokens` and `@layer base` blocks)
- Modify: `app/helpers/shell_helper.rb:6`, `:44-50`, `:125-133`
- Modify: `app/javascript/controllers/theme_controller.js:1-58`
- Modify: `app/javascript/lib/codemirror_theme.js:1-18`
- Modify: `app/assets/stylesheets/vendor-overrides.css` (Lexxy block, CodeMirror comment)
- Modify: `app/views/pwa/manifest.json.erb:20-21`
- Test: `test/integration/web/shell_layout_test.rb:94-114`, `test/integration/web/settings_hub_test.rb:70-97`,
  `test/system/shell_test.rb:43-61`, `test/system/settings_theme_test.rb:18-55`, `test/system/code_theme_test.rb:1-42`

- [ ] **Step 1: Rewrite the request test for the theme default**

In `test/integration/web/shell_layout_test.rb`, replace the whole test `"the theme comes from the
cookie and defaults to dark"` (lines 94–114) with:

```ruby
    test "the theme comes from the cookie and defaults to light" do
      get files_path
      assert_select "html[data-theme='light']"
      assert_select "meta[name='theme-color'][content='#f4f2ed']"
      assert_select "meta[name='color-scheme'][content='light']"

      cookies[:theme] = "dark"
      get files_path
      assert_select "html[data-theme='dark']"
      assert_select "meta[name='theme-color'][content='#141512']"
      assert_select "meta[name='color-scheme'][content='dark']"

      cookies[:theme] = "system"
      get files_path
      assert_select "html[data-theme='system']"
      assert_select "meta[name='theme-color'][content='#f4f2ed']"
      assert_select "meta[name='color-scheme'][content='light dark']"

      cookies[:theme] = "purple"
      get files_path
      assert_select "html[data-theme='light']"
    end
```

In `test/integration/web/settings_hub_test.rb`, change lines 70–71 to:

```ruby
      # cookies[:theme] is unset -- ShellHelper#ui_theme's default, "light".
      assert_select ".settings-fact", text: /light/
```

and replace lines 88–97 of `"the theme row is a three-way choice"` (from the first
`aria-pressed` assertion to the end of the test) with:

```ruby
      assert_select ".theme-choice button[data-theme-theme-param='light'][aria-pressed='true']"
      assert_select ".theme-choice button[data-theme-theme-param='dark'][aria-pressed='false']"
      assert_select ".theme-choice button[data-theme-theme-param='system'][aria-pressed='false']"

      cookies[:theme] = "dark"
      get settings_path

      assert_select ".theme-choice button[data-theme-theme-param='dark'][aria-pressed='true']"
      assert_select ".theme-choice button[data-theme-theme-param='light'][aria-pressed='false']"
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/shell_layout_test.rb test/integration/web/settings_hub_test.rb`
Expected: FAIL. `html[data-theme='light']` is not found (the default is still dark), and the
settings fact reads "Theme: dark".

- [ ] **Step 3: Flip `ShellHelper`**

In `app/helpers/shell_helper.rb`:

Line 6 becomes:

```ruby
  THEMES = %w[light dark system].freeze
```

Replace `ui_theme` (lines 44–50, including its comment) with:

```ruby
  # An unknown or absent cookie is the default, LIGHT ("Paper") since the 2026-10-08 redesign: the
  # library is mostly opaque white renders, and a paper page frames them where a dark one framed
  # white squares. The cookie is client-written (theme_controller.js) and is never trusted for
  # anything but this enum.
  def ui_theme
    value = cookies[:theme].to_s
    THEMES.include?(value) ? value : "light"
  end
```

Replace `theme_color_hex` and `color_scheme_meta` (lines 125–133) with:

```ruby
  # The browser chrome's colour: Graphite's ground for dark, Paper's for light AND for system,
  # because the server cannot see the OS setting and light is the default.
  def theme_color_hex = ui_theme == "dark" ? "#141512" : "#f4f2ed"

  def color_scheme_meta
    case ui_theme
    when "dark" then "dark"
    when "system" then "light dark"
    else "light"
    end
  end
```

- [ ] **Step 4: Replace the tokens and base layers in `application.css`**

Keep the header comment, the `@layer` order statement and the four `@font-face` rules exactly as
they are. Replace the whole `@layer tokens { … }` block with:

```css
@layer tokens {
  /* PAPER IS THE DEFAULT (2026-10-08 redesign): an absent or junk theme cookie renders
     data-theme="light", and :root carries the complete Paper set. Graphite redefines the SAME names
     below; a colour declared only inside a theme block never applies in the other state
     (design-system.md rule 4). Token names are the pre-redesign names on purpose, so every page
     sheet keeps working. Values: the Tinkerex Design System artifact. */
  :root {
    color-scheme: light;
    --bg: #f4f2ed;
    --surface: #fcfbf8;
    --raised: #ebe8e1;
    --line: #dcd8cf;
    --line-strong: #878276;
    --fg: #1b1c19;
    --fg-muted: #5b5c55;
    /* THE ACCENT IS SPENT ONCE PER SCREEN: the one primary action, and the destination it lands
       in. Selection, tabs, links and the active nav item are INK (--fg), never accent. */
    --accent: #c2410c;
    --accent-ink: #ffffff;
    --accent-text: #b23c0b;
    --accent-soft: rgba(194, 65, 12, .12);
    --ok: #24733f;
    --ok-soft: rgba(36, 115, 63, .14);
    --warn: #8a5a00;
    --warn-soft: rgba(138, 90, 0, .14);
    --danger: #b42318;
    --danger-soft: rgba(180, 35, 24, .14);
    --info: #1c5d99;
    --info-soft: rgba(28, 93, 153, .14);
    --focus: var(--accent);
    --shadow-float: 0 8px 24px rgba(27, 28, 25, .14), 0 1px 2px rgba(27, 28, 25, .10);
    --shadow-toggle: 0 1px 2px rgba(27, 28, 25, .12);
    --scrim: rgba(27, 28, 25, .45);
    /* A user's PHOTO is not a render: it sits on a neutral matte, never on the white stage. */
    --photo-stage: #ebe8e1;
    /* Rendered drawings (thumbnails, generator previews, cut sheets) are opaque white PNGs, so
       their stage stays paper-white in both themes; a dark stage would frame a white square.
       Anything painted ON the stage uses --thumb-ink, which does not flip either. */
    --thumb-stage: #ffffff;
    --thumb-ink: #5b5c55;
    /* Aliases for rules migrated from the pre-2026-09 sheets. New rules use the names above. */
    --muted: var(--fg-muted);
    --soft: var(--raised);
    --font-ui: "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif;
    --font-mono: "IBM Plex Mono", ui-monospace, Menlo, monospace;
    --space-1: 4px;
    --space-2: 8px;
    --space-3: 12px;
    --space-4: 16px;
    --space-5: 24px;
    --space-6: 32px;
    --space-7: 48px;
    --space-8: 64px;
    --radius-control: 3px;
    --radius-panel: 5px;
    --radius-float: 8px;
    --radius-pill: 999px;
    --control-height: 32px;
    --control-height-small: 26px;
    --row-height: 44px;
    --container-max: 1360px;
    --prose-measure: 72ch;
    --rail-width: 216px;
    --rail-collapsed-width: 56px;
    --topbar-height: 48px;
    --tabbar-height: 56px;
  }
  :root[data-theme="dark"] {
    color-scheme: dark;
    --bg: #141512;
    --surface: #1b1c19;
    --raised: #252622;
    --line: #32332d;
    --line-strong: #74756c;
    --fg: #ecebe5;
    --fg-muted: #a3a299;
    --accent: #ff7a33;
    --accent-ink: #1d0c02;
    --accent-text: #ff8f52;
    --accent-soft: rgba(255, 122, 51, .14);
    --ok: #56c27f;
    --ok-soft: rgba(86, 194, 127, .14);
    --warn: #e3a73d;
    --warn-soft: rgba(227, 167, 61, .14);
    --danger: #f36c5c;
    --danger-soft: rgba(243, 108, 92, .14);
    --info: #6fb2f0;
    --info-soft: rgba(111, 178, 240, .14);
    --shadow-float: 0 10px 30px rgba(0, 0, 0, .55), 0 1px 2px rgba(0, 0, 0, .4);
    --shadow-toggle: 0 1px 2px rgba(0, 0, 0, .5);
    --scrim: rgba(0, 0, 0, .6);
    --photo-stage: #0e0f0c;
  }
  @media (prefers-color-scheme: dark) {
    :root[data-theme="system"] {
      color-scheme: dark;
      --bg: #141512;
      --surface: #1b1c19;
      --raised: #252622;
      --line: #32332d;
      --line-strong: #74756c;
      --fg: #ecebe5;
      --fg-muted: #a3a299;
      --accent: #ff7a33;
      --accent-ink: #1d0c02;
      --accent-text: #ff8f52;
      --accent-soft: rgba(255, 122, 51, .14);
      --ok: #56c27f;
      --ok-soft: rgba(86, 194, 127, .14);
      --warn: #e3a73d;
      --warn-soft: rgba(227, 167, 61, .14);
      --danger: #f36c5c;
      --danger-soft: rgba(243, 108, 92, .14);
      --info: #6fb2f0;
      --info-soft: rgba(111, 178, 240, .14);
      --shadow-float: 0 10px 30px rgba(0, 0, 0, .55), 0 1px 2px rgba(0, 0, 0, .4);
      --shadow-toggle: 0 1px 2px rgba(0, 0, 0, .5);
      --scrim: rgba(0, 0, 0, .6);
      --photo-stage: #0e0f0c;
    }
  }
}
```

In the `@layer base` block, leave the four `@font-face` rules and the box-sizing, `html`,
`:focus-visible`, `::selection` and reduced-motion rules as they are, and replace these rules:

```css
  body {
    margin: 0; background: var(--bg); color: var(--fg);
    font: 400 14px/21px var(--font-ui);
  }
  /* Links are INK, not accent (the accent is spent on the one action). Navigation links (file
     names, crumbs) underline on hover; links inside prose are always underlined (.prose a). */
  a { color: var(--fg); text-decoration: none; }
  a:hover { text-decoration: underline; text-decoration-color: var(--line-strong); text-underline-offset: 3px; }
  h1, h2, h3 { margin: 0; text-wrap: balance; }
  h1 { font-size: 20px; line-height: 26px; font-weight: 600; letter-spacing: -0.01em; }
  h2 { font-size: 16px; line-height: 22px; font-weight: 600; }
  h3 { font-size: 14px; line-height: 20px; font-weight: 600; }
  p { margin: 0 0 8px; }
  code, kbd, pre, .mono { font-family: var(--font-mono); font-size: 13px; line-height: 20px; }
  .muted { color: var(--fg-muted); }
  .num { text-align: right; font-family: var(--font-mono); font-size: 12px; font-variant-numeric: tabular-nums; }
  .prose { max-width: var(--prose-measure); font-size: 15px; line-height: 24px; }
  .prose a { text-decoration: underline; text-decoration-color: var(--line-strong); text-underline-offset: 3px; }
  .prose a:hover { text-decoration-color: var(--fg); }
```

- [ ] **Step 5: Flip the theme controller**

In `app/javascript/controllers/theme_controller.js`, replace lines 1–12 (the header comment, `ORDER`
and `META`) with:

```js
import { Controller } from "@hotwired/stimulus"

// The theme button in the rail (spec §5.7), and — stage 2, S2-6 — the three-way choice on the
// settings page. Both write the same three states: light -> dark -> system in the rail (cycle),
// or pick one directly on the settings row (choose). Either way this stamps the choice on
// <html data-theme> for this page and writes the `theme` cookie so the layout renders the next
// page with it already applied (no flash, no inline script). ShellHelper#ui_theme treats any
// other cookie value as LIGHT, the default since the 2026-10-08 redesign. The rail's button and
// the settings row are TWO SEPARATE controller instances (each is its own data-controller="theme"),
// so each renders only its own label/option targets -- the rail's label updates on the rail's own
// next render, not from a click on the settings row.
const ORDER = ["light", "dark", "system"]
// theme-color mirrors ShellHelper#theme_color_hex: Paper's ground for light and system, Graphite's
// for dark.
const META = { light: ["light", "#f4f2ed"], dark: ["dark", "#141512"], system: ["light dark", "#f4f2ed"] }
```

Change the comment on `choose` so its last line reads `ever writing a cookie value
ShellHelper#ui_theme would then have to treat as light anyway.`, and change `current()` to:

```js
  current() {
    const value = document.documentElement.dataset.theme
    return ORDER.includes(value) ? value : "light"
  }
```

- [ ] **Step 6: Flip the CodeMirror theme switch**

In `app/javascript/lib/codemirror_theme.js`, replace lines 1–18 (the header comment through the end
of `darkThemeActive`) with:

```js
// Which CodeMirror theme a page wants, read from the same attribute the layout stamps
// (ShellHelper#ui_theme): "dark" and "system"-resolving-to-dark get oneDark; "light" gets
// CodeMirror's default (this app's vendor-overrides paint the chrome). One place, three editors.
//
// READ AT MOUNT, NOT WATCHED. theme_controller.js writes the cookie and flips
// html[data-theme] live, so an editor already on screen keeps the theme it mounted with until
// the page is next rendered. Following the flip means a Compartment per view and a listener per
// controller; the trade is deliberate and the fix, if it is ever wanted, is that — not a
// reconfigure bolted onto one of the three.
//
// THE DEFAULT IS LIGHT (2026-10-08), matching ui_theme's own rule: an absent or junk cookie means
// light, and a junk value never reaches this attribute anyway (the server only ever writes the
// enum).
export function darkThemeActive() {
  const theme = document.documentElement.dataset.theme
  if (theme === "dark") return true
  if (theme === "system") return window.matchMedia("(prefers-color-scheme: dark)").matches
  return false
}
```

- [ ] **Step 7: Update `vendor-overrides.css` and the PWA manifest**

In `app/assets/stylesheets/vendor-overrides.css`, replace

```css
lexxy-editor:focus-within { border-color: var(--accent); }
```

with

```css
lexxy-editor:focus-within { border-color: var(--fg); }
```

and replace

```css
.lexxy-content a { color: var(--accent); }
```

with

```css
/* Links are ink (design-system.md rule 13): the accent is spent on the one action. */
.lexxy-content a { color: var(--fg); text-decoration: underline; text-decoration-color: var(--line-strong); text-underline-offset: 3px; }
```

The CodeMirror painting rules stay exactly as they are. `:root[data-theme="light"]` now also
covers the default, because `ui_theme` renders `light` for an absent cookie. In the comment above
them, change "under the DARK theme app/javascript/lib/codemirror_theme.js adds oneDark" to "under
the dark theme, or `system` resolving dark, app/javascript/lib/codemirror_theme.js adds oneDark",
so it no longer reads as if dark were the default.

In `app/views/pwa/manifest.json.erb`, lines 20–21 become:

```erb
  "theme_color": "#fcfbf8",
  "background_color": "#f4f2ed"
```

- [ ] **Step 8: Run the request tests to verify they pass**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/shell_layout_test.rb test/integration/web/settings_hub_test.rb`
Expected: PASS, 0 failures.

- [ ] **Step 9: Rewrite the three system tests**

In `test/system/shell_test.rb`, replace the test `"the theme button cycles dark, light, system and
persists"` (lines 43–61) with:

```ruby
  test "the theme button cycles light, dark, system and persists" do
    visit files_path
    theme = -> { page.evaluate_script("document.documentElement.dataset.theme") }
    assert_equal "light", theme.call

    find("aside.rail [data-action='theme#cycle']").click
    assert_equal "dark", theme.call
    visit files_path
    assert_equal "dark", theme.call
    assert_selector "aside.rail [data-action='theme#cycle']", text: "Theme: dark"

    find("aside.rail [data-action='theme#cycle']").click
    assert_equal "system", theme.call
    find("aside.rail [data-action='theme#cycle']").click
    assert_equal "light", theme.call
    visit files_path
    assert_equal "light", theme.call
    assert_no_console_errors
  end
```

In `test/system/settings_theme_test.rb`, inside the one test:
- `assert_equal "dark", theme.call` (first assertion) becomes `assert_equal "light", theme.call`;
- the first `aria-pressed='true'` assertion names `light`;
- the click, the two following assertions and the cookie read use `dark` instead of `light`;
- after the reload, `text: "Theme: light"` becomes `text: "Theme: dark"`, and the pressed button
  is `dark`.

The `system` click at the end is unchanged. In the MUTATION-CHECKED comment, replace "line 25's" and
"line 26's" with "the first DOM assertion's" and "the cookie read's", and "flips to \"light\"" with
"flips to \"dark\"", so the comment survives the renumbering.

In `test/system/code_theme_test.rb`, replace the header comment's first sentence and the whole
test with:

```ruby
# The source viewer follows the theme (spec §3, §13): under the default light theme it keeps this
# app's own surface (--surface, Paper: #fcfbf8, rgb(252, 251, 248)); under the dark theme it is
# painted by oneDark (its ground is #282c34, rgb(40, 44, 52)). Asserting a computed colour rather
# than a class, because CodeMirror's theme classes are generated names (ͼ-prefixed) that change
# between builds.
```

```ruby
  test "the editor is light by default and dark under the dark theme" do
    visit file_path(@node.node_id)
    assert_selector ".cm-editor"
    assert_equal "rgb(252, 251, 248)", editor_background

    page.execute_script("document.cookie = 'theme=dark; path=/; max-age=31536000; samesite=lax'")
    visit file_path(@node.node_id)
    assert_selector ".cm-editor"
    assert_equal "rgb(40, 44, 52)", editor_background
    assert_no_console_errors
  ensure
    page.execute_script("document.cookie = 'theme=light; path=/; max-age=31536000; samesite=lax'")
  end
```

- [ ] **Step 10: Run the system tests to verify they pass**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/shell_test.rb test/system/settings_theme_test.rb test/system/code_theme_test.rb`
Expected: PASS, 0 failures.

- [ ] **Step 11: Mutation-check the default (§15)**

1. In `shell_helper.rb`, change `: "light"` in `ui_theme` back to `: "dark"`. Run
   `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/shell_layout_test.rb`. Expected:
   FAIL on `html[data-theme='light']`. Restore with `git checkout -- app/helpers/shell_helper.rb`
   and re-apply Step 3. Better: make the mutation by hand and undo it by hand, because the file has
   uncommitted changes. Then run `rm -rf tmp/cache/bootsnap*`, since bootsnap can mask an
   equal-length restore.
2. In `codemirror_theme.js`, change the final `return false` to `return true`. Run
   `code_theme_test.rb`. Expected: FAIL with `rgb(40, 44, 52)` where `rgb(252, 251, 248)` was
   expected. Undo by hand.

Report the actual failure output of both.

- [ ] **Step 12: Sweep every description of the old default**

Run: `grep -rn -i -E "default.*dark|dark.*default|as dark|means dark|dark -> light" app config lib docs/invariants`
Expected: no hits outside `docs/superpowers/` (dated history, left as written). Fix any that remain
in the same commit.

- [ ] **Step 13: Commit**

```bash
git add app/assets/stylesheets/application.css app/helpers/shell_helper.rb \
  app/javascript/controllers/theme_controller.js app/javascript/lib/codemirror_theme.js \
  app/assets/stylesheets/vendor-overrides.css app/views/pwa/manifest.json.erb \
  test/integration/web/shell_layout_test.rb test/integration/web/settings_hub_test.rb \
  test/system/shell_test.rb test/system/settings_theme_test.rb test/system/code_theme_test.rb
git commit -F <message file>
```

Message subject: `Paper is the default theme, and the redesign's tokens are installed`. Write the
body to a file and use `-F`: zsh runs backticks inside `-m "..."`.

---

### Task 2: Restyle the components

**Files:**
- Test: `test/css_hygiene_test.rb` (one new test)
- Modify: `app/assets/stylesheets/components.css` (rules listed below; every comment stays unless a
  step says otherwise)

- [ ] **Step 1: Write the failing guard: no colour literals in the component and shell sheets**

Append to `test/css_hygiene_test.rb`, before the final `end`:

```ruby
  # --- A COMPONENT OR SHELL RULE NAMES A TOKEN, NEVER A COLOUR (2026-10-08 redesign) -----------
  #
  # The thumbnail ink (#5f6873), the spinner (#d9dde3 / #7a8390) and the file-chooser scrim
  # (rgba(0, 0, 0, .55)) were literals in components.css. Each was right in exactly one theme and
  # a token flip could not reach it. Drawing colours (Measure, LightBurn, the tray top view) are
  # deliberately literal, and they live in pages/, which this guard does not scan. The one allowed
  # literal is inside a data: URI (the select chevron), which cannot read a custom property.
  test "components.css and shell.css name tokens, not colours" do
    %w[components.css shell.css].each do |sheet|
      css = strip_comments(read(sheet)).gsub(/url\("data:[^"]*"\)/, "")
      assert_operator css.length, :>, 1000, "#{sheet} is suspiciously short — the scan is vacuous"
      literals = css.scan(/#\h{3,8}\b|rgba?\([^)]*\)|hsla?\([^)]*\)/)
      assert_empty literals, "#{sheet} carries colour literals #{literals.uniq.inspect}; add a token"
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/css_hygiene_test.rb -n "/name tokens/"`
Expected: FAIL listing `#5f6873`, `#d9dde3`, `#7a8390` and `rgba(0, 0, 0, .55)` for components.css.

- [ ] **Step 3: Restyle `components.css`, rule by rule**

Each item gives the exact current line or lines and its replacement. Where a rule spans lines,
replace the whole rule. Leave unlisted rules and every comment as they are, except the three
comment edits named at the end.

**Buttons.**

```css
/* was lines 9-14 */
  .btn, input[type="submit"], .upload-btn span, details.composer > summary {
    display: inline-flex; align-items: center; justify-content: center; gap: var(--space-2);
    min-height: var(--control-height); padding: 0 14px; border-radius: var(--radius-control);
    border: 1px solid var(--line-strong); background: var(--surface); color: var(--fg);
    font: 500 14px/1 var(--font-ui); text-decoration: none; cursor: pointer; white-space: nowrap;
    transition: background-color .12s, border-color .12s;
  }
/* was line 15 */
  .btn:hover, input[type="submit"]:hover, .upload-btn span:hover, details.composer > summary:hover { background: var(--raised); text-decoration: none; }
  .btn svg { width: 16px; height: 16px; flex: 0 0 auto; }
/* was line 30 */
  .btn.danger:hover { background: var(--danger-soft); }
/* was line 35 */
  .btn.outline { background: transparent; border-color: var(--accent); color: var(--accent-text); }
/* was line 37 */
  .btn.small, input[type="submit"].small { min-height: var(--control-height-small); padding: 0 10px; font-size: 13px; }
/* was line 38 */
  .btn.icon { width: var(--control-height); padding: 0; }
  .btn.small.icon { width: var(--control-height-small); }
/* was line 39 */
  .btn:disabled, input[type="submit"]:disabled { opacity: .5; cursor: default; filter: none; }
/* was lines 40-42 */
  .linkbtn {
    background: none; border: 0; padding: 0; color: var(--fg); font: inherit; cursor: pointer;
    text-decoration: underline; text-decoration-color: var(--line-strong); text-underline-offset: 3px;
  }
  .linkbtn:hover { text-decoration-color: var(--fg); }
  .linkbtn.danger { color: var(--danger); text-decoration-color: currentColor; }
/* was line 46 */
  .uploader { display: inline-flex; align-items: center; gap: var(--space-3); }
```

Because the `.upload-btn span:hover` selector joins the neutral hover group, an opted-in uploader's
hover still comes from the `.upload-btn.primary span:hover` rule (line 28), which is more specific.
`accent_spend_test.rb` stays green, and Step 5 runs it.

**Inputs and fields.**

```css
/* was lines 49-54 (selector unchanged) */
  .app-shell input:not([type="checkbox"]):not([type="radio"]):not([type="file"]):not([type="submit"]):not([type="hidden"]),
  .app-shell select, .app-shell textarea,
  .auth-card input:not([type="checkbox"]):not([type="submit"]) {
    font: 400 14px/20px var(--font-ui); color: var(--fg); background: var(--surface);
    border: 1px solid var(--line-strong); border-radius: var(--radius-control);
    padding: 5px 10px; min-height: var(--control-height);
  }
/* was lines 55-56 */
  .app-shell input:hover, .app-shell select:hover, .app-shell textarea:hover,
  .auth-card input:hover { border-color: var(--fg-muted); }
/* was lines 57-58 */
  .app-shell input:focus-visible, .app-shell select:focus-visible, .app-shell textarea:focus-visible,
  .auth-card input:focus-visible { border-color: var(--fg); outline: 2px solid var(--focus); outline-offset: 1px; }
  .app-shell input::placeholder, .app-shell textarea::placeholder { color: var(--fg-muted); }
/* was line 59 */
  .app-shell textarea { min-height: 88px; line-height: 22px; }
/* was lines 60-64 */
  .app-shell select {
    padding-right: 28px; appearance: none;
    background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' fill='none' stroke='%23878276' stroke-width='1.5'/></svg>");
    background-repeat: no-repeat; background-position: right 10px center;
  }
/* was line 65 */
  .field { display: block; margin-bottom: var(--space-4); }
/* was line 66 */
  .field > span, .field > label { display: block; margin-bottom: var(--space-1); font-size: 13px; font-weight: 500; color: var(--fg); }
/* was line 69 */
  .field-inline { display: flex; align-items: center; gap: var(--space-2); margin-top: var(--space-2); font-size: 13px; }
/* was lines 72-75 */
  .form-errors {
    margin-bottom: var(--space-4); padding: 10px 12px; border-radius: var(--radius-control);
    border: 1px solid var(--danger); background: var(--danger-soft); color: var(--fg); font-size: 13px;
  }
```

The chevron's `%23878276` is `--line-strong` (Paper), and it is the one literal the guard allows
because a data URI cannot read a custom property. It passes 3:1 on both themes' `surface`.

**Chips and tags.**

```css
/* was lines 78-82 */
  .chip {
    display: inline-flex; align-items: center; gap: var(--space-1); min-height: var(--control-height-small);
    padding: 0 10px; border-radius: var(--radius-pill); border: 1px solid var(--line);
    background: var(--surface); color: var(--fg-muted); font: 500 13px/1 var(--font-ui); text-decoration: none;
  }
/* was line 84 */
  .chip.active { border-color: var(--fg); background: var(--fg); color: var(--surface); }
/* was line 85 */
  .chip .chip-x { opacity: .75; font-weight: 600; }
/* was line 86 */
  .chip.active:hover { border-color: var(--danger); background: var(--danger-soft); color: var(--danger); }
/* was lines 91-95 */
  .tag-chip {
    display: inline-flex; align-items: center; padding: 2px 8px; border-radius: var(--radius-pill);
    border: 1px solid var(--line); background: var(--surface); color: var(--fg-muted);
    font: 500 12px/16px var(--font-ui); text-transform: lowercase; text-decoration: none;
  }
/* was line 96 */
  .tag-chip:hover { border-color: var(--line-strong); color: var(--fg); text-decoration: none; }
```

**Segmented control.** Delete line 105 (`.view-toggle .toggle + .toggle { border-left: … }`),
because segments now sit on a track with a gap.

```css
/* was line 97 */
  .view-toggle { display: inline-flex; gap: 2px; padding: 2px; border-radius: var(--radius-control); background: var(--raised); }
/* was line 102 */
  .view-toggle .toggle {
    display: inline-flex; align-items: center; gap: 6px; min-height: calc(var(--control-height-small) - 2px); padding: 0 10px;
    border: 0; border-radius: 2px; background: none; color: var(--fg-muted);
    font: 500 13px/1 var(--font-ui); text-decoration: none; cursor: pointer;
  }
/* was line 103 */
  .view-toggle .toggle:hover { color: var(--fg); text-decoration: none; }
/* was line 104 */
  .view-toggle .toggle.active { background: var(--surface); color: var(--fg); box-shadow: var(--shadow-toggle); }
```

`repo_browser_test.rb:179` asserts that the active and idle toggle backgrounds differ:
`surface` versus `transparent`, so it still holds. Step 5 runs it.

**Toolbar, breadcrumb, pager, page head.**

```css
/* was line 106 */
  .toolbar { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-2) var(--space-3); margin: 0 0 var(--space-4); }
/* was line 119 */
  .toolbar-count { font: 400 12px/16px var(--font-mono); font-variant-numeric: tabular-nums; color: var(--fg-muted); white-space: nowrap; }
/* was line 120 */
  .breadcrumb { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; font-size: 14px; min-width: 0; }
/* was line 121 */
  .breadcrumb .sep { color: var(--line-strong); }
/* was line 123 */
  .breadcrumb a:hover { color: var(--fg); text-decoration: none; }
/* was line 125 */
  .pager { display: flex; align-items: center; gap: var(--space-4); margin: 0 0 var(--space-3); font-size: 13px; }
/* was line 127 */
  .page-head { display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: space-between; gap: var(--space-2) var(--space-4); margin: 0 0 var(--space-5); }
/* was line 128 */
  .page-head h1 { font-size: 20px; line-height: 26px; }
/* was line 129 */
  .page-subtitle { margin: 2px 0 0; font-size: 14px; color: var(--fg-muted); flex-basis: 100%; }
```

**Panels.**

```css
/* was line 133 */
  .panel { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-panel); padding: var(--space-4); }
/* was line 134 */
  .panel h2 { margin: 0 0 var(--space-3); font-size: 16px; }
/* was line 135 */
  .panel-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: var(--space-2) var(--space-3); margin-bottom: var(--space-3); }
/* was line 137 */
  .panel-actions { display: flex; flex-wrap: wrap; gap: var(--space-2); align-items: center; }
/* was line 145 */
  .panel-intro { margin: -6px 0 var(--space-3); font-size: 13px; color: var(--fg-muted); }
```

**The editing-mode surfaces stop spending the accent.** The layout bar and a tab slot are a *mode*,
not an action, so they move to `info`. The image picker and link cards select in ink.

```css
/* was lines 166-167 (selector line unchanged, second line replaced) */
  .layout-bar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px 16px;
                padding: 10px 12px; margin: 0 0 12px; border: 1px solid var(--info); border-radius: var(--radius-panel); background: var(--info-soft); }
/* was lines 196-197 */
  .panel-slot--tab { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 10px; padding: 8px 12px;
                     border: 1px solid var(--info); border-radius: var(--radius-panel); background: var(--info-soft); }
/* was line 232 */
  .block-link-card:hover { border-color: var(--fg); text-decoration: none; }
/* was line 254 */
  .image-pick.active { border-color: var(--fg); background: var(--raised); }
```

**Tabs: an ink underline, not a folder tab.**

```css
/* was line 202 */
  .tab-bar { display: flex; gap: var(--space-5); overflow-x: auto; white-space: nowrap; border-bottom: 1px solid var(--line); scrollbar-width: thin; }
/* was lines 203-204 */
  .tab-link { padding: 10px 0; border-bottom: 2px solid transparent; margin-bottom: -1px;
              color: var(--fg-muted); font-weight: 500; text-decoration: none; }
/* was line 206 */
  .tab-link.is-active, .tab-link[aria-selected="true"] { color: var(--fg); border-bottom-color: var(--fg); }
```

**Group heads keep Plex Sans** (cohesion decision 4: mono means data). Only the weight and line
height change:

```css
/* was lines 267-269 */
  .attachment-group-head, .tasks-group h3, .group-head {
    margin: 0 0 var(--space-2); font: 600 11px/16px var(--font-ui); text-transform: uppercase; letter-spacing: .08em; color: var(--fg-muted);
  }
```

**Tables.**

```css
/* was line 272 */
  table.files, .table { width: 100%; border-collapse: collapse; font-size: 14px; }
/* was lines 273-276 */
  table.files th, .table th {
    text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line-strong); white-space: nowrap;
    font: 600 11px/16px var(--font-ui); text-transform: uppercase; letter-spacing: .08em; color: var(--fg-muted);
  }
/* was line 277 */
  table.files td, .table td { height: var(--row-height); padding: 6px 10px; border-bottom: 1px solid var(--line); vertical-align: middle; }
/* was line 282 */
  table.files .num, .table .num { text-align: right; font: 400 12px/16px var(--font-mono); font-variant-numeric: tabular-nums; white-space: nowrap; color: var(--fg-muted); }
/* was line 283 */
  table.files .row-actions { justify-content: flex-end; opacity: 0; transition: opacity .12s; }
/* was line 287 */
  .file-cell { display: flex; align-items: center; gap: var(--space-3); min-width: 0; }
```

**Thumbnails and tiles.** This removes the three literals the guard found.

```css
/* was lines 292-295 */
  .thumb {
    position: relative; display: flex; align-items: center; justify-content: center; overflow: hidden;
    border: 1px solid var(--line); border-radius: var(--radius-control); background: var(--thumb-stage); color: var(--thumb-ink);
  }
/* was line 297 */
  .thumb-icon { font: 500 11px/1 var(--font-mono); letter-spacing: .06em; color: var(--thumb-ink); }
/* was lines 298-301 */
  .thumb-spinner {
    width: 14px; height: 14px; border: 2px solid transparent; border-top-color: var(--thumb-ink); border-right-color: var(--thumb-ink);
    border-radius: 50%; animation: thumb-spin .8s linear infinite;
  }
/* was line 303 */
  table.files .thumb { width: 32px; height: 32px; flex: 0 0 32px; }
/* was lines 304-306 */
  .folder-thumb, .generic-thumb { background: var(--raised); color: var(--fg-muted); }
  .folder-thumb .folder-glyph { width: 40%; height: 40%; }
  .generic-thumb { font: 500 12px/1 var(--font-mono); letter-spacing: .08em; }
  /* A user's PHOTO on a tile: the neutral matte and a crop, never letterboxed in white. */
  .thumb.photo { background: var(--photo-stage); }
  .thumb.photo img { object-fit: cover; }
  /* The folder glyph (ShellHelper#folder_glyph): the rail's `files` icon, inline beside a name. */
  .folder-glyph { width: 16px; height: 16px; flex: 0 0 auto; vertical-align: -3px; }
/* was line 307 */
  .grid-card { display: flex; flex-direction: column; gap: 2px; min-width: 0; color: var(--fg); text-decoration: none; }
  .grid-card .thumb { margin-bottom: var(--space-2); transition: border-color .12s; }
/* was line 309 */
  .grid-card:hover .thumb { border-color: var(--fg); }
/* was line 310 */
  .grid-card .grid-name { font-size: 13px; line-height: 18px; overflow-wrap: anywhere; }
```

**Meta strip.** Keys keep Plex Sans; values stay mono (they are data).

```css
/* was lines 313-316 */
  dl.meta {
    display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 6px var(--space-4); margin: 0 0 var(--space-4);
    padding: 12px var(--space-4); border: 1px solid var(--line); border-radius: var(--radius-panel); background: var(--surface);
  }
/* was line 319 */
  dl.meta dt { font: 600 11px/20px var(--font-ui); text-transform: uppercase; letter-spacing: .08em; color: var(--fg-muted); }
/* was line 320 */
  dl.meta dd { margin: 0; font: 400 13px/20px var(--font-mono); overflow-wrap: anywhere; }
```

**Badges.** These keep Plex Sans and sentence case (cohesion decision 5). The shape squares off, so
a fixed status reads differently from a removable round chip. The colours follow the accent rule:
orange marks only the current project.

```css
/* was lines 335-338 */
  .badge {
    display: inline-flex; align-items: center; padding: 1px 7px; border-radius: var(--radius-control);
    font: 600 12px/18px var(--font-ui); background: var(--raised); color: var(--fg-muted); white-space: nowrap;
  }
/* was line 344 */
  .badge.status-active { background: var(--info-soft); color: var(--info); }
/* was line 346 */
  .badge.status-done { background: var(--ok-soft); color: var(--ok); }
/* was line 347 */
  .badge.project-new { background: var(--info-soft); color: var(--info); text-transform: none; }
/* was line 348 */
  .badge.mstatus-want_to_print { background: var(--info-soft); color: var(--info); }
/* was line 349 */
  .badge.mstatus-printed { background: var(--ok-soft); color: var(--ok); }
/* was line 350 */
  .badge.mstatus-failed { background: var(--danger-soft); color: var(--danger); }
/* was line 351 */
  .badge.current-project-badge { background: var(--accent-soft); color: var(--accent-text); text-transform: none; }
/* was line 352 */
  .badge.low-stock { background: var(--warn-soft); color: var(--warn); text-transform: none; }
/* was line 353 */
  .badge.bom-stock { background: var(--ok-soft); color: var(--ok); text-transform: none; }
/* was line 354 */
  .badge.bom-file { background: var(--info-soft); color: var(--info); text-transform: none; }
/* was line 358 */
  .badge.visibility-public { background: var(--ok-soft); color: var(--ok); }
/* was line 359 */
  .badge.visibility-unlisted { background: var(--warn-soft); color: var(--warn); }
/* was line 371 */
  .badge.changed { background: var(--info-soft); color: var(--info); text-transform: none; }
```

**Empty state, truncation notice, flash.**

```css
/* was line 386 */
  .empty {
    padding: var(--space-7) var(--space-4); text-align: center; color: var(--fg-muted);
    border: 1px dashed var(--line-strong); border-radius: var(--radius-panel); background-color: var(--bg);
    background-image: linear-gradient(var(--line) 1px, transparent 1px), linear-gradient(90deg, var(--line) 1px, transparent 1px);
    background-size: 12px 12px; background-position: -1px -1px;
  }
/* was line 387 */
  .empty.inline { padding: 4px 0; text-align: left; border: 0; background: none; font-size: 13px; }
/* was line 392 */
  .panel .empty { border: 0; padding: 24px 16px; background: none; }
/* was line 396 */
  .truncated { margin: 0 0 var(--space-3); padding: 8px 12px; border-radius: var(--radius-control); background: var(--warn-soft); color: var(--fg); font-size: 13px; }
/* was lines 399-401 */
  .flash { display: flex; align-items: flex-start; gap: var(--space-3); padding: 10px 12px; border-radius: var(--radius-float); border: 1px solid; font-size: 14px; color: var(--fg); background: var(--surface); }
  /* Each toast LEADS WITH ITS WORD: a status is never colour alone (design-system.md rule 13). */
  .flash::before { flex: 0 0 auto; font: 600 11px/21px var(--font-ui); letter-spacing: .08em; text-transform: uppercase; }
  .flash-notice { border-color: var(--ok); background: var(--ok-soft); }
  .flash.flash-notice::before { content: "Done"; color: var(--ok); }
  .flash-alert { border-color: var(--danger); background: var(--danger-soft); }
  .flash.flash-alert::before { content: "Problem"; color: var(--danger); }
```

The `::before` word is scoped to `.flash.flash-*`, so the inline `p.flash-alert.task-error` and
`div.form-errors.flash-alert` (design-system.md rule 10) gain no prefix.

**Menus and popovers.**

```css
/* was lines 407-410 */
  .file-menu {
    position: absolute; z-index: 1000; min-width: 200px; padding: 4px;
    background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-float); box-shadow: var(--shadow-float);
  }
/* was lines 411-414 */
  .file-menu button, .file-menu a {
    display: flex; align-items: center; gap: var(--space-2); width: 100%; min-height: var(--control-height); padding: 0 10px;
    text-align: left; background: none; border: 0; color: var(--fg); font: 400 14px/1 var(--font-ui);
    border-radius: var(--radius-control); cursor: pointer; text-decoration: none; box-sizing: border-box;
  }
/* was lines 429-433 */
  dialog.move-conflict {
    display: block; position: static; width: 100%; max-width: none; margin: 0 0 16px; padding: 12px 14px;
    border: 1px solid var(--line-strong); border-radius: var(--radius-panel);
    background: var(--surface); color: var(--fg);
  }
/* was lines 447-450 */
  .menu-list {
    position: absolute; right: 0; top: calc(100% + 4px); z-index: 50; min-width: 220px; padding: 4px;
    background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-float); box-shadow: var(--shadow-float);
  }
/* was lines 452-456 */
  .menu-item {
    display: flex; align-items: center; gap: var(--space-2); width: 100%; min-height: var(--control-height); padding: 0 10px;
    text-align: left; background: none; border: 0; color: var(--fg); font: 400 14px/1 var(--font-ui);
    border-radius: var(--radius-control); cursor: pointer; text-decoration: none; white-space: nowrap;
  }
  .menu-sep { height: 1px; margin: 4px 6px; background: var(--line); }
```

`dialog.move-conflict` loses its 3px accent left edge. It was the one coloured-left-border card in
the app, and it spent the accent on a notice.

**Folder field and file chooser.**

```css
/* was lines 467-471 */
  .folder-field-btn {
    display: inline-flex; align-items: center; gap: 6px; max-width: 260px; min-height: var(--control-height);
    padding: 0 12px; border: 1px solid var(--line-strong); border-radius: var(--radius-control);
    background: var(--surface); color: var(--fg); font: 400 14px/20px var(--font-ui); cursor: pointer;
  }
/* was line 472 */
  .folder-field-btn:hover { border-color: var(--fg-muted); }
/* was lines 474-477 */
  .filechooser-overlay {
    position: fixed; inset: 0; z-index: 1000; padding: 16px; background: var(--scrim);
    display: flex; align-items: center; justify-content: center;
  }
/* was line 508 */
  .filechooser-row.sel { background: var(--fg); color: var(--surface); }
/* was line 510 */
  .filechooser-row.sel.is-file { color: var(--surface); }
```

**Comment edits** (in the same commit, so the record stays true):
1. The comment above `.tag-chip` (lines 87–89): replace "Smaller and lowercase" with "Smaller,
   lowercase and outlined".
2. The ONE PILL VOCABULARY comment (lines 322–334): append the sentence "Since the 2026-10-08
   redesign a `.badge` is square-shouldered (`--radius-control`) where a `.chip` stays round:
   shape says fixed-versus-removable, face and case stay shared."
3. The visibility comment (lines 356–357): replace "unlisted as the quieter accent" with "unlisted
   as a warning tone, since the accent is reserved for the one action".

- [ ] **Step 4: Run the guard and the hygiene suite**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/css_hygiene_test.rb`
Expected: PASS, every test (the new one included).

- [ ] **Step 5: Run the system tests that read component styles**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/accent_spend_test.rb test/system/file_menu_test.rb test/system/repo_browser_test.rb test/system/projects_models_pages_test.rb test/system/shell_test.rb`
Expected: PASS. `accent_spend_test` keeps its exact table. Nothing in this task fills a control
with the accent that did not already have it.

- [ ] **Step 6: Mutation-check the guard (§15)**

Change `color: var(--thumb-ink)` in the `.thumb-icon` rule to `color: #5f6873`. Run the guard.
Expected: FAIL naming `#5f6873`. Undo by hand. Then put `rgba(0, 0, 0, .55)` back in
`.filechooser-overlay`. Expected: FAIL naming it. Undo. Report both outputs.

- [ ] **Step 7: Look at it**

Start the app (`bin/dev`), sign in, and look at `/files` (grid and list), a file page, `/projects`
and a project, `/tools` and a tool page, `/settings` and `/trash`. Check light, then dark (the rail's
theme button). Things to check:
- One orange control per screen at most.
- Selected chips and toggles are ink, not orange.
- Badges read in both themes.
- Nothing scrolls sideways at a 375px window.

- [ ] **Step 8: Commit**

```bash
git add test/css_hygiene_test.rb app/assets/stylesheets/components.css
git commit -F <message file>
```

Subject: `Components wear the redesign: ink selection, the accent spent once, no colour literals`.

---

### Task 3: Restyle the shell

**Files:**
- Modify: `app/assets/stylesheets/shell.css` (rules listed below; the comments stay)

The Task 2 guard already covers `shell.css`, which has no literals today. This task must not add
any.

- [ ] **Step 1: Restyle `shell.css`, rule by rule**

```css
/* .rail (was lines 7-10) */
  .rail {
    position: sticky; top: 0; height: 100vh; display: flex; flex-direction: column; gap: var(--space-4);
    padding: 14px 8px; background: var(--bg); border-right: 1px solid var(--line); overflow: hidden auto;
  }
/* .brand (was line 11) */
  .brand { display: flex; align-items: center; gap: 10px; padding: 4px 8px; color: var(--fg); font-size: 15px; font-weight: 600; letter-spacing: -0.01em; white-space: nowrap; }
/* .brand-mark (was line 13): an orange square with a paper square cut from its centre */
  .brand-mark { position: relative; width: 18px; height: 18px; flex: 0 0 auto; border-radius: var(--radius-control); background: var(--accent); }
  .brand-mark::after { content: ""; position: absolute; left: 5px; top: 5px; width: 8px; height: 8px; border-radius: 1px; background: var(--bg); }
/* .current-project (was lines 32-36) */
  .current-project {
    display: flex; flex-direction: column; gap: 2px; padding: 10px;
    border-radius: var(--radius-panel); background: var(--accent-soft); border: 1px solid var(--accent);
  }
/* .current-project-label (was line 37): a label, so Plex Sans (cohesion decision 4) */
  .current-project-label { font: 600 11px/16px var(--font-ui); text-transform: uppercase; letter-spacing: .08em; color: var(--accent-text); }
/* .current-project-name (was line 38) */
  .current-project-name { font-size: 14px; font-weight: 600; color: var(--fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
/* .current-project-hint (was line 39) */
  .current-project-hint { font-size: 12px; line-height: 17px; color: var(--fg-muted); }
/* .current-project select (was line 40) */
  .current-project select { margin-top: var(--space-2); width: 100%; min-height: var(--control-height-small); padding: 2px 26px 2px 8px; font-size: 13px; }
/* .rail-nav ul (was line 42) */
  .rail-nav ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 1px; }
/* .rail-link (was lines 43-46) */
  .rail-link {
    position: relative; display: flex; align-items: center; gap: 10px; min-height: 34px; padding: 0 10px;
    border-radius: var(--radius-control); color: var(--fg-muted); font-weight: 500; white-space: nowrap;
  }
/* .rail-link[aria-current] (was line 48): INK, never accent — the accent is the one action */
  .rail-link[aria-current="page"] { color: var(--fg); background: var(--surface); box-shadow: inset 0 0 0 1px var(--line); }
  .rail-link[aria-current="page"]::before { content: ""; position: absolute; left: -8px; top: 8px; bottom: 8px; width: 3px; border-radius: 0 2px 2px 0; background: var(--fg); }
/* .rail-foot (was line 51) */
  .rail-foot { margin-top: auto; display: flex; flex-direction: column; gap: 2px; padding: var(--space-2) 0 0; border-top: 1px solid var(--line); }
/* .rail-btn (was lines 53-57) */
  .rail-btn {
    display: inline-flex; align-items: center; gap: 10px; width: 100%; min-height: 30px; padding: 0 10px;
    background: none; border: 0; border-radius: var(--radius-control); color: var(--fg-muted);
    font: 500 13px/1 var(--font-ui); text-align: left; cursor: pointer;
  }
/* .rail-foot .rail-btn[aria-current] (was line 64) */
  .rail-foot .rail-btn[aria-current="page"] { color: var(--fg); background: var(--surface); }
/* .rail-user (was line 65) */
  .rail-user { padding: 4px 10px; font: 400 12px/16px var(--font-mono); color: var(--fg-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
/* collapsed (was lines 68-69) */
  .rail--collapsed .rail { padding-inline: 8px; }
  .rail--collapsed .brand { justify-content: center; padding: 4px 0; }
/* .topbar (was lines 76-79) */
  .topbar {
    position: sticky; top: 0; z-index: 20; display: flex; align-items: center; gap: var(--space-4);
    min-height: var(--topbar-height); padding: 0 var(--space-5); background: var(--bg); border-bottom: 1px solid var(--line);
  }
/* .topbar-search (was lines 82-85) */
  .topbar-search {
    display: flex; align-items: center; gap: var(--space-2); flex: 0 1 340px; min-width: 160px; height: var(--control-height); padding: 0 10px;
    border: 1px solid var(--line-strong); border-radius: var(--radius-control); background: var(--surface); color: var(--fg-muted);
  }
/* .topbar-search:focus-within (was line 86) */
  .topbar-search:focus-within { border-color: var(--fg); outline: 2px solid var(--focus); outline-offset: 1px; }
/* .topbar-search input (was line 87) */
  .topbar-search input { flex: 1; min-width: 0; min-height: 0; padding: 0; border: 0; background: transparent; color: var(--fg); font: 400 14px/20px var(--font-ui); }
/* .topbar-kbd (was line 90) */
  .topbar-kbd { padding: 2px 5px; border: 1px solid var(--line); border-radius: 2px; font: 500 11px/1 var(--font-mono); color: var(--fg-muted); }
/* main.container (was line 92) */
  main.container { width: 100%; max-width: var(--container-max); margin: 0 auto; padding: var(--space-5) var(--space-5) var(--space-8); }
/* .flash-stack > .flash (was line 99): a floating toast is OPAQUE — the tint layers over surface */
  .flash-stack > .flash { box-shadow: var(--shadow-float); pointer-events: auto; background-color: var(--surface); background-image: linear-gradient(var(--ok-soft), var(--ok-soft)); }
  .flash-stack > .flash-alert { background-image: linear-gradient(var(--danger-soft), var(--danger-soft)); }
/* main.container.auth-main (was line 114) */
  main.container.auth-main { max-width: 440px; padding-top: var(--space-7); }
/* .auth-card (was line 115) */
  .auth-card { padding: var(--space-5); border: 1px solid var(--line); border-radius: var(--radius-panel); background: var(--surface); }
/* #error_explanation (was lines 122-125) */
  #error_explanation {
    margin: 0 0 14px; padding: 10px 12px; border-radius: var(--radius-control);
    border: 1px solid var(--danger); background: var(--danger-soft); color: var(--fg); font-size: 13px;
  }
```

Inside `@media (max-width: 1099px)`, change `.rail { padding-inline: 6px; }` to
`.rail { padding-inline: 8px; }` and `.brand { justify-content: center; padding: 2px 0; }` to
`.brand { justify-content: center; padding: 4px 0; }`.

Inside `@media (max-width: 719px)`:

```css
    .tabbar-link { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 3px; color: var(--fg-muted); font-size: 11px; }
    .tabbar-link[aria-current="page"] { color: var(--fg); font-weight: 600; }
    .topbar-project-label { font: 600 11px/16px var(--font-ui); text-transform: uppercase; letter-spacing: .08em; color: var(--accent-text); }
```

- [ ] **Step 2: Run the shell tests**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/shell_layout_test.rb test/css_hygiene_test.rb test/system/shell_test.rb`
Expected: PASS. `shell_test.rb` includes the 375px no-sideways-scroll sweep and the auth-card
computed width (`main.container.auth-main`, still qualified).

- [ ] **Step 3: Look at it**

With `bin/dev`, check the rail expanded and collapsed, at 1440px, 900px and 375px, in light and
dark. The active rail link is ink with a marker on the rail's edge, and the current-project card is
the only orange in the rail.

- [ ] **Step 4: Commit**

```bash
git add app/assets/stylesheets/shell.css
git commit -F <message file>
```

Subject: `The shell wears the redesign: an ink rail marker, the current project the only orange`.

---

### Task 4: Square tiles and the folder glyph

**Files:**
- Modify: `app/helpers/shell_helper.rb` (add `folder_glyph` after `rail_icon`)
- Modify: `app/assets/stylesheets/pages/files.css` (`.files-grid`, `.files-grid .thumb`, `.grid-sub`)
- Modify: `app/views/files/_grid.html.erb:18`, `app/views/files/_list.html.erb:64-65`,
  `app/views/trash/index.html.erb:38`, `app/views/shared/_folder_field.html.erb:42`
- Test: `test/integration/web/folder_nav_test.rb:52,74`; drop the stale `delete_prefix("📁 ")` in
  `files_type_filter_test.rb:49,58`, `files_sort_test.rb:51`, `files_search_test.rb:31`,
  `files_git_marker_test.rb:57`, `files_pagination_test.rb:39`

- [ ] **Step 1: Write the failing assertions**

In `test/integration/web/folder_nav_test.rb`, in `"root lists only root children, not nested
files"`, replace `assert_select "a", text: "📁 cad"` with:

```ruby
      assert_select "a.dir", text: "cad"
      # The folder glyph is the rail's line icon, never an emoji (design system: no emoji in the
      # interface).
      assert_select "a.dir svg.folder-glyph"
      assert_no_match "📁", response.body
```

In `"opening a folder lists only that folder's children"`, replace `assert_select "a", text: "📁
sub"` with `assert_select "a.dir", text: "sub"`.

- [ ] **Step 2: Run to verify it fails**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/folder_nav_test.rb`
Expected: FAIL. The link text is "📁 cad", and there is no `svg.folder-glyph`.

- [ ] **Step 3: Add the helper**

In `app/helpers/shell_helper.rb`, after `rail_icon`:

```ruby
  # The folder glyph on tiles, list rows, the trash and the folder field: the rail's own `files`
  # path, so a folder looks the same in the nav and in the grid (design system: no emoji in the
  # interface; the 📁 it replaces rendered differently on every OS).
  def folder_glyph
    tag.svg(viewBox: "0 0 16 16", class: "folder-glyph", "aria-hidden": "true") do
      tag.path(d: ICON_PATHS.fetch(:files), fill: "none", stroke: "currentColor",
               "stroke-width": "1.5", "stroke-linejoin": "round", "stroke-linecap": "round")
    end
  end
```

- [ ] **Step 4: Replace the four emoji**

`app/views/files/_grid.html.erb:18`:

```erb
        <span class="thumb folder-thumb" aria-hidden="true"><%= folder_glyph %></span>
```

`app/views/files/_list.html.erb:64-65` (keep the ERB comment above it):

```erb
            <%= link_to files_path(folder: node.node_id), class: "dir",
                        data: folder_menu_data(node.node_id, node.name) do %><%= folder_glyph %> <%= node.name %><% end %>
```

`app/views/trash/index.html.erb:38`:

```erb
              <span class="dir"><%= folder_glyph %> <%= entry.name %></span>
```

`app/views/shared/_folder_field.html.erb:42`:

```erb
    <%= folder_glyph %>
```

The addon test fixture `test/fixtures/addons/boxes/folder_field.js` carries its own 📁. It is the
addon repo's markup, so leave it alone.

- [ ] **Step 5: Square the tiles**

In `app/assets/stylesheets/pages/files.css`, replace:

```css
  .files-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 16px; }
  .files-grid .thumb { width: 100%; height: 140px; }
```

with:

```css
  /* SQUARE STAGES, AT LEAST 160PX (2026-10-08): about four per row where 140px fitted five — the
     redesign trades density for preview, since previews are what the library is used for. */
  .files-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: var(--space-5) var(--space-4); }
  .files-grid .grid-card { align-items: stretch; }
  .files-grid .thumb { width: 100%; height: auto; aspect-ratio: 1 / 1; }
```

and replace:

```css
  .grid-sub { display: block; font: 11px/1.4 var(--font-mono); color: var(--fg-muted); text-align: center; }
```

with:

```css
  .grid-sub { display: block; font: 400 12px/16px var(--font-mono); font-variant-numeric: tabular-nums; color: var(--fg-muted); }
```

`.files-grid .grid-card { align-items: stretch }` matters because a renderable tile is also a
`.file-cell` (`align-items: center`), which centred its name while a folder tile's sat left.

- [ ] **Step 6: Drop the stale `delete_prefix`**

In each of the five Files tests named above, delete `.delete_prefix("📁 ")` from the line. The
expression becomes `(cell.at_css(".file-name") || cell.at_css("a")).text.strip`. In
`files_type_filter_test.rb:49` it becomes `name = (cells[0].at_css(".file-name") ||
cells[0].at_css("a")).text.strip`.

- [ ] **Step 7: Run the Files suites**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/folder_nav_test.rb test/integration/web/files_type_filter_test.rb test/integration/web/files_sort_test.rb test/integration/web/files_search_test.rb test/integration/web/files_git_marker_test.rb test/integration/web/files_pagination_test.rb test/integration/web/template_hygiene_test.rb`
Expected: PASS.

- [ ] **Step 8: Mutation-check (§15)**

Put `📁 ` back in front of `<%= node.name %>` in `_list.html.erb`. Run `folder_nav_test.rb`.
Expected: FAIL on `assert_no_match "📁"`. Undo by hand. Report the output.

- [ ] **Step 9: Commit**

```bash
git add app/helpers/shell_helper.rb app/assets/stylesheets/pages/files.css app/views/files/_grid.html.erb \
  app/views/files/_list.html.erb app/views/trash/index.html.erb app/views/shared/_folder_field.html.erb \
  test/integration/web/folder_nav_test.rb test/integration/web/files_type_filter_test.rb \
  test/integration/web/files_sort_test.rb test/integration/web/files_search_test.rb \
  test/integration/web/files_git_marker_test.rb test/integration/web/files_pagination_test.rb
git commit -F <message file>
```

Subject: `Library tiles are square and a folder is the rail's folder icon, not an emoji`.

---

### Task 5: Record the rules

**Files:**
- Modify: `docs/invariants/design-system.md`

- [ ] **Step 1: Amend the invariants**

In `docs/invariants/design-system.md`:

Rule 4: replace "`[data-theme="light"]` and `@media (prefers-color-scheme: light) {
[data-theme="system"] }` redefine the same set. Dark is the default and what an absent or junk
cookie means." with:

```markdown
`[data-theme="dark"]` and `@media (prefers-color-scheme: dark) { [data-theme="system"] }` redefine
the same set. **Light ("Paper") is the default and what an absent or junk cookie means** (since the
2026-10-08 redesign; it was dark before). The default lives in four places that must agree:
`ShellHelper#ui_theme`, `theme_controller.js#current`, `lib/codemirror_theme.js#darkThemeActive` and
the PWA manifest.
```

Rule 5: after "`--thumb-stage` is white in BOTH themes because rendered previews are opaque white
PNGs —", replace the rest of the sentence with:

```markdown
anything that paints onto that stage uses `--thumb-ink`, which does not flip either (the model file
tree shipped light-on-white once for lack of one). A user's PHOTO is not a render and sits on
`--photo-stage` (`.thumb.photo`), never letterboxed in white.
```

Add after rule 12:

```markdown
13. **The accent is spent once per screen; selection is ink.** `--accent` fills the one primary
    action and marks the current project (where that action lands). Links, selected chips,
    toggles, tabs, the file-chooser selection and the active rail item use `--fg`. Status carries
    its word, never colour alone (`.flash::before`, badge labels). Text on an accent fill is
    `--accent-ink` (near-black in the dark theme), never a literal white. `components.css` and
    `shell.css` name tokens, never colour literals (`css_hygiene_test.rb`); drawing colours stay
    literal in `pages/` (rule 5). The values are the Tinkerex Design System artifact.
```

- [ ] **Step 2: Check the doc guard**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/docs_hygiene_test.rb`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add docs/invariants/design-system.md
git commit -F <message file>
```

Subject: `design-system.md records the light default, the photo stage and where the accent goes`.

---

### Task 6: Close out

- [ ] **Step 1: Run every gate**

Run: `bin/ci`. From a worktree, first run `export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync`.
Expected: all gates green. Read the three backend legs' run counts: `test`, `test-s3` and
`test-chunk-remote` must report **identical run counts**. A ±2 assertion difference is the known
flap (`tinkerex#131`); a structural difference is a bug.

- [ ] **Step 2: Finish the branch**

Run `/finish-branch`: commit anything left, push, and open the PR. The PR body states what was
verified (the gates, the run counts, every mutation check's actual output, the visual check) and
what was not.

- [ ] **Step 3: File the arc**

Run `bin/log arc --from-pr <n>` as the PR opens, and `bin/log close <n>` at merge. Exit code 3
means the write was spooled; file it before moving on.
