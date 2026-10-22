require "application_system_test_case"

# THE CALCULATOR'S LANGUAGE, PINNED EXPRESSION BY EXPRESSION — app/javascript/lib/calc.js.
#
# WHY A SYSTEM TEST FOR A PURE MODULE. test/system/README.md's rule is "a behaviour earns a system
# test iff it is observable only in a browser", and this one is: the engine is browser-only
# JavaScript, the repo has no JS unit runner, and the CI runners are not promised a node. So the
# page is only a host for `import("lib/calc")` — WHICH page does not matter, only that it is a
# signed-in app page carrying the importmap — and the whole table goes through in ONE browser round
# trip, because a round trip is the ~1 s this tier costs.
#
# WHAT IT PINS: precedence (unary minus looser than ^, ^ right-associative), implicit
# multiplication and its limits, percent as desk-calculator percent, every unit and alias, the four
# conversion spellings and `in`'s double duty, the fraction-literal rule against ordinary division,
# the left-operand display unit both ways, areas and volumes, trig in radians and degrees, rounding
# noise, every error message a maker can be shown, and formatInches/formatNumber.
#
# MUTATION-CHECKED (test/system/README.md, CLAUDE.md §15) on 2026-10-21, each RED, each restored by
# copying a saved calc.js back (it was untracked, so git could not restore it):
#   (a) foldLiterals' fraction branch disabled, so `1/4in` is 1 ÷ (4 in) — 8 rows red, starting
#       `"1/4in": expected 0.25 in (dim 1), got [0.25, "0.25 1/in", "1/in", -1, false]`. Note the
#       VALUE survives the mutation (0.25 either way); only the unit and dim catch it, which is why
#       every row asserts all of them.
#   (b) the + / − dimension check skipped when one side is plain — 7 rows red, starting
#       `"12mm + 1": expected "Can't add a plain number to a length. …", got … "text" => "13 mm"`.
#   (c) ^ made a left-associative loop — red on `"2^3^2": expected 512 (dim 0), got [64, …]`.
class CalculatorEngineTest < ApplicationSystemTestCase
  setup { sign_in_as("calc-engine@example.com") }

  # [input, value, text, dim]. The unit is the text after its first space ("" when there is none),
  # and `fractionable` must be exactly "the unit is in", so both are checked off these four.
  ANSWERS = [
    # precedence and associativity
    [ "1+2*3", 7, "7", 0 ],
    [ "(1+2)*3", 9, "9", 0 ],
    [ "10-4-3", 3, "3", 0 ],
    [ "-2^2", -4, "-4", 0 ],
    [ "(-2)^2", 4, "4", 0 ],
    [ "2^3^2", 512, "512", 0 ],
    [ "2**3", 8, "8", 0 ],
    [ "2^-1", 0.5, "0.5", 0 ],
    [ "-(3)", -3, "-3", 0 ],
    [ "+5", 5, "5", 0 ],
    [ "6 × 7", 42, "42", 0 ],
    [ "6 · 7", 42, "42", 0 ],
    [ "84 ÷ 2", 42, "42", 0 ],
    [ "50 − 8", 42, "42", 0 ],
    [ "12.5", 12.5, "12.5", 0 ],
    [ ".5", 0.5, "0.5", 0 ],
    [ "1e3", 1000, "1000", 0 ],
    [ "1.5e-3", 0.0015, "0.0015", 0 ],
    [ "3+4=", 7, "7", 0 ],
    # implicit multiplication — only these four shapes
    [ "2(3+4)", 14, "14", 0 ],
    [ "2pi", 6.28318530718, "6.283185307", 0 ],
    [ "2π", 6.28318530718, "6.283185307", 0 ],
    [ "(1+1)(2+2)", 8, "8", 0 ],
    [ "2sqrt(9)", 6, "6", 0 ],
    [ "(1+1)sqrt(9)", 6, "6", 0 ],
    # percent is percent, never modulo
    [ "10%", 0.1, "0.1", 0 ],
    [ "300mm + 10%", 330, "330 mm", 1 ],
    [ "200 - 25%", 150, "150", 0 ],
    [ "50 * 10%", 5, "5", 0 ],
    # units and every alias
    [ "2mm", 2, "2 mm", 1 ],
    [ "2 cm", 2, "2 cm", 1 ],
    [ "2m", 2, "2 m", 1 ],
    [ "2in", 2, "2 in", 1 ],
    [ "2 in", 2, "2 in", 1 ],
    [ "2ft", 2, "2 ft", 1 ],
    [ "2 inch", 2, "2 in", 1 ],
    [ "2 Inches", 2, "2 in", 1 ],
    [ '2"', 2, "2 in", 1 ],
    [ "2”", 2, "2 in", 1 ],
    [ "2 foot", 2, "2 ft", 1 ],
    [ "2 FEET", 2, "2 ft", 1 ],
    [ "2'", 2, "2 ft", 1 ],
    [ "2 millimeter", 2, "2 mm", 1 ],
    [ "2 millimeters", 2, "2 mm", 1 ],
    [ "2 millimetre", 2, "2 mm", 1 ],
    [ "2 millimetres", 2, "2 mm", 1 ],
    [ "2 centimeter", 2, "2 cm", 1 ],
    [ "2 centimeters", 2, "2 cm", 1 ],
    [ "2 centimetre", 2, "2 cm", 1 ],
    [ "2 centimetres", 2, "2 cm", 1 ],
    [ "2 meter", 2, "2 m", 1 ],
    [ "2 meters", 2, "2 m", 1 ],
    [ "2 metre", 2, "2 m", 1 ],
    [ "2 metres", 2, "2 m", 1 ],
    [ "2 MM", 2, "2 mm", 1 ],
    [ "(3+4)in", 7, "7 in", 1 ],
    [ "1e3mm", 1000, "1000 mm", 1 ],
    [ "3 * 12mm", 36, "36 mm", 1 ],
    # the four conversion spellings, and `in` as both the inch and the keyword
    [ "3 ft to mm", 914.4, "914.4 mm", 1 ],
    [ "2.5in in mm", 63.5, "63.5 mm", 1 ],
    [ "3ft as cm", 91.44, "91.44 cm", 1 ],
    [ "3ft -> in", 36, "36 in", 1 ],
    [ "3ft → in", 36, "36 in", 1 ],
    [ "5in in in", 5, "5 in", 1 ],
    [ "3 in to mm", 76.2, "76.2 mm", 1 ],
    [ "1 m to millimetres", 1000, "1000 mm", 1 ],
    [ "100mm to cm", 10, "10 cm", 1 ],
    [ "2 ft in in", 24, "24 in", 1 ],
    [ "(3+4)in in mm", 177.8, "177.8 mm", 1 ],
    [ "10in*2in to mm", 12903.2, "12903.2 mm²", 2 ],
    [ "3 in^2 in mm", 1935.48, "1935.48 mm²", 2 ],
    # fraction literals and mixed numbers, against ordinary division
    [ "1/4in", 0.25, "0.25 in", 1 ],
    [ "1/4 in", 0.25, "0.25 in", 1 ],
    [ '3/8"', 0.375, "0.375 in", 1 ],
    [ "3 1/2in", 3.5, "3.5 in", 1 ],
    [ '3 1/2"', 3.5, "3.5 in", 1 ],
    [ "3 1/2 in", 3.5, "3.5 in", 1 ],
    [ "3 1/2", 3.5, "3.5", 0 ],
    [ "-1/4in", -0.25, "-0.25 in", 1 ],
    [ "3/2^2", 0.75, "0.75", 0 ],
    [ "10/4", 2.5, "2.5", 0 ],
    [ "1 / 4in", 0.25, "0.25 1/in", -1 ],
    [ "1/4in * 4", 1, "1 in", 1 ],
    # the answer is in the LEFT operand's unit, both ways round
    [ "12.5mm + 1/4in", 18.85, "18.85 mm", 1 ],
    [ "1/4in + 12.5mm", 0.742125984252, "0.7421259843 in", 1 ],
    [ "1ft - 6in", 0.5, "0.5 ft", 1 ],
    # areas and volumes
    [ "10in * 2in", 20, "20 in²", 2 ],
    [ "6in^2 / 2in", 3, "3 in", 1 ],
    [ "6in² / 2in", 3, "3 in", 1 ],
    [ "20 in²", 20, "20 in²", 2 ],
    [ "12mm / 3mm", 4, "4", 0 ],
    [ "(2in)^2", 4, "4 in²", 2 ],
    [ "2in*3in*4in", 24, "24 in³", 3 ],
    [ "2mm³", 2, "2 mm³", 3 ],
    [ "sqrt(9in*4in)", 6, "6 in", 1 ],
    # functions, trig in radians and degrees
    [ "sqrt(16)", 4, "4", 0 ],
    [ "sin(30deg)", 0.5, "0.5", 0 ],
    [ "sin(30°)", 0.5, "0.5", 0 ],
    [ "sin(pi/6)", 0.5, "0.5", 0 ],
    [ "cos(60 deg)", 0.5, "0.5", 0 ],
    [ "tan(45deg)", 1, "1", 0 ],
    [ "sin(pi)", 0, "0", 0 ],
    [ "cos(90deg)", 0, "0", 0 ],
    [ "asin(0.5) to deg", 30, "30 °", 0 ],
    [ "acos(0.5) to deg", 60, "60 °", 0 ],
    [ "atan(1) to deg", 45, "45 °", 0 ],
    [ "atan(1) in deg", 45, "45 °", 0 ],
    [ "atan(1) to °", 45, "45 °", 0 ],
    [ "abs(-3mm)", 3, "3 mm", 1 ],
    [ "round(12.6mm)", 13, "13 mm", 1 ],
    [ "round(1/4in + 12.5mm)", 1, "1 in", 1 ],
    [ "round(-2.5)", -3, "-3", 0 ],
    [ "floor(2.7in)", 2, "2 in", 1 ],
    [ "ceil(2.1)", 3, "3", 0 ],
    [ "ceil(0.1*3*10)", 3, "3", 0 ],
    [ "ln(1)", 0, "0", 0 ],
    [ "log(1000)", 3, "3", 0 ],
    # rounding noise
    [ "0.1+0.2", 0.3, "0.3", 0 ],
    [ "0.3-0.1-0.2", 0, "0", 0 ],
    [ "1/3", 0.333333333333, "0.3333333333", 0 ]
  ].freeze

  # input => the exact message.
  REFUSALS = {
    "12mm + 1" => "Can't add a plain number to a length. Give the 1 a unit, like 1mm.",
    "5in + 2" => "Can't add a plain number to a length. Give the 2 a unit, like 2in.",
    "2 + 5in" => "Can't add a plain number to a length. Give the 2 a unit, like 2in.",
    "5in + (1+1)" => "Can't add a plain number to a length. Give it a unit, like 1in.",
    "5in - 2" => "Can't subtract a plain number from a length. Give the 2 a unit, like 2in.",
    "2 - 5in" => "Can't subtract a length from a plain number. Give the 2 a unit, like 2in.",
    "10in*2in + 3" => "Can't add a plain number to an area. Give the 3 a unit, like 3in².",
    "5mm + 2mm*3mm" => "Can't add mm and mm² — they're different kinds of measurement.",
    "5mm - 2mm*3mm" => "Can't subtract mm² from mm — they're different kinds of measurement.",
    "5 to mm" => "Nothing to convert — 5 has no unit. Write 5mm or 5in.",
    "(2+3) to mm" => "Nothing to convert — the result has no unit.",
    "3mm to deg" => "Can't convert a length to degrees.",
    "3 ft to" => 'Convert to what? End with a unit, like "to mm".',
    "3 + kg" => 'Unknown word "kg".',
    "3 ft to Kg" => 'Unknown word "Kg".',
    "2x3" => 'Unknown word "x". To multiply, use * or ×.',
    "" => "Nothing to calculate.",
    "   " => "Nothing to calculate.",
    "(3+4" => "Missing a closing parenthesis.",
    "3)" => 'Unexpected ")".',
    "*3" => 'Unexpected "*".',
    "3 × × 4" => 'Unexpected "×".',
    "3 +" => "The expression ends too soon.",
    "2 3" => 'Missing an operator before "3".',
    "pi(2)" => 'Unexpected "(".',
    "sqrt 9" => "sqrt needs parentheses, like sqrt(9).",
    "1/0" => "Division by zero.",
    "1/0in" => "Division by zero.",
    "1e308 * 10" => "The result is too large to show.",
    "sqrt(-1)" => "Can't take the square root of a negative number.",
    "sqrt(4mm)" => "The square root of a length isn't a length. Square it first, or drop the unit.",
    "ln(0)" => "ln needs a positive number.",
    "log(-1)" => "log needs a positive number.",
    "ln(3mm)" => "ln needs a plain number.",
    "sin(3mm)" => "sin needs a plain number or an angle (like 30deg).",
    "cos(1in)" => "cos needs a plain number or an angle (like 30deg).",
    "(2in)^0.5" => "Can't raise in to the power 0.5 — the unit wouldn't be whole.",
    "x" * 501 => "That expression is too long."
  }.freeze

  # [inches, denominator, text, exact]
  INCHES = [
    [ 3.1875, 16, "3 3/16 in", true ],
    [ 0.09375, 32, "3/32 in", true ],
    [ 5, 16, "5 in", true ],
    [ -1.5, 16, "-1 1/2 in", true ],
    [ 0, 16, "0 in", true ],
    [ 0.5, 16, "1/2 in", true ],        # 8/16, reduced
    [ 0.75, 32, "3/4 in", true ],       # 24/32, reduced
    [ 1.03125, 32, "1 1/32 in", true ],
    [ 0.1, 16, "1/8 in", false ],       # 1.6/16 rounds to 2/16
    [ 0.1, 32, "3/32 in", false ],      # ...but to 3/32 at the finer grid
    [ 2.999, 16, "3 in", false ],       # rounds to a whole number
    [ -0.01, 16, "0 in", false ],       # never "-0 in"
    [ 0.742125984252, 16, "3/4 in", false ]
  ].freeze

  # number => formatNumber's text
  NUMBERS = {
    12903.2 => "12903.2",
    0.30000000000000004 => "0.3",
    -0.0 => "0",
    0.000001 => "0.000001",
    1.5e-7 => "1.5e-7",
    123456789012 => "123456789000",
    1e15 => "1e15",
    -42.5 => "-42.5"
  }.freeze

  test "the calculator language answers and refuses exactly as specified" do
    visit tools_path
    inputs = ANSWERS.map(&:first) + REFUSALS.keys
    out = page.evaluate_async_script(<<~JS, inputs, INCHES.map { |i, d, *| [ i, d ] }, NUMBERS.keys)
      const [inputs, inches, numbers, done] = arguments
      import("lib/calc")
        .then((m) => done({
          results: inputs.map((s) => m.evaluate(s)),
          inches: inches.map(([i, d]) => m.formatInches(i, d)),
          numbers: numbers.map((n) => m.formatNumber(n)),
        }))
        .catch((e) => done({ error: String(e) }))
    JS
    assert_nil out["error"], "lib/calc did not import"
    results = out["results"]
    assert_equal inputs.size, results.size # a short answer list would pass every loop below vacuously

    wrong = []
    ANSWERS.each_with_index do |(input, value, text, dim), i|
      r = results[i]
      unit = text[/ (.+)\z/, 1].to_s
      got = r["ok"] ? [ r["value"], r["text"], r["unit"], r["dim"], r["fractionable"] ] : r["error"]
      wrong << "#{input.inspect}: expected #{text} (dim #{dim}), got #{got.inspect}" unless
        r["ok"] && r["value"] == value && r["text"] == text && r["unit"] == unit && r["dim"] == dim &&
        r["fractionable"] == (unit == "in")
    end
    REFUSALS.each_with_index do |(input, message), j|
      r = results[ANSWERS.size + j]
      wrong << "#{input[0, 40].inspect}: expected #{message.inspect}, got #{r.inspect}" unless
        r == { "ok" => false, "error" => message }
    end
    assert_empty wrong, "evaluate() disagreed with the language:\n#{wrong.join("\n")}"

    inch_wrong = INCHES.zip(out["inches"]).reject { |(_, _, text, exact), got| got == { "text" => text, "exact" => exact } }
    assert_empty inch_wrong, "formatInches disagreed: #{inch_wrong.inspect}"
    assert_equal NUMBERS.values, out["numbers"], "formatNumber disagreed"
  end
end
