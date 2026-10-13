# Plan — swappable visual themes for the Maker app

> **HISTORICAL — not re-verified.** Written before the repository split of 2026-08-20, when the
> sync engine and the Rust client still lived here (they are `chaim354/tinkerex-sync` and
> `chaim354/tinkerex-client` now). Kept for its reasoning and its measurements; it does not
> describe what this repository contains today. The current map is `docs/README.md`.


**Status:** plan only (do not implement yet).
**Scope:** the Tauri desktop app frontend (`client/maker-app/src`). A user-selectable
visual theme, persisted, applied instantly app-wide, with at least four built-in themes:

- **default** — the current clean light/dark (system-following) palette.
- **hacker** — terminal green-on-black, monospace accents.
- **woodworker** — warm wood tones (walnut/oak/amber).
- **craft mom** — friendly pastels (soft pink/mint/lavender, rounded, playful).

This is a low-risk, additive change: the CSS is **already token-driven** (every color in
`styles.css` reads a `var(--…)` custom property — see `:root` and the
`@media (prefers-color-scheme: dark)` block), so theming is mostly *defining more token
sets* + a switcher, not restyling components.

## 1. Why this is cheap here

`styles.css` already centralizes the palette as CSS custom properties:

```
--bg --card --line --ink --muted --accent --accent-hover --accent-ink
--ok --warn --off --err --err-bg --ok-bg --hover --focus
```

Every component (`.card`, `.pill`, `.lib-card`, `.proj-row`, `.inv-row`, `.bom-table`,
`.prev-card`, modals, toasts…) already consumes those. So a theme = **one block that
re-binds those ~17 variables** (plus a few new ones for fonts/radii). No per-component
edits.

The only non-token bits today are a couple of hard-coded hexes (`.fav.on { color:
#f5b301 }`, the conflict-side accent). Those get promoted to tokens as part of step 2.

## 2. Theming architecture — design tokens + a `data-theme` attribute

### 2a. Token layering

Split tokens into two tiers so themes stay small and consistent:

- **Primitive tokens** (a theme defines these): raw palette + typography + radius knobs.
  ```
  --bg --card --line --ink --muted
  --accent --accent-hover --accent-ink
  --ok --warn --err --off
  --hover --focus --err-bg --ok-bg
  --font-ui --font-mono            (NEW — themes can swap the typeface)
  --r-sm --r-md --r-lg            (already exist; themes may soften/sharpen)
  --fav                            (NEW — promote the hard-coded star color)
  --shadow                         (NEW — themes can add depth, e.g. craft-mom)
  ```
- **Semantic/component tokens** (defined once in the base, reference primitives): keeps
  components decoupled from raw palette. Mostly already implicit; formalize the few that
  vary (e.g. `--badge-bg: var(--hover)`).

### 2b. Theme selection mechanism

Apply the active theme by setting an attribute on `<html>`:

```html
<html data-theme="hacker">
```

and define each theme as an attribute-scoped `:root` override:

```css
:root { /* default light primitives */ }
@media (prefers-color-scheme: dark) { :root { /* default dark */ } }

[data-theme="hacker"] {
  --bg: #0a0e0a; --card: #0f140f; --ink: #b6ffb6; --accent: #2fff6a;
  --accent-ink: #001400; --line: #1f2a1f; --muted: #5fa05f;
  --font-ui: "JetBrains Mono", ui-monospace, monospace;
  --font-mono: ui-monospace, monospace;
  --r-sm: 2px; --r-md: 3px; --r-lg: 4px;   /* sharp terminal corners */
}
[data-theme="woodworker"] {
  --bg: #f3e9dc; --card: #fbf4ea; --ink: #3a2a1a; --accent: #a0522d;
  --accent-ink: #fff6ee; --line: #d9c4a9; --muted: #7a5c40;
  --ok: #5a7d33; --warn: #b5651d; --fav: #c8902a;
  --font-ui: "Georgia", "Iowan Old Style", serif;
}
[data-theme="craftmom"] {
  --bg: #fff5fa; --card: #ffffff; --ink: #5a4a55; --accent: #ff8fb1;
  --accent-ink: #ffffff; --line: #ffe0ec; --muted: #b08aa0;
  --ok: #6fcf97; --warn: #f2c14e; --fav: #ff7eb6;
  --r-sm: 14px; --r-md: 18px; --r-lg: 24px;  /* extra-rounded, friendly */
  --shadow: 0 2px 10px rgba(255, 143, 177, 0.18);
}
```

`data-theme="default"` (or the attribute absent) → the existing `:root` rules, so the
default still follows the OS light/dark preference. The other themes are intentionally
fixed-mode (a "hacker" theme that flips to light would be wrong); if a dark/light variant
of woodworker/craftmom is wanted later, add `[data-theme="woodworker"][data-mode="dark"]`.

### 2c. Why attribute over class or separate stylesheets

- One stylesheet, no FOUC from swapping `<link>`s, no bundler.
- `data-theme` reads naturally and supports the optional `data-mode` axis later.
- Specificity stays flat (`[data-theme=…]` == `:root`), so overrides are predictable.

## 3. The switcher

### 3a. UI placement

Add a theme selector to the **Settings** view (already exists — `viewSettings`). A new card:

