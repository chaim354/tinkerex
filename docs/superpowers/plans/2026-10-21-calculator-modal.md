# A quick-access calculator modal, pinnable in the sidebar, saving results to a project — Implementation Plan

> **For agentic workers:** `.claude/commands/execute-plan.md` is the house default. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A maker's calculator (lengths in mm/cm/m/in/ft, inch fractions, `+ − × ÷`, powers, `%`,
`sqrt`, trig with `pi`) that opens as a native `<dialog>` over any signed-in page, from a Tools
gallery card or — once pinned — a sidebar link, and whose result can be saved, labelled, onto a
project's new **Calculations** panel.

**Architecture:** A core app feature, not a `/tools` addon (an addon is a sandboxed bundle on its
own page and cannot open over every page). Three parts:

1. **The engine** — `app/javascript/lib/calc.js`, a plain ES module with a hand-written
   recursive-descent parser. **No `eval`, no `new Function`** (CSP and safety), and no math.js
   (Apache-2.0, but ~170 KB minified for a few hundred lines of need). One host importmap pin.
2. **The modal** — `layouts/_calculator.html.erb`, rendered ONCE in the signed-in shell, driven by
   `calculator_controller.js`. Any element carrying `data-calculator-open` opens it (a delegated
   `click@document` listener), so the rail link, the Tools card and the panel's "Open in calculator"
   share one door. Its **Save to project** form is a lazy `<turbo-frame>` (`GET /calculations/new`)
   that loads only when the maker opens the save section, so the layout itself costs **zero
   queries** for the calculator — the same reason the top bar's New ▾ tool list is a lazy frame.
3. **The data** — table `maker_calculations`; `CalculationsController` (session-authed, `new` /
   `create` / `update` / `destroy`); the project page's `calculations` panel, a member of
   `Maker::Project::PANELS` and of `ProjectsController::ON_DEMAND`. The pin is
   `users.calculator_pinned`, toggled by `Tools::CalculatorPinsController`.

**Tech Stack:** Rails 8, Stimulus, Turbo frames + streams, importmap, Minitest + Capybara/Selenium.

**Worktree:** `.claude/worktrees/calculator-modal-0fa948`, branch `claude/calculator-modal-0fa948`.

---

## Decisions made without the owner

Each is recorded here because the owner was asleep; each is cheap to reverse.

1. **The pin is a `users` boolean, `calculator_pinned` (default false).** It is ONE flag, and no
   preferences mechanism exists to join. A JSON prefs column or a key/value table would be machinery
   for one value; `Maker::Pin` pins FOLDERS by `node_id` and a tool is not a node. Server-side, so it
   follows the maker across devices, unlike the rail's collapse state, which is a per-browser cookie
   because it is about the screen, not the person. If more built-in tools arrive and want pins, that
   is the moment for a `maker_tool_pins` table.
2. **The sidebar link sits in the rail foot's "Tools and trash" nav, directly under Tools.** It is a
   tool. It never carries `aria-current` (it opens a modal, it is not a place), so "exactly one lit
   link" is untouched.
3. **The phone tab bar keeps its four destinations.** At phone width the calculator is reached from
   the Tools tab → the Calculator card; the dialog goes full-width there.
4. **A dimension mismatch is an ERROR, never a guess.** `12mm + 1` answers "Can't add a plain number
   to a length. Give the 1 a unit, like 1mm." Silently treating a bare number as the left side's unit
   is the classic calculator bug, and a maker cutting a board is the person it bites. Multiplying or
   dividing a length by a plain number is fine (`3 × 12mm`).
5. **Mixed units add in the LEFT operand's unit**: `12.5mm + 1/4in` = `18.85 mm`; `1/4in + 12.5mm` =
   `0.742126 in`. `to`/`in`/`as`/`->` at the end converts (`3 ft to mm`, `2.5in in mm`).
6. **A fraction written against a unit is ONE literal**: `1/4in` is a quarter inch, not `1 ÷ (4 in)`,
   and `3 1/2in` (a whole number, a space, a fraction) is three and a half inches. A bare `3 1/2` is
   3.5 as well — the alternative reading (implicit multiplication of two numbers) is never what was
   meant. Implicit multiplication exists only for `2pi`, `2(3+4)` and `(a)(b)`.
