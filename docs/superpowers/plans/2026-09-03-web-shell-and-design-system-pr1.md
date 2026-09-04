# Web Shell and Design System, PR 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file (each task below is already one coherent unit), dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Land the design system and the new application shell from the spec (`docs/superpowers/specs/2026-09-03-web-shell-and-design-system-design.md`) so every page is restyled underneath, with the rail, top bar, toasts, theme, self-hosted fonts, the Files name search, restyled auth pages, and the guards that keep all of it honest. PRs 2 to 4 (page-by-page control tidying) get their own plans.

**Architecture:** Plain CSS in cascade layers (`tokens, base, components, shell, pages`) served by Propshaft with no build step; one definition per component selector in `components.css`; page-family sheets under `pages/`; one unlayered `vendor-overrides.css` linked last. The layout renders the rail, the current-project card, the top bar and the toast stack; theme and rail state are cookies read server-side; three small Stimulus controllers (`theme`, `rail`, `toast`). Every class the tests and the addon bundles pin keeps its name.

**Tech Stack:** Rails 8, Propshaft, importmap + Stimulus 3, Turbo, Devise, Minitest (request tests under `test/integration/web/`, Capybara/Selenium system tests under `test/system/`), IBM Plex Sans/Mono (SIL OFL 1.1, self-hosted woff2).

---

## Before you start

- **Read `CLAUDE.md` §14d, §14e and §15** and `docs/invariants/files-preview.md` (this plan touches `app/views/files/`). Do not read the record; everything needed is here.
- **You are in a git worktree** on branch `claude/ui-ux-rework-458036`. Commit on it; never push to `main`.
- **Running tests needs a library path**, or 187 tests error before anything runs:
  ```bash
  export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)
  bin/rails test test/integration/web/shell_layout_test.rb   # one file
  bin/rails test                                             # the share leg
  bin/rails test test/system/shell_test.rb                   # system tests need Chrome; they are slow
  ```
- **Gates:** `bin/ci --list` names them (`setup style scan test test-s3 test-chunk-remote system`). `bin/ci style` is rubocop with rails-omakase: double quotes, `[ a, b ]` with inner spaces, `{ a: 1 }`. Run it after every Ruby edit. From this worktree the chunk_remote leg needs `export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync` (see the memory note in `~/.claude/projects/-Users-charlesschwartz-Desktop-repos-tinkerex/memory/`).
- **Three ERB rules that bite:** never write the ERB close delimiter inside an ERB comment (the comment ends there and the rest prints into the page); every `data-controller` value is a literal string, never interpolated (`test/stimulus_hygiene_test.rb` scans the literal); every `form_with` keeps its `scope:`/`model:` so field names do not change.
- **Mutation-check every guard you write** (§15): after a test that forbids something goes green, break the thing and confirm it goes red, then restore with `git checkout -- <file>`.
- **Class names are a contract.** The spec's §10 lists the pinned selectors and the 52 classes the addon bundles use. You restyle them; you never rename them.
- **To look at a page while you work:** the memory note names the recipe (seeded scratch library, `bin/rails server`, the STL thumbnailer build). Looking is optional for CSS tasks; the tests are the gate.

## File structure

