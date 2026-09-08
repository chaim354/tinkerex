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

    # `id="user-content-title"` since stage 4, S4-4 — kramdown always emitted `id="title"`,
    # ALLOWED_ATTRS used to strip it, and the namespace is what keeps a README's ids off the app's
    # own (the anchor tests at the bottom of this file carry the measured collision).
    assert_match %r{<h1 id="user-content-title">Title</h1>}, html
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

  # A `#fragment` href is an IN-DOCUMENT link, never a path — the resolve block is not asked. It is
  # rewritten into the README namespace (`#user-content-…`) so it still lands on the heading it
  # named, which now carries that prefix; the anchor tests at the bottom of this file pin the pair.
  test "a leading # anchor stays an in-document link, and the resolve block is never asked about it" do
    html = Maker::Markdown.render("[section](#usage)") { |_href| raise "resolve must not be called for a # anchor" }

    assert_match %r{<a href="#user-content-usage">section</a>}, html
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

  # THE UNWRAP IS A TEXT NODE, NEVER A STRING — the link-side twin of the image rule above. `a.text`
  # is DECODED, so a link whose visible text was the escaped literal `&lt;strong&gt;shout&lt;/strong&gt;`
  # comes back as `<strong>shout</strong>`; `a.replace(String)` parsed that as markup and an
  # allowlisted element the maker wrote to be DISPLAYED became live (`<h1>` split the paragraph),
  # while an escaped `<script>` became the prose "alert(1)". Found by S3-4's review probing the
  # entity-escaped form — the raw `<b>` form cannot show it, kramdown strips that before `.text`.
  test "an unresolved link's text is inserted as text, never re-parsed as markup" do
    html = Maker::Markdown.render("[&lt;strong&gt;shout&lt;/strong&gt;](nope/missing.md)") { |_h| nil }

    assert_no_match %r{<strong>}, html
    assert_match %r{&lt;strong&gt;shout&lt;/strong&gt;}, html

    script = Maker::Markdown.render("[&lt;script&gt;alert(1)&lt;/script&gt;](nope/x.md)") { |_h| nil }

    assert_no_match %r{<script}, script
    assert_match %r{&lt;script&gt;alert\(1\)&lt;/script&gt;}, script
  end

  # STAGE 4, S4-4 (story 5.4): a README's headings keep their anchor, so `#build-steps` in a link
  # — or in the URL a reader was handed — lands somewhere. kramdown has always emitted these ids;
  # ALLOWED_ATTRS is what dropped them, and the pass this test pins is what makes allowing them
  # safe rather than a hole for every `id` kramdown can be talked into emitting.
  #
  # THE `user-content-` PREFIX IS THE FIX FOR A MEASURED COLLISION (a5b6e66's review). A README's
  # ids land in the SAME document as the app's own: `## Project Tasks` rendered `id="project-tasks"`,
  # which is the Turbo Stream target `Projects::TasksController` replaces — resolved by
  # `getElementById`, first match in tree order, and the README card renders BEFORE the tasks
  # panel. GitHub's convention, so a maker who knows it is not surprised by it.
  test "a heading keeps its id, normalized to a-z 0-9 and hyphens, inside the user-content namespace" do
    html = Maker::Markdown.render(<<~MD)
      # Desk Lamp

      ## Build steps

      ### Bill of Materials (v2)
    MD

    assert_match %r{<h1 id="user-content-desk-lamp">Desk Lamp</h1>}, html
    assert_match %r{<h2 id="user-content-build-steps">Build steps</h2>}, html
    assert_match %r{<h3 id="user-content-bill-of-materials-v2">}, html
  end

  test "a heading id kramdown built out of non-ascii is squeezed to the allowed alphabet" do
    # PROBED, NOT ASSUMED: kramdown answers `id="unicode-ü--symbols"` here — a character outside
    # [a-z0-9-] AND a double hyphen, both straight from its own auto_id generator.
    html = Maker::Markdown.render("## Unicode ü & Symbols!\n")

    assert_match %r{<h2 id="user-content-unicode-symbols">}, html
    assert_no_match(/ü"/, html)
  end

  test "an id on anything that is not a heading is dropped" do
    # Two ways to get one: kramdown's block IAL, and raw HTML. Both reach the fragment.
    html = Maker::Markdown.render("Some text\n{: #para-ial}\n\n<p id=\"raw\">raw</p>\n")

    assert_includes html, "Some text"
    assert_no_match(/id="para-ial"/, html)
    assert_no_match(/id="raw"/, html)
  end

  test "a raw-HTML heading's hand-written id is normalized rather than trusted" do
    html = Maker::Markdown.render(%(<h2 id="Clobber Me!">Raw</h2>\n))

    assert_match %r{<h2 id="user-content-clobber-me">Raw</h2>}, html
  end

  test "a heading whose id normalizes to nothing loses the attribute rather than carrying an empty one" do
    html = Maker::Markdown.render(%(<h2 id="一二三">Three</h2>\n))

    assert_match %r{<h2>Three</h2>}, html
  end

  # THE TEST WHOSE NAME IS THE DEFECT. Measured before the fix: `## Project Tasks` rendered
  # `<h2 id="project-tasks">` — the id of the section in `app/views/projects/_tasks.html.erb` and
  # the Turbo Stream target `Projects::TasksController` replaces — so every task add/toggle/delete
  # swapped the README's heading and left the real panel stale. `## Entry 12` is the same shape on
  # the public page: `entry-12` is the build-log anchor Maker::PublicProject puts in feed URLs.
  test "a heading titled Project Tasks does not produce id=\"project-tasks\": README ids cannot collide with the app's own" do
    html = Maker::Markdown.render("## Project Tasks\n\n## Entry 12\n")

    assert_no_match(/id="project-tasks"/, html)
    assert_no_match(/id="entry-12"/, html)
    assert_match %r{<h2 id="user-content-project-tasks">Project Tasks</h2>}, html
    assert_match %r{<h2 id="user-content-entry-12">Entry 12</h2>}, html
  end

  # THE LINK AND THE HEADING GO THROUGH ONE SLUG FUNCTION. A heading and a link that normalize
  # differently is a link that never resolves, so `#Build-Steps` (as an author types it) must land
  # on the id `## Build Steps` was given — case, prefix and all.
  test "an in-document link is rewritten into the same namespace as the heading it names" do
    html = Maker::Markdown.render("## Build Steps\n\n[Build](#Build-Steps)\n") { |_href| raise "resolve must not be called for a # anchor" }

    assert_match %r{<h2 id="user-content-build-steps">Build Steps</h2>}, html
    assert_match %r{<a href="#user-content-build-steps">Build</a>}, html
  end

  test "a bare # href is left exactly as written" do
    html = Maker::Markdown.render("[top](#)\n")

    assert_match %r{<a href="#">top</a>}, html
  end

  # A README written for GitHub already carries the prefix — on a raw-HTML heading's id and in the
  # links that point at it. Both are recognised, and neither is prefixed twice.
  test "an id or link that already carries user-content- is not double-prefixed" do
    html = Maker::Markdown.render(%(<h2 id="user-content-already">Raw</h2>\n\n[x](#user-content-already)\n))

    assert_match %r{<h2 id="user-content-already">Raw</h2>}, html
    assert_match %r{<a href="#user-content-already">x</a>}, html
    assert_no_match(/user-content-user-content-/, html)
  end

  # A link whose fragment normalizes to nothing has nowhere to land; it unwraps to its words the way
  # an unresolvable relative link does (a Text node, never a String Nokogiri would re-parse).
  test "an in-document link whose fragment normalizes to nothing becomes text" do
    html = Maker::Markdown.render("[nowhere](#!!!)\n")

    assert_no_match %r{<a[\s>]}, html
    assert_match %r{nowhere}, html
  end

  # THE SQUEEZE MERGES IDS KRAMDOWN KEPT DISTINCT — `a---b`/`a-b` and `foo-ü`/`foo` (probed) each
  # collapse to one slug — so the pass de-duplicates AFTER normalizing, with kramdown's own `-1`,
  # `-2` convention. Two headings with one id are two anchor targets with one name, and a browser
  # only ever finds the first. Links cannot know which duplicate an author meant and keep pointing
  # at the first, as GitHub's do.
  test "two headings whose ids collapse to the same slug get distinct ids" do
    hyphens = Maker::Markdown.render("## A - B\n\n## A B\n")

    assert_match %r{<h2 id="user-content-a-b">A - B</h2>}, hyphens
    assert_match %r{<h2 id="user-content-a-b-1">A B</h2>}, hyphens

    unicode = Maker::Markdown.render("## Foo ü\n\n## Foo\n")

    assert_match %r{<h2 id="user-content-foo">Foo ü</h2>}, unicode
    assert_match %r{<h2 id="user-content-foo-1">Foo</h2>}, unicode
  end

  # THE NAMESPACE BELONGS TO README CONTENT ALONE. An app-side view or Stimulus controller that put
  # its own id inside `user-content-` would recreate the collision the prefix exists to end. Both
  # scanned sets are asserted NON-EMPTY first: a guard over an empty glob passes over nothing
  # (CLAUDE.md §14e), and either directory can move.
  test "no app view or JavaScript claims an id in the README anchor namespace" do
    assert_equal "user-content-", Maker::Markdown::ANCHOR_PREFIX # GitHub's convention, pinned by name

    views = Dir.glob("**/*.erb", base: Rails.root.join("app/views").to_s).sort.map { |rel| File.join("app/views", rel) }
    scripts = Dir.glob("**/*.js", base: Rails.root.join("app/javascript").to_s).sort.map { |rel| File.join("app/javascript", rel) }
    refute_empty views, "app/views/**/*.erb matched nothing — this scan is vacuous (CLAUDE.md §14e)"
    refute_empty scripts, "app/javascript/**/*.js matched nothing — this scan is vacuous (CLAUDE.md §14e)"

    needle = Maker::Markdown::ANCHOR_PREFIX.b # binread + a binary needle: a file's encoding is not this test's business
    offenders = (views + scripts).select { |rel| File.binread(Rails.root.join(rel)).include?(needle) }

    assert_empty offenders, "the `user-content-` namespace belongs to README anchors alone, and these app files use it: #{offenders.join(', ')}"
  end
end
