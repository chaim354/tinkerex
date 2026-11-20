# HTML Thumbnail Drawing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every `.html` file's grid thumbnail is one fixed "code" drawing (ink browser window, three dots, orange `</>`) instead of its first lines of source.

**Architecture:** A new bytes-ignoring renderer `Maker::Previews::HtmlThumb` claims `html` in `Registry::FORMAT_RENDERERS` (merged over the derived text table) and rasterises a fixed SVG through the existing `SvgRasterizer` (resvg). `TextThumb` stops claiming `html`. `THUMBNAIL_REVISION = 3` makes every HTML row `TextThumb` stamped at 2 stale, so tiles redraw themselves through the existing backfill.

**Tech Stack:** Rails 8, Minitest, resvg (already shipped), `Maker::Previews::Palette`.

> **Amended in the build (commit "The HTML tile draws at its real stroke widths and needs no font"):**
> Task 2's code below is the first build. Rendering it showed a hairline window, so `render` passes
> `stylesheet: nil` (Gerber's opt-out) and the `</>` is two polylines and a line, not a `<text>`.
> `app/services/maker/previews/html_thumb.rb` and the spec are the current truth.

Spec: `docs/superpowers/specs/2026-11-20-html-thumbnail-design.md`. Run Ruby from the worktree root; a bare `bin/rails test` needs `LIBRARY_PATH` (memory: bare-rails-test-needs-library-path), so every test command below is prefixed with `LIBRARY_PATH=$(mktemp -d)`.

---

### Task 1: `Palette::ACCENT`

**Files:**
- Modify: `app/services/maker/previews/palette.rb`
- Test: `test/services/maker/previews/palette_test.rb`

- [ ] **Step 1: Write the failing tests.** In `palette_test.rb`, widen the hex check and add the CSS pin beside the `INK` one:

```ruby
      test "the palette is four lowercase six-digit hex colours" do
        { PAPER: Palette::PAPER, INK: Palette::INK, MATERIAL: Palette::MATERIAL,
          ACCENT: Palette::ACCENT }.each do |name, value|
          assert_match HEX, value, "Palette::#{name}"
          assert_equal value.downcase, value, "Palette::#{name} — the comparisons below are exact"
        end
        assert_equal "#ffffff", Palette::PAPER,
                     "the ground is multiplied onto the card, so it must be EXACTLY white"
      end
```

```ruby
      # PAPER'S, LIKE INK: the card is light in both themes (design-system.md rule 5), so the
      # drawing's orange is the light theme's accent wherever it is shown.
      test "ACCENT is Paper's --accent, the first :root block's" do
        block = css[/^\s*:root\s*\{(.*?)^\s*\}/m, 1]
        assert_not_nil block, "application.css has no :root { … } block"
        accent = block[/^\s*--accent:\s*([^;]+);/, 1]
        assert_not_nil accent, "the Paper :root block no longer defines --accent"
        assert_equal Palette::ACCENT, accent.strip.downcase,
                     "Paper's --accent is #{accent.strip}; Palette::ACCENT is #{Palette::ACCENT}"
      end
```

- [ ] **Step 2: Run, expect FAIL** (`NameError: uninitialized constant …::ACCENT`):
  `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/palette_test.rb`

- [ ] **Step 3: Implement.** In `palette.rb`, add after `MATERIAL`:

```ruby
      ACCENT = "#c2410c".freeze
```

  and in the header comment: add `HtmlThumb` to the "bump the `THUMBNAIL_REVISION` of every renderer that paints it" list, and a paragraph: "ACCENT IS PAPER'S `--accent`, drawn only by `HtmlThumb` (its `</>` and first title-bar dot); `palette_test.rb` holds the two equal."

- [ ] **Step 4: Run, expect PASS** (same command).

### Task 2: the `HtmlThumb` renderer

**Files:**
- Create: `app/services/maker/previews/html_thumb.rb`
- Create: `test/services/maker/previews/html_thumb_test.rb`
- Create: `test/fixtures/files/sample.html`
- Modify: `test/services/maker/previews/renderer_contract_test.rb` (FIXTURES)
- Modify: `test/services/maker/previews/palette_test.rb` (colour sweep)

- [ ] **Step 1: Write the failing tests.** `html_thumb_test.rb`:

```ruby
require "test_helper"

module Maker
  module Previews
    # AN HTML FILE'S TILE IS ONE FIXED DRAWING (spec 2026-11-20-html-thumbnail-design.md). The
    # renderer is handed the page's bytes like every other and must never read them: two different
    # pages are the same picture.
    class HtmlThumbTest < ActiveSupport::TestCase
      test "claims .html and nothing else, from the vocabulary" do
        assert_equal Maker::FileAttachment::HTML_EXTS, HtmlThumb::EXTENSIONS
        assert_equal %w[html], HtmlThumb::EXTENSIONS
      end

      test "every HTML file gets the same picture, whatever the page holds" do
        skip "resvg is not on this box" unless HtmlThumb.available?

        a = HtmlThumb.render("<!doctype html><title>Walnut PC Case</title><p>case</p>", size: 64)
        b = HtmlThumb.render("<p>a different page entirely</p>", size: 64)
        assert_equal "image/png", a[:content_type]
        assert_equal [ 64, 64 ], [ a[:width], a[:height] ]
        assert a[:bytes].start_with?("\x89PNG".b), "not a PNG"
        assert_equal a[:bytes], b[:bytes], "the drawing must not depend on the page"
      end

      test "the drawing is a window with a code mark, scaled from one 512 grid" do
        svg = HtmlThumb.to_svg(128)
        assert_includes svg, %(width="128" height="128" viewBox="0 0 512 512")
        assert_includes svg, "&lt;/&gt;"
      end
    end
  end
end
```

  `palette_test.rb`, beside the TextThumb sweep:

```ruby
      test "HtmlThumb paints the palette, its two dots, and no other colour" do
        svg = HtmlThumb.to_svg(512)
        expected = [ Palette::PAPER, Palette::INK, Palette::ACCENT, HtmlThumb::AMBER, HtmlThumb::SAGE ].sort

        painted = svg.scan(/\b(?:fill|stroke|stop-color|color)="([^"]*)"/).flatten.uniq
        assert_not_empty painted, "HtmlThumb's SVG paints nothing this scan can see"
        assert_equal expected, painted.sort
        assert_equal expected, svg.scan(/#\h{6}\b|#\h{3}\b/).uniq.sort
      end
```

  `test/fixtures/files/sample.html`:

```html
<!doctype html>
<meta charset="utf-8">
<title>Sample page</title>
<p>A page whose thumbnail is the code drawing.</p>
```

  `renderer_contract_test.rb` FIXTURES, after the TextThumb line:

```ruby
        Maker::Previews::HtmlThumb => "sample.html", # the fixed "code" drawing via resvg
```

- [ ] **Step 2: Run, expect FAIL** (`uninitialized constant Maker::Previews::HtmlThumb`):
  `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/html_thumb_test.rb test/services/maker/previews/palette_test.rb`

- [ ] **Step 3: Implement** `app/services/maker/previews/html_thumb.rb`:

```ruby
module Maker
  module Previews
    # AN HTML FILE'S GRID THUMBNAIL IS ONE FIXED DRAWING, NOT ITS SOURCE (2026-11-20; spec
    # docs/superpowers/specs/2026-11-20-html-thumbnail-design.md). The owner chose it: an ink
    # browser window, three dots in its title bar, an orange `</>`. The first sixteen lines of a
    # page — a doctype, a <meta>, a stylesheet — say nothing about what it draws, and a real
    # screenshot would mean running the page on the server.
    #
    # IT NEVER READS THE BYTES. `render` takes them because every renderer does (Registry's
    # contract); the picture is the same for every page, and `html_thumb_test.rb` renders two
    # different pages to prove it.
    #
    # Drawn on a 512 grid on a PURE-WHITE ground (Palette::PAPER — design-system.md rule 5: the
    # card's colour comes through by multiply) and rasterised by the same resvg step TextThumb uses,
    # so no new binary. `DejaVu Sans Mono` is the face the image already ships for TextThumb.
    module HtmlThumb
      module_function

      # DERIVED FROM THE ONE VOCABULARY (§14d), and claimed OVER TextThumb: Registry merges
      # FORMAT_RENDERERS on top, and TextThumb::EXTENSIONS subtracts this list.
      EXTENSIONS = Maker::FileAttachment::HTML_EXTS

      # Decoration of this one drawing, not palette colours: the second and third title-bar dots.
      AMBER = "#e0a526".freeze
      SAGE = "#6b8f5e".freeze

      # NEVER 1 OR 2 (§14h). Before this renderer, TextThumb drew every HTML tile and stamped it
      # with ITS revision (1, then 2). A stored row is current when its revision EQUALS the
      # renderer's (`Enqueue.revision_current?`), so either value here would serve the old
      # source-text picture forever. At 3 every one of those rows is stale and redraws.
      THUMBNAIL_REVISION = 3

      def payload_revision(_kind) = THUMBNAIL_REVISION

      def available? = Maker::Previews::SvgRasterizer.available?

      # size×size PNG of the drawing. Returns { bytes:, content_type:, width:, height: }.
      def render(_bytes, size: 512)
        png = Maker::Previews::SvgRasterizer.to_png(to_svg(size), size:)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
      end

      def to_svg(size)
        <<~SVG
          <svg xmlns="http://www.w3.org/2000/svg" width="#{size}" height="#{size}" viewBox="0 0 512 512">
          <rect width="512" height="512" fill="#{Palette::PAPER}"/>
          <rect x="76" y="112" width="360" height="292" rx="30" fill="#{Palette::PAPER}" stroke="#{Palette::INK}" stroke-width="16"/>
          <line x1="76" y1="176" x2="436" y2="176" stroke="#{Palette::INK}" stroke-width="12"/>
          <circle cx="120" cy="144" r="11" fill="#{Palette::ACCENT}"/>
          <circle cx="154" cy="144" r="11" fill="#{AMBER}"/>
          <circle cx="188" cy="144" r="11" fill="#{SAGE}"/>
          <text x="256" y="324" text-anchor="middle" font-family="DejaVu Sans Mono, monospace" font-weight="700" font-size="104" fill="#{Palette::ACCENT}">&lt;/&gt;</text>
          </svg>
        SVG
      end
    end
  end
end
```

- [ ] **Step 4: Run, expect PASS** (same command).

### Task 3: wire it into the registry

**Files:**
- Modify: `app/services/maker/previews/registry.rb` (FORMAT_RENDERERS)
- Modify: `app/services/maker/previews/text_thumb.rb` (EXTENSIONS)
- Modify: `test/services/maker/previews/registry_test.rb`
- Modify: `test/services/maker/previews/thumbnail_revision_test.rb`
- Modify: `test/services/maker/previews/thumbnail_map_test.rb`

- [ ] **Step 1: Write the failing tests.** `thumbnail_revision_test.rb`, in `THUMBNAIL_REVISIONS` after `"a.asm"`:

```ruby
        "a.html"  => 3, # HtmlThumb  — a fixed drawing; never 1 or 2, TextThumb's stamps on HTML rows
```

  `thumbnail_map_test.rb`, after "re-enqueues a thumbnail built by an older renderer":

```ruby
      # AN HTML TILE TEXTTHUMB DREW MUST REDRAW (spec 2026-11-20-html-thumbnail-design.md). Every
      # such row is stamped with TextThumb's revision; HtmlThumb's differs on purpose, so the row
      # is stale rather than current, and the page render re-enqueues it. Set HtmlThumb's revision
      # to TextThumb's and this goes red: the old source picture would be served forever.
      test "an HTML tile TextThumb drew is stale and redraws as HtmlThumb's drawing" do
        serve info("n-html", name: "viewer.html", token: "tok")
        row = @user.maker_previews.create!(node_id: "n-html", version_id: "tok", kind: "thumbnail",
                                           status: "ready",
                                           renderer_revision: Maker::Previews::TextThumb::THUMBNAIL_REVISION)
        row.asset.attach(io: StringIO.new("\x89PNG".b), filename: "t.png", content_type: "image/png")
        assert_enqueued_with(job: Maker::GeneratePreviewJob) { ThumbnailMap.for(@user, [ "n-html" ]) }
        assert_equal Maker::Previews::HtmlThumb::THUMBNAIL_REVISION, row.reload.renderer_revision
      end
```

  `registry_test.rb`: replace the body of "every text extension the vocabulary knows resolves to TextThumb" and the overlap tripwire, and add the HTML test:

```ruby
      test "every text extension the vocabulary knows resolves to TextThumb, but HTML's" do
        exts = Maker::FileAttachment::TEXT_EXTENSIONS - Maker::Previews::HtmlThumb::EXTENSIONS
        assert_operator exts.size, :>, 50, "the sweep needs a subject"
        exts.each do |ext|
          assert_equal Maker::Previews::TextThumb, Maker::Previews::Registry.for(ext), ext
        end
      end
```

```ruby
      test "the one text extension a format renderer claims is HTML's" do
        overlap = Maker::Previews::Registry::FORMAT_RENDERERS.keys &
                  Maker::FileAttachment::TEXT_EXTENSIONS
        assert_equal Maker::Previews::HtmlThumb::EXTENSIONS.sort, overlap.sort,
                     "FORMAT_RENDERERS wins the merge, so these text extensions no longer get " \
                     "TextThumb. Intended? Then say so here, and subtract them from TextThumb::EXTENSIONS."
      end

      # AN HTML FILE IS STILL TEXT ON ITS PAGE (the Source view) — only its TILE is the drawing.
      test "an HTML file's tile is HtmlThumb's drawing, and TextThumb no longer claims it" do
        assert_equal Maker::Previews::HtmlThumb, Maker::Previews::Registry.for_filename("viewer.html")
        assert_not_includes Maker::Previews::TextThumb::EXTENSIONS, "html"
        assert_includes Maker::FileAttachment::TEXT_EXTENSIONS, "html"
      end
```

  Keep the existing comments above both rewritten tests, amending the overlap one's last paragraph to say the overlap is now exactly HTML's, by intent (2026-11-20).

- [ ] **Step 2: Run, expect FAIL** (registry still hands `.html` to TextThumb):
  `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/registry_test.rb test/services/maker/previews/thumbnail_revision_test.rb test/services/maker/previews/thumbnail_map_test.rb test/services/maker/previews/renderer_contract_test.rb`

- [ ] **Step 3: Implement.** `registry.rb`, in `FORMAT_RENDERERS` after the `"pdf"`/`"ai"` entries:

```ruby
        # AN HTML PAGE'S TILE IS A DRAWING, NOT ITS SOURCE (2026-11-20). `html` is a text extension,
        # so this entry is merged OVER TextThumb's — the one overlap, pinned in registry_test.rb —
        # and TextThumb::EXTENSIONS subtracts it so the contract test agrees.
        "html"  => Maker::Previews::HtmlThumb,
```

  `text_thumb.rb`:

```ruby
      EXTENSIONS = (Maker::FileAttachment::TEXT_EXTENSIONS - Maker::Previews::HtmlThumb::EXTENSIONS).freeze
```

  and extend the "A TEXT EXTENSION WITH A RICHER RENDERER" paragraph: "`html` is the one today (HtmlThumb's drawing), subtracted here."

- [ ] **Step 4: Run, expect PASS** (same command).

- [ ] **Step 5: Commit** tasks 1–3:

```bash
git add app/services/maker/previews/{html_thumb,palette,registry,text_thumb}.rb test/services/maker/previews/{html_thumb,palette,registry,renderer_contract,thumbnail_map,thumbnail_revision}_test.rb test/fixtures/files/sample.html
git commit -F <message file>
```

### Task 4: the rule

**Files:**
- Modify: `docs/invariants/files-preview.md` (the "An HTML file RUNS" section)

- [ ] **Step 1:** Change "Eight rules:" to "Nine rules:" in the section's lead, and append:

```markdown
- **ITS TILE IS A DRAWING, NOT ITS SOURCE (2026-11-20; spec
  `docs/superpowers/specs/2026-11-20-html-thumbnail-design.md`).** `Maker::Previews::HtmlThumb` claims
  `html` over `TextThumb` and draws one picture — an ink browser window, three dots, an orange `</>` —
  whatever the page holds; it never reads the bytes. `TextThumb::EXTENSIONS` subtracts it, or the
  contract test goes red. **Its `THUMBNAIL_REVISION` is never 1 or 2**: `TextThumb` stamped HTML rows
  with those, and a row is current when its revision EQUALS the renderer's, so either value serves the
  old source picture forever (§14h). Pinned by `thumbnail_map_test.rb`, red on that mutation.
```

- [ ] **Step 2:** `LIBRARY_PATH=$(mktemp -d) bin/rails test test/docs_hygiene_test.rb` → PASS. Commit.

### Task 5: prove the guards, then the gate

- [ ] **Mutation 1:** `HtmlThumb::THUMBNAIL_REVISION = 2` → the thumbnail_map HTML test and `thumbnail_revision_test` go RED. Restore; clear `tmp/cache/bootsnap*`.
- [ ] **Mutation 2:** `TextThumb::EXTENSIONS = Maker::FileAttachment::TEXT_EXTENSIONS` → `renderer_contract_test` and the registry HTML test go RED. Restore.
- [ ] **Mutation 3:** `render` uses the bytes (`to_svg(size) + bytes.to_s[0, 1].to_s` inside a `<!-- -->`) → `html_thumb_test` "same picture" goes RED. Restore.
- [ ] **Look at it:** render `HtmlThumb.render("", size: 512)` to `tmp/html-thumb.png` and view it.
- [ ] **Gate:** bare `bin/ci` (needs `TINKEREX_SYNC_DIR` from a worktree), run last, judged by its own ✅/❌ lines; three legs equal RUN counts.
- [ ] **Close out:** `/finish-branch` — PR, `bin/log arc --from-pr <n>`.
