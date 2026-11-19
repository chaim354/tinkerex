require "test_helper"

# EVERY TEXT TOKEN CLEARS 4.5:1 ON EVERY GROUND IT IS DRAWN ON, IN PAPER AND IN GRAPHITE
# (Shop manual slice 4, 2026-11-19). The token blocks in application.css carry their contrast in
# comments, and a comment is a claim nothing checks: a later nudge to one red, one grey, one ground
# drops a pair below the line with every other test green, because no other test asks what colour
# anything is against anything else. This reads the THREE blocks design-system.md rule 4 names
# (Paper's `:root`, `:root[data-theme="dark"]`, and the system query's copy of it) and computes WCAG
# 2 contrast for each pair the sheets actually draw:
#
# - text: --fg, --fg-muted, --accent-text and the four status words, on the page (--bg), a surface,
#   --raised (the left column, the viewers' ground) and --accent-soft (a selected row, a search
#   match), at 4.5:1;
# - code: every --code-* on the editor's ground (--surface) and its gutter and tooltips (--raised);
# - a text on its own fill: --accent-ink on the accent (.fig-num, the wordmark's disc), the page on
#   ink (the ink primary, an ink chip, a pressed toggle), --thumb-ink on the thumbnail card, and a
#   status word on its own soft tint laid over --surface (the flash's "Problem");
# - marks, at 3:1 (WCAG 1.4.11, a non-text part): the accent and the focus ring and the strong line
#   on the three grounds, and the one mesh material on the viewer's --raised and multiplied onto
#   the card, as a thumbnail is (design-system.md rule 5).
#
# A soft tint is an rgba, and an rgba has no contrast until it is laid over something: it is
# composited over its theme's --surface, which is what it sits on. A `var()` resolves within the
# theme, so --focus (Paper's `var(--accent)`) is checked as the red each theme draws.
#
# Every failure is collected before the one assertion, so a red run names every pair that fell.
# EVERY PARSE ASSERTS IT MATCHED (§14e): a regex that finds no block compares nothing and passes.
#
# MUTATION-CHECKED (§15, each reverted): Graphite's --accent-text nudged to #f2463a reddens the text
# arm with only "Graphite: --accent-text on --accent-soft is 4.43:1"; Paper's --fg-muted at #7a8088
# with "Paper: --fg-muted on --raised is 3.62:1" (and the error pages' brand copy); Graphite's
# --line-strong at #4a4f57 reddens the marks arm, "Graphite: --line-strong on --raised is 2.03:1";
# Graphite's --thumb-stage at #8a8e93 reddens both, "--thumb-ink on --thumb-stage is 3.22:1" and
# "--model-material multiplied onto --thumb-stage is 2.94:1"; the system copy's --bg alone at #141512
# reddens the blocks arm, "--bg: "#111316" chosen, "#141512" under the system query"; and
# theme_controller.js's dark META, or 500.html's dark .brand, set back to its old value reddens the
# copies arm, naming the file.
class ThemeContrastTest < ActiveSupport::TestCase
  ROOT = Rails.root
  CSS = ROOT.join("app/assets/stylesheets/application.css")

  TEXT = %w[--fg --fg-muted --accent-text --ok --warn --danger --info].freeze
  GROUNDS = %w[--bg --surface --raised --accent-soft].freeze
  CODE = %w[--code-keyword --code-string --code-number --code-comment --code-function --code-type
            --code-property --code-meta --code-invalid].freeze
  CODE_GROUNDS = %w[--surface --raised].freeze
  # text => the fill it is drawn on.
  ON_FILL = { "--accent-ink" => "--accent", "--bg" => "--fg", "--thumb-ink" => "--thumb-stage" }.freeze
  SOFT = { "--ok" => "--ok-soft", "--warn" => "--warn-soft", "--danger" => "--danger-soft",
           "--info" => "--info-soft" }.freeze
  MARKS = %w[--accent --focus --line-strong].freeze
  MARK_GROUNDS = %w[--bg --surface --raised].freeze
  TEXT_MIN = 4.5
  MARK_MIN = 3.0

  test "every text token clears 4.5:1 on every ground it is drawn on, in both themes" do
    failures = themes.flat_map do |name, t|
      pairs = TEXT.product(GROUNDS) + CODE.product(CODE_GROUNDS) + ON_FILL.to_a
      low = pairs.filter_map { |fg, bg| below(name, t, fg, bg, TEXT_MIN) }
      low + SOFT.filter_map do |word, soft|
        tint = over(colour(t, soft), colour(t, "--surface"))
        ratio = contrast(colour(t, word), tint)
        "#{name}: #{word} on #{soft} (over --surface) is #{ratio.round(2)}:1" if ratio < TEXT_MIN
      end
    end
    assert_empty failures, "below #{TEXT_MIN}:1 —\n#{failures.join("\n")}"
  end

  test "the accent, the focus ring, the strong line and the mesh material clear 3:1 as marks" do
    failures = themes.flat_map do |name, t|
      low = MARKS.product(MARK_GROUNDS).filter_map { |fg, bg| below(name, t, fg, bg, MARK_MIN) }
      low << below(name, t, "--model-material", "--raised", MARK_MIN)
      card = colour(t, "--thumb-stage")
      ratio = contrast(multiply(colour(t, "--model-material"), card), card)
      low << "#{name}: --model-material multiplied onto --thumb-stage is #{ratio.round(2)}:1" if ratio < MARK_MIN
      low.compact
    end
    assert_empty failures, "below #{MARK_MIN}:1 —\n#{failures.join("\n")}"
  end

  # Rule 4: the OS's dark (System) and the chosen dark are one Graphite, so the two copies must be
  # the same declarations, value for value; and a name Graphite sets is declared on :root first, or
  # it never applies in Paper.
  test "the system query's Graphite is the chosen Graphite, and Paper declares every name first" do
    chosen, system = blocks.fetch(:graphite), blocks.fetch(:system)
    differ = (chosen.keys | system.keys).reject { chosen[_1] == system[_1] }
    assert_empty differ.map { "#{_1}: #{chosen[_1].inspect} chosen, #{system[_1].inspect} under the system query" },
                 "the @media (prefers-color-scheme: dark) copy of Graphite differs from :root[data-theme=\"dark\"]"
    missing = blocks.fetch(:graphite).keys - blocks.fetch(:paper).keys
    assert_empty missing, "Graphite sets #{missing.inspect}, which Paper's :root never declares"
  end

  # THE GROUND IS SPELLED OUTSIDE THE SHEET, where no token reaches: the browser chrome's colour
  # (ShellHelper#theme_color_hex, and theme_controller.js's META, which flips it without a load) and
  # the three static error pages, which Rails serves without the app's stylesheet. Each copy is held
  # to the token it copies, so a theme change cannot leave a stale page colour behind (slice 1 found
  # Paper's old ground spelled in eight files).
  test "the copies of each theme's ground outside the sheet are the tokens" do
    paper, graphite = themes.fetch("Paper"), themes.fetch("Graphite")

    helper = File.read(ROOT.join("app/helpers/shell_helper.rb"))
    dark, light = helper.match(/def theme_color_hex = ui_theme == "dark" \? "(#\h{6})" : "(#\h{6})"/)&.captures
    assert_not_nil dark, "ShellHelper#theme_color_hex no longer reads as one dark/light ternary"
    assert_equal [ hex(graphite, "--bg"), hex(paper, "--bg") ], [ dark, light ].map(&:downcase), "ShellHelper#theme_color_hex (dark, light)"

    js = File.read(ROOT.join("app/javascript/controllers/theme_controller.js"))
    meta = js.match(/const META = \{ light: \["light", "(#\h{6})"\], dark: \["dark", "(#\h{6})"\], system: \["light dark", "(#\h{6})"\] \}/)&.captures
    assert_not_nil meta, "theme_controller.js's META no longer reads as light/dark/system"
    assert_equal [ paper, graphite, paper ].map { hex(_1, "--bg") }, meta.map(&:downcase), "theme_controller.js's META (light, dark, system)"

    %w[404 422 500].each do |code|
      page = File.read(ROOT.join("public/#{code}.html"))
      light = page.match(/^\s*body \{[^}]*background: (#\h{6}); color: (#\h{6}); \}/)&.captures
      brand = page[/^\s*\.brand \{[^}]*color: (#\h{6});/, 1]
      dark = page.match(/@media \(prefers-color-scheme: dark\) \{ body \{ background: (#\h{6}); color: (#\h{6}); \} \.brand \{ color: (#\h{6}); \} \}/)&.captures
      assert_not_nil light, "public/#{code}.html: no body { background; color } rule"
      assert_not_nil brand, "public/#{code}.html: no .brand colour"
      assert_not_nil dark, "public/#{code}.html: no one-line prefers-color-scheme: dark block"
      assert_equal %w[--bg --fg --fg-muted].map { hex(paper, _1) }, [ *light, brand ].map(&:downcase), "public/#{code}.html in Paper (ground, ink, brand)"
      assert_equal %w[--bg --fg --fg-muted].map { hex(graphite, _1) }, dark.map(&:downcase), "public/#{code}.html in Graphite (ground, ink, brand)"
    end
  end

  private

  def below(name, t, fg, bg, min)
    ratio = contrast(colour(t, fg), colour(t, bg))
    "#{name}: #{fg} on #{bg} is #{ratio.round(2)}:1" if ratio < min
  end

  # Paper is its own block; Graphite is Paper with the dark block over it, exactly as the cascade
  # resolves a name Graphite does not set.
  def themes
    @themes ||= { "Paper" => blocks.fetch(:paper), "Graphite" => blocks.fetch(:paper).merge(blocks.fetch(:graphite)) }
  end

  def blocks
    @blocks ||= begin
      css = File.read(CSS).gsub(%r{/\*.*?\*/}m, "")
      found = {
        paper: css[/^\s*:root\s*\{(.*?)\}/m, 1],
        graphite: css[/:root\[data-theme="dark"\]\s*\{(.*?)\}/m, 1],
        system: css[/@media \(prefers-color-scheme: dark\)\s*\{\s*:root\[data-theme="system"\]\s*\{(.*?)\}/m, 1]
      }
      found.each { |k, v| assert_not_nil v, "application.css has no #{k} token block" }
      found.transform_values do |body|
        decls = body.scan(/(--[\w-]+)\s*:\s*((?:url\("[^"]*"\)|[^;])+);/).to_h { |k, v| [ k, v.strip ] }
        assert_operator decls.size, :>, 20, "a token block parsed to #{decls.size} declarations"
        decls
      end
    end
  end

  # [r, g, b, a] for a token, following var() within the theme.
  def colour(t, name, depth = 0)
    value = t[name]
    assert_not_nil value, "no #{name} in the theme"
    raise "#{name}: var() cycle" if depth > 5

    case value
    when /\Avar\((--[\w-]+)\)\z/ then colour(t, $1, depth + 1)
    when /\A#(\h{2})(\h{2})(\h{2})\z/ then [ $1, $2, $3 ].map { _1.to_i(16) } + [ 1.0 ]
    when /\Argba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)\z/ then [ $1.to_i, $2.to_i, $3.to_i, $4.to_f ]
    else flunk "#{name} is #{value.inspect}, which this test cannot read as a colour — extend it"
    end
  end

  def hex(t, name) = format("#%02x%02x%02x", *colour(t, name).first(3))

  def over((r, g, b, a), (br, bg, bb, _)) = [ [ r, br ], [ g, bg ], [ b, bb ] ].map { |c, base| c * a + base * (1 - a) } + [ 1.0 ]

  def multiply(top, base) = top.first(3).zip(base.first(3)).map { |a, b| a * b / 255.0 } + [ 1.0 ]

  def luminance((r, g, b, a))
    assert_equal 1.0, a, "a translucent colour has no luminance until it is composited"
    lin = ->(c) { (c /= 255.0) <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
    0.2126 * lin.(r) + 0.7152 * lin.(g) + 0.0722 * lin.(b)
  end

  def contrast(a, b)
    hi, lo = [ luminance(a), luminance(b) ].sort.reverse
    (hi + 0.05) / (lo + 0.05)
  end
end
