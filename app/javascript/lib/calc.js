// The maker's calculator engine: a string in, an answer (or a plain-English refusal) out.
// calculator_controller.js is the only importer; this file knows nothing about the modal.
//
// A HAND-WRITTEN PARSER, NEVER `eval` OR `new Function`. The app's script-src carries no
// 'unsafe-eval' (config/initializers/content_security_policy.rb), so either would be refused the
// day the policy enforces, and an input box that evaluates JavaScript is a code-execution door
// whatever the policy says. Three stages, each small enough to read in one sitting: `tokenize`
// (characters to tokens, unknown words refused there), `foldLiterals` (the fraction rules below),
// then a recursive-descent `Parser` to an AST that `evaluateNode` walks.
//
// PURE: NO DOM, NO IMPORTS. That is what lets calculator_engine_test.rb drive the whole language
// from one `import()` in a page, and what keeps a bundle from needing it — a HOST pin like
// lib/print_sheet, which no addon may import.
//
// EVERY LENGTH IS MILLIMETRES INSIDE, WITH AN INTEGER DIMENSION (1 length, 2 area, 3 volume,
// negative for 1/mm), AND THE UNIT IT IS SHOWN IN TRAVELS SEPARATELY. The display unit is the first
// length unit met reading left to right, so `12.5mm + 1/4in` answers in mm and `1/4in + 12.5mm` in
// inches: the maker started in that unit, and the answer should come back in it.
//
// A DIMENSION MISMATCH IS AN ERROR, NEVER A GUESS. `12mm + 1` refuses and says how to fix it.
// Quietly reading the bare 1 as "1 of whatever the left side was" is the classic calculator bug,
// and a maker cutting a board is the person it bites. Multiplying a length by a plain number is
// fine; adding one is not.
//
// A FRACTION WRITTEN AGAINST A UNIT IS ONE LITERAL. `1/4in` is a quarter inch, not 1 ÷ (4 in), and
// `3 1/2"` is three and a half inches. It is decided on TOKENS, before parsing, because it is the
// one place spacing matters: `INT/INT` with no space around the slash, followed by a unit — or
// preceded by a whole number and a space — folds into a single number. Everywhere else `/` is
// division at its ordinary precedence (`3/2^2` = 0.75, `1 / 4in` = 0.25 per inch).
//
// `in` IS BOTH THE INCH AND A CONVERSION KEYWORD, and position decides. Directly after a number or
// `)` it is the inch (`3 in`); between a complete expression and a final unit it converts
// (`2.5in in mm`, `5in in in`). The conversion is split off the END of the token list before
// anything is parsed, so it can only ever apply to the whole input.
//
// THE ANSWER IS ROUNDED TO 12 SIGNIFICANT DIGITS, so 0.1 + 0.2 is 0.3 rather than a float's
// 0.30000000000000004. A difference that cancels to float noise is snapped to 0, and so is a sine
// or cosine at a multiple of π, because "6.1e-17" is never what `cos(90deg)` meant.

const MAX_LENGTH = 500
const SIG_DIGITS = 12

// Millimetres per unit.
const LENGTH = { mm: 1, cm: 10, m: 1000, in: 25.4, ft: 304.8 }

class CalcError extends Error {}
const fail = (message) => { throw new CalcError(message) }

const WORDS = new Map()
const alias = (names, token) => { for (const n of names) WORDS.set(n, token) }
alias(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], { t: "unit", u: "mm" })
alias(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], { t: "unit", u: "cm" })
alias(["m", "meter", "meters", "metre", "metres"], { t: "unit", u: "m" })
alias(["in", "inch", "inches"], { t: "unit", u: "in" })
alias(["ft", "foot", "feet"], { t: "unit", u: "ft" })
alias(["deg", "degree", "degrees"], { t: "deg" })
alias(["pi"], { t: "const" })
alias(["to", "as"], { t: "kw" })

// A function's name and the example its "needs parentheses" message offers.
const FUNCTIONS = {
  sqrt: "sqrt(9)", sin: "sin(30deg)", cos: "cos(60deg)", tan: "tan(45deg)", asin: "asin(0.5)",
  acos: "acos(0.5)", atan: "atan(1)", abs: "abs(-3)", round: "round(2.5)", floor: "floor(2.5)",
  ceil: "ceil(2.5)", ln: "ln(10)", log: "log(100)",
}
for (const f of Object.keys(FUNCTIONS)) WORDS.set(f, { t: "func", f })

