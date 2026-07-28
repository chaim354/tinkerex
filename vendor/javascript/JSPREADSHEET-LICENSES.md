# Vendored grid libraries

Both MIT — permissive, per CLAUDE.md §9. Vendored as prebuilt browser bundles from jsDelivr rather
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

## UMD, not ESM

Both bundles are UMD (verified — zero `export`/`import` statements in either file):

```js
!function(e,t){"object"==typeof exports&&"undefined"!=typeof module?module.exports=t():"function"==typeof define&&define.amd?define(t):e.jspreadsheet=t()}(this, ...)   // jspreadsheet.js
!function(e,t){"object"==typeof exports&&"undefined"!=typeof module?module.exports=t():"function"==typeof define&&define.amd?define(t):e.jSuites=t()}(this, ...)        // jsuites.js
```

Loaded via a classic `<script>` tag (no CommonJS `module`/`exports`, no AMD `define`), each falls to
its `else` branch and sets a property on `this` — which is `window` — so they publish plain globals:
**`window.jspreadsheet`** and **`window.jSuites`** (capital S in the middle — mind the casing; it is
not `window.jsuites`). Task 4's Stimulus controller reads `window.jspreadsheet`.

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
package to Pro or copy Pro-only code in. Formulas, which are what this library was chosen for, are
in CE — confirmed present in the CE source (the bundle's own dependency on `@jspreadsheet/formula`,
visible in the same top-of-file require shim above, and in `jspreadsheet-ce`'s own
`package.json#dependencies`).