| path | responsibility | task |
|---|---|---|
| `app/assets/fonts/ibm-plex-sans.woff2`, `ibm-plex-sans-italic.woff2`, `ibm-plex-mono-400.woff2`, `ibm-plex-mono-500.woff2`, `LICENSE-IBM-Plex.txt` | the self-hosted faces and their licence | 1 |
| `app/assets/stylesheets/application.css` | the `@layer` order statement, tokens for both themes, `@font-face`, the reset and base typography | 2 |
| `app/assets/stylesheets/components.css` | the one definition of every component selector | 2 |
| `app/assets/stylesheets/pages/files.css`, `pages/projects.css`, `pages/models.css`, `pages/tools.css`, `pages/preview.css` | page-family rules (the migrated rules from today's four sheets, re-expressed in tokens) | 2 |
| `app/assets/stylesheets/vendor-overrides.css` | the unlayered Lexxy / CodeMirror / spreadsheet skins | 2 |
| `test/css_hygiene_test.rb` | layers, one-definition, deleted sheets, link order | 2 |
| `app/assets/stylesheets/shell.css` | rail, top bar, tab bar, container, toast stack, auth card, responsive | 3 |
| `app/helpers/shell_helper.rb` | `ui_theme`, `rail_collapsed?`, `body_classes`, `rail_section`, `rail_links`, `rail_icon`, `page_title_text`, meta colours | 3 |
| `app/views/layouts/application.html.erb`, `layouts/_rail.html.erb`, `layouts/_topbar.html.erb`, `layouts/_flash.html.erb`, `layouts/_tabbar.html.erb` | the shell | 3 |
| `app/javascript/controllers/theme_controller.js`, `rail_controller.js`, `toast_controller.js` | theme cycle + cookie, rail collapse + cookie + ⌘K, toast dismissal | 3 |
| `app/views/projects/show.html.erb`, `projects/sheets/show.html.erb`, `models/show.html.erb` | breadcrumb moves into `content_for :crumbs` | 3 |
| `app/views/files/_list.html.erb` | per-column classes so the phone layout can drop columns | 3 |
| `public/favicon.ico`, `app/views/pwa/manifest.json.erb` | the 404 and the red manifest colours | 3 |
| `test/integration/web/shell_layout_test.rb` | rail, active state, theme/rail cookies, search field, breadcrumb slot, current-project card, fonts | 3 |
| `app/controllers/files_controller.rb`, `app/helpers/files_helper.rb`, `app/views/files/index.html.erb`, `files/_ext_filter.html.erb` | the `q` search | 4 |
| `test/integration/web/files_search_test.rb` | the search's behaviour | 4 |
| `app/views/users/**` (7 templates) | the auth card | 5 |
| `test/integration/web/auth_pages_test.rb` | auth pages render the card with Devise's field names intact | 5 |
| `test/system/shell_test.rb` | collapse persists, theme cycles, toasts, ⌘K, no sideways scroll at 375px | 6 |
| `CLAUDE.md` §14d | the design-system invariant | 7 |

Deleted in task 2: `app/assets/stylesheets/projects.css`, `models.css`, `notes.css`.

**Dependencies:** Task 1 and Task 2 can run in parallel. Task 3 needs Task 2 (it rewrites the layout that Task 2 edits the link tags of). Tasks 4 and 5 need Task 3 and can run in parallel with each other. Task 6 needs 3, 4 and 5. Task 7 is last.

---

### Task 1: Vendor the IBM Plex fonts

**Files:**
- Create: `app/assets/fonts/ibm-plex-sans.woff2`, `app/assets/fonts/ibm-plex-sans-italic.woff2`, `app/assets/fonts/ibm-plex-mono-400.woff2`, `app/assets/fonts/ibm-plex-mono-500.woff2`, `app/assets/fonts/LICENSE-IBM-Plex.txt`

Why these four: Google serves Plex Sans as one variable file covering weights 400–600 (verified 2026-09-03: the CSS API returns the same URL for 400, 500 and 600), so Sans is two files (upright + italic) and Mono is two static weights. Latin subset only. The licence text must travel with the files (OFL §1).

- [ ] **Step 1: Fetch the Latin woff2 files through the Google Fonts CSS API**

```bash
mkdir -p app/assets/fonts && cd app/assets/fonts
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
curl -sS -A "$UA" "https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:ital,wght@0,400;0,500;0,600;1,400&family=IBM+Plex+Mono:wght@400;500&display=swap" -o /tmp/plex.css
python3 - <<'PY'
import re, urllib.request
css = open("/tmp/plex.css").read()
wanted = {("IBM Plex Sans", "normal"): "ibm-plex-sans.woff2",
          ("IBM Plex Sans", "italic"): "ibm-plex-sans-italic.woff2",
          ("IBM Plex Mono", "400"): "ibm-plex-mono-400.woff2",
          ("IBM Plex Mono", "500"): "ibm-plex-mono-500.woff2"}
for m in re.finditer(r"/\* latin \*/\s*@font-face \{(.*?)\}", css, re.S):
    b = m.group(1)
    fam = re.search(r"font-family: '([^']+)'", b).group(1)
    style = re.search(r"font-style: (\w+)", b).group(1)
    weight = re.search(r"font-weight: (\d+)", b).group(1)
    url = re.search(r"url\((https://[^)]+\.woff2)\)", b).group(1)
    key = (fam, style) if fam == "IBM Plex Sans" else (fam, weight)
    name = wanted.get(key)
    if name:
        urllib.request.urlretrieve(url, name)
        print(name, url)
PY
curl -sS -o LICENSE-IBM-Plex.txt https://raw.githubusercontent.com/IBM/plex/master/LICENSE.txt
ls -la; head -3 LICENSE-IBM-Plex.txt; cd -
```

Expected: four `.woff2` files (Sans upright ≈ 40 KB, Mono 400 ≈ 10 KB), and the licence starting `Copyright © 2017 IBM Corp. with Reserved Font Name "Plex"` / `This Font Software is licensed under the SIL Open Font License, Version 1.1.`

- [ ] **Step 2: Confirm each file really is woff2**

```bash
for f in app/assets/fonts/*.woff2; do printf '%s: ' "$f"; head -c 4 "$f" | od -An -c | tr -d ' \n'; echo; done
```

Expected: every line ends with `w O F 2`.

- [ ] **Step 3: Commit**

```bash
git add app/assets/fonts
git commit -m "Vendor IBM Plex Sans and Mono (OFL) so the shell's type is same-origin"
```

---

### Task 2: The stylesheets and their guard

**Files:**
- Rewrite: `app/assets/stylesheets/application.css`
- Create: `app/assets/stylesheets/components.css`, `app/assets/stylesheets/pages/files.css`, `pages/projects.css`, `pages/models.css`, `pages/tools.css`, `pages/preview.css`, `app/assets/stylesheets/vendor-overrides.css`
- Delete: `app/assets/stylesheets/projects.css`, `models.css`, `notes.css`
- Modify: `app/views/layouts/application.html.erb` (the five `stylesheet_link_tag` lines only; Task 3 rewrites the rest)
- Test: `test/css_hygiene_test.rb`

The old `application.css` is the source for the migrated rules. **Read it once, top to bottom, before touching anything** (`git show HEAD:app/assets/stylesheets/application.css`), so the line ranges below make sense. Rules migrate **verbatim**, wrapped in a layer block, with only the substitutions in the table applied. Do not "improve" a migrated rule; that is PR 2–4's job, page by page.

**Substitution table for every migrated rule:**

| in the old sheet | write |
|---|---|
| `var(--soft)` | `var(--raised)` |
| `var(--muted)` | `var(--fg-muted)` |
| `#fff` / `#ffffff` as a **background** | `var(--surface)` — except `.thumb`, `.box-preview .preview-image`, `.box-topview-canvas`, `.generator-preview`, `.file-tree-box`, `.box-topview-canvas`, which draw a rendered drawing and keep `var(--thumb-stage)` |
| `#f8fafc`, `#f3f4f6` | `var(--raised)` |
| `#e5e7eb`, `#eee`, `#f1f5f9`, `#dfe5ed`, `#f7f8fa` | `var(--line)` |
| `#334155`, `#1c2230` | `var(--fg)` |
| `#64748b`, `#6b7280`, `#9ca3af` | `var(--fg-muted)` |
| `#1a7f37` | `var(--ok)` |
| `#2563eb`, `#06c` | `var(--accent)` |
| `#dc2626` | `var(--danger)` |
| any `ui-monospace, ... monospace` stack | `var(--font-mono)` |
| `system-ui, -apple-system, ...` stack | `var(--font-ui)` |
| `border-radius: 10px` / `8px` on a panel-like box | `var(--radius-panel)` |
| `rgba(0, 0, 0, 0.25)` / `0.15` / `0.18` box shadows | `var(--shadow-float)` |
| `#fffbeb` / `#fde68a` / `#92400e` (`.placeholder-note`) | `color-mix(in srgb, var(--accent) 14%, var(--surface))` / `color-mix(in srgb, var(--accent) 40%, transparent)` / `var(--fg)` |
| flash / badge literal tints (`#ecfdf5 #065f46`, `#fef2f2 #991b1b`, `#eff6ff #1e40af`) | dropped: the tints are defined once in `components.css` |

- [ ] **Step 1: Write `application.css`**

Replace the whole file with:

```css
/* Tinkerex design system: the layer order, the tokens, the fonts and the base rules.
   Components live in components.css (one definition each), the shell in shell.css, page families
   under pages/, and the third-party skins in vendor-overrides.css — the ONE unlayered sheet.
   THE @layer STATEMENT MUST STAY THE FIRST RULE OF THIS FILE, AND THIS FILE THE FIRST OUR LAYOUT
   LINKS: the first @layer statement the browser meets fixes the order for the whole document.
   test/css_hygiene_test.rb guards both. Spec: docs/superpowers/specs/2026-09-03-web-shell-and-design-system-design.md */
@layer tokens, base, components, shell, pages;

@layer tokens {
  :root {
    color-scheme: dark;
    --bg: #15181d;
    --surface: #1b1f25;
    --raised: #232830;
    --line: #2b313a;
    --line-strong: #3a424d;
    --fg: #e4e7ec;
    --fg-muted: #8a93a2;
    --accent: #f0a53a;
    --accent-ink: #1a1408;
    --accent-soft: rgba(240, 165, 58, .10);
    --ok: #5cc186;
    --danger: #ef6b5c;
    --focus: var(--accent);
    --shadow-float: 0 10px 30px rgba(0, 0, 0, .45);
    /* Rendered drawings (thumbnails, generator previews, cut sheets) are opaque white PNGs, so
       their stage stays paper-white in both themes; a dark stage would frame a white square. */
    --thumb-stage: #ffffff;
    /* Aliases for rules migrated from the pre-2026-09 sheets. New rules use the names above. */
    --muted: var(--fg-muted);
    --soft: var(--raised);
    --font-ui: "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif;
    --font-mono: "IBM Plex Mono", ui-monospace, Menlo, monospace;
    --radius-control: 4px;
    --radius-panel: 6px;
    --radius-float: 10px;
    --rail-width: 188px;
    --rail-collapsed-width: 56px;
    --topbar-height: 44px;
    --tabbar-height: 52px;
  }
  :root[data-theme="light"] {
    color-scheme: light;
    --bg: #f4f5f7;
    --surface: #ffffff;
    --raised: #eceef2;
    --line: #dfe2e7;
    --line-strong: #c9ced6;
    --fg: #1a1e26;
    --fg-muted: #626b78;
    --accent: #b8700a;
    --accent-ink: #ffffff;
    --accent-soft: rgba(184, 112, 10, .10);
    --ok: #2f8f5b;
    --danger: #c8413a;
    --shadow-float: 0 10px 30px rgba(20, 24, 32, .18);
  }
  @media (prefers-color-scheme: light) {
    :root[data-theme="system"] {
      color-scheme: light;
      --bg: #f4f5f7;
      --surface: #ffffff;
      --raised: #eceef2;
      --line: #dfe2e7;
      --line-strong: #c9ced6;
      --fg: #1a1e26;
      --fg-muted: #626b78;
      --accent: #b8700a;
      --accent-ink: #ffffff;
      --accent-soft: rgba(184, 112, 10, .10);
      --ok: #2f8f5b;
      --danger: #c8413a;
      --shadow-float: 0 10px 30px rgba(20, 24, 32, .18);
    }
  }
}

@layer base {
  /* Self-hosted (app/assets/fonts, SIL OFL 1.1): the CSP's font_src is :self, and a self-hosted
     app does not call Google. Propshaft rewrites these url()s to the fingerprinted paths. */
  @font-face {
    font-family: "IBM Plex Sans"; font-style: normal; font-weight: 400 600; font-display: swap;
    src: url("ibm-plex-sans.woff2") format("woff2");
  }
  @font-face {
    font-family: "IBM Plex Sans"; font-style: italic; font-weight: 400; font-display: swap;
    src: url("ibm-plex-sans-italic.woff2") format("woff2");
  }
  @font-face {
    font-family: "IBM Plex Mono"; font-style: normal; font-weight: 400; font-display: swap;
    src: url("ibm-plex-mono-400.woff2") format("woff2");
  }
  @font-face {
    font-family: "IBM Plex Mono"; font-style: normal; font-weight: 500; font-display: swap;
    src: url("ibm-plex-mono-500.woff2") format("woff2");
  }

  *, *::before, *::after { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body {
    margin: 0; background: var(--bg); color: var(--fg);
    font: 13px/1.45 var(--font-ui);
  }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  h1, h2, h3 { margin: 0; line-height: 1.2; letter-spacing: -0.01em; text-wrap: balance; }
  h1 { font-size: 20px; font-weight: 600; }
  h2 { font-size: 16px; font-weight: 600; }
  h3 { font-size: 13px; font-weight: 600; }
  p { margin: 0 0 8px; }
  code, kbd, pre, .mono { font-family: var(--font-mono); font-size: 12px; }
  .muted { color: var(--fg-muted); }
  .num { text-align: right; font-family: var(--font-mono); font-variant-numeric: tabular-nums; }
  .prose { max-width: 72ch; font-size: 14px; line-height: 1.55; }
  :focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }
  ::selection { background: var(--accent-soft); }
  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { animation-duration: .001ms !important; transition-duration: .001ms !important; }
  }
}
```

- [ ] **Step 2: Write `components.css`**

```css
/* Tinkerex component vocabulary. ONE DEFINITION PER COMPONENT SELECTOR, HERE AND NOWHERE ELSE:
   the pre-2026-09 sheets defined `.btn` twice (application.css blue, projects.css grey) and the
   later file won, so `.btn` rendered grey everywhere and `.btn.primary` blue. A page sheet under
   pages/ may style its own classes and may qualify a component inside a page container
   (`.files-grid .thumb`), but never redeclares a bare component selector from this file.
   test/css_hygiene_test.rb fails if one does. Every colour is a token from application.css. */
@layer components {
  /* --- Buttons --- */
  .btn, input[type="submit"], .upload-btn span, details.composer > summary {
    display: inline-flex; align-items: center; justify-content: center; gap: 6px;
    min-height: 30px; padding: 0 12px; border-radius: var(--radius-control);
    border: 1px solid var(--line); background: var(--raised); color: var(--fg);
    font: 500 13px/1 var(--font-ui); text-decoration: none; cursor: pointer; white-space: nowrap;
  }
  .btn:hover, input[type="submit"]:hover, details.composer > summary:hover { border-color: var(--line-strong); text-decoration: none; }
  .btn.primary, .upload-btn span, input[type="submit"].primary {
    background: var(--accent); border-color: var(--accent); color: var(--accent-ink); font-weight: 600;
  }
  .btn.primary:hover, .upload-btn span:hover, input[type="submit"].primary:hover { filter: brightness(1.06); border-color: var(--accent); }
  .btn.danger { background: transparent; border-color: var(--danger); color: var(--danger); }
  .btn.danger:hover { background: color-mix(in srgb, var(--danger) 12%, transparent); }
  .btn.ghost { background: transparent; border-color: transparent; }
  .btn.ghost:hover { background: var(--raised); }
  .btn.small, input[type="submit"].small { min-height: 24px; padding: 0 8px; font-size: 12px; }
  .btn.icon { width: 30px; padding: 0; }
  .btn:disabled, input[type="submit"]:disabled { opacity: .55; cursor: default; }
  .linkbtn { background: none; border: 0; padding: 0; color: var(--accent); font: inherit; cursor: pointer; }
  .linkbtn:hover { text-decoration: underline; }
  .linkbtn.danger { color: var(--danger); }
  .linkbtn.small { font-size: 12px; }
  .upload-btn { display: inline-flex; cursor: pointer; }
  .upload-status { font-size: 12px; color: var(--fg-muted); }
  .uploader { display: inline-flex; align-items: center; gap: 10px; }

  /* --- Inputs --- */
  .app-shell input:not([type="checkbox"]):not([type="radio"]):not([type="file"]):not([type="submit"]):not([type="hidden"]),
  .app-shell select, .app-shell textarea,
  .auth-card input:not([type="checkbox"]):not([type="submit"]) {
    font: 13px/1.4 var(--font-ui); color: var(--fg); background: var(--surface);
    border: 1px solid var(--line); border-radius: var(--radius-control); padding: 5px 9px; min-height: 30px;
  }
  .app-shell input:hover, .app-shell select:hover, .app-shell textarea:hover,
  .auth-card input:hover { border-color: var(--line-strong); }
  .app-shell input:focus-visible, .app-shell select:focus-visible, .app-shell textarea:focus-visible,
  .auth-card input:focus-visible { border-color: var(--accent); outline: 2px solid var(--focus); outline-offset: 0; }
  .app-shell textarea { min-height: 80px; line-height: 1.5; }
  .app-shell select {
    padding-right: 26px; appearance: none;
    background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' fill='none' stroke='%238a93a2' stroke-width='1.5'/></svg>");
    background-repeat: no-repeat; background-position: right 9px center;
  }
  .field { display: block; margin-bottom: 14px; }
  .field > span, .field > label { display: block; font-size: 12px; color: var(--fg-muted); margin-bottom: 4px; }
  .field input, .field textarea, .field select { width: 100%; max-width: 480px; }
  .field > .folder-field { display: inline-flex; }
  .field-inline { display: flex; align-items: center; gap: 6px; margin-top: 8px; font-size: 12px; }
  .field-inline input { width: auto; }
  .form-actions { display: flex; gap: 12px; align-items: center; }
  .form-errors {
    margin-bottom: 14px; padding: 8px 12px; border-radius: var(--radius-control);
    background: color-mix(in srgb, var(--danger) 14%, var(--surface)); color: var(--danger); font-size: 13px;
  }

  /* --- Chips, segmented control, toolbar, breadcrumb, pager, page head --- */
  .chip {
    display: inline-flex; align-items: center; gap: 6px; padding: 2px 9px; border-radius: 999px;
    border: 1px solid var(--line); background: var(--surface); color: var(--fg-muted);
    font: 500 12px/1.4 var(--font-mono); text-decoration: none;
  }
  .chip:hover { border-color: var(--line-strong); color: var(--fg); text-decoration: none; }
  .chip.active { border-color: var(--accent); color: var(--accent); background: var(--accent-soft); }
  .chip .chip-x { opacity: .7; font-weight: 700; }
  .chip.active:hover { border-color: var(--danger); color: var(--danger); background: transparent; }
  .view-toggle { display: inline-flex; overflow: hidden; border: 1px solid var(--line); border-radius: var(--radius-control); background: var(--surface); }
  .view-toggle .toggle { padding: 4px 10px; font: 500 12px/1.4 var(--font-ui); color: var(--fg-muted); text-decoration: none; }
  .view-toggle .toggle:hover { background: var(--raised); color: var(--fg); text-decoration: none; }
  .view-toggle .toggle.active { background: var(--raised); color: var(--accent); }
  .view-toggle .toggle + .toggle { border-left: 1px solid var(--line); }
  .toolbar { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; margin: 0 0 12px; }
  .toolbar-spacer { flex: 1; }
  .breadcrumb { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; font-size: 13px; min-width: 0; }
  .breadcrumb .sep { color: var(--fg-muted); }
  .breadcrumb a { color: var(--fg-muted); }
  .breadcrumb a:hover { color: var(--fg); }
  .breadcrumb [aria-current="page"] { color: var(--fg); font-weight: 600; }
  .pager { display: flex; align-items: center; gap: 14px; margin: 0 0 12px; font-size: 12px; }
  .pager-status { color: var(--fg-muted); font-family: var(--font-mono); }
  .page-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px 16px; margin: 0 0 16px; }
  .page-head h1 { font-size: 20px; }
  .page-subtitle { margin: 2px 0 0; font-size: 13px; flex-basis: 100%; }
  .page-actions, .row-actions, .head-actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }

  /* --- Panels, group headers, tables --- */
  .panel { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-panel); padding: 12px 14px; }
  .panel h2 { margin: 0 0 10px; font-size: 14px; }
  .panel-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px 12px; margin-bottom: 8px; }
  .panel-head h2 { margin: 0; }
  .panel-actions { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; }
  .attachment-group-head, .tasks-group h3, .group-head {
    margin: 0 0 8px; font: 600 11px/1.4 var(--font-mono); text-transform: uppercase; letter-spacing: .08em; color: var(--fg-muted);
  }
  .attachment-group-head { cursor: pointer; }
  .attachment-group-head:hover { color: var(--fg); }
  table.files, .table { width: 100%; border-collapse: collapse; font-size: 13px; }
  table.files th, .table th {
    text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line-strong); white-space: nowrap;
    font: 500 11px/1.4 var(--font-mono); text-transform: uppercase; letter-spacing: .08em; color: var(--fg-muted);
  }
  table.files td, .table td { padding: 6px 8px; border-bottom: 1px solid var(--line); vertical-align: middle; }
  table.files tbody tr:hover, .table tbody tr:hover { background: var(--raised); }
  table.files th a { color: inherit; }
  table.files th.sorted a { color: var(--fg); }
  table.files .num, .table .num { text-align: right; font-family: var(--font-mono); font-variant-numeric: tabular-nums; white-space: nowrap; }
  table.files .row-actions { justify-content: flex-end; font-size: 12px; opacity: 0; transition: opacity .12s; }
  table.files tr:hover .row-actions, table.files tr:focus-within .row-actions { opacity: 1; }
  @media (hover: none) { table.files .row-actions { opacity: 1; } }
  .dir { font-weight: 600; }
  .file-cell { display: flex; align-items: center; gap: 10px; min-width: 0; }
  .file-name { overflow-wrap: anywhere; }

  /* --- Tiles and thumbnails (the markup is files/_thumb.html.erb; thumbs_controller swaps its
     children, so every state below keeps its class) --- */
  .thumb {
    display: flex; align-items: center; justify-content: center; overflow: hidden;
    border: 1px solid var(--line); border-radius: var(--radius-control); background: var(--thumb-stage); color: #5f6873;
  }
  .thumb img { width: 100%; height: 100%; object-fit: contain; display: block; }
  .thumb-icon { font: 600 10px/1 var(--font-mono); letter-spacing: .04em; color: #5f6873; }
  .thumb-spinner {
    width: 14px; height: 14px; border: 2px solid #d9dde3; border-top-color: #7a8390; border-radius: 50%;
    animation: thumb-spin .8s linear infinite;
  }
  @keyframes thumb-spin { to { transform: rotate(360deg); } }
  table.files .thumb { width: 40px; height: 40px; flex: 0 0 40px; }
  .folder-thumb, .generic-thumb { background: var(--raised); color: var(--fg-muted); }
  .folder-thumb { font-size: 40px; }
  .generic-thumb { font: 700 13px/1 var(--font-mono); letter-spacing: .06em; }
  .grid-card { display: flex; flex-direction: column; gap: 6px; min-width: 0; color: var(--fg); text-decoration: none; }
  .grid-card:hover { text-decoration: none; }
  .grid-card:hover .thumb { border-color: var(--accent); }
  .grid-card .grid-name { font-size: 12px; line-height: 1.35; text-align: center; overflow-wrap: anywhere; }

  /* --- Metadata strip, badges, empty state --- */
  dl.meta {
    display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 4px 16px; margin: 0 0 16px;
    padding: 10px 12px; border: 1px solid var(--line); border-radius: var(--radius-panel); background: var(--surface);
  }
  dl.meta dt { font: 500 11px/1.6 var(--font-mono); text-transform: uppercase; letter-spacing: .08em; color: var(--fg-muted); }
  dl.meta dd { margin: 0; font-family: var(--font-mono); font-size: 12px; line-height: 1.6; overflow-wrap: anywhere; }
  @media (min-width: 900px) { dl.meta { grid-template-columns: max-content minmax(0, 1fr) max-content minmax(0, 1fr); } }
  .badge {
    display: inline-flex; align-items: center; padding: 1px 8px; border-radius: 999px;
    font: 600 11px/1.6 var(--font-ui); background: var(--raised); color: var(--fg-muted); text-transform: capitalize;
  }
  .badge.status-archived { background: var(--raised); color: var(--fg-muted); }
  .badge.mstatus-want_to_print { background: var(--accent-soft); color: var(--accent); }
  .badge.mstatus-printed { background: color-mix(in srgb, var(--ok) 16%, transparent); color: var(--ok); }
  .badge.mstatus-failed { background: color-mix(in srgb, var(--danger) 16%, transparent); color: var(--danger); }
  .badge.current-project-badge { background: var(--accent-soft); color: var(--accent); text-transform: none; }
  .empty { padding: 40px 16px; text-align: center; color: var(--fg-muted); border: 1px dashed var(--line); border-radius: var(--radius-panel); }
  .truncated { margin: 0 0 12px; padding: 8px 12px; border-radius: var(--radius-control); background: var(--raised); color: var(--fg-muted); font-size: 12px; }

  /* --- Flash (inline colours here; the floating stack is shell.css's .flash-stack) --- */
  .flash { display: flex; align-items: flex-start; gap: 10px; padding: 10px 12px; border-radius: var(--radius-panel); border: 1px solid transparent; font-size: 13px; color: var(--fg); }
  .flash-notice { background: color-mix(in srgb, var(--ok) 14%, var(--surface)); border-color: color-mix(in srgb, var(--ok) 40%, transparent); }
  .flash-alert { background: color-mix(in srgb, var(--danger) 14%, var(--surface)); border-color: color-mix(in srgb, var(--danger) 45%, transparent); }
  .flash-text { flex: 1; }
  .flash-close { background: none; border: 0; padding: 0 2px; color: inherit; font-size: 16px; line-height: 1; cursor: pointer; opacity: .7; }
  .flash-close:hover { opacity: 1; }

  /* --- Floating things: menu, popover, dialog, composer --- */
  .file-menu {
    position: absolute; z-index: 1000; min-width: 160px; padding: 4px;
    background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-panel); box-shadow: var(--shadow-float);
  }
  .file-menu button, .file-menu a {
    display: block; width: 100%; text-align: left; padding: 7px 10px; background: none; border: 0;
    color: var(--fg); font: 13px/1.4 var(--font-ui); border-radius: var(--radius-control); cursor: pointer; text-decoration: none; box-sizing: border-box;
  }
  .file-menu button:hover, .file-menu a:hover { background: var(--raised); text-decoration: none; }
  .note-popover {
    position: absolute; z-index: 1001; width: 320px; max-width: 90vw; padding: 10px;
    background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-float); box-shadow: var(--shadow-float);
  }
  .note-popover textarea { width: 100%; box-sizing: border-box; resize: vertical; }
  .note-popover-actions { display: flex; align-items: center; gap: 8px; margin-top: 8px; }
  .note-popover-status { font-size: 12px; color: var(--fg-muted); }
  .note-badge { display: inline-block; margin-left: 6px; font: 500 11px/1 var(--font-mono); color: var(--fg-muted); vertical-align: middle; white-space: nowrap; }
  dialog.move-conflict {
    display: block; position: static; width: 100%; max-width: none; margin: 0 0 16px; padding: 12px 14px;
    border: 1px solid var(--line); border-left: 3px solid var(--accent); border-radius: var(--radius-panel);
    background: var(--surface); color: var(--fg);
  }
  dialog.move-conflict p { margin: 0 0 10px; }
  dialog.move-conflict .dialog-actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
  dialog.move-conflict form { display: inline; }
  details.composer > summary { list-style: none; }
  details.composer > summary::-webkit-details-marker { display: none; }
  details.composer[open] > summary { margin-bottom: 10px; }

  /* --- The folder/file chooser (filechooser_controller.js; shared with the addon bundles, which
     build this markup themselves — every class here is part of the §14c contract) --- */
  .folder-field { display: inline-flex; }
  .folder-field-btn {
    display: inline-flex; align-items: center; gap: 6px; max-width: 260px; min-height: 30px;
    padding: 0 12px; border: 1px solid var(--line); border-radius: var(--radius-control);
    background: var(--surface); color: var(--fg); font: 13px/1.4 var(--font-ui); cursor: pointer;
  }
  .folder-field-btn:hover { border-color: var(--accent); }
  .folder-field-btn .ff-path { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .filechooser-overlay {
    position: fixed; inset: 0; z-index: 1000; padding: 16px; background: rgba(0, 0, 0, .55);
    display: flex; align-items: center; justify-content: center;
  }
  .filechooser {
    display: flex; flex-direction: column; overflow: hidden; width: min(720px, 100%); max-height: min(560px, 90vh);
    background: var(--surface); color: var(--fg); border: 1px solid var(--line); border-radius: var(--radius-float); box-shadow: var(--shadow-float);
  }
  .filechooser-head { display: flex; align-items: center; justify-content: space-between; padding: 12px 16px; border-bottom: 1px solid var(--line); font-weight: 600; }
  .filechooser-close { background: none; border: 0; font-size: 16px; color: var(--fg-muted); cursor: pointer; }
  .filechooser-crumbs { padding: 8px 16px; border-bottom: 1px solid var(--line); color: var(--fg-muted); font: 12px/1.4 var(--font-mono); white-space: nowrap; overflow-x: auto; }
  .filechooser-cols { display: flex; flex: 1; min-height: 0; overflow-x: auto; }
  .filechooser-col { flex: 0 0 200px; min-height: 0; overflow-y: auto; border-right: 1px solid var(--line); }
  .filechooser-row { display: block; padding: 7px 12px; font-size: 13px; cursor: pointer; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .filechooser-row:hover { background: var(--raised); }
  .filechooser-row.sel { background: var(--accent); color: var(--accent-ink); }
  .filechooser-row.is-file { color: var(--fg-muted); }
  .filechooser-row.sel.is-file { color: var(--accent-ink); }
  .filechooser-empty { padding: 10px 12px; color: var(--fg-muted); font-size: 12px; }
  .filechooser-foot { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 12px 16px; border-top: 1px solid var(--line); }
  .filechooser-actions { display: flex; align-items: center; gap: 8px; }
  .filechooser-sel { max-width: 240px; font-size: 12px; color: var(--fg-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .filechooser-back { display: none; }
  .filechooser-newform { display: flex; align-items: center; gap: 6px; }
  .filechooser-newerr { color: var(--danger); font-size: 12px; }
  @media (max-width: 640px) {
    .filechooser-col { flex-basis: 100%; }
    .filechooser-col:not(:last-child) { display: none; }
    .filechooser-back { display: inline-flex; }
  }
}
```

- [ ] **Step 3: Write `pages/files.css`**

New rules, plus the migrated ones named in the comment:

```css
/* The Files pages: the list and grid, the type filter, sorting, notes. Components (table.files,
   .thumb, .chip, .view-toggle) come from components.css; these are the page's own classes. */
@layer pages {
  .files-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 16px; }
  .files-grid .thumb { width: 100%; height: 140px; }
  .sort-form { display: flex; align-items: center; gap: 8px; margin: 0 0 12px; }
  .hidden-toggle { margin: 0 0 10px; font-size: 12px; }
  .upload-to-project { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; margin: 0 0 12px; }
  .upload-alt { font-size: 12px; }

  /* MIGRATED VERBATIM (old application.css 639-657): .ext-filter, .ext-picker, .ext-picker label,
     .ext-picker select, .ext-picker select:disabled, .ext-active, .ext-filter .chip,
     .ext-filter .chip:hover, .ext-filter .chip.active, .ext-filter .chip .chip-x,
     .ext-filter .chip.active:hover — with the substitution table applied. */

  /* Column classes files/_list.html.erb carries (Task 3), so a phone drops columns instead of
     scrolling sideways. Order of loss: modified, version, then size. */
  @media (max-width: 719px) { table.files .col-modified, table.files .col-version { display: none; } }
  @media (max-width: 479px) { table.files .col-size, table.files .col-folder { display: none; } }

  /* MIGRATED VERBATIM (old notes.css): .notes-panel, .notes-panel h2, .note, .note-body :first-child,
     .note-body :last-child, .note-meta — substitution table applied. (.note-badge, .file-menu and
     .note-popover are components now and are NOT copied here.) */

  /* MIGRATED VERBATIM (old projects.css): .attach-to-project, .attach-form, .attach-form select,
     .project-chip, .project-chip form, .chip-x, .chip-x:hover — these live on files/show. */
}
```

- [ ] **Step 4: Write `pages/projects.css`**

```css
/* The Projects hub: index tiles, the project page's panels, tasks, the build-log timeline,
   sheets. Panels, buttons, badges and fields are components. */
@layer pages {
  /* MIGRATED VERBATIM (old projects.css), substitution table applied, in this order:
     .projects-grid, .project-tile, .project-tile form, .project-card, .project-card:hover,
     .project-card:hover .thumb, .project-card .thumb, .project-thumb-empty, .project-name,
     .project-head, .project-head h1, .project-description,
     .project-panels and its @media (min-width: 900px) block, .photo-attach,
     .attachments-grid, .entry-photos, .attachment-tile, .attachment-tile .thumb,
     .attachment-tile.unavailable .thumb, .tile-meta, .entry-photo .thumb,
     .attachment-group, .attachment-group:last-child, .attachment-group details[open] > .attachment-group-head,
     .attachments-missing, .task-form input, .log-timeline, .log-entry, .entry-head, .entry-body,
     .tasks-group, .task-row, .task-actions, .picker-results, .picker-result, .picker-search,
     .picker-search input, .sheet-head, .sheet-head h1, .sheet-rename, .sheet-grid, .sheet-status,
     .sheet-status-error, .sheets-panel .sheet-row, .sheets-panel .sheet-row:last-child.
     NOT copied (they are components now): .btn*, .linkbtn.small, .badge*, .panel, .panel h2,
     .panel-head, .panel-actions, .field*, .field-inline*, .form-actions, .form-errors,
     .attachment-group-head (the heading rule), .attach-to-project, .attach-form*, .project-chip*,
     .chip-x* (those five are in pages/files.css). */
  .project-description { max-width: 72ch; font-size: 14px; line-height: 1.55; }
}
```

- [ ] **Step 5: Write `pages/models.css`**

```css
/* The model catalog: index toolbar, the detail page's two columns, the file tree, print log,
   and the shelves settings page. */
@layer pages {
  /* MIGRATED VERBATIM (old models.css), substitution table applied, in file order — every rule
     EXCEPT the three .badge.mstatus-* rules, which are components now. Literal hexes in this
     file (#f8fafc, #e5e7eb, #334155, #64748b, #eee, #f1f5f9, #fff) all have rows in the table;
     .file-tree-box keeps var(--thumb-stage) as its background because it is a paper-like list. */
}
```

- [ ] **Step 6: Write `pages/tools.css`**

```css
/* The /tools gallery, the addon host page, and the classes the addon BUNDLES build their own
   markup with (Box Generator, Generators, OpenSCAD). Those class names are a cross-repo contract
   (docs/invariants/addons.md, spec §10): restyle, never rename. */
@layer pages {
  /* MIGRATED VERBATIM (old application.css 352-379, 381-603 and 658-659), substitution table
     applied, in file order: .tools-grid, .addon-card*, .addon-icon, .addon-title, .addon-desc,
     .addon-permissions, ul.addon-permissions*, .addon-thumb*, .addon-thumb-empty,
     .box-search, .box-index*, .box-toc*, .box-group*, .box-saved*, .addon-params dd,
     .saved-boxes*, .box-noresults, the @media (max-width: 1080px) block, .box-editor*,
     .box-params, .box-field*, the @media (max-width: 640px) block, .box-actions*, the
     @media (max-width: 720px) blocks, .box-side*, .box-preview*, .box-topview*, .tv-*,
     .generator-*, .box-prior*, .box-help*, .param-groups-head, .param-groups-title,
     .param-group*, .param-group-adv*. */
}
```

- [ ] **Step 7: Write `pages/preview.css`**

```css
/* The preview surfaces on a file page: image/PDF/text previews, the CodeMirror viewer and editor,
   the repository banner, the commit box and staging groups, file history, the 3D viewer, the
   Measure view and the LightBurn settings panel. docs/invariants/measure-view.md and
   files-preview.md govern the behaviour behind these classes; this file only paints them. */
@layer pages {
  /* MIGRATED VERBATIM (old application.css 85-92, 94-133, 136-239, 241-307, 605-620),
     substitution table applied, in file order. Keep every comment that travels with a rule —
     several explain source-order dependencies (.measure-contour--marked after --hover) that
     the tests pin by computed style. Measure's literal layer colours (#2b7, #d40, the rgba tints,
     #888) STAY literal: they are the file's own colours, not the theme's. */
}
```

- [ ] **Step 8: Write `vendor-overrides.css`**

```css
/* THE ONE UNLAYERED SHEET, LINKED LAST. Lexxy, CodeMirror and the spreadsheet grid ship their
   own unlayered CSS, and an unlayered rule outranks every layered one — so the overrides that
   must beat them cannot live in a layer. Nothing else in the app may be unlayered
   (test/css_hygiene_test.rb). Tokens only; no new colours. */

/* Lexxy (the build-log and notes editors): the element is <lexxy-editor class="lexxy-content">
   in light DOM. */
lexxy-editor, lexxy-editor.lexxy-content {
  background: var(--surface); color: var(--fg); border: 1px solid var(--line); border-radius: var(--radius-panel);
  font-family: var(--font-ui);
}
lexxy-editor:focus-within { border-color: var(--accent); }
lexxy-editor button, lexxy-toolbar button { color: var(--fg-muted); }
lexxy-editor button:hover, lexxy-toolbar button:hover { color: var(--fg); background: var(--raised); }
lexxy-toolbar { border-bottom: 1px solid var(--line); background: var(--surface); }
.lexxy-content a { color: var(--accent); }

/* CodeMirror 6 (the source viewer, the editor, diffs, history blobs). */
.cm-editor { background: var(--surface); color: var(--fg); border: 1px solid var(--line); border-radius: var(--radius-panel); }
.cm-editor .cm-gutters { background: var(--raised); color: var(--fg-muted); border-right: 1px solid var(--line); }
.cm-editor .cm-activeLine { background: color-mix(in srgb, var(--accent) 8%, transparent); }
.cm-editor .cm-activeLineGutter { background: color-mix(in srgb, var(--accent) 12%, var(--raised)); }
.cm-editor .cm-selectionBackground, .cm-editor ::selection { background: color-mix(in srgb, var(--accent) 30%, transparent); }
.cm-editor .cm-cursor { border-left-color: var(--fg); }

/* The spreadsheet grid (jspreadsheet CE + jsuites) stays a LIGHT ISLAND in PR 1 — spec §13 names
   it as the one third-party surface that may keep its own scheme. color-scheme: light keeps its
   native form controls readable inside the dark shell. */
.sheet-grid { color-scheme: light; background: #ffffff; color: #1a1e26; border-radius: var(--radius-panel); padding: 4px; }
```

- [ ] **Step 9: Delete the three old sheets and relink the layout**

```bash
git rm -q app/assets/stylesheets/projects.css app/assets/stylesheets/models.css app/assets/stylesheets/notes.css
```

In `app/views/layouts/application.html.erb` replace the five `stylesheet_link_tag` lines (`application`, `projects`, `notes`, `models`, `lexxy`) with:

```erb
    <%= stylesheet_link_tag "application", "components", "shell",
                            "pages/files", "pages/projects", "pages/models", "pages/tools", "pages/preview",
                            "data-turbo-track": "reload" %>
    <%= stylesheet_link_tag "lexxy", "data-turbo-track": "reload" %>
    <%= stylesheet_link_tag "vendor-overrides", "data-turbo-track": "reload" %>
```

`shell.css` does not exist until Task 3; Propshaft raises `Propshaft::MissingAssetError` for a linked file that is absent, so create it now as a placeholder that Task 3 replaces:

```css
/* The application shell. Replaced in Task 3. */
@layer shell {
  .shell-placeholder { display: none; }
}
```

- [ ] **Step 10: Boot check — every page still renders**

```bash
export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)
bin/rails test test/integration/web/current_project_topbar_test.rb test/controllers/tools/addons_controller_test.rb test/integration/web/files_type_filter_test.rb
```

Expected: all green (these render the layout, an addon page and the Files list; a missing asset would 500 them).

- [ ] **Step 11: Write the failing CSS hygiene test**

`test/css_hygiene_test.rb`:

```ruby
require "test_helper"

# Guards the stylesheet architecture from the shell spec
# (docs/superpowers/specs/2026-09-03-web-shell-and-design-system-design.md §4.1, §7):
#
# - `application.css` OPENS with the @layer order statement, because the first @layer statement
#   the browser meets fixes the order for the document; a rule that lands in a layer before the
#   order is declared gets an order nobody chose.
# - EVERY rule of ours sits inside a layer. An unlayered rule outranks every layered one, so a
#   stray unlayered `.btn {}` in a page sheet would silently beat components.css — which is the
#   pre-2026-09 bug (two `.btn` definitions, the later file winning) with a new face.
# - `vendor-overrides.css` is the ONE unlayered sheet: it has to beat Lexxy's, CodeMirror's and the
#   spreadsheet's own unlayered CSS, and a layered rule cannot.
# - A COMPONENT SELECTOR IS DEFINED ONCE, in components.css. A page sheet may qualify a component
#   inside a container (`.files-grid .thumb`) — that is a different selector — but never redeclare
#   the bare one.
# - The three sheets the migration deleted stay deleted, and the layout links ours before the
#   vendor sheet and the overrides last.
#
# THE SCAN ASSERTS ITS OWN NON-VACUITY (§14e): a sheet that parses to zero rules fails rather than
# passing over nothing.
class CssHygieneTest < ActiveSupport::TestCase
  SHEETS_DIR = Rails.root.join("app/assets/stylesheets")
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")
  LAYER_ORDER = "@layer tokens, base, components, shell, pages;".freeze
  OURS = %w[
    application.css components.css shell.css
    pages/files.css pages/projects.css pages/models.css pages/tools.css pages/preview.css
  ].freeze
  OVERRIDES = "vendor-overrides.css".freeze
  DELETED = %w[projects.css models.css notes.css].freeze
  COMPONENT_SELECTORS = %w[
    .btn .linkbtn .chip .view-toggle .toolbar .breadcrumb .pager .page-head .panel .thumb
    .grid-card .badge dl.meta .empty .flash .file-menu .note-popover .filechooser
    table.files .folder-field-btn
  ].freeze

  def read(name) = SHEETS_DIR.join(name).read

  def strip_comments(css) = css.gsub(%r{/\*.*?\*/}m, "")

  # Every rule as [selector_text, enclosing_block_heads]. A block whose head starts with "@" is an
  # at-rule (layer, media, font-face, keyframes) and is not itself a rule; its children are.
  def rules(css)
    out = []
    stack = []
    buf = +""
    strip_comments(css).each_char do |ch|
      case ch
      when "{"
        head = buf.strip
        stack << head
        out << [ head, stack.dup ] unless head.start_with?("@")
        buf = +""
      when "}"
        stack.pop
        buf = +""
      when ";"
        buf = +""
      else
        buf << ch
      end
    end
    out
  end

  def layered?(enclosing) = enclosing.any? { |head| head.start_with?("@layer ") }

  def selectors_of(rule_head) = rule_head.split(",").map(&:strip)

  test "application.css opens with the layer order statement" do
    assert strip_comments(read("application.css")).lstrip.start_with?(LAYER_ORDER),
           "the first statement of application.css must be #{LAYER_ORDER}"
    OURS.each do |sheet|
      statements = strip_comments(read(sheet)).scan(/@layer\s+[\w, ]+;/)
      assert_equal (sheet == "application.css" ? [ LAYER_ORDER ] : []), statements,
                   "#{sheet}: the layer ORDER is declared once, in application.css"
    end
  end

  test "every rule in our sheets sits inside a cascade layer" do
    OURS.each do |sheet|
      parsed = rules(read(sheet))
      assert_operator parsed.size, :>, 5, "#{sheet} parsed to #{parsed.size} rules — the scan is vacuous"
      unlayered = parsed.reject { |_sel, enclosing| layered?(enclosing) }.map(&:first)
      assert_empty unlayered, "#{sheet}: rules outside any @layer: #{unlayered.inspect}"
    end
  end

  test "vendor-overrides.css is the one unlayered sheet" do
    parsed = rules(read(OVERRIDES))
    assert_operator parsed.size, :>, 3, "#{OVERRIDES} parsed to #{parsed.size} rules — the scan is vacuous"
    layered = parsed.select { |_sel, enclosing| layered?(enclosing) }.map(&:first)
    assert_empty layered, "#{OVERRIDES} must stay unlayered so it can outrank the vendor sheets: #{layered.inspect}"
  end

  test "a component selector is defined in components.css and nowhere else" do
    defined = rules(read("components.css")).flat_map { |sel, _| selectors_of(sel) }
    COMPONENT_SELECTORS.each do |component|
      assert_includes defined, component, "components.css does not define #{component}"
    end
    (OURS - [ "components.css" ] + [ OVERRIDES ]).each do |sheet|
      redeclared = rules(read(sheet)).flat_map { |sel, _| selectors_of(sel) } & COMPONENT_SELECTORS
      assert_empty redeclared, "#{sheet} redeclares component selector(s) #{redeclared.inspect}; only components.css may"
    end
  end

  test "the migrated sheets stay deleted" do
    DELETED.each { |name| refute SHEETS_DIR.join(name).exist?, "#{name} came back; its rules live under pages/ now" }
  end

  test "the layout links our sheets first, lexxy after, and the overrides last" do
    layout = LAYOUT.read
    order = %w[application components shell pages/files pages/projects pages/models pages/tools pages/preview lexxy vendor-overrides]
    positions = order.map { |name| [ name, layout.index(%("#{name}")) ] }
    positions.each { |name, pos| assert pos, "the layout does not link #{name}" }
    assert_equal positions.map(&:last), positions.map(&:last).sort, "link order is #{positions.map(&:first).inspect}; it must be #{order.inspect}"
  end
end
```

- [ ] **Step 12: Run it**

```bash
bin/rails test test/css_hygiene_test.rb
```

Expected: 6 runs, 0 failures. If "a component selector is defined…" fails naming a migrated rule (for example `.chip` copied into `pages/files.css` from the old `.ext-filter .chip` — that one is qualified and allowed; a bare one is not), remove the bare duplicate from the page sheet.

- [ ] **Step 13: Mutation-check the guard, reporting each result**

```bash
printf '\n.btn { color: red; }\n' >> app/assets/stylesheets/pages/files.css
bin/rails test test/css_hygiene_test.rb -n /nowhere/     # expected: 1 failure naming pages/files.css and .btn
git checkout -- app/assets/stylesheets/pages/files.css

sed -i '' 's/^@layer shell {/\/\* no layer \*\/ {/' app/assets/stylesheets/shell.css
bin/rails test test/css_hygiene_test.rb -n /cascade/     # expected: 1 failure naming shell.css
git checkout -- app/assets/stylesheets/shell.css

sed -i '' '1,/^@layer tokens, base, components, shell, pages;/{/^@layer tokens, base, components, shell, pages;/d;}' app/assets/stylesheets/application.css
bin/rails test test/css_hygiene_test.rb -n /opens/       # expected: 1 failure
git checkout -- app/assets/stylesheets/application.css
git status --porcelain                                    # expected: only the intended new/deleted files
```

- [ ] **Step 14: Run the share leg and style**

```bash
bin/ci style && bin/rails test
```

Expected: rubocop clean; the suite green with the same run count as before this task (no test asserts a colour).

- [ ] **Step 15: Commit**

```bash
git add app/assets/stylesheets app/views/layouts/application.html.erb test/css_hygiene_test.rb
git commit -m "One design system: tokens and layers, one definition per component, page sheets, a guard"
```

---

### Task 3: The shell — layout, rail, top bar, toasts, theme and rail cookies, controllers

**Files:**
- Create: `app/helpers/shell_helper.rb`, `app/views/layouts/_rail.html.erb`, `app/views/layouts/_topbar.html.erb`, `app/views/layouts/_flash.html.erb`, `app/views/layouts/_tabbar.html.erb`, `app/javascript/controllers/theme_controller.js`, `app/javascript/controllers/rail_controller.js`, `app/javascript/controllers/toast_controller.js`, `public/favicon.ico`
- Rewrite: `app/views/layouts/application.html.erb`, `app/assets/stylesheets/shell.css`
- Modify: `app/views/projects/show.html.erb`, `app/views/projects/sheets/show.html.erb`, `app/views/models/show.html.erb` (breadcrumb into `content_for :crumbs`), `app/views/files/_list.html.erb` (column classes), `app/views/pwa/manifest.json.erb`
- Test: `test/integration/web/shell_layout_test.rb`

- [ ] **Step 1: Write the failing request tests**

`test/integration/web/shell_layout_test.rb`:

```ruby
require "test_helper"

module Web
  # The application shell (spec §5): the rail with one active section, the current-project card
  # that keeps the switcher the topbar tests pin, the top bar's breadcrumb slot and search field,
  # the theme and rail-collapse cookies rendered server-side (no inline script under the CSP),
  # and the self-hosted fonts actually resolving.
  class ShellLayoutTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "shell-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "a signed-in page renders the rail with exactly one active section" do
      get files_path
      assert_response :success
      assert_select "body.app-shell aside.rail"
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Files"
    end

    test "each top-level section lights its own link" do
      { projects_path => "Projects", models_path => "Models", tools_path => "Tools",
        trash_index_path => "Trash" }.each do |path, label|
        get path
        assert_response :success
        assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: label
      end
    end

    test "a nested controller lights its family" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      get new_project_attachment_path(project)
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Projects"
      get shelves_path
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Models"
    end

    test "the sign-in page has no rail and no shell class" do
      delete destroy_user_session_path
      get new_user_session_path
      assert_response :success
      assert_select "aside.rail", count: 0
      assert_select "body.app-shell", count: 0
    end

    test "the theme comes from the cookie and defaults to dark" do
      get files_path
      assert_select "html[data-theme='dark']"
      assert_select "meta[name='theme-color'][content='#15181d']"
      assert_select "meta[name='color-scheme'][content='dark']"

      cookies[:theme] = "light"
      get files_path
      assert_select "html[data-theme='light']"
      assert_select "meta[name='theme-color'][content='#f4f5f7']"
      assert_select "meta[name='color-scheme'][content='light']"

      cookies[:theme] = "system"
      get files_path
      assert_select "html[data-theme='system']"
      assert_select "meta[name='color-scheme'][content='light dark']"

      cookies[:theme] = "purple"
      get files_path
      assert_select "html[data-theme='dark']"
    end

    test "the rail collapse state comes from the cookie" do
      get files_path
      assert_select "body.rail--collapsed", count: 0
      cookies[:rail] = "collapsed"
      get files_path
      assert_select "body.rail--collapsed"
      assert_select "aside.rail [data-action='rail#toggle'][aria-expanded='false']"
    end

    test "the top bar carries the library search on every page" do
      get projects_path
      assert_select "header.topbar form.topbar-search[action=?][method='get'] input[type='search'][name='q']", files_path
    end

    test "a page with a breadcrumb renders it in the top bar, not in main" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      get project_path(project)
      assert_select "header.topbar nav.breadcrumb a", text: "Projects"
      assert_select "main nav.breadcrumb", count: 0
      get models_path
      assert_select "header.topbar .topbar-title", text: "Models"
    end

    test "the current-project card keeps the switcher the topbar tests pin" do
      @user.maker_projects.create!(name: "Desk Lamp")
      get files_path
      assert_select "aside.rail .current-project select[name='project_id']"
      assert_select "aside.rail form[action=?] select[name='project_id'] option[value='']", current_project_path,
                    text: /none/i
      assert_select "aside.rail .current-project-hint", text: /land here/
    end

    test "the phone tab bar mirrors the rail" do
      get trash_index_path
      assert_select "nav.tabbar a.tabbar-link", count: 5
      assert_select "nav.tabbar a.tabbar-link[aria-current='page']", count: 1, text: "Trash"
    end

    test "the stylesheet references fingerprinted, servable Plex fonts" do
      get Rails.application.assets.resolver.resolve("application.css")
      assert_response :success
      css = response.body
      %w[ibm-plex-sans ibm-plex-sans-italic ibm-plex-mono-400 ibm-plex-mono-500].each do |name|
        font = css[%r{/assets/#{name}-[0-9a-f]{8,}\.woff2}]
        assert font, "application.css does not reference a fingerprinted #{name}.woff2"
        get font
        assert_response :success
        assert_equal "font/woff2", response.media_type
        assert response.body.start_with?("wOF2"), "#{font} is not a woff2 file"
      end
    end
  end
end
```

Note on the last test: if `assert_equal "font/woff2"` fails with another media type while the `wOF2` assertion passes, the file is being served and Rack names its type differently — pin whatever `response.media_type` prints; the claim is "served as a font", not the exact string.

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/integration/web/shell_layout_test.rb
```

Expected: failures on `aside.rail`, `html[data-theme]`, `header.topbar`, `nav.tabbar` (the layout has none of them yet); the font test passes already (Task 2 wrote the `@font-face` rules).

- [ ] **Step 3: Write the helper**

`app/helpers/shell_helper.rb`:

```ruby
# The application shell's server-side state (spec §5): which rail section this request belongs
# to, and the two cookies the layout renders into the first byte of HTML so there is no flash of
# the wrong theme and no inline script — the CSP nonces script-src (§14e), and a script that
# runs before paint is exactly the kind of thing not to add.
module ShellHelper
  THEMES = %w[dark light system].freeze

  # controller_path's FIRST segment, so projects/tasks, models/print_runs and tools/addons all
  # resolve to their family. A controller not listed here lights nothing, which is correct for
  # Devise's pages (they render without the rail anyway).
  SECTIONS = {
    "files" => %w[files library_browse notes repo_commits repo_histories],
    "models" => %w[models shelves],
    "projects" => %w[projects current_project],
    "tools" => %w[tools],
    "trash" => %w[trash]
  }.freeze

  ICON_PATHS = {
    files: "M2 4h5l2 2h5v7H2z",
    models: "M8 2l6 3v6l-6 3-6-3V5z M2 5l6 3 6-3 M8 8v6",
    projects: "M2 3h12v10H2z M6 3v10 M10 3v10",
    tools: "M10.5 2.5a3.5 3.5 0 0 0-3.2 4.9L2 12.7 3.3 14l5.3-5.3a3.5 3.5 0 0 0 4.9-3.2L11.6 7.4 9.6 6.4l1.9-1.9z",
    trash: "M3 4h10 M6 4V2.5h4V4 M4.5 4l.8 9.5h5.4L11.5 4 M7 7v4.5 M9 7v4.5",
    search: "M7 2.5a4.5 4.5 0 1 0 0 9 4.5 4.5 0 0 0 0-9z M10.5 10.5L14 14",
    theme: "M8 2a6 6 0 0 0 0 12V2z M8 2a6 6 0 1 1 0 12",
    collapse: "M3 8h10 M7 4L3 8l4 4"
  }.freeze

  # An unknown or absent cookie is the default. The cookie is client-written (theme_controller.js)
  # and is never trusted for anything but this enum.
  def ui_theme
    value = cookies[:theme].to_s
    THEMES.include?(value) ? value : "dark"
  end

  def rail_collapsed? = cookies[:rail] == "collapsed"

  def body_classes
    classes = []
    classes << "app-shell" if respond_to?(:user_signed_in?) && user_signed_in?
    classes << "rail--collapsed" if rail_collapsed?
    classes.join(" ")
  end

  def rail_section
    head = controller_path.split("/").first
    SECTIONS.find { |_key, heads| heads.include?(head) }&.first
  end

  def rail_links
    [
      [ "files", "Files", files_path, :files ],
      [ "models", "Models", models_path, :models ],
      [ "projects", "Projects", projects_path, :projects ],
      [ "tools", "Tools", tools_path, :tools ],
      [ "trash", "Trash", trash_index_path, :trash ]
    ]
  end

  def rail_icon(name)
    tag.svg(viewBox: "0 0 16 16", class: "rail-icon", "aria-hidden": "true") do
      tag.path(d: ICON_PATHS.fetch(name), fill: "none", stroke: "currentColor",
               "stroke-width": "1.5", "stroke-linejoin": "round", "stroke-linecap": "round")
    end
  end

  # The page's own name for the top bar when it supplies no breadcrumb: the title minus the
  # " — Tinkerex" suffix every page appends.
  def page_title_text
    content_for(:title).to_s.sub(/\s+[—-]\s+Tinkerex\z/, "").presence || "Tinkerex"
  end

  def theme_color_hex = ui_theme == "light" ? "#f4f5f7" : "#15181d"

  def color_scheme_meta
    case ui_theme
    when "light" then "light"
    when "system" then "light dark"
    else "dark"
    end
  end
end
```

- [ ] **Step 4: Write the layout**

Replace `app/views/layouts/application.html.erb` entirely:

```erb
<!DOCTYPE html>
<html lang="en" data-theme="<%= ui_theme %>">
  <head>
    <title><%= content_for(:title) || "Tinkerex" %></title>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="application-name" content="Tinkerex">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="color-scheme" content="<%= color_scheme_meta %>">
    <meta name="theme-color" content="<%= theme_color_hex %>">
    <%= csrf_meta_tags %>
    <%= csp_meta_tag %>

    <%= yield :head %>

    <link rel="icon" href="/favicon.ico" sizes="32x32">
    <link rel="icon" href="/icon.svg" type="image/svg+xml">
    <link rel="apple-touch-icon" href="/icon.png">

    <%= stylesheet_link_tag "application", "components", "shell",
                            "pages/files", "pages/projects", "pages/models", "pages/tools", "pages/preview",
                            "data-turbo-track": "reload" %>
    <%= stylesheet_link_tag "lexxy", "data-turbo-track": "reload" %>
    <%= stylesheet_link_tag "vendor-overrides", "data-turbo-track": "reload" %>
    <%= javascript_importmap_tags "application", importmap: (@importmap || Rails.application.importmap) %>
  </head>

  <body class="<%= body_classes %>">
    <% if respond_to?(:user_signed_in?) && user_signed_in? %>
      <%= render "layouts/rail" %>
      <div class="shell-main">
        <%= render "layouts/topbar" %>
        <%= render "layouts/flash" %>
        <%# Pages that need the full width opt in with content_for :container_class, "container-wide"
            (the addon host page does, from its manifest). Inert everywhere else. %>
        <main class="container <%= content_for(:container_class) %>">
          <%= yield %>
        </main>
      </div>
      <%= render "layouts/tabbar" %>
    <% else %>
      <%= render "layouts/flash" %>
      <main class="container auth-main">
        <%= yield %>
      </main>
    <% end %>
  </body>
</html>
```

`app/views/layouts/_rail.html.erb`:

```erb
<%# The rail (spec §5.1-5.2). The current-project card KEEPS the form and the select that
    current_project_topbar_test, box_revisions_test and addon_bundle_test pin
    (form[action=current_project_path] select[name=project_id], .current-project select). %>
<aside class="rail" id="rail" data-controller="rail">
  <%= link_to files_path, class: "brand", "aria-label": "Tinkerex home" do %>
    <span class="brand-mark" aria-hidden="true"></span><span class="brand-name">Tinkerex</span>
  <% end %>

  <% choices = current_project_choices %>
  <% if choices.any? %>
    <%= form_with url: current_project_path, method: :patch, data: { turbo: false },
                  class: "current-project-form" do %>
      <label class="current-project">
        <span class="current-project-label">Current project</span>
        <span class="current-project-name"><%= current_project&.name || "None" %></span>
        <span class="current-project-hint">Uploads and tool output land here</span>
        <%= select_tag :project_id,
              options_for_select([ [ "— none —", "" ] ] + choices, current_project&.id),
              onchange: "this.form.requestSubmit()", "aria-label": "Switch current project" %>
      </label>
    <% end %>
  <% end %>

  <nav class="rail-nav" aria-label="Main">
    <ul>
      <% rail_links.each do |key, label, path, icon| %>
        <li>
          <%= link_to path, class: "rail-link", title: label,
                      "aria-current": (rail_section == key ? "page" : nil) do %>
            <%= rail_icon(icon) %><span class="rail-label"><%= label %></span>
          <% end %>
        </li>
      <% end %>
    </ul>
  </nav>

  <div class="rail-foot">
    <button type="button" class="rail-btn" data-controller="theme" data-action="theme#cycle"
            aria-label="Theme: <%= ui_theme %>">
      <%= rail_icon(:theme) %><span data-theme-target="label">Theme: <%= ui_theme %></span>
    </button>
    <button type="button" class="rail-btn" data-action="rail#toggle" data-rail-target="toggle"
            aria-expanded="<%= rail_collapsed? ? "false" : "true" %>" aria-label="Collapse navigation">
      <%= rail_icon(:collapse) %><span>Collapse</span>
    </button>
    <span class="rail-user" title="<%= current_user.email %>"><%= current_user.email %></span>
    <%= button_to "Sign out", destroy_user_session_path, method: :delete, class: "rail-btn" %>
  </div>
</aside>
```

`app/views/layouts/_topbar.html.erb`:

```erb
<%# The top bar (spec §5.3): the page's breadcrumb when it supplies one via content_for :crumbs,
    else its title; and the library search. @q is set by FilesController#index (Task 4) and is
    nil everywhere else, which renders an empty field. %>
<header class="topbar">
  <div class="topbar-crumbs">
    <% if content_for?(:crumbs) %>
      <%= content_for(:crumbs) %>
    <% else %>
      <span class="topbar-title"><%= page_title_text %></span>
    <% end %>
  </div>
  <%= form_with url: files_path, method: :get, class: "topbar-search", role: "search",
                data: { turbo: false } do %>
    <%= rail_icon(:search) %>
    <input type="search" name="q" value="<%= @q %>" placeholder="Search files"
           aria-label="Search files" autocomplete="off">
    <kbd class="topbar-kbd" aria-hidden="true">⌘K</kbd>
  <% end %>
</header>
```

`app/views/layouts/_flash.html.erb`:

```erb
<%# Toasts (spec §5.5). The classes are the ones four system tests assert on. Only notice and
    alert are drawn, exactly as the old layout did. A notice removes itself (toast_controller.js);
    an alert stays until dismissed. %>
<div class="flash-stack" data-controller="toast" aria-live="polite">
  <% if flash[:notice].present? %>
    <div class="flash flash-notice" role="status" data-toast-target="item">
      <span class="flash-text"><%= flash[:notice] %></span>
      <button type="button" class="flash-close" aria-label="Dismiss" data-action="toast#dismiss">&times;</button>
    </div>
  <% end %>
  <% if flash[:alert].present? %>
    <div class="flash flash-alert" role="alert" data-toast-target="item">
      <span class="flash-text"><%= flash[:alert] %></span>
      <button type="button" class="flash-close" aria-label="Dismiss" data-action="toast#dismiss">&times;</button>
    </div>
  <% end %>
</div>
```

`app/views/layouts/_tabbar.html.erb`:

```erb
<%# The phone navigation (spec §5.4): the same five links as the rail, shown below 720px by
    shell.css and hidden above it. %>
<nav class="tabbar" aria-label="Main">
  <% rail_links.each do |key, label, path, icon| %>
    <%= link_to path, class: "tabbar-link", "aria-current": (rail_section == key ? "page" : nil) do %>
      <%= rail_icon(icon) %><span><%= label %></span>
    <% end %>
  <% end %>
</nav>
```

- [ ] **Step 5: Write the three controllers**

`app/javascript/controllers/theme_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// The theme button in the rail (spec §5.7). Cycles dark -> light -> system, stamps the choice on
// <html data-theme> for this page and writes the `theme` cookie so the layout renders the next
// page with it already applied (no flash, no inline script). ShellHelper#ui_theme treats any
// other cookie value as dark.
const ORDER = ["dark", "light", "system"]
const META = { dark: ["dark", "#15181d"], light: ["light", "#f4f5f7"], system: ["light dark", "#15181d"] }

export default class extends Controller {
  static targets = ["label"]

  connect() {
    this.render(this.current())
  }

  cycle() {
    const next = ORDER[(ORDER.indexOf(this.current()) + 1) % ORDER.length]
    document.documentElement.dataset.theme = next
    document.cookie = `theme=${next}; path=/; max-age=31536000; samesite=lax`
    document.querySelector("meta[name=color-scheme]")?.setAttribute("content", META[next][0])
    document.querySelector("meta[name=theme-color]")?.setAttribute("content", META[next][1])
    this.render(next)
  }

  current() {
    const value = document.documentElement.dataset.theme
    return ORDER.includes(value) ? value : "dark"
  }

  render(theme) {
    this.element.setAttribute("aria-label", `Theme: ${theme}`)
    if (this.hasLabelTarget) this.labelTarget.textContent = `Theme: ${theme}`
  }
}
```

`app/javascript/controllers/rail_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// The rail (spec §5.4): the collapse button toggles `rail--collapsed` on <body> and writes the
// `rail` cookie so the layout renders the next page already collapsed; Cmd/Ctrl-K focuses the
// top-bar search. Listeners attach on connect and detach on disconnect because Turbo swaps the
// rail on every navigation.
export default class extends Controller {
  static targets = ["toggle"]

  connect() {
    this.onKeydown = (event) => this.shortcut(event)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  toggle() {
    const collapsed = document.body.classList.toggle("rail--collapsed")
    document.cookie = `rail=${collapsed ? "collapsed" : "expanded"}; path=/; max-age=31536000; samesite=lax`
    if (this.hasToggleTarget) this.toggleTarget.setAttribute("aria-expanded", String(!collapsed))
  }

  shortcut(event) {
    if (!(event.metaKey || event.ctrlKey) || event.key.toLowerCase() !== "k") return
    const field = document.querySelector(".topbar-search input[type=search]")
    if (!field) return
    event.preventDefault()
    field.focus()
    field.select()
  }
}
```

`app/javascript/controllers/toast_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// The flash stack (spec §5.5). A notice removes itself after NOTICE_MS; an alert stays until its
// close button is pressed. Timers are cleared on disconnect so a Turbo navigation mid-countdown
// does not remove an element that no longer exists.
const NOTICE_MS = 6000

export default class extends Controller {
  static targets = ["item"]

  connect() {
    this.timers = this.itemTargets
      .filter((item) => item.classList.contains("flash-notice"))
      .map((item) => setTimeout(() => item.remove(), NOTICE_MS))
  }

  disconnect() {
    (this.timers || []).forEach(clearTimeout)
  }

  dismiss(event) {
    event.currentTarget.closest(".flash")?.remove()
  }
}
```

- [ ] **Step 6: Write `shell.css`**

Replace the placeholder entirely:

```css
/* The application shell (spec §5): the rail and its current-project card, the top bar, the phone
   tab bar, the content container, the toast stack, the auth card, and the three widths. */
@layer shell {
  body.app-shell { display: grid; grid-template-columns: var(--rail-width) minmax(0, 1fr); min-height: 100vh; }
  body.app-shell.rail--collapsed { grid-template-columns: var(--rail-collapsed-width) minmax(0, 1fr); }

  .rail {
    position: sticky; top: 0; height: 100vh; display: flex; flex-direction: column; gap: 14px;
    padding: 12px 8px; background: var(--surface); border-right: 1px solid var(--line); overflow: hidden auto;
  }
  .brand { display: flex; align-items: center; gap: 8px; padding: 2px 8px; color: var(--fg); font-weight: 600; white-space: nowrap; }
  .brand:hover { text-decoration: none; }
  .brand-mark { width: 18px; height: 18px; flex: 0 0 auto; border-radius: 4px; background: var(--accent); }

  .current-project-form { margin: 0; }
  .current-project {
    display: flex; flex-direction: column; gap: 2px; padding: 10px 10px 8px;
    border-radius: var(--radius-panel); background: var(--accent-soft);
    border: 1px solid color-mix(in srgb, var(--accent) 35%, transparent);
  }
  .current-project-label { font: 600 10px/1.4 var(--font-mono); text-transform: uppercase; letter-spacing: .1em; color: var(--accent); }
  .current-project-name { font-weight: 600; color: var(--fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .current-project-hint { font-size: 11px; color: var(--fg-muted); }
  .current-project select { margin-top: 6px; width: 100%; min-height: 26px; padding: 3px 24px 3px 8px; font-size: 12px; }

  .rail-nav ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
  .rail-link {
    display: flex; align-items: center; gap: 10px; padding: 7px 8px; border-radius: var(--radius-control);
    border-left: 2px solid transparent; color: var(--fg-muted); font-weight: 500; white-space: nowrap;
  }
  .rail-link:hover { color: var(--fg); background: var(--raised); text-decoration: none; }
  .rail-link[aria-current="page"] { color: var(--accent); border-left-color: var(--accent); background: var(--accent-soft); }
  .rail-icon { width: 16px; height: 16px; flex: 0 0 auto; }

  .rail-foot { margin-top: auto; display: flex; flex-direction: column; gap: 4px; padding: 8px 2px 0; border-top: 1px solid var(--line); }
  .rail-foot form { margin: 0; }
  .rail-btn {
    display: inline-flex; align-items: center; gap: 8px; width: 100%; padding: 5px 6px;
    background: none; border: 0; border-radius: var(--radius-control); color: var(--fg-muted);
    font: 500 12px/1.4 var(--font-ui); text-align: left; cursor: pointer;
  }
  .rail-btn:hover { color: var(--fg); background: var(--raised); }
  .rail-user { padding: 2px 6px; font: 11px/1.4 var(--font-mono); color: var(--fg-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  /* Collapsed: icons only. The same rules apply below 1100px whatever the cookie says. */
  .rail--collapsed .rail { padding-inline: 6px; }
  .rail--collapsed .brand { justify-content: center; padding: 2px 0; }
  .rail--collapsed .brand-name, .rail--collapsed .rail-label, .rail--collapsed .current-project,
  .rail--collapsed .rail-user, .rail--collapsed .rail-btn span { display: none; }
  .rail--collapsed .rail-link, .rail--collapsed .rail-btn { justify-content: center; padding-inline: 0; }
  .rail--collapsed .rail-foot form button { justify-content: center; }

  .shell-main { min-width: 0; display: flex; flex-direction: column; }
  .topbar {
    position: sticky; top: 0; z-index: 20; display: flex; align-items: center; gap: 16px;
    min-height: var(--topbar-height); padding: 0 24px; background: var(--surface); border-bottom: 1px solid var(--line);
  }
  .topbar-crumbs { flex: 1 1 auto; min-width: 0; display: flex; align-items: center; }
  .topbar-title { font-weight: 600; }
  .topbar-search {
    display: flex; align-items: center; gap: 8px; flex: 0 1 320px; min-width: 160px; height: 30px; padding: 0 8px;
    border: 1px solid var(--line); border-radius: var(--radius-control); background: var(--bg); color: var(--fg-muted);
  }
  .topbar-search:focus-within { border-color: var(--accent); }
  .topbar-search input { flex: 1; min-width: 0; min-height: 0; padding: 0; border: 0; background: transparent; color: var(--fg); font: 13px/1.4 var(--font-ui); }
  .topbar-search input:focus-visible { outline: none; }
  .topbar-search input::-webkit-search-cancel-button { filter: grayscale(1); }
  .topbar-kbd { padding: 3px 5px; border: 1px solid var(--line); border-radius: 3px; font: 500 10px/1 var(--font-mono); color: var(--fg-muted); }

  main.container { width: 100%; max-width: 1360px; margin: 0 auto; padding: 20px 24px 64px; }
  main.container.container-wide { max-width: none; }

  .flash-stack {
    position: fixed; top: 12px; right: 12px; z-index: 900; display: flex; flex-direction: column; gap: 8px;
    width: min(420px, calc(100vw - 24px)); pointer-events: none;
  }
  .flash-stack > .flash { box-shadow: var(--shadow-float); pointer-events: auto; }
  .flash-stack:empty { display: none; }

  .tabbar { display: none; }

  /* Signed-out pages: the auth card (Task 5 writes the markup). */
  .auth-main { max-width: 440px; padding-top: 48px; }
  .auth-card { padding: 24px; border: 1px solid var(--line); border-radius: var(--radius-float); background: var(--surface); }
  .auth-card .brand { padding: 0; margin-bottom: 18px; }
  .auth-card h2 { font-size: 18px; margin: 0 0 16px; }
  .auth-card .field input { max-width: none; }
  .auth-card .actions { margin-top: 8px; }
  .auth-hint { font-size: 12px; color: var(--fg-muted); }
  .auth-links { list-style: none; margin: 16px 0 0; padding: 12px 0 0; border-top: 1px solid var(--line); display: flex; flex-direction: column; gap: 6px; font-size: 12px; }
  #error_explanation {
    margin: 0 0 14px; padding: 10px 12px; border-radius: var(--radius-control);
    background: color-mix(in srgb, var(--danger) 14%, var(--surface)); color: var(--danger); font-size: 13px;
  }
  #error_explanation h2 { font-size: 13px; margin: 0 0 4px; }
  #error_explanation ul { margin: 0; padding-left: 18px; }
  .account-delete { margin-top: 24px; padding-top: 16px; border-top: 1px solid var(--line); }

  @media (max-width: 1099px) {
    body.app-shell { grid-template-columns: var(--rail-collapsed-width) minmax(0, 1fr); }
    .rail { padding-inline: 6px; }
    .brand { justify-content: center; padding: 2px 0; }
    .brand-name, .rail-label, .current-project, .rail-user, .rail-btn span { display: none; }
    .rail-link, .rail-btn { justify-content: center; padding-inline: 0; }
    .topbar { padding: 0 16px; }
    main.container { padding: 16px 16px 64px; }
  }

  @media (max-width: 719px) {
    body.app-shell { grid-template-columns: minmax(0, 1fr); padding-bottom: var(--tabbar-height); }
    .rail { display: none; }
    .tabbar {
      position: fixed; left: 0; right: 0; bottom: 0; z-index: 30; display: flex;
      height: var(--tabbar-height); background: var(--surface); border-top: 1px solid var(--line);
    }
    .tabbar-link { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 3px; color: var(--fg-muted); font-size: 10px; }
    .tabbar-link:hover { text-decoration: none; }
    .tabbar-link[aria-current="page"] { color: var(--accent); }
    .topbar { flex-wrap: wrap; gap: 6px 8px; padding: 6px 12px; }
    .topbar-search { flex: 1 1 100%; min-width: 0; }
    .topbar-kbd { display: none; }
    main.container { padding: 12px 12px 72px; }
    .page-head h1 { font-size: 18px; }
  }
}
```

- [ ] **Step 7: Move the three breadcrumbs into the top bar and class the list columns**

In `app/views/projects/show.html.erb`, wrap the existing `<nav class="breadcrumb" …>…</nav>` block:

```erb
<% content_for :crumbs do %>
  <nav class="breadcrumb" aria-label="Project path">
    <%= link_to "Projects", projects_path %>
    <span class="sep" aria-hidden="true">/</span>
    <span aria-current="page"><%= @project.name %></span>
  </nav>
<% end %>
```

Do the same in `app/views/projects/sheets/show.html.erb` and `app/views/models/show.html.erb`: the `nav.breadcrumb` element and its contents are unchanged, only wrapped in `content_for :crumbs do … end`. (`files/index.html.erb` gets the same treatment in Task 4, which owns that file.)

In `app/views/files/_list.html.erb` add a column class to every header and cell, in this order — `col-name`, `col-type`, `col-folder` (the `@flat` column), `col-size`, `col-version` (the `capabilities.versioned?` column), `col-modified`, `col-actions`. `sort_header` builds the `<th>`; give it a `col:` keyword (the column class) so the sortable headers can carry one:

In `app/helpers/files_helper.rb`:

```ruby
  def sort_header(label, key, current_sort, current_dir, extra = {}, col: nil)
    active = current_sort == key
    next_dir = (active && current_dir == "asc") ? "desc" : "asc"
    arrow = active ? (current_dir == "asc" ? " ▲" : " ▼") : ""
    aria  = active ? (current_dir == "asc" ? "ascending" : "descending") : "none"
    tag.th("aria-sort": aria, class: [ ("sorted" if active), col ].compact.join(" ").presence) do
      link_to("#{label}#{arrow}", files_path(extra.merge(sort: key, dir: next_dir)))
    end
  end
```

Then in `_list.html.erb`:

```erb
      <%= sort_header "Name", "name", @sort, @dir, files_query_base, col: "col-name" %>
      <%= sort_header "Type", "type", @sort, @dir, files_query_base, col: "col-type" %>
      <% if @flat %><th class="col-folder">Folder</th><% end %>
      <th class="num col-size">Size</th>
      <% if capabilities.versioned? %><th class="col-version">Version</th><% end %>
      <%= sort_header "Modified", "modified", @sort, @dir, files_query_base, col: "col-modified" %>
      <th class="col-actions"></th>
```

and on the matching `<td>`s: `class="col-name"`, `class="muted col-type"`, `class="muted col-folder"`, `class="num muted col-size"`, `class="muted mono col-version"`, `class="muted col-modified"`, `class="row-actions col-actions"`. Keep every other attribute and the cell contents exactly as they are; `files_type_filter_test.rb` reads cells by position, so the column ORDER must not change.

- [ ] **Step 8: The favicon and the manifest**

```bash
sips -z 32 32 public/icon.png --out public/favicon.ico >/dev/null && file public/favicon.ico
```

Expected: `public/favicon.ico: PNG image data, 32 x 32` — a PNG under the `.ico` name, which every current browser accepts for the default `/favicon.ico` request that 404s today.

In `app/views/pwa/manifest.json.erb` replace the two `"red"` values:

```json
  "theme_color": "#1b1f25",
  "background_color": "#15181d"
```

- [ ] **Step 9: Run the shell tests and the guards**

```bash
bin/rails test test/integration/web/shell_layout_test.rb test/stimulus_hygiene_test.rb test/css_hygiene_test.rb \
  test/integration/web/current_project_topbar_test.rb test/integration/web/template_hygiene_test.rb \
  test/controllers/tools/addons_controller_test.rb test/integration/web/files_type_filter_test.rb
bin/ci style
```

Expected: all green. If `template_hygiene_test` fails, an ERB comment contains the close delimiter — none of the comments above do, so look for a typo.

- [ ] **Step 10: Mutation-check the active-state and cookie claims, reporting output**

```bash
# 1. Active state: make rail_section always nil → "exactly one active section" fails.
sed -i '' 's/SECTIONS.find { |_key, heads| heads.include?(head) }&.first/nil/' app/helpers/shell_helper.rb
bin/rails test test/integration/web/shell_layout_test.rb -n /active|family|tab bar/   # expected: 4 failures
git checkout -- app/helpers/shell_helper.rb
# 2. Theme cookie: ignore it → the light/system assertions fail.
sed -i '' 's/THEMES.include?(value) ? value : "dark"/"dark"/' app/helpers/shell_helper.rb
bin/rails test test/integration/web/shell_layout_test.rb -n /theme/                 # expected: 1 failure
git checkout -- app/helpers/shell_helper.rb
git status --porcelain
```

- [ ] **Step 11: Run the share leg**

```bash
bin/rails test
```

Expected: green. Every existing assertion on `.flash-notice`, `.current-project select`, `main.container`, `select[name='project_id']` still holds because those hooks were kept.

- [ ] **Step 12: Commit**

```bash
git add app/helpers/shell_helper.rb app/views/layouts app/javascript/controllers/theme_controller.js \
        app/javascript/controllers/rail_controller.js app/javascript/controllers/toast_controller.js \
        app/assets/stylesheets/shell.css app/views/projects/show.html.erb app/views/projects/sheets/show.html.erb \
        app/views/models/show.html.erb app/views/files/_list.html.erb app/helpers/files_helper.rb \
        public/favicon.ico app/views/pwa/manifest.json.erb test/integration/web/shell_layout_test.rb
git commit -m "The shell: a rail with the current project on it, a top bar, toasts, theme and rail cookies"
```

---

### Task 4: The library search

**Files:**
- Modify: `app/controllers/files_controller.rb` (`#index`, `#files_query_base`, new `#resolve_query`, `QUERY_MAX`), `app/helpers/files_helper.rb` (`ext_toggle_path`), `app/views/files/index.html.erb` (breadcrumb into `content_for :crumbs`, empty state), `app/views/files/_ext_filter.html.erb` (carry `q`)
- Test: `test/integration/web/files_search_test.rb`

Spec §9. Read `FilesController#index` and `#flat_ext_scope`/`#flat_order` first; the search composes with them rather than adding a third listing path.

- [ ] **Step 1: Write the failing tests**

`test/integration/web/files_search_test.rb`:

```ruby
require "test_helper"

module Web
  # The library search (spec §9): ?q= is a flat, whole-library, case-insensitive name match that
  # composes with the type filter, survives every link the page builds, is bounded and escaped,
  # and says what it searched for when nothing matches. Nodes are created directly, as
  # files_type_filter_test.rb does — a listing test is about the query, not the bytes.
  class FilesSearchTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "q-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir")
      @user.nodes.create!(node_id: "dir-sub", name: "Lamp parts", kind: "dir", parent_node_id: "dir-cad")
      file("root.stl", nil)
      file("Lamp-Base.stl", "dir-cad")
      file("lamp shade.3mf", "dir-cad")
      file("notes.pdf", "dir-sub")
      file("100%-done.txt", nil)
    end

    def file(name, parent)
      @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file",
                          parent_node_id: parent, mtime: 1_000_000_000, size: 5)
    end

    def listed_names
      css_select("table.files tbody tr td:first-child").map do |cell|
        (cell.at_css(".file-name") || cell.at_css("a")).text.strip.delete_prefix("📁 ")
      end
    end

    test "a search matches names case-insensitively across the whole library, folders included" do
      get files_path(q: "lamp")
      assert_response :success
      assert_equal [ "Lamp parts", "Lamp-Base.stl", "lamp shade.3mf" ], listed_names.sort
    end

    test "a search composes with the type filter" do
      get files_path(q: "lamp", ext: "stl")
      assert_equal [ "Lamp-Base.stl" ], listed_names
    end

    test "a search is flat: the folder is ignored and the breadcrumb says so" do
      get files_path(folder: "dir-sub", q: "stl")
      assert_equal [ "Lamp-Base.stl", "root.stl" ], listed_names.sort
      assert_select "header.topbar nav.breadcrumb [aria-current='page']", text: /Search “stl”/
      assert_select "nav.breadcrumb a[href=?]", files_path(folder: "dir-sub"), count: 0
      assert_select "header.topbar input[name='q'][value='stl']"
    end

    test "the search rides along on the view toggle, the type picker and the sort headers" do
      get files_path(q: "lamp")
      assert_select ".view-toggle a[href=?]", files_path(q: "lamp", view: "grid")
      assert_select "form.ext-picker input[type='hidden'][name='q'][value='lamp']"
      assert_select "th a[href=?]", files_path(q: "lamp", sort: "name", dir: "desc")
      get files_path(q: "lamp", ext: "stl")
      assert_select ".ext-active a.chip[href=?]", files_path(q: "lamp")
      assert_select ".ext-active a.clear-filter[href=?]", files_path(q: "lamp")
    end

    test "LIKE metacharacters are literal, not wildcards" do
      get files_path(q: "%")
      assert_equal [ "100%-done.txt" ], listed_names
      get files_path(q: "_")
      assert_equal [], listed_names
    end

    test "a blank query is no query, and a long one is bounded" do
      get files_path(q: "   ")
      assert_select "nav.breadcrumb [aria-current='page']", count: 0
      assert_equal %w[100%-done.txt cad root.stl], listed_names.sort
      get files_path(q: "a" * 100)
      assert_select "header.topbar input[name='q'][value=?]", "a" * 80
    end

    test "an empty result says what was searched" do
      get files_path(q: "zzz")
      assert_select ".empty", text: /No files match “zzz”/
      get files_path(q: "zzz", ext: "stl")
      assert_select ".empty", text: /No files match “zzz” among \.stl/
    end
  end
end
```

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/integration/web/files_search_test.rb
```

Expected: every test fails (`?q=` is ignored today, so the folder view renders).

- [ ] **Step 3: The controller**

In `app/controllers/files_controller.rb`, change the top of `#index` from

```ruby
    @exts = resolve_exts
    @flat = @exts.any?
    if @flat
      @folder = nil
      @crumbs = []
      scope = flat_ext_scope(@exts).visible_entries(@show_hidden)
      @match_count = scope.count
      @nodes = scope.order(flat_order(@exts, @sort, @dir)).limit(FLAT_LIMIT).to_a
      @truncated = @match_count > FLAT_LIMIT
```

to

```ruby
    @exts = resolve_exts
    @q = resolve_query
    # A search is flat for the same reason a type filter is: it is a question about the whole
    # library, not about one folder (spec §9). With no types active the base scope is every live
    # node, folders included — finding "desk-lamp" the folder is as useful as finding its files.
    @flat = @exts.any? || @q.present?
    if @flat
      @folder = nil
      @crumbs = []
      scope = (@exts.any? ? flat_ext_scope(@exts) : current_user.nodes.present).visible_entries(@show_hidden)
      # LOWER on both sides: SQLite's LIKE is case-insensitive for ASCII and Postgres's is not,
      # and this app runs on both (§14e). sanitize_sql_like makes % and _ literal.
      scope = scope.where("LOWER(name) LIKE ?", "%#{Node.sanitize_sql_like(@q.downcase)}%") if @q
      @match_count = scope.count
      # flat_order's "type" ranking is a CASE over the active extensions and has nothing to rank
      # with none active, so a search without types sorts by name instead.
      sort_key = (@exts.empty? && @sort == "type") ? "name" : @sort
      @nodes = scope.order(flat_order(@exts, sort_key, @dir)).limit(FLAT_LIMIT).to_a
      @truncated = @match_count > FLAT_LIMIT
```

Change `#files_query_base` to

```ruby
  def files_query_base
    { folder: @folder&.node_id, ext: @exts.presence&.join(","), q: @q }.compact
  end
```

and add, next to `MAX_EXTS`:

```ruby
  # The library search (spec §9). Stripped and bounded; blank is nil so `if @q` reads as "a search
  # is active". 80 characters is longer than any name the list shows without an ellipsis, and it
  # bounds the LIKE the same way EXT_RE bounds the type filter's.
  QUERY_MAX = 80

  def resolve_query
    params[:q].to_s.strip.first(QUERY_MAX).presence
  end
```

- [ ] **Step 4: The helper and the two views**

`app/helpers/files_helper.rb`, `ext_toggle_path`:

```ruby
  def ext_toggle_path(ext, active_exts, q: nil)
    toggled = active_exts.include?(ext) ? active_exts - [ ext ] : active_exts + [ ext ]
    files_path({ ext: toggled.presence&.join(","), q: }.compact)
  end
```

`app/views/files/_ext_filter.html.erb`: after the existing hidden `ext` input inside `form.ext-picker` add

```erb
    <% if @q %><input type="hidden" name="q" value="<%= @q %>"><% end %>
```

change the chip call to `ext_toggle_path(ext, @exts, q: @q)` and the clear link to

```erb
      <%= link_to "Clear filter", files_path({ q: @q }.compact), class: "muted clear-filter" %>
```

`app/views/files/index.html.erb`: replace the `<nav class="breadcrumb" …>…</nav>` block with

```erb
<% content_for :crumbs do %>
  <nav class="breadcrumb" aria-label="Folder path">
    <%= link_to "Files", files_path %>
    <% @crumbs.each_with_index do |crumb, i| %>
      <span class="sep" aria-hidden="true">/</span>
      <% if i == @crumbs.length - 1 %>
        <%= link_to crumb.name, files_path(folder: crumb.node_id), "aria-current": "page" %>
      <% else %>
        <%= link_to crumb.name, files_path(folder: crumb.node_id) %>
      <% end %>
    <% end %>
    <% if @q %>
      <span class="sep" aria-hidden="true">/</span>
      <span aria-current="page">Search “<%= @q %>”</span>
    <% end %>
  </nav>
<% end %>
```

(keep the explanatory ERB comment that precedes it), and replace the two-branch empty state with

```erb
<% if @nodes.empty? %>
  <%# Three emptinesses. "No files yet" is advice for a new library; said to someone who searched
      or filtered, it reads as "your library is empty" and is a lie. %>
  <% if @q && @exts.any? %>
    <p class="empty muted">No files match “<%= @q %>” among <%= @exts.map { |e| ".#{e}" }.to_sentence %>.</p>
  <% elsif @q %>
    <p class="empty muted">No files match “<%= @q %>”.</p>
  <% elsif @flat %>
    <p class="empty muted">No files match <%= @exts.map { |e| ".#{e}" }.to_sentence %>.</p>
  <% else %>
    <p class="empty muted">No files yet. Upload one to get started.</p>
  <% end %>
```

- [ ] **Step 5: Run the tests**

```bash
bin/rails test test/integration/web/files_search_test.rb test/integration/web/files_type_filter_test.rb \
  test/integration/web/files_sort_test.rb test/integration/web/files_pagination_test.rb test/integration/web/shell_layout_test.rb
bin/ci style
```

Expected: green.

- [ ] **Step 6: Mutation-check, reporting output**

```bash
sed -i '' 's/Node.sanitize_sql_like(@q.downcase)/@q.downcase/' app/controllers/files_controller.rb
bin/rails test test/integration/web/files_search_test.rb -n /metacharacters/   # expected: 1 failure (every file matches "%")
git checkout -- app/controllers/files_controller.rb
sed -i '' 's/LOWER(name) LIKE ?/name LIKE ?/' app/controllers/files_controller.rb
bin/rails test test/integration/web/files_search_test.rb -n /case-insensitively/ # expected: green on SQLite (its LIKE is ASCII case-insensitive) — report it, then restore; the LOWER is for the Postgres leg
git checkout -- app/controllers/files_controller.rb
```

- [ ] **Step 7: Query budget**

```bash
bin/rails test test/integration/web/page_query_budget_test.rb
```

Expected: green (the flat branch already counted and selected; `q` adds no query).

- [ ] **Step 8: Commit**

```bash
git add app/controllers/files_controller.rb app/helpers/files_helper.rb app/views/files/index.html.erb \
        app/views/files/_ext_filter.html.erb test/integration/web/files_search_test.rb
git commit -m "Search the library by name from the top bar: flat, case-insensitive, bounded, escaped"
```

---

### Task 5: The auth pages

**Files:**
- Modify: `app/views/users/sessions/new.html.erb`, `users/registrations/new.html.erb`, `users/registrations/edit.html.erb`, `users/passwords/new.html.erb`, `users/passwords/edit.html.erb`, `users/confirmations/new.html.erb`, `users/shared/_links.html.erb`
- Test: `test/integration/web/auth_pages_test.rb`

The field names are Devise's and do not change; `account_settings_test.rb` pins the delete form's `user[current_password]` inside `div.account-delete`. Every page becomes one `.auth-card` (the styles are in `shell.css` from Task 3). `registrations/edit` is a signed-in page (it renders inside the shell) and keeps its two forms; it gets the card too, so the account page reads like the others.

- [ ] **Step 1: Write the failing test**

`test/integration/web/auth_pages_test.rb`:

```ruby
require "test_helper"

module Web
  # The Devise pages wear the auth card (spec §8) and keep Devise's field names: a restyled sign-in
  # form that renamed a field would look finished and never sign anyone in.
  class AuthPagesTest < ActionDispatch::IntegrationTest
    test "sign in renders the card with Devise's fields" do
      get new_user_session_path
      assert_response :success
      assert_select ".auth-card .brand-name", text: "Tinkerex"
      assert_select ".auth-card form[action=?] input[name='user[email]'][type='email']", user_session_path
      assert_select ".auth-card form input[name='user[password]'][type='password']"
      assert_select ".auth-card form input[name='user[remember_me]'][type='checkbox']"
      assert_select ".auth-card form input[type='submit'][value='Log in'].primary"
      assert_select ".auth-card ul.auth-links a[href=?]", new_user_registration_path
      assert_select ".auth-card ul.auth-links a[href=?]", new_user_password_path
    end

    test "sign up, reset and resend render the card with their fields" do
      get new_user_registration_path
      assert_select ".auth-card form input[name='user[email]']"
      assert_select ".auth-card form input[name='user[password]']"
      assert_select ".auth-card form input[name='user[password_confirmation]']"
      assert_select ".auth-card form input[type='submit'][value='Sign up'].primary"

      get new_user_password_path
      assert_select ".auth-card form input[name='user[email]']"
      assert_select ".auth-card form input[type='submit'].primary"

      get new_user_confirmation_path
      assert_select ".auth-card form input[name='user[email]']"
    end

    test "a failed sign-in shows the alert as a toast, not inside the card" do
      post user_session_path, params: { user: { email: "nobody@example.com", password: "wrong" } }
      assert_response :unprocessable_entity
      assert_select ".flash-stack .flash-alert"
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

```bash
bin/rails test test/integration/web/auth_pages_test.rb
```

Expected: failures on `.auth-card` (none of the pages has it). If the third test reports a different status, Devise's failure app answers with what `config.responder` says — use the status it prints (`assert_response :unprocessable_entity` is Devise 4.9's default under Turbo).

- [ ] **Step 3: Rewrite the seven templates**

`app/views/users/sessions/new.html.erb`:

```erb
<div class="auth-card">
  <div class="brand"><span class="brand-mark" aria-hidden="true"></span><span class="brand-name">Tinkerex</span></div>
  <h2>Log in</h2>

  <%= form_for(resource, as: resource_name, url: session_path(resource_name)) do |f| %>
    <div class="field">
      <%= f.label :email %>
      <%= f.email_field :email, autofocus: true, autocomplete: "email" %>
    </div>

    <div class="field">
      <%= f.label :password %>
      <%= f.password_field :password, autocomplete: "current-password" %>
    </div>

    <% if devise_mapping.rememberable? %>
      <label class="field-inline">
        <%= f.check_box :remember_me %>
        <span>Remember me</span>
      </label>
    <% end %>

    <div class="actions">
      <%= f.submit "Log in", class: "primary" %>
    </div>
  <% end %>

  <%= render "users/shared/links" %>
</div>
```

`app/views/users/registrations/new.html.erb`:

```erb
<div class="auth-card">
  <div class="brand"><span class="brand-mark" aria-hidden="true"></span><span class="brand-name">Tinkerex</span></div>
  <h2>Sign up</h2>

  <%= form_for(resource, as: resource_name, url: registration_path(resource_name)) do |f| %>
    <%= render "users/shared/error_messages", resource: resource %>

    <div class="field">
      <%= f.label :email %>
      <%= f.email_field :email, autofocus: true, autocomplete: "email" %>
    </div>

    <div class="field">
      <%= f.label :password %>
      <%= f.password_field :password, autocomplete: "new-password" %>
      <% if @minimum_password_length %>
        <span class="auth-hint"><%= @minimum_password_length %> characters minimum</span>
      <% end %>
    </div>

    <div class="field">
      <%= f.label :password_confirmation %>
      <%= f.password_field :password_confirmation, autocomplete: "new-password" %>
    </div>

    <div class="actions">
      <%= f.submit "Sign up", class: "primary" %>
    </div>
  <% end %>

  <%= render "users/shared/links" %>
</div>
```

`app/views/users/passwords/new.html.erb`:

```erb
<div class="auth-card">
  <div class="brand"><span class="brand-mark" aria-hidden="true"></span><span class="brand-name">Tinkerex</span></div>
  <h2>Forgot your password?</h2>

  <%= form_for(resource, as: resource_name, url: password_path(resource_name), html: { method: :post }) do |f| %>
    <%= render "users/shared/error_messages", resource: resource %>

    <div class="field">
      <%= f.label :email %>
      <%= f.email_field :email, autofocus: true, autocomplete: "email" %>
    </div>

    <div class="actions">
      <%= f.submit "Send me reset password instructions", class: "primary" %>
    </div>
  <% end %>

  <%= render "users/shared/links" %>
</div>
```

`app/views/users/passwords/edit.html.erb`:

```erb
<div class="auth-card">
  <div class="brand"><span class="brand-mark" aria-hidden="true"></span><span class="brand-name">Tinkerex</span></div>
  <h2>Change your password</h2>

  <%= form_for(resource, as: resource_name, url: password_path(resource_name), html: { method: :put }) do |f| %>
    <%= render "users/shared/error_messages", resource: resource %>
    <%= f.hidden_field :reset_password_token %>

    <div class="field">
      <%= f.label :password, "New password" %>
      <%= f.password_field :password, autofocus: true, autocomplete: "new-password" %>
      <% if @minimum_password_length %>
        <span class="auth-hint"><%= @minimum_password_length %> characters minimum</span>
      <% end %>
    </div>

    <div class="field">
      <%= f.label :password_confirmation, "Confirm new password" %>
      <%= f.password_field :password_confirmation, autocomplete: "new-password" %>
    </div>

    <div class="actions">
      <%= f.submit "Change my password", class: "primary" %>
    </div>
  <% end %>

  <%= render "users/shared/links" %>
</div>
```

`app/views/users/confirmations/new.html.erb`:

```erb
<div class="auth-card">
  <div class="brand"><span class="brand-mark" aria-hidden="true"></span><span class="brand-name">Tinkerex</span></div>
  <h2>Resend confirmation instructions</h2>

  <%= form_for(resource, as: resource_name, url: confirmation_path(resource_name), html: { method: :post }) do |f| %>
    <%= render "users/shared/error_messages", resource: resource %>

    <div class="field">
      <%= f.label :email %>
      <%= f.email_field :email, autofocus: true, autocomplete: "email",
                        value: (resource.pending_reconfirmation? ? resource.unconfirmed_email : resource.email) %>
    </div>

    <div class="actions">
      <%= f.submit "Resend confirmation instructions", class: "primary" %>
    </div>
  <% end %>

  <%= render "users/shared/links" %>
</div>
```

`app/views/users/shared/_links.html.erb` (the same conditions, as a list):

```erb
<ul class="auth-links">
  <%- if controller_name != 'sessions' %>
    <li><%= link_to "Log in", new_session_path(resource_name) %></li>
  <% end %>

  <%- if devise_mapping.registerable? && controller_name != 'registrations' %>
    <li><%= link_to "Sign up", new_registration_path(resource_name) %></li>
  <% end %>

  <%- if devise_mapping.recoverable? && controller_name != 'passwords' && controller_name != 'registrations' %>
    <li><%= link_to "Forgot your password?", new_password_path(resource_name) %></li>
  <% end %>

  <%- if devise_mapping.confirmable? && controller_name != 'confirmations' %>
    <li><%= link_to "Didn't receive confirmation instructions?", new_confirmation_path(resource_name) %></li>
  <% end %>

  <%# OmniAuth sign-in links only render when a provider strategy is actually configured
      (config/initializers/omniauth.rb, env-guarded). Without that, the authorize route
      helper is undefined, so we guard on the helper's presence. %>
  <%- if devise_mapping.omniauthable? && respond_to?(:omniauth_authorize_path) %>
    <%- resource_class.omniauth_providers.each do |provider| %>
      <li><%= button_to "Sign in with #{OmniAuth::Utils.camelize(provider)}", omniauth_authorize_path(resource_name, provider), data: { turbo: false }, class: "btn" %></li>
    <% end %>
  <% end %>
</ul>
```

`app/views/users/registrations/edit.html.erb`: wrap the whole existing file in `<div class="auth-card">…</div>`, change `<h2>Edit <%= resource_name.to_s.humanize %></h2>` to `<h2>Your account</h2>`, remove every `<br />`, turn the two `<i>`/`<em>` hints into `<span class="auth-hint">…</span>` placed after their fields, give the two submits `class: "primary"` (Update) and `class: "btn danger"` (Delete my account), and keep `div.account-delete`, its `<p>`, its form and `name: "user[current_password]"` exactly as they are. `<%= link_to "Back", :back %>` becomes `<%= link_to "Back", files_path, class: "btn ghost" %>`.

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/integration/web/auth_pages_test.rb test/integration/web/account_settings_test.rb \
  test/integration/web/account_enumeration_test.rb test/integration/web/template_hygiene_test.rb
bin/ci style
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add app/views/users test/integration/web/auth_pages_test.rb
git commit -m "The auth pages wear the card and keep Devise's field names"
```

---

### Task 6: The system tests — collapse, theme, toasts, ⌘K, and no sideways scroll on a phone

**Files:**
- Create: `test/system/shell_test.rb`
- Possibly modify: `app/assets/stylesheets/shell.css`, `pages/files.css`, `pages/projects.css` (whatever the phone guard reveals)

- [ ] **Step 1: Write the tests**

`test/system/shell_test.rb`:

```ruby
require "application_system_test_case"

# The shell's behaviour only a browser can see (spec §12): the rail's collapse surviving a Turbo
# navigation and a reload, the theme button cycling and persisting, a notice toast leaving on its
# own while an alert waits to be dismissed, Cmd/Ctrl-K reaching the search field, and — the guard
# for the bug that started this rework — no page scrolling sideways at phone width.
class ShellTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("shell@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "collapsing the rail survives a navigation and a reload" do
    visit files_path
    assert_selector "aside.rail"
    assert_no_selector "body.rail--collapsed"

    find("aside.rail [data-action='rail#toggle']").click
    assert_selector "body.rail--collapsed"

    find("aside.rail a.rail-link[title='Projects']").click
    assert_current_path projects_path
    assert_selector "body.rail--collapsed"

    visit projects_path
    assert_selector "body.rail--collapsed"

    find("aside.rail [data-action='rail#toggle']").click
    assert_no_selector "body.rail--collapsed"
    assert_no_console_errors
  end

  test "the theme button cycles dark, light, system and persists" do
    visit files_path
    theme = -> { page.evaluate_script("document.documentElement.dataset.theme") }
    assert_equal "dark", theme.call

    find("aside.rail [data-action='theme#cycle']").click
    assert_equal "light", theme.call
    visit files_path
    assert_equal "light", theme.call
    assert_selector "aside.rail [data-action='theme#cycle']", text: "Theme: light"

    find("aside.rail [data-action='theme#cycle']").click
    assert_equal "system", theme.call
    find("aside.rail [data-action='theme#cycle']").click
    assert_equal "dark", theme.call
    visit files_path
    assert_equal "dark", theme.call
    assert_no_console_errors
  end

  test "a notice toast leaves on its own and an alert waits to be dismissed" do
    # sign_in_as landed on /files carrying Devise's "Signed in successfully." notice.
    assert_selector ".flash-stack .flash-notice", text: "Signed in successfully."
    assert_no_selector ".flash-stack .flash-notice", wait: 9

    find("aside.rail button", text: "Sign out").click
    visit files_path
    assert_selector ".flash-stack .flash-alert", text: /sign in/i
    sleep 7
    assert_selector ".flash-stack .flash-alert", text: /sign in/i
    find(".flash-stack .flash-alert .flash-close").click
    assert_no_selector ".flash-stack .flash-alert"
  end

  test "command-K focuses the library search" do
    visit projects_path
    find("body").send_keys([ :control, "k" ])
    assert_equal "q", page.evaluate_script("document.activeElement.name")
    assert_no_console_errors
  end

  test "no page scrolls sideways at phone width" do
    project = @user.maker_projects.create!(name: "Desk Lamp", description: "A lamp." * 20)
    long = create_node!(@user, node_id: SecureRandom.uuid, kind: "file",
                        name: "a-very-long-file-name-that-would-push-the-table-out-of-the-viewport-v3-final.stl")
    page.driver.browser.manage.window.resize_to(375, 812)
    begin
      [ files_path(view: "list"), files_path(view: "grid"), project_path(project), file_path(long.node_id),
        tools_path, models_path ].each do |path|
        visit path
        assert_selector "nav.tabbar", visible: true
        assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
               "#{path} scrolls sideways at 375px (scrollWidth #{page.evaluate_script('document.documentElement.scrollWidth')})"
      end
      assert_no_console_errors
    ensure
      page.driver.browser.manage.window.resize_to(1400, 1400)
    end
  end
end
```

- [ ] **Step 2: Run them**

```bash
bin/rails test test/system/shell_test.rb
```

Expected: the first four green. The phone test tells you which page overflows and by how much. Fix in CSS, page by page, with rules of these shapes (all inside the existing `@layer` blocks):

- a flex row that must wrap: `.page-actions`, `.head-actions`, `.panel-actions` already wrap (components.css); a page-specific row that does not gets `flex-wrap: wrap; min-width: 0`.
- a long word: `overflow-wrap: anywhere` on the element (`.file-name`, `.grid-name` and `h1` already have it; add it to `.project-description`, `dl.meta dd` if the guard names them).
- a fixed-width box wider than the viewport: `max-width: 100%`.
- a table that still overflows after dropping columns: wrap it — in `pages/files.css` add `.files-table-wrap { overflow-x: auto; }` and in `_list.html.erb` wrap `<table class="files" …>` in `<div class="files-table-wrap">…</div>`.

The `nav.tabbar` assertion doubles as proof the phone rules are active at all (a wrong media query would leave the rail in place and the guard could pass for the wrong reason).

- [ ] **Step 3: Mutation-check the phone guard**

```bash
sed -i '' 's/table.files .col-modified, table.files .col-version { display: none; }/\/* dropped *\//' app/assets/stylesheets/pages/files.css
bin/rails test test/system/shell_test.rb -n /sideways/    # expected: 1 failure naming files_path(view: "list")
git checkout -- app/assets/stylesheets/pages/files.css
```

If the mutation stays green, the long name is not long enough for the columns to matter at 375px — lengthen it until the mutation goes red, then restore and re-run green.

- [ ] **Step 4: Commit**

```bash
git add test/system/shell_test.rb app/assets/stylesheets
git commit -m "The shell's behaviour, pinned in a browser: collapse, theme, toasts, command-K, no sideways scroll"
```

---

### Task 7: Docs and close-out

**Files:**
- Modify: `CLAUDE.md` (§14d)

- [ ] **Step 1: Add the invariant to §14d**

Insert as the last bullet of §14d, before the `### 14e.` heading:

```markdown
- **THE WEB UI IS ONE DESIGN SYSTEM: TOKENS, CASCADE LAYERS, ONE DEFINITION PER COMPONENT.**
  `application.css` OPENS with `@layer tokens, base, components, shell, pages;` and every rule of
  ours sits in one of those layers; `vendor-overrides.css` is the ONE unlayered sheet, linked last,
  because an unlayered vendor rule outranks every layered one and the overrides must outrank it
  back. A component selector (`.btn`, `.chip`, `.panel`, `.thumb`, …) is defined in
  `components.css` and nowhere else — the pre-2026-09 sheets defined `.btn` twice and the later
  file won, so `.btn` rendered grey everywhere and `.btn.primary` blue. Colours are tokens on
  `:root` (dark, the default) redefined under `[data-theme="light"]` and `[data-theme="system"]`;
  theme and rail state are COOKIES the layout renders, never an inline script (the CSP nonces
  `script-src`). Fonts are self-hosted (`app/assets/fonts`, OFL) because `font_src` is `:self`.
  The classes the tests pin and the 52 the addon bundles build markup with keep their names
  through any restyle. Guard: `test/css_hygiene_test.rb`. Spec:
  `docs/superpowers/specs/2026-09-03-web-shell-and-design-system-design.md`.
```

- [ ] **Step 2: Check the ceiling**

```bash
wc -l CLAUDE.md
bin/rails test test/docs_hygiene_test.rb
```

Expected: at or under the `MAX_LINES` the test names (1,354 as of this plan). If over, shorten the bullet — do not touch other sections.

- [ ] **Step 3: The full gate**

```bash
export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync
bin/ci
```

Expected: every gate green. **Read the three backend legs' run counts** (`test`, `test-s3`, `test-chunk-remote`) and confirm they are identical; `bin/ci` prints them and does not compare them.

- [ ] **Step 4: Commit and hand over**

```bash
git add CLAUDE.md
git commit -m "Record the design-system invariant"
```

Then `/finish-branch` (commit, push, open the PR), and `bin/log arc --from-pr <n>` the moment the PR exists — the record is part of the work.

---

## Self-review (done while writing; kept so the reader can check it)

- **Spec coverage.** §4.1 layers/sheets → Task 2. §4.2 fonts → Task 1 + Task 2 `@font-face` + Task 3 font test. §4.3 controllers → Task 3. §4.4 cookies server-side → Task 3 (`ShellHelper`, layout). §5.1 card → Task 3 rail. §5.2 active state → `rail_section`. §5.3 top bar → `_topbar` + crumbs moves (Tasks 3 and 4). §5.4 responsive → `shell.css` media queries + column classes + Task 6 guard. §5.5 toasts → `_flash` + `toast_controller` + scoping the fixed rule to `.flash-stack > .flash` (the inline `.flash-alert.task-error` stays inline). §5.6 container → `shell.css`. §5.7 theme → tokens + helper + controller. §6 tokens → `application.css`. §7 components → `components.css`. §8 auth → Task 5; the rest of §8 is PR 2–4 by the spec's own delivery order. §9 search → Task 4. §10 contracts → hooks kept; guards run in Tasks 3–6. §12 tests → Tasks 2, 3, 4, 5, 6. §13 sheet-page light island → `vendor-overrides.css`.
- **Placeholders.** None: every step shows its code or an exact command. The migrated-rule steps in Task 2 name the exact source line ranges and rule names and the exact substitution table rather than re-pasting 600 lines of existing CSS.
- **Consistency.** Cookie names `theme` / `rail` and their enums match between `ShellHelper`, the two controllers and the tests. `data-action` names (`rail#toggle`, `theme#cycle`, `toast#dismiss`) match between partials, controllers and system tests. `col-*` classes match between `_list`, `pages/files.css` and the Task 6 mutation. The `COMPONENT_SELECTORS` list in the hygiene test names only selectors `components.css` defines as bare selectors.