```html
<section class="card">
  <h2>Theme</h2>
  <div id="themeGrid" class="theme-grid"></div>   <!-- swatch buttons -->
</section>
```

Render one swatch button per theme showing a mini preview (three dots in `--bg`/`--accent`/
`--ink` of that theme). Clicking applies + persists. A small live "Aa" + a sample
badge/button updates instantly. Keep it keyboard-accessible (`role="radiogroup"`,
arrow-key navigation, `aria-checked`).

### 3b. Apply + persist logic (`theme.js`, a new module)

```js
const THEMES = ["default", "hacker", "woodworker", "craftmom"];
const KEY = "maker.theme";

export function applyTheme(name) {
  const t = THEMES.includes(name) ? name : "default";
  document.documentElement.setAttribute("data-theme", t);
  localStorage.setItem(KEY, t);
}

// Apply BEFORE first paint to avoid a flash: call from an inline <script> in <head>,
// or as the very first statement of the module graph (main.js loads first).
applyTheme(localStorage.getItem(KEY) || "default");
```

- **Persistence:** `localStorage` is simplest and synchronous (no IPC), survives app
  restarts, and is per-install. (Tauri's WKWebView localStorage is wiped by the existing
  `webview_cache::evict_if_version_changed` purge on *version bump* only — acceptable; the
  user re-picks once per update, or we move the pref to the Rust prefs.json via
  `get_prefs`/`set_prefs`, see 3c.)
- **No flash:** apply the saved theme as the first thing that runs. Because the frontend is
  the bundled static site, an inline `<script>` in `<head>` (before `styles.css`'s cascade
  matters) setting `data-theme` from `localStorage` is the cleanest no-FOUC path.

### 3c. Optional: persist via the Rust layer instead of localStorage

If we want the theme to survive a webview-cache purge and be per-account, extend the
existing `Prefs` struct (`client/maker-app/src-tauri/src/lib.rs`, already wired through
`get_prefs`/`set_prefs`) with a `theme: String` field. Trade-off: an async IPC round-trip
on boot → a 1-frame flash unless we also keep a localStorage mirror for the fast path.
**Recommendation:** localStorage for instant no-flash apply, mirror into `Prefs.theme` on
change for durability. Read `Prefs.theme` only as a fallback when localStorage is empty.

## 4. Per-theme polish beyond color

Some themes want more than a palette swap; keep these *opt-in via tokens* so the base CSS
stays theme-agnostic:

- **hacker:** monospace `--font-ui`, sharp radii, a subtle scanline/glow on `.pill.on`
  (a `[data-theme="hacker"] .pill.on { text-shadow: 0 0 6px var(--accent) }` rule).
- **woodworker:** serif headings, a faint wood-grain `background-image` on `body` (an
  inline SVG data-URI or a bundled texture in `src/assets`), warmer shadows.
- **craftmom:** big radii (already token), soft `--shadow` on cards, a friendlier font,
  maybe a pastel gradient header.

Each lives under its `[data-theme="…"]` selector so it can't leak into other themes.

## 5. Implementation steps (when greenlit)

1. **Promote stragglers to tokens** — replace the remaining hard-coded hexes
   (`.fav.on`, conflict accent, any literal in the new surface CSS) with `var(--…)`; add
   `--font-ui`/`--font-mono`/`--fav`/`--shadow` to the base `:root`; set
   `body { font-family: var(--font-ui) }`, `.code/.codebox { font-family: var(--font-mono) }`.
   *Verify the default theme looks identical (pure refactor).*
2. **Add the four theme blocks** to `styles.css` (or a new `themes.css` linked after it).
3. **`theme.js`** — `applyTheme` + boot-apply + the no-FOUC `<head>` inline shim.
4. **Settings theme card** — swatch radiogroup + live sample; wire to `applyTheme`.
5. **(Optional)** add `theme` to `Prefs` + mirror on change.
6. **Bundle fonts** if a theme needs a non-system face (keep permissive: JetBrains Mono =
   OFL, fine; check any serif before bundling — §9 licensing).

## 6. Testing

- **Pure-logic (the only testable JS):** `applyTheme` normalizes unknown names to
  `default`, writes the attribute, persists to localStorage. If `theme` moves into `Prefs`,
  add a Rust test (the prefs round-trip test already exists — extend it for the new field).
- **Visual:** a manual checklist screenshotting each surface (Sync/Library/Projects/
  Inventory/Preview/Settings) under each theme for contrast/legibility; add a contrast
  check (WCAG AA on `--ink`/`--bg`, `--accent-ink`/`--accent`) since custom palettes are
  easy to get wrong — the hacker/craftmom accents especially.
- **No-FOUC:** verify the saved theme is applied before first paint (no white flash on a
  hacker/woodworker user's launch).

## 7. Risks / notes

- **Contrast:** custom palettes can fail accessibility; bake an AA contrast check into the
  visual checklist (and pick the four palettes' tokens to pass it).
- **Dark-mode interaction:** only `default` follows `prefers-color-scheme`; the themed ones
  are fixed-mode by design. Document this so it's not read as a bug.
- **Webview cache purge** wiping localStorage on app update → mirror into `Prefs.theme`
  (3c) if that's unacceptable.
- **Scope discipline:** themes touch *only* `styles.css` + a new `theme.js` + the Settings
  card. No component markup changes — the token layer is the whole point.
