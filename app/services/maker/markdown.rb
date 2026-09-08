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
  # "alert(1)", not to nothing). That is why `rewrite_fragment` removes the EXECUTABLE
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
    # `id` IS ALLOWED FOR HEADINGS AND FOR NOTHING ELSE, AND THE ALLOWLIST CANNOT SAY SO — Rails'
    # `sanitize` takes one flat attribute list with no per-tag arm, so `id` here would also permit
    # one on `<a>`, `<img>`, `<p>` and every other allowed element. `#keep_heading_anchors` below
    # is the half that makes this narrow: it runs BEFORE the sanitizer, strips every `id` off
    # anything that is not h1–h6, and puts the ones it keeps under ANCHOR_PREFIX — because a
    # README's ids land in the SAME document as the app's own, and `## Project Tasks` once rendered
    # `id="project-tasks"`, the Turbo Stream target Projects::TasksController replaces. Adding the
    # attribute here without that pass is the hole; keeping the pass without the prefix is the
    # collision.
    ALLOWED_ATTRS = %w[href src alt title id].freeze

    # WHAT AN ANCHOR MAY CONTAIN. Not decoration: kramdown's own auto_id generator answers
    # `unicode-ü--symbols` for `## Unicode ü & Symbols!` (probed), a block IAL can hand any block
    # element any id at all, and RAW HTML passes an `id` through verbatim — so "kramdown already
    # sanitizes it" is false in all three directions. Anything outside this set collapses to a
    # single hyphen; an id that survives as empty loses the attribute rather than becoming `id=""`.
    ANCHOR_ALPHABET = /[^a-z0-9-]+/
    # WHERE A README'S ANCHORS LIVE. A README's headings render into the SAME document as the app's
    # own ids, and an id is found by `getElementById` — first match in tree order, and the README
    # card renders BEFORE the panels that follow it on the project page. Measured (a5b6e66's
    # review): `## Project Tasks` rendered `<h2 id="project-tasks">`, the id of the section in
    # app/views/projects/_tasks.html.erb and the Turbo Stream target Projects::TasksController
    # replaces, so every task add, toggle or delete swapped the README's heading and left the real
    # panel stale; `## Entry 12` was `entry-12`, the public page's build-log anchor
    # (Maker::PublicProject). GitHub's own prefix, so a maker who knows it is not surprised, and an
    # id or `#link` a GitHub README already wrote with it is recognised rather than prefixed twice
    # (#anchor_slug). markdown_test.rb's static guard keeps app/views and app/javascript OUT of it.
    ANCHOR_PREFIX = "user-content-".freeze
    HEADINGS = %w[h1 h2 h3 h4 h5 h6].freeze

    # resolve: ->(href) { url-or-nil }, asked only for a RELATIVE href — no scheme, no leading
    # slash, no leading "#" (an absolute URL, a `mailto:`, or a root-relative "/x" never reaches the
    # block, so it never has to recognise those itself: an absolute `<a href>` is left exactly as
    # kramdown wrote it, an absolute `<img src>` becomes its alt text, and a `#fragment` is
    # rewritten into the README's own anchor namespace — see rewrite_fragment). nil DROPS the
    # link: an `<a>`
    # unwraps to its own text (the words stay, the link doesn't), an `<img>` is removed outright —
    # there is no broken-image placeholder to fall back to, and a dangling `src` would just 404 in
    # the browser. No block at all (a caller with nothing to resolve against) behaves the same as a
    # block that always returns nil.
    def self.render(text, &resolve)
      html = Kramdown::Document.new(text.to_s, input: "GFM", hard_wrap: false, syntax_highlighter: nil).to_html
      # ALWAYS rewritten, never skipped when `resolve` is nil — a relative href with nothing to
      # resolve against is exactly the "unresolvable" case, not "leave it as a live link".
      rewritten = rewrite_fragment(html) { |href| resolve&.call(href) }
      ActionController::Base.helpers.sanitize(rewritten, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRS)
    end

    class << self
      private

      # "Relative" is defined once, here, rather than left for each caller of #rewrite_fragment
      # to reason about: no URI scheme (http:, mailto:, javascript: — the sanitizer's job, not this
      # method's) and no leading "/". Only what's left over is a path the block might resolve
      # against the repo's own subtree; what an ABSOLUTE href gets instead is the element's own
      # business (a link keeps it, an image loses it — see below). A protocol-relative
      # "//cdn.example/p.png" is absolute by the leading-slash arm, not by a scheme, which is why
      # this one predicate is the whole test and neither call site adds a second one.
      def absolute_href?(href) = href.to_s.match?(%r{\A(?:[a-zA-Z][a-zA-Z0-9+.\-]*:|/)})

      # HEADING ANCHORS, AND THE STRIPPING THAT MAKES THEM SAFE (stage 4, S4-4; story 5.4). ONE
      # pass over the fragment the caller already parsed — never a second Nokogiri parse, which is
      # what would let the two passes disagree about what the document is.
      #
      # AN `id` ON ANYTHING BUT A HEADING IS REMOVED, not normalized: kramdown's block IAL
      # (`{: #x}`) and raw HTML both put ids on ordinary elements, none of them is an anchor anyone
      # linked to, and an attacker-chosen `id` on an allowed element is DOM clobbering
      # (`<img id="attributes">` shadows a property on the form it sits in). The heading case is the
      # only one with a reason to exist, so it is the only one kept.
      #
      # THE ONES KEPT ARE NAMESPACED AND DE-DUPLICATED. The prefix is ANCHOR_PREFIX's story — the
      # `project-tasks` Turbo target a README heading could claim — and it goes on AFTER
      # normalizing, so a heading and the `#link` that names it (rewritten in #rewrite_fragment)
      # meet at one string built by one function, #anchor_slug. The de-dup exists because the
      # squeeze MERGES ids kramdown kept distinct: `## A - B` / `## A B` are `a---b` / `a-b` to
      # kramdown and one slug here, as are `## Foo ü` / `## Foo` (probed). A repeat takes `-1`,
      # `-2`, … — kramdown's own convention — in tree order, the order `getElementById` would have
      # picked a winner in. Links stay pointed at the first, as GitHub's do; they cannot know which
      # duplicate the author meant.
      #
      # A CAVEAT MEASURED BUT NOT PINNED: this pass runs over Nokogiri's HTML4 parse of the fragment
      # while `sanitize` re-parses it with Rails::HTML5 (gumbo); ~15 parser-differential shapes were
      # probed and none let an `id` past this pass, and nothing pins that equilibrium.
      def keep_heading_anchors(fragment)
        used = Set.new
        fragment.css("[id]").each do |el|
          next el.remove_attribute("id") unless HEADINGS.include?(el.name)

          slug = anchor_slug(el["id"])
          next el.remove_attribute("id") if slug.empty?

          unique = slug
          n = 0
          unique = "#{slug}-#{n += 1}" while used.include?(unique)
          used << unique
          el["id"] = ANCHOR_PREFIX + unique
        end
      end

      # THE ONE SLUG FUNCTION for a heading's id and a link's fragment — two copies that normalize
      # differently is a link that never resolves. Lowercase; strip the prefix a GitHub README
      # already carries (once, so it is never doubled); collapse everything outside ANCHOR_ALPHABET
      # to a single hyphen; trim the ends. Empty is a legitimate answer (`一二三`, `!!!`) and both
      # callers handle it: the heading loses the attribute, the link unwraps to its words.
      def anchor_slug(raw)
        raw.to_s.downcase.delete_prefix(ANCHOR_PREFIX)
           .gsub(ANCHOR_ALPHABET, "-").gsub(/-+/, "-")
           .delete_prefix("-").delete_suffix("-")
      end

      def rewrite_fragment(html)
        fragment = Nokogiri::HTML.fragment(html)
        # EXECUTABLE ELEMENTS GO WITH THEIR CONTENT, here, before the sanitizer sees them: the
        # allowlist `sanitize` below UNWRAPS a disallowed tag (Loofah's PermitScrubber), so on its
        # own it turned `<script>alert(1)</script>` into the prose "alert(1)" in the middle of a
        # README (seen live, 2026-09-05). Safe, and still wrong to show.
        fragment.css("script, style, iframe, object, embed, noscript, template").each(&:remove)
        keep_heading_anchors(fragment)

        fragment.css("a[href]").each do |a|
          href = a["href"].to_s
          # AN IN-DOCUMENT LINK IS REWRITTEN INTO THE README NAMESPACE, never resolved: `#Build-Steps`
          # must land on the id `## Build Steps` was given above, so its fragment goes through the
          # SAME #anchor_slug and takes the same prefix. A bare `#` is left exactly as written — it
          # names the top of the page, not a heading — and a fragment that normalizes to nothing has
          # nowhere to land, so it unwraps the way an unresolvable link does.
          if href.start_with?("#")
            next if href == "#"

            slug = anchor_slug(href.delete_prefix("#"))
            if slug.empty?
              unwrap_link(a)
            else
              a["href"] = "##{ANCHOR_PREFIX}#{slug}"
            end
            next
          end
          next if absolute_href?(href)

          if (target = yield(href))
            a["href"] = target
          else
            unwrap_link(a)
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

      # UNWRAP AS A TEXT NODE, NEVER `a.replace(a.text)` WITH A STRING — the same rule the image
      # loop in #rewrite_fragment states at length. `a.text` is DECODED text, so a link whose
      # visible text was the escaped literal `&lt;strong&gt;shout&lt;/strong&gt;` comes back as
      # `<strong>shout</strong>`, and a String replacement is PARSED as markup: an allowlisted
      # element the maker wrote to be displayed became live markup, and an escaped `<script>`
      # became the prose "alert(1)". Probed 2026-09-06 (S3-4's review); a Text node serializes
      # escaped and cannot re-enter the tree as an element. ONE method for both callers — the
      # unresolvable relative link and the empty in-document fragment — so neither can drift back
      # to the String form on its own.
      def unwrap_link(a) = a.replace(Nokogiri::XML::Text.new(a.text, a.document)) # drop the link, keep the words
    end
  end
end
