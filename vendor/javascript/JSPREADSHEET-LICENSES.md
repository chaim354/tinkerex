# Vendored grid libraries

All MIT — permissive, per CLAUDE.md §9. Vendored as prebuilt browser bundles from jsDelivr rather
than pinned through jspm/importmap: these are UMD, so they carry no bare-specifier imports and
cannot reintroduce the shared-chunk problem documented in `config/importmap.rb` (the hand-patched
`buffer.js` that jszip and Maker.js share). They are loaded via classic `<script>` tags on the sheet
page only (Task 4), never added to `config/importmap.rb`.

| File | Package | Resolved version | Licence | Source |
|---|---|---|---|---|
| `vendor/javascript/jspreadsheet.js` | `jspreadsheet-ce` | 5.0.4 | MIT | `https://cdn.jsdelivr.net/npm/jspreadsheet-ce@5/dist/index.min.js` |
| `app/assets/stylesheets/jspreadsheet.css` | `jspreadsheet-ce` | 5.0.4 | MIT | `https://cdn.jsdelivr.net/npm/jspreadsheet-ce@5/dist/jspreadsheet.min.css` |
| `vendor/javascript/jsuites.js` | `jsuites` | 5.13.5 | MIT | `https://cdn.jsdelivr.net/npm/jsuites@5/dist/jsuites.min.js` |
| `app/assets/stylesheets/jsuites.css` | `jsuites` | 5.13.5 | MIT | `https://cdn.jsdelivr.net/npm/jsuites@5/dist/jsuites.min.css` |
| `vendor/javascript/formula-parser.js` | `hot-formula-parser` | 4.0.0 | MIT | `https://cdn.jsdelivr.net/npm/hot-formula-parser@4.0.0/dist/formula-parser.min.js` |

`@5` is a floating major-version range, not a pin — the table above records what it actually
resolved to on **2026-07-28** (from jsDelivr's own `Original file: /npm/<pkg>@<version>/...` banner
comment at the top of each downloaded file, cross-checked against each package's `package.json`
`version` field via `cdn.jsdelivr.net/npm/<pkg>@5/package.json`, which agreed exactly). Re-running
the curl commands later can legitimately produce a newer patch version; if so, update this table.

Note: each bundle also carries its own internally-hardcoded version string used only for an
in-app diagnostic printout — `"5.0.0"` in jspreadsheet.js's `version` object, `"5.13.3"` in
jsuites.js's — one and two patch releases behind the resolved versions above respectively. That
string is not kept in sync with the npm patch version on every release; the table above (npm
`package.json` + the jsDelivr banner) is the authoritative version, not the in-bundle string.

## Licence evidence

**jspreadsheet-ce (jspreadsheet.js / jspreadsheet.css):** the minified bundle embeds its own
metadata object verbatim: `{version:"5.0.0",host:"https://bossanova.uk/jspreadsheet",
license:"MIT",print:function(){return[["Jspreadsheet CE",this.version,this.host,
this.license].join("\r\n")]}}`. That is Jspreadsheet's own runtime self-identification as both
**MIT** and **"Jspreadsheet CE"** (not Pro), straight from the source, not a copied banner comment.
Cross-checked against the actual npm `LICENSE` file (`cdn.jsdelivr.net/npm/jspreadsheet-ce@5/LICENSE`,
HTTP 200): standard MIT License text, `Copyright (c) 2024 Jspreadsheet Ltd`. (`package.json` has no
top-level `license`/`licenses` field for this package — not a red flag given the other two
independent confirmations above.)

**jsuites (jsuites.js / jsuites.css):** the minified bundle carries **no** licence string anywhere —
grepping the whole file for `licen[sc]e` (case-insensitive) returns nothing; the only case-insensitive
matches for the substring "mit" are false positives inside words like `submitButton`, `limit`,
`onlimit`. Confirmed instead from npm packaging metadata: `package.json`'s `licenses` array —
`[{"type":"MIT","url":"https://github.com/jsuites/jsuites/blob/master/LICENSE"}]` — and the actual
`LICENSE` file (`cdn.jsdelivr.net/npm/jsuites@5/LICENSE`, HTTP 200): standard MIT License text,
`Copyright (c) Jspreadsheet` (same publisher as jspreadsheet-ce).

**hot-formula-parser (formula-parser.js) and its two bundled dependencies:** all three confirmed MIT
from **two** independent sources each — the npm registry's own `license` field (not just the
`package.json` shipped in the tarball) and the actual `LICENSE` file text fetched over HTTP, which is
the check that mattered for `@jspreadsheet/formula` (below) and is why it isn't skipped here:

| Package | `registry.npmjs.org` `license` field | `LICENSE` file (HTTP) |
|---|---|---|
| `hot-formula-parser@4.0.0` | `"MIT"` | `(The MIT License)` / Copyright Handsoncode sp. z o.o. |
| `@handsontable/formulajs@2.0.2` | `"MIT"` | `The MIT License (MIT)` / Copyright Sutoiku, Inc. |
| `tiny-emitter@2.1.0` | `"MIT"` | `The MIT License (MIT)` / Copyright Scott Corgan |

`@handsontable/formulajs`'s `LICENSE` file is not a single grant — it embeds **two more** under an
"Other libraries included" heading (the BESSEL* functions, Copyright SheetJS, and jStat, Copyright
jStat), because that package itself vendors code from both. Read in full, not just grepped: both
are the same standard MIT text as the top grant, so nothing non-permissive rides in underneath it.
This is the same class of check that caught `@jspreadsheet/formula` having no grant at all — a
`license` field can be wrong or absent, so the field and the file were both pulled for every one of
these three, not assumed from the field alone.

The bundle itself (`formula-parser.js`) carries no licence banner text either (same `licen[sc]e`
grep, same empty result) — expected for a minified bundle and not a red flag given the table above.

## UMD, not ESM

All three bundles are UMD (verified — zero `export`/`import` statements in any file):

```js
!function(e,t){"object"==typeof exports&&"undefined"!=typeof module?module.exports=t():"function"==typeof define&&define.amd?define(t):e.jspreadsheet=t()}(this, ...)   // jspreadsheet.js
!function(e,t){"object"==typeof exports&&"undefined"!=typeof module?module.exports=t():"function"==typeof define&&define.amd?define(t):e.jSuites=t()}(this, ...)        // jsuites.js
!function(r,n){"object"==typeof exports&&"object"==typeof module?module.exports=n():"function"==typeof define&&define.amd?define("formulaParser",[],n):"object"==typeof exports?exports.formulaParser=n():r.formulaParser=n()}(window, ...)  // formula-parser.js
```

Loaded via a classic `<script>` tag (no CommonJS `module`/`exports`, no AMD `define`), each falls to
its final branch and sets a property on the global object, so they publish plain globals:
**`window.jspreadsheet`**, **`window.jSuites`** (capital S in the middle — mind the casing; it is
not `window.jsuites`), and **`window.formulaParser`**. Task 4's Stimulus controller reads
`window.jspreadsheet`; `lib/formula_adapter.js` reads `window.formulaParser` and, in turn, sets
`window.formula` (see below).

`formula-parser.js` differs from the other two in one harmless way: it closes over the literal
identifier `window` rather than `this`, verified by trying to `require()` the raw file under plain
Node — it throws `ReferenceError: window is not defined` (Node has no such global) until one is
shimmed in (`global.window = global`). That only matters for a Node-based sanity check, never for
the actual delivery mechanism: a real browser always has `window`, and the file is never loaded any
other way here.

**`formula-parser.js` is self-contained** — grepping it for `require(` (any spelling, not just the
Node/CJS convenience shim jspreadsheet.js and jsuites.js each carry) returns nothing, so its two
bundled dependencies (`@handsontable/formulajs`, `tiny-emitter`) are compiled into the file, not
fetched at runtime. Confirmed further by loading the bundle (Node, with the `window` shim above) and
exercising it end-to-end: `formulaParser.Parser` is a real constructor; `new Parser()` exposes
`.on(event, callback)` (a `tiny-emitter` instance under the hood) and `.parse(expression)`, which
returns `{error, result}`; `.on("callCellValue", (coord, done) => …)` receives `coord.label` (e.g.
`"A1"`) and `.on("callVariable", (name, done) => …)` receives a bare name string — both call `done`
with the resolved value, which is exactly the seam `lib/formula_adapter.js` feeds from
`formulaExpressions`. Real Excel error strings came back from the running bundle, not just from
reading source: `1/0` → `#DIV/0!`, an unresolved bare name → `#NAME?`, malformed syntax (`SUM(`) →
`#ERROR!`.