// Phones turn " and ' into curly quotes after a digit, so the curly and prime forms count too.
const SYMBOLS = {
  '"': { t: "unit", u: "in" }, "“": { t: "unit", u: "in" }, "”": { t: "unit", u: "in" }, "″": { t: "unit", u: "in" },
  "'": { t: "unit", u: "ft" }, "‘": { t: "unit", u: "ft" }, "’": { t: "unit", u: "ft" }, "′": { t: "unit", u: "ft" },
  "°": { t: "deg" }, "π": { t: "const" }, "²": { t: "sup", n: 2 }, "³": { t: "sup", n: 3 },
  "+": { t: "op", op: "+" }, "-": { t: "op", op: "-" }, "−": { t: "op", op: "-" },
  "*": { t: "op", op: "*" }, "×": { t: "op", op: "*" }, "·": { t: "op", op: "*" }, "⋅": { t: "op", op: "*" },
  "/": { t: "op", op: "/" }, "÷": { t: "op", op: "/" }, "^": { t: "op", op: "^" }, "%": { t: "op", op: "%" },
  "(": { t: "op", op: "(" }, ")": { t: "op", op: ")" }, "→": { t: "kw" }, "=": { t: "eq" },
}

const NUMBER = /(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/y
const WORD = /[A-Za-z]+/y

function tokenize(src) {
  const tokens = []
  let i = 0
  let space = false
  while (i < src.length) {
    const ch = src[i]
    if (/\s/.test(ch)) { space = true; i++; continue }
    let tok
    NUMBER.lastIndex = i
    WORD.lastIndex = i
    let m
    if ((m = NUMBER.exec(src))) {
      tok = { t: "num", value: Number(m[0]), isInt: /^\d+$/.test(m[0]), text: m[0] }
    } else if ((m = WORD.exec(src))) {
      const known = WORDS.get(m[0].toLowerCase())
      if (!known) {
        const hint = m[0].toLowerCase() === "x" ? " To multiply, use * or ×." : ""
        fail(`Unknown word "${m[0]}".${hint}`)
      }
      tok = { ...known, text: m[0] }
    } else if (src.startsWith("**", i)) {
      tok = { t: "op", op: "^", text: "**" }
    } else if (src.startsWith("->", i)) {
      tok = { t: "kw", text: "->" }
    } else if (SYMBOLS[ch]) {
      tok = { ...SYMBOLS[ch], text: ch }
    } else {
      fail(`Unexpected "${ch}".`)
    }
    tok.sb = space
    space = false
    tokens.push(tok)
    i += tok.text.length
  }
  // A trailing "=" is the desk-calculator habit, not an error; anywhere else it is.
  if (tokens.length && tokens[tokens.length - 1].t === "eq") tokens.pop()
  const eq = tokens.find((tok) => tok.t === "eq")
  if (eq) fail(`Unexpected "${eq.text}".`)
  return tokens
}

const isOp = (tok, op) => !!tok && tok.t === "op" && tok.op === op
const isInt = (tok) => !!tok && tok.t === "num" && tok.isInt
// Only the ASCII slash makes a fraction; ÷ is always division.
const isTightSlash = (tok) => isOp(tok, "/") && tok.text === "/" && !tok.sb
const isUnitLike = (tok) => !!tok && (tok.t === "unit" || tok.t === "deg")

// Split a trailing `to mm` / `in mm` / `as mm` / `-> mm` / `to deg` off the end.
function splitConversion(tokens) {
  const n = tokens.length
  if (n >= 3) {
    const k = tokens[n - 2]
    const w = tokens[n - 1]
    let keyword = k.t === "kw"
    if (k.t === "unit" && k.text.toLowerCase() === "in") {
      // `3 in mm` reads the `in` as the inch (it follows a number), so it is not a conversion —
      // unless the target is an angle (no "inches of degrees" exists), or the number before it is
      // an exponent (`3 in^2 in mm`), which a unit could never attach to.
      const prev = tokens[n - 3]
      const attaches = (prev.t === "num" && !isOp(tokens[n - 4], "^")) || isOp(prev, ")")
      keyword = w.t === "deg" || !attaches
    }
    if (keyword && isUnitLike(w)) {
      return { tokens: tokens.slice(0, n - 2), target: w.t === "deg" ? "deg" : w.u }
    }
  }
  if (n >= 2 && tokens[n - 1].t === "kw") fail('Convert to what? End with a unit, like "to mm".')
  return { tokens, target: null }
}

// The two fraction rules, as a token pass (see the header for why here and not in the grammar).
function foldLiterals(tokens) {
  const out = []
  for (let i = 0; i < tokens.length; i++) {
    const [a, b, c, d] = [tokens[i], tokens[i + 1], tokens[i + 2], tokens[i + 3]]
    // Mixed number: INT, whitespace, INT/INT — `3 1/2`, with or without a unit after it.
    if (isInt(a) && isInt(b) && b.sb && isTightSlash(c) && isInt(d) && !d.sb) {
      out.push({ t: "frac", whole: a.value, n: b.value, d: d.value, text: `${a.text} ${b.text}/${d.text}`, sb: a.sb })
      i += 3
      continue
    }
    // Fraction literal: INT/INT directly before a unit — `1/4in`, `1/4 in`, `3/8"`.
    if (isInt(a) && isTightSlash(b) && isInt(c) && !c.sb && isUnitLike(d)) {
      out.push({ t: "frac", whole: 0, n: a.value, d: c.value, text: `${a.text}/${c.text}`, sb: a.sb })
      i += 2
      continue
    }
    out.push(a)
  }
  return out
}

function strayError(tok) {
  if (tok.t === "num" || tok.t === "frac") return `Missing an operator before "${tok.text}".`
  return `Unexpected "${tok.text}".`
}

// Precedence, loosest first: + -  then  * / (and implicit *)  then unary -  then ^ (right-assoc),
// then postfix %, then a primary with its unit or angle suffix. Unary minus sits OUTSIDE ^ so that
// -2^2 is -4, and ^'s right operand is a unary so that 2^-1 parses.
class Parser {
  constructor(tokens) { this.toks = tokens; this.i = 0 }
  peek() { return this.toks[this.i] }
  next() { return this.toks[this.i++] }

  parse() {
    const node = this.additive()
    if (this.i < this.toks.length) fail(strayError(this.peek()))
    return node
  }

  additive() {
    let left = this.term()
    while (isOp(this.peek(), "+") || isOp(this.peek(), "-")) {
      const op = this.next().op
      left = { k: "bin", op, l: left, r: this.term() }
    }
    return left
  }

  term() {
    let left = this.unary()
    for (;;) {
      const t = this.peek()
      if (isOp(t, "*") || isOp(t, "/")) {
        this.next()
        left = { k: "bin", op: t.op, l: left, r: this.unary() }
      } else if (this.implicitNext()) {
        left = { k: "bin", op: "*", l: left, r: this.power() }
      } else {
        return left
      }
    }
  }

  // Implicit multiplication exists ONLY for 2(3+4), 2pi, (a)(b), 2sqrt(9) and (a)sqrt(b). Never
  // number-space-number: `3 1/2` is a mixed number and `3 4` is a missing operator.
  implicitNext() {
    const p = this.toks[this.i - 1]
    const t = this.peek()
    if (!p || !t) return false
    const afterNumber = p.t === "num" || p.t === "frac"
    const afterParen = isOp(p, ")")
    if (isOp(t, "(") || t.t === "func") return afterNumber || afterParen
    if (t.t === "const") return afterNumber
    return false
  }

  unary() {
    if (isOp(this.peek(), "-")) { this.next(); return { k: "neg", e: this.unary() } }
    if (isOp(this.peek(), "+")) { this.next(); return this.unary() }
    return this.power()
  }

  power() {
    let base = this.postfix()
    if (this.peek() && this.peek().t === "sup") base = { k: "pow", l: base, r: { k: "num", v: this.next().n } }
    if (isOp(this.peek(), "^")) { this.next(); return { k: "pow", l: base, r: this.unary() } }
    return base
  }

  postfix() {
    const node = this.primary()
    if (isOp(this.peek(), "%")) { this.next(); return { k: "pct", e: node } }
    return node
  }

  primary() {
    const t = this.next()
    if (!t) fail("The expression ends too soon.")
    if (t.t === "num") return this.suffix({ k: "num", v: t.value })
    if (t.t === "frac") return this.suffix({ k: "frac", whole: t.whole, n: t.n, d: t.d })
    if (t.t === "const") return { k: "num", v: Math.PI, constant: true }
    if (t.t === "func") {
      if (!isOp(this.next(), "(")) fail(`${t.text} needs parentheses, like ${FUNCTIONS[t.f]}.`)
      const arg = this.additive()
      this.close()
      return this.suffix({ k: "call", f: t.f, e: arg })
    }
    if (isOp(t, "(")) {
      const inner = this.additive()
      this.close()
      return this.suffix(inner)
    }
    fail(`Unexpected "${t.text}".`)
  }

  close() {
    const t = this.next()
    if (!t) fail("Missing a closing parenthesis.")
    if (!isOp(t, ")")) fail(strayError(t))
  }

  // A unit (optionally with its own power: `6in^2`, `6in²` — six SQUARE inches, not (6in)²) or an
  // angle suffix, directly after a number, a fraction literal or a `)`.
  suffix(node) {
    const t = this.peek()
    if (t && t.t === "deg") { this.next(); return { k: "deg", e: node } }
    if (!t || t.t !== "unit") return node
    this.next()
    let p = 1
    const s = this.peek()
    if (s && s.t === "sup") {
      this.next()
      p = s.n
    } else if (isOp(s, "^")) {
      let j = this.i + 1
      let sign = 1
      if (isOp(this.toks[j], "-") || isOp(this.toks[j], "+")) { sign = this.toks[j].op === "-" ? -1 : 1; j++ }
      const num = this.toks[j]
      if (num && num.t === "num") {
        if (!num.isInt) fail(`A unit's power must be a whole number, like ${t.u}^2.`)
        this.i = j + 1
        p = sign * num.value
      }
    }
    return { k: "unit", e: node, u: t.u, p }
  }
}

// ---- values: { v (millimetres^dim, or a plain number), dim, u (display unit, null when plain) }

const plain = (v) => ({ v, dim: 0, u: null })
const SUPERSCRIPT = "⁰¹²³⁴⁵⁶⁷⁸⁹"
const superscript = (n) => (n === 1 ? "" : String(n).split("").map((c) => SUPERSCRIPT[c]).join(""))

function unitString(u, dim) {
  if (dim === 0 || !u) return ""
  return dim > 0 ? u + superscript(dim) : `1/${u}${superscript(-dim)}`
}

function kindOf(dim) {
  return { 1: "a length", 2: "an area", 3: "a volume" }[dim] || "a measurement"
}

function round12(x) {
  const r = Number(x.toPrecision(SIG_DIGITS))
  return r === 0 ? 0 : r
}

function checked(x) {
  if (!Number.isFinite(x.v)) fail("The result is too large to show.")
  return x
}

// The number a node was written as, when it was written as one — used to say "Give the 2 a unit"
// instead of "Give it a unit". Returns null for anything computed.
function literalValue(node) {
  if (node.k === "num" && !node.constant) return node.v
  if (node.k === "frac" && node.d !== 0) return node.whole + node.n / node.d
  if (node.k === "neg") { const v = literalValue(node.e); return v === null ? null : -v }
  return null
}

function mismatchMessage(op, L, R, lNode, rNode) {
  if (L.dim === 0 || R.dim === 0) {
    const plainLeft = L.dim === 0
    const measured = plainLeft ? R : L
    const kind = kindOf(measured.dim)
    const head = op === "+" ? `Can't add a plain number to ${kind}.`
      : plainLeft ? `Can't subtract ${kind} from a plain number.` : `Can't subtract a plain number from ${kind}.`
    const unit = unitString(measured.u, measured.dim)
    if (measured.dim < 0) return `${head} Give it a matching unit.`
    const lit = literalValue(plainLeft ? lNode : rNode)
    if (lit === null) return `${head} Give it a unit, like 1${unit}.`
    const shown = formatNumber(lit)
    return `${head} Give the ${shown} a unit, like ${shown}${unit}.`
  }
  const a = unitString(L.u, L.dim)
  const b = unitString(R.u, R.dim)
  return op === "+" ? `Can't add ${a} and ${b} — they're different kinds of measurement.`
    : `Can't subtract ${b} from ${a} — they're different kinds of measurement.`
}

// The value in its own display unit, cleaned to 12 digits — what round/floor/ceil act on, so that
// ceil(0.1*3*10) is 3, not the 4 a float's 3.0000000000000004 would give.
const displayScale = (x) => (x.dim === 0 ? 1 : LENGTH[x.u] ** x.dim)

function callFunction(f, x) {
  const needsPlain = (msg) => { if (x.dim !== 0) fail(msg) }
  switch (f) {
    case "sqrt": {
      if (x.dim === 1) fail("The square root of a length isn't a length. Square it first, or drop the unit.")
      if (x.dim === 3) fail("The square root of a volume isn't a length or an area.")
      if (x.dim % 2 !== 0) fail(`Can't take the square root of ${unitString(x.u, x.dim)}.`)
      if (x.v < 0) fail("Can't take the square root of a negative number.")
      const dim = x.dim / 2
      return { v: Math.sqrt(x.v), dim, u: dim === 0 ? null : x.u }
    }
    case "sin": case "cos": case "tan": {
      needsPlain(`${f} needs a plain number or an angle (like 30deg).`)
      if (f === "tan" && Math.abs(Math.cos(x.v)) < 1e-12) fail("tan is undefined at that angle.")
      const r = Math[f](x.v)
      return plain(Math.abs(x.v) >= 1 && Math.abs(r) < 1e-12 ? 0 : r)
    }
    case "asin": case "acos": {
      needsPlain(`${f} needs a plain number.`)
      if (x.v < -1 || x.v > 1) fail(`${f} needs a number between -1 and 1.`)
      return plain(Math[f](x.v))
    }
    case "atan":
      needsPlain("atan needs a plain number.")
      return plain(Math.atan(x.v))
    case "ln": case "log":
      needsPlain(`${f} needs a plain number.`)
      if (x.v <= 0) fail(`${f} needs a positive number.`)
      return plain(f === "ln" ? Math.log(x.v) : Math.log10(x.v))
    case "abs":
      return { ...x, v: Math.abs(x.v) }
    default: { // round, floor, ceil — in the display unit: round(12.6mm) is 13 mm
      const scale = displayScale(x)
      const shown = round12(x.v / scale)
      const r = f === "floor" ? Math.floor(shown) : f === "ceil" ? Math.ceil(shown)
        : Math.sign(shown) * Math.round(Math.abs(shown)) // half away from zero: round(-2.5) is -3
      return { ...x, v: (r === 0 ? 0 : r) * scale }
    }
  }
}

function evaluateNode(n) {
  switch (n.k) {
    case "num":
      return plain(n.v)
    case "frac":
      if (n.d === 0) fail("Division by zero.")
      return plain(n.whole + n.n / n.d)
    case "neg": {
      const x = evaluateNode(n.e)
      return { ...x, v: -x.v }
    }
    case "unit": {
      const x = evaluateNode(n.e)
      if (x.dim !== 0) fail("Can't put a unit on something that already has one.")
      return checked({ v: x.v * LENGTH[n.u] ** n.p, dim: n.p, u: n.p === 0 ? null : n.u })
    }
    case "deg": {
      const x = evaluateNode(n.e)
      if (x.dim !== 0) fail("deg goes on a plain number, like 30deg.")
      return plain((x.v * Math.PI) / 180)
    }
    case "pct": {
      const x = evaluateNode(n.e)
      if (x.dim !== 0) fail("% goes on a plain number, like 10%.")
      return plain(x.v / 100)
    }
    case "call":
      return checked(callFunction(n.f, evaluateNode(n.e)))
    case "pow": {
      const b = evaluateNode(n.l)
      const e = evaluateNode(n.r)
      if (e.dim !== 0) fail("A power must be a plain number.")
      let dim = 0
      if (b.dim !== 0) {
        dim = b.dim * e.v
        if (Math.abs(dim - Math.round(dim)) > 1e-9) {
          fail(`Can't raise ${unitString(b.u, b.dim)} to the power ${formatNumber(e.v)} — the unit wouldn't be whole.`)
        }
        dim = Math.round(dim)
      }
      if (b.v === 0 && e.v < 0) fail("Division by zero.")
      if (b.v < 0 && !Number.isInteger(e.v)) fail("Can't raise a negative number to a fractional power.")
      return checked({ v: b.v ** e.v, dim, u: dim === 0 ? null : b.u })
    }
    case "bin":
      return checked(binary(n))
  }
  fail("Couldn't read that expression.")
}

function binary(n) {
  const L = evaluateNode(n.l)
  // `a + b%` and `a - b%` with the percentage written directly: a × (1 ± b/100), keeping a's unit —
  // `300mm + 10%` is 330 mm, the way every desk calculator does a shrinkage allowance.
  if ((n.op === "+" || n.op === "-") && n.r.k === "pct") {
    const P = evaluateNode(n.r)
    return { ...L, v: L.v * (n.op === "+" ? 1 + P.v : 1 - P.v) }
  }
  const R = evaluateNode(n.r)
  switch (n.op) {
    case "+":
    case "-": {
      if (L.dim !== R.dim) fail(mismatchMessage(n.op, L, R, n.l, n.r))
      const v = n.op === "+" ? L.v + R.v : L.v - R.v
      const snapped = Math.abs(v) < 1e-12 * Math.max(Math.abs(L.v), Math.abs(R.v)) ? 0 : v
      return { v: snapped, dim: L.dim, u: L.u ?? R.u }
    }
    case "*": {
      const dim = L.dim + R.dim
      return { v: L.v * R.v, dim, u: dim === 0 ? null : L.u ?? R.u }
    }
    case "/": {
      if (R.v === 0) fail("Division by zero.")
      const dim = L.dim - R.dim
      return { v: L.v / R.v, dim, u: dim === 0 ? null : L.u ?? R.u }
    }
  }
  fail("Couldn't read that expression.")
}

function convert(x, target, ast) {
  if (target === "deg") {
    if (x.dim !== 0) fail(`Can't convert ${kindOf(x.dim)} to degrees.`)
    return { ...x, v: (x.v * 180) / Math.PI, degrees: true }
  }
  if (x.dim === 0) {
    const lit = literalValue(ast)
    if (lit === null) fail("Nothing to convert — the result has no unit.")
    const shown = formatNumber(lit)
    fail(`Nothing to convert — ${shown} has no unit. Write ${shown}mm or ${shown}in.`)
  }
  return { ...x, u: target }
}

function run(input) {
  const src = input == null ? "" : String(input)
  if (src.length > MAX_LENGTH) fail("That expression is too long.")
  const all = tokenize(src)
  if (all.length === 0) fail("Nothing to calculate.")
  const { tokens, target } = splitConversion(all)
  const ast = new Parser(foldLiterals(tokens)).parse()
  let x = evaluateNode(ast)
  if (target) x = convert(x, target, ast)

  let value = x.degrees ? x.v : x.v / displayScale(x)
  if (!Number.isFinite(value)) fail("The result is too large to show.")
  value = round12(value)
  const unit = x.degrees ? "°" : unitString(x.u, x.dim)
  return {
    ok: true,
    value,
    unit,
    dim: x.dim,
    text: formatNumber(value) + (unit ? " " + unit : ""),
    fractionable: unit === "in",
  }
}

export function evaluate(input) {
  try {
    return run(input)
  } catch (e) {
    if (e instanceof CalcError) return { ok: false, error: e.message }
    return { ok: false, error: "Couldn't read that expression." }
  }
}

// Up to 10 significant digits, plain decimals between 1e-6 and 1e15 and an exponent outside it
// (written `1.5e-7`, which this calculator reads back), no grouping so the text stays copyable.
export function formatNumber(n) {
  if (typeof n !== "number" || !Number.isFinite(n)) return String(n)
  const r = Number(n.toPrecision(10))
  if (r === 0) return "0"
  const a = Math.abs(r)
  if (a >= 1e-6 && a < 1e15) return String(r)
  return r.toExponential().replace("e+", "e")
}

const gcd = (a, b) => (b === 0 ? a : gcd(b, a % b))

// The nearest 1/denominator inch, reduced: `3 3/16 in`, `3/32 in`, `5 in`, `-1 1/2 in`. `exact`
// says whether rounding moved it; the modal prints "≈ " when it did.
export function formatInches(inches, denominator) {
  const den = Number.isInteger(denominator) && denominator > 0 ? denominator : 16
  if (typeof inches !== "number" || !Number.isFinite(inches)) return { text: `${String(inches)} in`, exact: false }
  const ticks = Math.round(Math.abs(inches) * den)
  const whole = Math.floor(ticks / den)
  let num = ticks % den
  let d = den
  if (num) { const g = gcd(num, d); num /= g; d /= g }
  let body
  if (ticks === 0) body = "0"
  else if (num === 0) body = String(whole)
  else if (whole === 0) body = `${num}/${d}`
  else body = `${whole} ${num}/${d}`
  const sign = inches < 0 && ticks !== 0 ? "-" : ""
  const rounded = (inches < 0 ? -1 : 1) * (ticks / den)
  return { text: `${sign}${body} in`, exact: Math.abs(rounded - inches) < 1e-9 }
}
