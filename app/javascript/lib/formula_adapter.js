// Wires hot-formula-parser (MIT) behind the ONE global hook jspreadsheet.js calls for every
// formula cell — see vendor/javascript/JSPREADSHEET-LICENSES.md for why a second engine is needed
// at all (jspreadsheet-ce's own formula plugin, @jspreadsheet/formula, ships with no licence grant)
// and docs/superpowers/specs/2026-07-27-project-page-overhaul-design.md §9b/§9b.1 for the decision.
//
// A CLASSIC SCRIPT, not an ES module — it must set a global (window.formula) before jspreadsheet.js
// loads, and importmap modules are deferred (they'd connect too late, same reason
// projects/sheets/show.html.erb marks every grid script data-turbo-track="reload"). Load order,
// enforced by that view: jsuites -> formula-parser -> this file -> jspreadsheet.
//
// The call site, read directly out of vendor/javascript/jspreadsheet.js (not documentation):
//   res = formula(expression.substr(1), formulaExpressions, x, y, obj)
//   if (typeof res === "function") res = "#ERROR"     // and a throw is ALSO caught -> "#ERROR"
//
// Two facts about that call, both verified against the bundle bytes:
//
// 1. The grid resolves cell references itself before calling in. It strips "$" from A1-style refs,
//    EXPANDS ranges (`SUM(A1:A5)` arrives as `SUM(A1,A2,A3,A4,A5)` — tokensUpdate() joins the
//    expanded cells with commas and substitutes them into the expression text), and builds
//    `formulaExpressions`, a plain object mapping every remaining cell token to its value. So this
//    adapter's job is expression evaluation against an injected scope, not reference resolution —
//    hot-formula-parser's `callCellValue`/`callVariable` hooks are exactly that seam.
// 2. Values in `formulaExpressions` are pre-formatted for `eval`, which is the trap: blanks are
//    `null`, numbers are numbers, and STRINGS ARE WRAPPED IN LITERAL DOUBLE QUOTE CHARACTERS —
//    `'"text"'` (6 characters for "text"), not `"text"` (4). Confirmed both by reading the bundle's
//    `formulaExpressions[tokens[i]]='"'+t+'"'` assignment and by running this exact adapter against
//    the real vendored dist/formula-parser.min.js in Node: without the unwrap below, `=A1&"!"` on
//    A1 holding "abc" returns `"abc"!` (quotes intact); with it, `abc!`.
;(function () {
  if (typeof formulaParser === "undefined") return
  var Parser = formulaParser.Parser

  function unwrap(value) {
    if (
      typeof value === "string" &&
      value.length >= 2 &&
      value.charAt(0) === '"' &&
      value.charAt(value.length - 1) === '"'
    ) {
      return value.slice(1, -1)
    }
    return value
  }

  window.formula = function (expression, variables) {
    var parser = new Parser()

    // coord is {label, row, column}; label is the "A1" token, matching formulaExpressions' keys.
    parser.on("callCellValue", function (coord, done) {
      done(unwrap(variables[coord.label]))
    })
    // Bare names (not cell refs) resolve the same way; hot-formula-parser throws its own #NAME?
    // if done() is never called with a defined value, so an unrecognized name still errors sanely.
    parser.on("callVariable", function (name, done) {
      done(unwrap(variables[name]))
    })

    var parsed = parser.parse(expression)
    // Real Excel error strings (#DIV/0!, #NAME?, #VALUE!, …) beat the grid's generic "#ERROR",
    // which is all a caller gets if this function throws or returns a function — so return the
    // engine's own error text instead of letting an exception collapse it to the generic one.
    return parsed.error ? parsed.error : parsed.result
  }
})()
