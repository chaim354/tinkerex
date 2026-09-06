require "test_helper"

class Maker::MarkdownTest < ActiveSupport::TestCase
  test "headings, lists and fenced code render" do
    html = Maker::Markdown.render(<<~MD)
      # Title

      - one
      - two

      ```ruby
      puts 1
      ```
    MD

    assert_match %r{<h1>Title</h1>}, html
    assert_match %r{<li>one</li>}, html
    assert_match %r{<li>two</li>}, html
    assert_match %r{<pre><code>puts 1}, html
  end

  # RAW HTML IS NOT KRAMDOWN'S TO STRIP — it passes `<script>` through verbatim (probed at the
  # console). The renderer removes executable elements WITH their content before the allowlist
  # sanitizer runs, because that sanitizer UNWRAPS a disallowed tag (Loofah's PermitScrubber, not
  # its CDATA-aware safelist Scrubber) and would otherwise leave the script's text as prose.
  test "a script tag goes WITH its text, and an onclick attribute is stripped" do
    html = Maker::Markdown.render(%(before\n\n<script>alert(1)</script>\n\n<p onclick="evil()">after</p>\n))

    assert_no_match %r{<script}, html
    # THE TEXT TOO: the sanitizer alone unwraps the tag and leaves "alert(1)" as prose (seen live on
    # a README, 2026-09-05); the renderer removes executable elements with their content first.
    assert_no_match %r{alert\(1\)}, html
    assert_no_match %r{onclick}, html
    assert_match %r{before}, html
    assert_match %r{after}, html
  end

  test "a relative link resolves through the block" do
    html = Maker::Markdown.render("[base](models/base.stl)") { |href| href == "models/base.stl" ? "/files/n-1" : nil }

    assert_match %r{<a href="/files/n-1">base</a>}, html
  end

  test "an unresolvable relative link becomes text, not a link" do
    html = Maker::Markdown.render("[gone](missing.stl)") { |_href| nil }

    assert_no_match %r{<a[\s>]}, html
    assert_match %r{gone}, html
  end

  test "an absolute link survives, and the resolve block is never asked about it" do
    html = Maker::Markdown.render("[docs](https://example.com)") { |_href| raise "resolve must not be called for an absolute href" }

    assert_match %r{<a href="https://example\.com">docs</a>}, html
  end

  # `javascript:` HAS A SCHEME, so it is "absolute" by this class's own definition and never
  # reaches the resolve block at all — the sanitizer is what removes it, by dropping the whole
  # `href` attribute (probed: `sanitize` turns `<a href="javascript:...">bad</a>` into `<a>bad</a>`).
  test "a javascript: href is dropped by the sanitizer, and the resolve block is never asked about it" do
    html = Maker::Markdown.render("[bad](javascript:alert(1))") { |_href| raise "resolve must not be called for a javascript: href" }

    assert_no_match %r{javascript:}, html
    assert_no_match %r{<a\s}, html
    assert_match %r{bad}, html
  end

  test "a leading # anchor survives untouched" do
    html = Maker::Markdown.render("[section](#usage)") { |_href| raise "resolve must not be called for a # anchor" }

    assert_match %r{<a href="#usage">section</a>}, html
  end

  test "a relative image resolves the same way, and an unresolved one is dropped rather than left broken" do
    html = Maker::Markdown.render("![alt](img/x.png)\n\n![alt2](img/y.png)") do |href|
      href == "img/x.png" ? "/files/n-2" : nil
    end

    assert_match %r{<img src="/files/n-2" alt="alt">}, html
    assert_no_match %r{img/y\.png}, html
    assert_no_match %r{alt2}, html
  end

  # STAGE 3, S3-4: an absolute IMAGE is not an absolute LINK. A link is prose the reader chooses to
  # follow; an `<img>` is fetched by the browser on render, so a hotlinked one on a public project
  # page is a tracking pixel aimed at every visitor — and `img-src 'self' data: blob:` blocks it
  # anyway once the CSP enforces, leaving a broken image where words used to be.
  test "an absolute image becomes its alt text, and the resolve block is never asked about it" do
    html = Maker::Markdown.render("![pix](https://evil.example/p.gif)") do |href|
      raise "resolve must not be called for an absolute img src (#{href})"
    end

    assert_no_match %r{<img}, html
    assert_no_match %r{evil\.example}, html
    assert_match %r{pix}, html
  end

  test "a protocol-relative or data: image is absolute too, and one with no alt leaves nothing behind" do
    assert_match %r{logo}, Maker::Markdown.render("![logo](data:image/png;base64,AAAA)")

    html = Maker::Markdown.render("![](//cdn.example/p.png)")

    assert_no_match %r{<img}, html
    assert_no_match %r{cdn\.example}, html
  end

  # THE ALT TEXT GOES IN AS A TEXT NODE, NEVER AS A STRING Nokogiri would re-parse as markup. This
  # loop runs AFTER the executable elements were removed, so a String replacement re-injects a
  # `<script>` nothing will look at again, and the allowlist sanitizer then UNWRAPS it into the
  # prose "alert(1)" — the exact defect the renderer's header records. Probed both ways.
  test "an image's alt text is inserted as text, never re-parsed as markup" do
    html = Maker::Markdown.render(%(![<script>alert(1)</script>](https://x/y.png)))

    assert_no_match %r{<script}, html
    assert_match %r{&lt;script&gt;alert\(1\)&lt;/script&gt;}, html
  end

  # RAW HTML REACHES THE SAME TWO RULES. kramdown passes a well-formed `<img …>` through as an
  # element (probed: an UNQUOTED `src=x` is escaped to text instead, which is kramdown's business,
  # not this class's), so an absolute one loses its src the same way — taking `onerror` with it —
  # and a relative one that resolves keeps only the allowlisted attributes.
  test "a raw HTML image is subject to both rules, and onerror never survives either way" do
    absolute = Maker::Markdown.render(%(x\n\n<img src="https://evil.example/p.gif" onerror="alert(1)" alt="hi">\n))

    assert_no_match %r{onerror}, absolute
    assert_no_match %r{<img}, absolute
    assert_match %r{hi}, absolute

    relative = Maker::Markdown.render(%(x\n\n<img src="img/x.png" onerror="alert(1)" alt="hi">\n)) { |_h| "/files/n-9" }

    assert_no_match %r{onerror}, relative
    assert_match %r{<img src="/files/n-9" alt="hi">}, relative
  end

  test "rendering with no block at all leaves relative links unresolved as text" do
    html = Maker::Markdown.render("[gone](missing.stl)")

    assert_no_match %r{<a[\s>]}, html
    assert_match %r{gone}, html
  end
end