7. **`%` is percent, not modulo.** `x%` is x/100, and `a + b%` / `a − b%` mean a × (1 ± b/100), the
   way every desk calculator behaves (`300mm + 10%` = 330 mm, for shrinkage allowances).
8. **Trig is in radians, with a `deg` / `°` suffix** (`sin(30deg)`), and `to deg` converts a plain
   result (`atan(1) to deg` = 45). `pi` / `π` is the only constant; `e` stays free for `1e3`.
9. **Inch fractions are a display choice** (Decimal / nearest 1/16 / nearest 1/32), remembered per
   browser and saved with a calculation as `inch_fraction` (16, 32 or null), so the panel shows the
   same `3 3/16 in` the maker saw. A rounded fraction says so (`≈`).
10. **A label is required** ("Shelf depth") and a project holds at most **100** calculations. The cap
    bounds the panel (it has no pagination) and stands in for a rate limit: a per-user write door
    that a person drives by hand, like tasks and connections, which carry none.
11. **The panel is on-demand**, like Tasks and Sheets: absent while empty, offered by "+ Add panel",
    and its quiet state says how to fill it. It is **never public**: `public/projects/_page`'s
    `public_panels` map is the whole definition of a public face, and `calculations` is not in it.
12. **The demo account may use, pin and save.** It may already add tasks, connections and blocks;
    the nightly reset destroys the account through `User#destroy`, whose `dependent:` takes the rows.
13. **History is the last 20 results in `localStorage`**, wrapped in try/catch, so a private window
    or blocked storage costs the history and nothing else.

## Decisions after review (2026-10-22)

The owner reviewed the open questions and asked for two changes (14 and 15); everything else above
stands. The details inside each were decided while building it and are recorded here.

14. **A keyboard shortcut opens the calculator: Alt+C, shown as ⌥C on a Mac.**
    - **Why this key.** `⌘/Ctrl+Shift+C` is DevTools' inspect-element key in Chrome, Edge and
      Firefox, and nearly every `⌘/Ctrl` letter is a browser command. Alt+C is unbound in Chrome,
      Firefox, Edge (its Alt keys are D, E, F and Shift+B/I/T) and Safari. No `accesskey` in the app
      uses C. jspreadsheet's grid ignores Alt chords where it would start a cell edit on a bare key.
    - **Why not a bare key.** WCAG 2.1.4 requires that a one-character shortcut can be turned off,
      and `=` starts a formula in a selected sheet cell.
    - **Where it never fires.** In any `input`, `textarea`, `select`, contenteditable (Lexxy) or
      CodeMirror editor, so it can never eat a typed character: ⌥C types ç on a Mac.
    - **Which key counts.** The letter C on whatever layout. On a Mac, where ⌥ turns the key into ç,
      it falls back to the physical C key.
    - **Already open.** Pressed again from inside the modal, it puts focus back in the input.
    - **Where it is shown.** The Tools card's description shows the platform's spelling, read from
      the user agent; a wrong guess costs a label, never the key. The pinned rail link's title (the
      collapsed rail's tooltip), the panel's Open calculator button and the help page name it too.
      Every opener carries `aria-keyshortcuts="Alt+C"`.
    - **Keys typed in the dialog stay in the dialog.** `keydown`, `paste`, `copy` and `cut` stop at
      the dialog, because a calculator opened from the keyboard leaves a sheet cell selected (a
      click elsewhere would have cleared it). jspreadsheet puts its key and clipboard handlers on
      `document`, so before this its Backspace cleared that cell (measured), and by its code a paste
      would land in it and a cut would clear it.
15. **A bare number after feet is inches**: `5' 6` is 66 in. So are `5' 6 1/2` (66.5 in) and
    `5' 1/2` (60.5 in), whose tight fraction is a fraction of an inch.
    - **What may follow the bare number.** Only `+ - * / )`, a conversion, or the end:
      `5' 6 + 1in`, `5' 6 * 2`, `5' 6 to mm`.
    - **What keeps the old "Missing an operator" error.** Anything that attaches to the 6 itself:
      `5' 6^2`, `5' 6%`, `5' 6deg`, `5' 6(2)`, `5' 6 7`. Reading those as inches would be a guess:
      `5' 6^2` would come out as 4356 in².
    - **The edge cases.** `5'` alone stays 5 ft. `5' 6"` is unchanged (66 in). `5 6`, with no feet
      mark, stays refused.
    - **An explicit non-inch unit is refused, not summed.** `5' 6 mm` answers "Only inches can follow
      feet, like 5' 6". To add 6mm, write 5' + 6mm." Nobody reads feet and millimetres off one
      tape, so this follows decision 4: say what works, never guess. `5ft 6mm`, `5' 6 cm` and
      `5' 6'` get the same message.

