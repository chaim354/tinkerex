require "nokogiri"

module Maker
  # README rendering (stage 3, S3-2): kramdown (a dependency already, plus kramdown-parser-gfm for
  # `input: "GFM"` — fenced code, tables, strikethrough) with RAW HTML STRIPPED — a README is the
  # user's prose, never trusted markup — and relative links resolved by the CALLER's block, so a
  # `[base](models/base.stl)` becomes the file page when the path exists and plain text when it
  # does not. `render` returns an html_safe String that has been through Rails' sanitizer with an
  # allowlist of the elements kramdown emits for GFM prose.
  #
  # RAW HTML IS STRIPPED BY THE SANITIZER, NOT BY KRAMDOWN — there is no kramdown option that drops
  # it. Probed: `Kramdown::Document.new("<script>alert(1)</script>", input: "GFM").to_html` returns
  # the tag VERBATIM. The allowlist `sanitize` call below is what removes it, and it is worth being
  # precise about HOW: passing `tags:`/`attributes:` routes through Loofah's PermitScrubber, not its
  # safelist Scrubber — the one that treats `<script>`/`<style>` contents as CDATA to discard
  # outright — so a disallowed tag is UNWRAPPED (the element goes, its text stays as a bare text
  # node) rather than deleted whole (probed: `<script>alert(1)</script>` sanitizes to the bare text
  # "alert(1)", not to nothing). That is why `rewrite_relative_links` removes the EXECUTABLE
  # elements (script, style, iframe, object, embed, noscript, template) WITH their content first —
  # a README's script must not become prose — and leaves every other disallowed tag to the
  # sanitizer's unwrapping, so "raw HTML stripped" means the element a browser would run is gone,
  # never "every word that was ever inside a tag disappears too".
  #
  # `syntax_highlighter: nil` IS NOT COSMETIC. kramdown's fenced-code default is `:rouge`, and this
  # app ships neither rouge nor coderay (probed: absent from Gemfile.lock) — a fenced block would
  # try to load a highlighter gem that was never installed. A plain `<pre><code>` is what
  # ALLOWED_TAGS was written for anyway: `class="language-xxx"` is not in ALLOWED_ATTRS and would be
  # stripped even if a highlighter did emit it.
  class Markdown
    ALLOWED_TAGS = %w[p br h1 h2 h3 h4 h5 h6 ul ol li strong em code pre blockquote a img table thead tbody tr th td hr del].freeze
    ALLOWED_ATTRS = %w[href src alt title].freeze

    # resolve: ->(href) { url-or-nil }, asked only for a RELATIVE href — no scheme, no leading
    # slash (an absolute URL, a `mailto:`, or a root-relative "/x" never reaches the block, so it
    # never has to recognise those itself: an absolute `<a href>` is left exactly as kramdown wrote
    # it, an absolute `<img src>` becomes its alt text — see rewrite_relative_links). nil DROPS the
    # link: an `<a>`
    # unwraps to its own text (the words stay, the link doesn't), an `<img>` is removed outright —
    # there is no broken-image placeholder to fall back to, and a dangling `src` would just 404 in
    # the browser. No block at all (a caller with nothing to resolve against) behaves the same as a
    # block that always returns nil.
    def self.render(text, &resolve)
      html = Kramdown::Document.new(text.to_s, input: "GFM", hard_wrap: false, syntax_highlighter: nil).to_html
      # ALWAYS rewritten, never skipped when `resolve` is nil — a relative href with nothing to
      # resolve against is exactly the "unresolvable" case, not "leave it as a live link".
      rewritten = rewrite_relative_links(html) { |href| resolve&.call(href) }
      ActionController::Base.helpers.sanitize(rewritten, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRS)
    end

    class << self
      private

      # "Relative" is defined once, here, rather than left for each caller of #rewrite_relative_links
      # to reason about: no URI scheme (http:, mailto:, javascript: — the sanitizer's job, not this
      # method's) and no leading "/". Only what's left over is a path the block might resolve
      # against the repo's own subtree; what an ABSOLUTE href gets instead is the element's own
      # business (a link keeps it, an image loses it — see below). A protocol-relative
      # "//cdn.example/p.png" is absolute by the leading-slash arm, not by a scheme, which is why
      # this one predicate is the whole test and neither call site adds a second one.
      def absolute_href?(href) = href.to_s.match?(%r{\A(?:[a-zA-Z][a-zA-Z0-9+.\-]*:|/)})

      def rewrite_relative_links(html)
        fragment = Nokogiri::HTML.fragment(html)
        # EXECUTABLE ELEMENTS GO WITH THEIR CONTENT, here, before the sanitizer sees them: the
        # allowlist `sanitize` below UNWRAPS a disallowed tag (Loofah's PermitScrubber), so on its
        # own it turned `<script>alert(1)</script>` into the prose "alert(1)" in the middle of a
        # README (seen live, 2026-09-05). Safe, and still wrong to show.
        fragment.css("script, style, iframe, object, embed, noscript, template").each(&:remove)

        fragment.css("a[href]").each do |a|
          href = a["href"].to_s
          next if href.start_with?("#") || absolute_href?(href)

          if (target = yield(href))
            a["href"] = target
          else
            a.replace(a.text) # unwrap: drop the link, keep the words
          end
        end

        fragment.css("img[src]").each do |img|
          src = img["src"].to_s
          # AN ABSOLUTE IMAGE BECOMES ITS ALT TEXT; AN ABSOLUTE LINK IS LEFT ALONE, and the two are
          # deliberately different (stage 3, S3-4). A link is the user's prose — an outbound
          # reference the reader chooses to follow. An `<img>` is fetched by the BROWSER the moment
          # the page renders, so a hotlinked one on a public project page is a tracking pixel
          # pointed at every visitor, and `img-src 'self' data: blob:`
          # (config/initializers/content_security_policy.rb) blocks it anyway once the CSP enforces
          # — leaving the src in place would show a broken image where prose used to be.
          #
          # A TEXT NODE, NEVER `img.replace(alt)` WITH A STRING. Nokogiri PARSES a String
          # replacement as markup, and this loop runs AFTER the executable elements were removed
          # above, so `![<script>alert(1)</script>](https://x/y.png)` would re-inject a script that
          # nothing else in this method will look at again — the sanitizer then unwraps it into the
          # prose "alert(1)", the exact defect this class's header records. A Text node serializes
          # escaped and cannot re-enter the tree as an element.
          if absolute_href?(src)
            alt = img["alt"].to_s
            alt.empty? ? img.remove : img.replace(Nokogiri::XML::Text.new(alt, img.document))
            next
          end

          if (target = yield(src))
            img["src"] = target
          else
            img.remove # no text to fall back to
          end
        end

        fragment.to_html
      end
    end
  end
end