**`jsuites` MUST load before `jspreadsheet`, and this is enforced, not just conventional.**
`jspreadsheet.js` opens with a Node/CJS convenience shim —
`if(!jSuites&&"function"==typeof require)var jSuites=require("jsuites");` — that is inert in a
browser (`typeof require` is `"undefined"` there) but confirms the dependency, and its own bundled
code calls directly into the global at multiple points: `jSuites.ajax(`, `jSuites.calendar(`,
`jSuites.color(`, `jSuites.contextmenu(`, `jSuites.dropdown(`, `jSuites.editor(`, `jSuites.image(`,
`jSuites.picker(`, `jSuites.setDictionary(`, `jSuites.tabs(`, among others. If `jsuites.js` has not
already run, `window.jSuites` is `undefined` and any of those calls throws
`TypeError: Cannot read properties of undefined`. Both the script tags (Task 4's `<head>` block)
and the stylesheet tags must keep this order: `jsuites` first, `jspreadsheet` second.

**Community Edition only.** Jspreadsheet *Pro* is a paid commercial licence; do not upgrade the
package to Pro or copy Pro-only code in.

**Correction to an earlier version of this file:** that earlier version claimed formulas are bundled
in CE, reading the top-of-file require shim (`if(!formula&&"function"==typeof require)var
formula=require("@jspreadsheet/formula")`) as proof the formula engine ships inside
`jspreadsheet.js`. **It proves the opposite.** A shim exists *because* the code is not there — CE
depends on `@jspreadsheet/formula` as a **second, separate runtime package**
(`jspreadsheet-ce@5.0.4`'s own `package.json` lists it as a dependency of equal standing to
`jsuites`), and only `jsuites` was vendored here. With no formula engine loaded, every formula
rendered `#ERROR`, including `=1+1` — observed live, not inferred, and not a cross-reference problem
since that expression has no cell refs at all.

Worse, `@jspreadsheet/formula` **cannot be vendored**: it publishes with no licence grant at all (no
`license` field on the npm registry, `/LICENSE` 404s, no banner in the bundle), and its README
describes a Basic (MIT) / Premium (paid) split requiring a licence for redistribution or SaaS use —
exactly this product's managed-hosting mode. See
`docs/superpowers/specs/2026-07-27-project-page-overhaul-design.md` §9b for the full evidence trail.

## Formulas: a second engine, not the CE plugin

**`vendor/javascript/formula-parser.js` (`hot-formula-parser`) is wired in as a replacement for
`@jspreadsheet/formula`, not an addition to it** — `@jspreadsheet/formula` is never vendored or
loaded anywhere in this app. `jspreadsheet.js` calls a single global function for every formula
cell:

```js
res = formula(expression.substr(1), formulaExpressions, x, y, obj)
if (typeof res === "function") res = "#ERROR"     // a throw is also caught -> "#ERROR"
```

`expression` arrives without its leading `=`. Before this call, the grid itself strips `$` from
A1-style refs, **expands ranges** (`SUM(A1:A5)` becomes `SUM(A1,A2,A3,A4,A5)` in the expression
text), and builds `formulaExpressions` — a plain object mapping every remaining cell token to its
value, pre-formatted for `eval`: blanks are `null`, numbers are numbers, and **strings are wrapped in
literal double-quote characters** (`'"text"'`, six characters for `text`, not four). So the contract
for whatever fills the `formula` global is expression evaluation against an injected scope, not
reference resolution — and any replacement must unwrap those quoted strings itself, or every string
formula result comes out re-quoted. All of this was read directly out of the bundle bytes (the
`formulaExpressions[tokens[i]]='"'+t+'"'` assignment, the `/\$?([A-Z]+)\$?([0-9]+)/g` strip, the
`tokensUpdate` range expansion), not assumed from documentation.

The two peer shims (`jSuites`/`formula`) sit **outside** the UMD factory, at script top level — so in
a classic `<script>` tag, `var formula` at top level *is* `window.formula`, and setting that global
before `jspreadsheet.js` loads works exactly the way `jsuites` already does. Load order, enforced by
`projects/sheets/show.html.erb`: `jsuites` → `formula-parser` → `lib/formula_adapter.js` →
`jspreadsheet`. `lib/formula_adapter.js` is the piece that turns `window.formulaParser` (this file)
into `window.formula` (what `jspreadsheet.js` calls) — see that file for the unwrap logic and why
the adapter returns the engine's own error string (`#DIV/0!`, `#NAME?`, `#VALUE!`, …) instead of
throwing, which would collapse everything to the grid's generic `#ERROR`.

Why `hot-formula-parser` over a `new Function`/`eval` adapter on top of `@formulajs/formulajs`
directly (also MIT, and simpler): Excel and JavaScript disagree on several operators *silently* — `&`
is concatenation in Excel, bitwise-AND in JS; `^` is exponentiation vs XOR; `<>` is not-equal vs a
syntax error; `=` is equality vs assignment. `hot-formula-parser` implements Excel's own operator
semantics (dedicated modules per operator), avoiding that entire class of wrong-but-not-erroring
result.