## Rules for every implementer (read first)

1. Focused tests only: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test <files>`.
   The parent session runs bare `bin/ci` (SYNC_PORT=3073, TINKEREX_SYNC_DIR set).
2. Ruby edit scripts: `LANG=en_US.UTF-8 ruby -Eutf-8:utf-8`. Prefer the Edit tool.
3. Git: explicit paths, `git commit -F <file> -- <paths>`; never `-A`, never stash.
4. Mutation-check every guard; clear `tmp/cache/bootsnap*` after restoring Ruby.

## File map

| File | Responsibility |
|---|---|
| `app/javascript/lib/calc.js` (new) | tokenizer, parser, evaluator, formatter — pure, no DOM |
| `config/importmap.rb` | `pin "lib/calc"` |
| `test/system/calculator_engine_test.rb` (new) | the engine's table of expressions, run in Chrome |
| `db/migrate/…_create_maker_calculations.rb`, `…_add_calculator_pinned_to_users.rb` (new) | the table, the flag |
| `app/models/maker/calculation.rb` (new) | validations, `project_belongs_to_user`, CAP |
| `app/models/user.rb`, `app/models/maker/project.rb` | `has_many … dependent: :destroy`; reserved handle |
| `app/controllers/calculations_controller.rb` (new) | the modal's save frame + create; the panel's rename + delete |
| `app/controllers/tools/calculator_pins_controller.rb` (new) | pin / unpin |
| `config/routes.rb` | `resources :calculations`, `tools/calculator/pin` above `tools/:key` |
| `app/views/layouts/_calculator.html.erb` (new), `application.html.erb` | the dialog, once |
| `app/views/calculations/new.html.erb`, `_form.html.erb`, `_saved.html.erb` (new) | the save frame |
| `app/javascript/controllers/calculator_controller.js` (new) | open/close, Enter, history, save prep |
| `app/views/layouts/_rail.html.erb`, `app/helpers/shell_helper.rb` | the pinned link, the icon |
| `app/views/tools/home/index.html.erb` | the Built-in section and its card + pin toggle |
| `app/views/projects/_calculations.html.erb` (new), `projects_controller.rb`, `projects_helper.rb` | the panel |
| `app/assets/stylesheets/components.css`, `pages/projects.css`, `pages/tools.css` | `.calculator`, the panel, the card |
| `lib/schema_map.rb`, `docs/schema-map.html` | LAYOUT + EDGES |
| guards | `structural_orphan_test`, `tenant_cleanup_test`, `template_hygiene_test`, `page_query_budget_test`, `css_hygiene_test` |

## Tasks

- [ ] **1. Engine** (`lib/calc.js` + importmap pin + `calculator_engine_test.rb`). API:
  `evaluate(input) → { ok: true, value, unit, dim, text } | { ok: false, error }` and
  `formatInches(valueInInches, denominator)`. Mutation-check: break fraction literals, the
  mismatch error and right-associative `^`.
- [ ] **2. Data** — migrations, model, associations, schema map, the four derived guards.
- [ ] **3. Doors** — routes, `CalculationsController`, `Tools::CalculatorPinsController`, request tests
  (create/update/destroy scoping, cross-tenant 404, foreign project refused, cap, the form's field
  names and its refused-state values, pin/unpin).
- [ ] **4. Modal + rail + Tools card** — layout partial, Stimulus controller, CSS, request tests for
  the pinned/unpinned rail and the card, a system test driving open/Enter/Esc/focus/history/save.
- [ ] **5. Panel** — `calculations` in PANELS/LABELS/ON_DEMAND/anchors, the partial, the query
  budget, never on the public page or the preview.
- [ ] **6. Verify** — drive the real pages (several pages, pin/unpin, save, panel, 375px, light and
  dark), bare `bin/ci`, PR with screenshots, record, merge.
