# Flat-file dimensions and the Material estimate tool — Implementation Plan

> **For agentic workers:** execute this with **`.claude/commands/execute-plan.md`** — this repo's
> default (CLAUDE.md §15), which overrides a generic subagent-driven loop: one implementer per task
> below (each task is already one file or one coherent unit), independent tasks in parallel, no
> spec-compliance stage, one capped quality review per task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Show SVG, LightBurn, DXF and MillMage files' drawn size in mm and inches in the file facts
(file page and Library inspector), and add a built-in `/tools/material` page that measures
uploaded, project or library files and reports each part's size, the total area and the sheets of
stock they need.

**Architecture:** One new measurer/reader, `Maker::Previews::Dimensions`, sits on the traversals
the Measure view already uses; SVG and DXF thumbnails start storing its Hash as row metadata (a
per-kind thumbnail revision bump). The tool is server-rendered: a stateless form whose parts ride
as hidden fields, a pure-Ruby MaxRects packer, and turbo-stream replaces of two regions.

**Tech Stack:** Rails 8, Hotwire (Turbo streams + one Stimulus controller), Minitest, Capybara
system tests. Spec: `docs/superpowers/specs/2026-11-22-material-estimate-design.md`.

**Worktree:** `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/material-estimate`,
branch `claude/material-estimate`. Run every command from there.

**Running one test file** (the share leg; LIBRARY_PATH is required, memory note "bare rails test
needs LIBRARY_PATH"):

```bash
LANG=en_US.UTF-8 LIBRARY_PATH=$(mktemp -d) bin/rails test test/path/to/file_test.rb
```

**Commits:** zsh runs backticks inside `-m "…"`, so write each message to a file in the scratchpad
and `git commit -F <file>`. End every message with
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

---

## Execution waves (for execute-plan.md)

| Wave | Tasks (parallel within a wave) | Why this order |
|---|---|---|
| A | 1 Dimensions · 4 SheetPack · 7 Built-in plumbing | No dependencies; disjoint files |
| B | 2 Thumbnails · 3 Facts row · 5 Estimate | 2 and 3 need Task 1; 5 needs Task 4 |
| C | 6 Sources | Needs 1 and 5 |
| D | 8 Page, controller, views, Stimulus | Needs 5, 6, 7 |
| E | 9 System test | Needs 8 |
| — | 10 Close-out | Last |

File ownership is disjoint inside every wave. Task 3 owns `pages/files.css`, Task 8 owns
`pages/tools.css`; Task 7 owns `tools/home/index.html.erb` and `config/routes.rb`.

---

### Task 1: `Maker::Previews::Dimensions` — the one measurer and reader

**Files:**
- Create: `app/services/maker/previews/dimensions.rb`
- Test: `test/services/maker/previews/dimensions_test.rb`

Known numbers (measured with the existing parsers on 2026-11-22): `plate.svg` draws 80 × 40 mm on a
100 × 60 mm canvas; `plate.dxf` 80 × 40; `nested-plate.lbrn2` 60 × 40; `pages.lbrn2` pages
"Page 1" 205 × 50, "Back" 50 × 50 (current), "Page 3" empty; `pages.mage` "Top" 100 × 60 (current),
"Bottom" 20 × 20; `real-export.mage` 100 × 60.

**`Dxf.drawing` does not exist until Task 2.** This task's `.dxf` arm calls it, so its DXF test is
written here but only goes green after Task 2 lands. Mark it with `skip "needs Task 2's Dxf.drawing"
unless Maker::Previews::Dxf.respond_to?(:drawing)` and Task 2 removes the skip.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Maker
  module Previews
    # THE ONE MEASURER AND READER OF A FLAT FILE'S SIZE (spec 2026-11-22-material-estimate-design.md).
    # Every expected number is a literal measured off the fixture, so a change in what any traversal
    # reports shows up here as a number, not as "still returns a Hash".
    class DimensionsTest < ActiveSupport::TestCase
      def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))

      test "an SVG measures as its DRAWING, never its canvas" do
        # plate.svg's canvas is 100 x 60 mm; what it draws is 80 x 40. The canvas must not win.
        assert_equal({ "job" => { "width" => 80.0, "height" => 40.0 } },
                     Dimensions.measure("plate.svg", fixture("plate.svg")))
      end

      test "a DXF measures in millimetres through its own walk" do
        skip "needs Task 2's Dxf.drawing" unless Maker::Previews::Dxf.respond_to?(:drawing)

        assert_equal({ "job" => { "width" => 80.0, "height" => 40.0 } },
                     Dimensions.measure("plate.dxf", fixture("plate.dxf")))
      end

      test "LightBurn and MillMage keep the size keys their metadata already stores" do
        assert_equal({ "job" => { "width" => 60.0, "height" => 40.0 } },
                     Dimensions.measure("nested-plate.lbrn2", fixture("nested-plate.lbrn2")))
        assert_equal({ "job" => { "width" => 100.0, "height" => 60.0 } },
                     Dimensions.measure("real-export.mage", fixture("real-export.mage")))
      end

      test "a multi-page file reads back one page per page, the saved one current, an empty one unsized" do
        facts = Dimensions.from_metadata(Dimensions.measure("pages.lbrn2", fixture("pages.lbrn2")))

        assert facts.multi_page?
        assert_equal [ "Page 1", "Back", "Page 3" ], facts.pages.map(&:name)
        assert_equal [ [ 205.0, 50.0 ], [ 50.0, 50.0 ], [ nil, nil ] ], facts.pages.map { |p| [ p.width, p.height ] }
        assert_equal [ false, true, false ], facts.pages.map(&:current)
        assert_equal [ "Page 1", "Back" ], facts.sized_pages.map(&:name)
      end

      test "a one-page file is one unnamed page" do
        facts = Dimensions.from_metadata({ "job" => { "width" => 12.5, "height" => 3.0 } })

        refute facts.multi_page?
        assert_equal [ [ nil, 12.5, 3.0, true ] ], facts.pages.map { |p| [ p.name, p.width, p.height, p.current ] }
      end

      test "the extension decides, case-insensitively" do
        assert Dimensions.measurable_name?("PLATE.SVG")
        assert Dimensions.measurable_name?("old.lbrn")
        refute Dimensions.measurable_name?("bracket.stl")
        refute Dimensions.measurable_name?("README")
        assert_equal 80.0, Dimensions.measure("PLATE.SVG", fixture("plate.svg"))["job"]["width"]
      end

      test "a file it cannot measure says why, in words a person reads" do
        cases = {
          [ "bracket.stl", "solid x" ]          => Dimensions::UNSUPPORTED,
          [ "broken.svg", "not xml at all" ]    => "not a readable SVG",
          [ "broken.lbrn2", "garbage" ]         => "not a readable LightBurn file",
          [ "broken.mage", "garbage" ]          => "not a readable MillMage file",
          [ "empty.svg", %(<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="10mm"/>) ] => Dimensions::NO_SHAPES
        }
        cases.each do |(name, bytes), reason|
          error = assert_raises(Dimensions::Unmeasurable, name) { Dimensions.measure(name, bytes) }
          assert_equal reason, error.message, name
        end
      end

      test "metadata_for never raises, because a size must never cost a file its thumbnail" do
        assert_nil Dimensions.metadata_for("not xml at all", ext: "svg")
        assert_nil Dimensions.metadata_for("garbage", ext: "lbrn2")
        assert_equal({ "job" => { "width" => 80.0, "height" => 40.0 } },
                     Dimensions.metadata_for(fixture("plate.svg"), ext: "svg"))
      end

      test "from_metadata reads only two finite, non-negative numbers, at least one above zero" do
        assert_nil Dimensions.from_metadata(nil)
        assert_nil Dimensions.from_metadata("job")
        assert_nil Dimensions.from_metadata({})
        assert_nil Dimensions.from_metadata({ "job" => { "width" => 0, "height" => 0 } })
        assert_nil Dimensions.from_metadata({ "job" => { "width" => "abc", "height" => 4 } })
        assert_nil Dimensions.from_metadata({ "job" => { "width" => -3, "height" => 4 } })
        assert_nil Dimensions.from_metadata({ "job" => { "width" => Float::INFINITY, "height" => 4 } })
        # A straight line measures: 50 x 0 is a real extent, and the packer inflates it by the gap.
        assert_equal [ 50.0, 0.0 ], Dimensions.from_metadata({ "job" => { "width" => 50, "height" => 0 } })
                                              .pages.first.then { |p| [ p.width, p.height ] }
      end

      test "job_metadata wraps a size the caller already holds, or answers nil for an empty drawing" do
        assert_equal({ "job" => { "width" => 1.0, "height" => 2.0 } },
                     Dimensions.job_metadata({ "width" => 1.0, "height" => 2.0 }))
        assert_nil Dimensions.job_metadata(nil)
        assert_nil Dimensions.job_metadata({ "width" => 0.0, "height" => 0.0 })
      end

      # THE RECIPE DISCRIMINATOR (spec Part 1): metadata holding only a size is not a recipe, so an
      # SVG's row draws no Laser settings panel. LightBurn's metadata can omit `layers` (.compact),
      # so this keys on "anything besides the size keys", never on `layers`.
      test "recipe? is true only for metadata with something besides a size" do
        refute Dimensions.recipe?(nil)
        refute Dimensions.recipe?({ "job" => { "width" => 1, "height" => 1 } })
        refute Dimensions.recipe?({ "job" => { "width" => 1, "height" => 1 }, "pages" => [] })
        assert Dimensions.recipe?(Maker::Previews::LbrnMetadata.parse(fixture("nested-plate.lbrn2")))
        assert Dimensions.recipe?({ "app_version" => "1.7.00", "job" => { "width" => 1, "height" => 1 } })
      end
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run: `LANG=en_US.UTF-8 LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/dimensions_test.rb`
Expected: errors, `NameError: uninitialized constant Maker::Previews::Dimensions`.

- [ ] **Step 3: Write the module**

```ruby
module Maker
  module Previews
    # A FLAT FILE'S SIZE, IN MILLIMETRES — THE ONE MEASURER AND THE ONE READER (2026-11-22; spec
    # docs/superpowers/specs/2026-11-22-material-estimate-design.md).
    #
    # Four formats measure: SVG, LightBurn, DXF and MillMage. Each already has a traversal that
    # draws and measures it (§14h), and THIS MODULE ADDS NO FIFTH READING of any of them: an SVG's
    # size is its Measure payload's job box (`SvgGeometry.build`), a DXF's is the box its thumbnail's
    # own walk draws (`Dxf.drawing`), and LightBurn's and MillMage's are what their metadata modules
    # already store (`Lbrn2.page_metadata`). So the facts list, the Measure view and the Material
    # estimate tool cannot disagree about one file. A second parser here would be §14b's
    # `LbrnMetadata` second-copy bug.
    #
    # THE HASH IS THE STORED SHAPE. `measure` returns exactly what a thumbnail row's `metadata` holds
    # for a size — `"job" => {"width", "height"}` in mm and, for a multi-page file, `"pages"` — so the
    # tool reads an upload it just measured and a library file's stored row through ONE
    # `from_metadata`.
    #
    # IT IS THE EXTENT OF WHAT IS DRAWN, never an SVG's width/height canvas: a design exported on an
    # A4 page measures as the design, which is what LightBurn's own job size has always meant.
    module Dimensions
      module_function

      EXTENSIONS = %w[svg dxf lbrn lbrn2 mage].freeze

      # The keys a size occupies in a thumbnail's metadata. Metadata holding nothing else is a size
      # and not a recipe, so it draws no Laser or CNC settings panel — see `recipe?`.
      SIZE_KEYS = %w[job pages].freeze

      MM_PER_INCH = 25.4

      UNSUPPORTED = "not an SVG, LightBurn, DXF or MillMage file".freeze
      NO_SHAPES = "no measurable shapes".freeze

      # Raised by `measure` with a reason a person can read; the tool shows it beside the file.
      Unmeasurable = Class.new(StandardError)

      # One page of a file, mm. `name` is nil for a one-page file; `width`/`height` are nil for an
      # empty page of a multi-page one.
      Page = Data.define(:name, :width, :height, :current) do
        def sized? = !width.nil?
      end

      Facts = Data.define(:pages) do
        def multi_page? = pages.length > 1
        def sized_pages = pages.select(&:sized?)
      end

      def extension(name) = File.extname(name.to_s).delete_prefix(".").downcase

      def measurable_name?(name) = EXTENSIONS.include?(extension(name))

      # bytes -> the stored Hash. Raises Unmeasurable; anything else a parser raises propagates,
      # which the tool's caller (Maker::Material::Sources) turns into a reason of its own.
      def measure(name, bytes) = measure_ext(extension(name), bytes)

      # FOR A THUMBNAIL RENDER: the same Hash, or nil, and NEVER a raise. A size is a fact beside the
      # picture, so a drawing this module cannot measure must not cost the file its thumbnail.
      def metadata_for(bytes, ext:)
        measure_ext(ext, bytes)
      rescue StandardError => e
        Rails.logger.warn("dimensions: .#{ext}: #{e.class}: #{e.message}") unless e.is_a?(Unmeasurable)
        nil
      end

      # A size the caller already holds (`{"width", "height"}`, mm), in the stored shape — or nil for
      # an empty drawing. The DXF thumbnail's walk measures as it draws and hands its box here.
      def job_metadata(size)
        hash = { "job" => size }
        from_metadata(hash) ? hash : nil
      end

      # A stored (or just-measured) Hash -> Facts, or nil when it holds no usable size.
      def from_metadata(metadata)
        return nil unless metadata.is_a?(Hash)

        pages = listed_pages(metadata["pages"]) || [ page(nil, metadata["job"], true) ]
        pages.any?(&:sized?) ? Facts.new(pages:) : nil
      end

      def recipe?(metadata) = metadata.is_a?(Hash) && (metadata.keys.map(&:to_s) - SIZE_KEYS).any?

      def measure_ext(ext, bytes)
        hash = read_sizes(ext, bytes)
        raise Unmeasurable, NO_SHAPES if from_metadata(hash).nil?

        hash
      end

      def read_sizes(ext, bytes)
        case ext
        when "svg" then svg(bytes)
        when "dxf" then job_metadata(Maker::Previews::Dxf.drawing(bytes).last)
        when "lbrn", "lbrn2" then recipe_sizes(Maker::Previews::LbrnMetadata.parse(bytes), "LightBurn")
        when "mage" then recipe_sizes(Maker::Previews::MageMetadata.parse(bytes), "MillMage")
        else raise Unmeasurable, UNSUPPORTED
        end
      end

      # A multi-page file's pages, or nil for a one-page file (whose metadata carries no "pages").
      def listed_pages(listed)
        return nil unless listed.is_a?(Array) && listed.any?

        listed.filter_map { |pg| page(pg["name"], pg["job"], pg["current"] == true) if pg.is_a?(Hash) }
      end

      # The Measure payload's own job box, so the facts row and the Measure view read one number.
      def svg(bytes)
        job = Maker::Previews::SvgGeometry.build(bytes)["job"]
        { "job" => { "width" => job["w"], "height" => job["h"] } }
      rescue Maker::Previews::SvgGeometry::ParseError
        raise Unmeasurable, "not a readable SVG"
      end

      # LbrnMetadata/MageMetadata answer nil for a file that is not theirs (they rescue internally).
      def recipe_sizes(metadata, app)
        raise Unmeasurable, "not a readable #{app} file" if metadata.nil?

        metadata.slice(*SIZE_KEYS)
      end

      def page(name, job, current)
        width, height = size(job)
        Page.new(name: name.to_s.presence, width:, height:, current:)
      end

      # [width, height] in mm, or [nil, nil] for anything that is not two finite, non-negative
      # numbers with at least one above zero. A 0 x 0 box is an empty drawing, never a part.
      def size(job)
        return [ nil, nil ] unless job.is_a?(Hash)

        w = mm(job["width"])
        h = mm(job["height"])
        w && h && (w.positive? || h.positive?) ? [ w, h ] : [ nil, nil ]
      end

      def mm(value)
        f = Float(value, exception: false)
        f if f&.finite? && !f.negative?
      end
    end
  end
end
```

- [ ] **Step 4: Run it to see it pass**

Run: `LANG=en_US.UTF-8 LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/dimensions_test.rb`
Expected: all green, one skip ("needs Task 2's Dxf.drawing").

- [ ] **Step 5: Mutation-check (report each output)**

1. In `size`, drop `(w.positive? || h.positive?)` → "from_metadata reads only…" goes RED on the
   0 × 0 case. Restore.
2. In `svg`, read `SvgGeometry`'s canvas instead — replace the body's job with
   `{ "w" => 100.0, "h" => 60.0 }` → "an SVG measures as its DRAWING" goes RED. Restore.
3. In `recipe?`, return `metadata.is_a?(Hash) && metadata.key?("layers")` → RED on the
   `app_version`-only case. Restore.

Restore with `git checkout -- app/services/maker/previews/dimensions.rb` only if you committed
first; otherwise undo the edit by hand and `git diff` to confirm. Clear bootsnap after a restore of
equal length: `rm -rf tmp/cache/bootsnap*` (memory: bootsnap masks equal-length restores).

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/previews/dimensions.rb test/services/maker/previews/dimensions_test.rb
git commit -F <scratchpad>/msg.txt   # "A flat file's size is measured and read back by one module"
```

---

### Task 2: SVG and DXF thumbnails store the drawing's size

**Files:**
- Modify: `app/services/maker/previews/svg.rb`
- Modify: `app/services/maker/previews/dxf.rb` (`render`, `to_svg`, the `BBox` class)
- Modify: `app/services/maker/previews/lbrn2.rb:205-209` (`outline_thumbnail`)
- Modify: `app/services/maker/previews/mage.rb:82-86` (`outline_thumbnail`)
- Modify: `test/services/maker/previews/svg_test.rb`, `test/services/maker/previews/dxf_geometry_test.rb`,
  `test/services/maker/previews/geometry_test.rb`, `test/services/maker/previews/dimensions_test.rb` (drop the skip)
- Modify: `docs/invariants/measure-view.md` (new bullets)

The rule this task implements (§14h): a change in what a thumbnail row stores is a per-kind
`THUMBNAIL_REVISION` bump, and the geometry revisions do not move. And the delegate rule: `Svg.render`
is also what Dxf, Lbrn2 and Mage called to rasterize an SVG *they generated*; that path must carry
no metadata, so it becomes `Svg.rasterize`.

- [ ] **Step 1: Write the failing tests**

Append to `test/services/maker/previews/svg_test.rb`, inside the class:

```ruby
      def plate = File.binread(Rails.root.join("test/fixtures/files/plate.svg"))

      # THE ABSOLUTE PIN, as GEOMETRY_REVISIONS pins the payloads: 2 is "the row stores the drawing's
      # size". A forgotten bump leaves every stored SVG thumbnail without one, forever (§14h).
      test "the thumbnail is at revision 2, the build that stores the drawing's size" do
        assert_equal 2, Maker::Previews::Svg::THUMBNAIL_REVISION
      end

      test "the thumbnail carries the drawing's size, not the canvas's" do
        skip "resvg not installed on this box" unless Maker::Previews::Svg.available?

        result = Maker::Previews::Svg.render(plate, size: 64)
        assert_equal "image/png", result[:content_type]
        assert_equal({ "job" => { "width" => 80.0, "height" => 40.0 } }, result[:metadata])
      end

      # THE DELEGATE RULE'S GUARD. Dxf, Lbrn2 and Mage rasterize an SVG they GENERATED; a size
      # measured off that document describes the wrong thing (a DXF's units are resolved before it,
      # a LightBurn bed frame is in it). Their own `render` merges their metadata over it today, which
      # is exactly why only this assertion can see the rule break.
      test "the bare rasterize carries no size, because a delegate's SVG is not the file" do
        skip "resvg not installed on this box" unless Maker::Previews::Svg.available?

        refute Maker::Previews::Svg.rasterize(plate, size: 64).key?(:metadata)
      end

      test "a drawing with nothing to measure still gets its thumbnail" do
        skip "resvg not installed on this box" unless Maker::Previews::Svg.available?

        empty = %(<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="10mm" viewBox="0 0 10 10"></svg>)
        result = Maker::Previews::Svg.render(empty, size: 32)
        assert_equal "image/png", result[:content_type]
        assert_nil result[:metadata]
      end
```

Append to `test/services/maker/previews/dxf_geometry_test.rb`, directly after the test
"the file is lexed exactly once per render, on both legs" (it reuses that class's `counting` and
`fixture` helpers):

```ruby
      test "the thumbnail is at revision 4, the build that stores the drawing's size" do
        assert_equal 4, Dxf::THUMBNAIL_REVISION
      end

      # THE FACTS ROW AND THE MEASURE VIEW READ ONE NUMBER. The thumbnail measures in its own walk
      # (one lex, below) rather than calling DxfGeometry, so the two boxes are pinned equal here.
      test "the drawing's stored size is the Measure payload's job box" do
        %w[plate.dxf sample.dxf].each do |name|
          bytes = fixture(name)
          job = DxfGeometry.build(bytes)["job"]
          assert_operator job["w"], :>, 0, "#{name}: precondition — the fixture draws something"

          _svg, drawn = Dxf.drawing(bytes)
          assert_equal [ job["w"], job["h"] ], [ drawn["width"], drawn["height"] ],
                       "#{name}: the thumbnail's size and the Measure view's disagree"
        end
      end

      test "the thumbnail carries that size and its render still lexes the file once" do
        skip "resvg not installed on this box" unless Svg.available?

        result = nil
        lexes = counting(:tokenize) { result = Dxf.render(fixture("plate.dxf"), size: 64) }
        assert_equal 1, lexes, "measuring must ride the drawing's lex, not add one"
        assert_equal({ "job" => { "width" => 80.0, "height" => 40.0 } }, result[:metadata])
      end
```

In `test/services/maker/previews/geometry_test.rb`, inside the test
"Enqueue reads each renderer's per-kind revision rather than the base default", after the existing
`Lbrn2::THUMBNAIL_REVISION` assertion, add:

```ruby
        assert_equal Maker::Previews::Svg::THUMBNAIL_REVISION, Enqueue.revision_for_name("a.svg", "thumbnail")
        assert_equal Maker::Previews::Dxf::THUMBNAIL_REVISION, Enqueue.revision_for_name("a.dxf", "thumbnail")
```

In `test/services/maker/previews/dimensions_test.rb`, delete the line
`skip "needs Task 2's Dxf.drawing" unless Maker::Previews::Dxf.respond_to?(:drawing)`.

- [ ] **Step 2: Run them to see them fail**

Run: `LANG=en_US.UTF-8 LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/svg_test.rb test/services/maker/previews/dxf_geometry_test.rb test/services/maker/previews/dimensions_test.rb test/services/maker/previews/geometry_test.rb`
Expected: the revision pins fail (1 ≠ 2, 3 ≠ 4); `rasterize`/`drawing` raise `NoMethodError`.

- [ ] **Step 3: Change `svg.rb`**

Replace the revision block, `render`, and the "NOTE THIS IS ALSO THE DELEGATE TARGET" comment with:

```ruby
      # Which build produced a stored artifact — see `Enqueue.revision_for`. PER KIND, so bumping
      # the measure payload does not re-rasterize every SVG thumbnail in the library.
      #
      #   1  original (thumbnail)
      #   2  the row stores the drawing's size (Maker::Previews::Dimensions) for the facts list and the
      #      Material estimate tool. The picture's bytes do not move; the bump is for the metadata.
      THUMBNAIL_REVISION = 2

      def payload_revision(kind)
        kind == "geometry" ? Maker::Previews::SvgGeometry::PAYLOAD_REVISION : THUMBNAIL_REVISION
      end

      # `kind` selects the ARTIFACT, mirroring Lbrn2's, Mage's and Dxf's branch.
      #
      # THE GEOMETRY ARM DOES NOT NEED resvg, while `available?` reports on exactly that — which
      # is why `available_for?` exists above and why the job asks IT rather than `available?`.
      #
      # THE THUMBNAIL OF AN .svg FILE carries its drawing's size, measured by the same traversal as
      # the Measure payload (`Dimensions.metadata_for`, which never raises). Only this entry adds it:
      # the formats that generate an SVG and rasterize it call `rasterize` below.
      def render(svg_bytes, size: 512, kind: "thumbnail")
        return Maker::Previews::SvgGeometry.render(svg_bytes) if kind == "geometry"

        rasterize(svg_bytes, size:).merge(metadata: Maker::Previews::Dimensions.metadata_for(svg_bytes, ext: "svg"))
      end

      # THE BARE RASTERIZE, AND THE DELEGATE TARGET for Dxf, Lbrn2 and Mage, which build an SVG of
      # their own file and rasterize it here. IT CARRIES NO METADATA, AND MUST NOT: a size measured
      # off a GENERATED document describes that document — a DXF's units are resolved before it, a
      # LightBurn bed frame is in it — not the file the row belongs to. Each delegate states its own.
      def rasterize(svg_bytes, size: 512)
        png = Maker::Previews::SvgRasterizer.to_png(svg_bytes, size:)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
      end
```

Also update the module's top comment line "Dxf and Lbrn2 build an SVG and delegate here, so this
is the single 2D-vector rasterize point." to read "Dxf, Lbrn2 and Mage build an SVG and delegate to
`rasterize`, so that is the single 2D-vector rasterize point."

- [ ] **Step 4: Change `dxf.rb`**

Bump the revision, appending to its list:

```ruby
      #   4  the row stores the drawing's size in mm (Maker::Previews::Dimensions), measured in the
      #      same walk that draws it. The picture's bytes do not move.
      THUMBNAIL_REVISION = 4
```

Replace `render`'s thumbnail line:

```ruby
      def render(dxf_bytes, size: 512, kind: "thumbnail")
        return Maker::Previews::DxfGeometry.render(dxf_bytes) if kind == "geometry"

        svg, drawn = drawing(dxf_bytes, size:)
        Maker::Previews::Svg.rasterize(svg, size:)
                            .merge(metadata: Maker::Previews::Dimensions.job_metadata(drawn))
      end
```

Replace the body of `to_svg` (keep every comment above it) and add `drawing` directly below it:

```ruby
      def to_svg(dxf_bytes, size: 512) = drawing(dxf_bytes, size:).first

      # ONE LEX, ONE WALK, TWO ANSWERS: the thumbnail's SVG and the drawing's size in mm. The size is
      # the box of the very points this walk draws, scaled by $INSUNITS — what DxfGeometry's job box
      # reports (pinned equal in dxf_geometry_test.rb). It is measured HERE, not by calling
      # DxfGeometry from the thumbnail path, because that would lex the file a second time per
      # render — the cost this file's lex-once guard exists to refuse (§14h).
      def drawing(dxf_bytes, size: 512)
        pairs = tokenize(dxf_bytes)
        colors = layer_colors(pairs)
        bbox = BBox.new
        els = []

        each_geometry(pairs) do |layer, points, closed, curve, _object_id|
          flipped = points.map { |(x, y)| flip(x, y) }
          flipped.each { |(x, y)| bbox.add(x, y) }
          els << element_svg(flipped, closed, curve, colors[layer] || STROKE)
        end

        [ wrap_svg(els, bbox, size), bbox.size_mm(mm_per_unit(pairs)) ]
      end
```

Add to `class BBox`, after `empty?`:

```ruby
        # The drawn extent in mm, rounded as Geometry rounds a job box, or nil when nothing was drawn.
        def size_mm(scale)
          return nil if empty?

          { "width" => ((@max_x - @min_x) * scale).round(Maker::Previews::Geometry::PRECISION),
            "height" => ((@max_y - @min_y) * scale).round(Maker::Previews::Geometry::PRECISION) }
        end
```

- [ ] **Step 5: Point the two other delegates at `rasterize`**

In `lbrn2.rb` `outline_thumbnail`: `Maker::Previews::Svg.render(to_svg(lbrn2_bytes, size:), size:)` →
`Maker::Previews::Svg.rasterize(to_svg(lbrn2_bytes, size:), size:)`.

In `mage.rb` `outline_thumbnail`:
`Maker::Previews::Svg.render(Maker::Previews::Lbrn2.to_svg(mage_bytes, size:), size:)` →
`Maker::Previews::Svg.rasterize(Maker::Previews::Lbrn2.to_svg(mage_bytes, size:), size:)`.

Neither renderer's `THUMBNAIL_REVISION` moves: their stored metadata does not change.

- [ ] **Step 6: Sweep every comment that names the old delegate call**

Run `grep -rn "Svg.render" app lib docs test`. Every remaining hit must be either the job's own
call path (`Registry.render`) or a test of an `.svg` file. Fix any comment still describing
`Svg.render(svg_string, size:)` as the delegate target.

- [ ] **Step 7: Run the tests to see them pass**

Run: `LANG=en_US.UTF-8 LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/ test/jobs/maker/generate_preview_job_test.rb`
Expected: green (skips only where resvg is absent). `RendererContractTest` must still pass.

- [ ] **Step 8: Mutation-check (report each output)**

1. `rasterize` merges `metadata: Dimensions.metadata_for(svg_bytes, ext: "svg")` → "the bare
   rasterize carries no size" goes RED.
2. `Dxf.render` calls `DxfGeometry.build(dxf_bytes)` for its size → the lex-count assertion goes
   RED (2 ≠ 1).
3. `size_mm` forgets `* scale` → `plate.dxf` stays green (it is $INSUNITS=4, mm, scale 1). So also
   run it against a non-mm file: edit `plate.dxf`'s `$INSUNITS` value 4 → 1 (inches) in a scratch
   copy and assert by hand that `Dxf.drawing(copy).last["width"]` reads 2032.0. Report it. Restore.
4. Revert `Svg::THUMBNAIL_REVISION` to 1 → the pin goes RED.

- [ ] **Step 9: Write the invariant bullets**

Append to `docs/invariants/measure-view.md`, before its last section:

```markdown
- **A FLAT FILE'S SIZE HAS ONE MEASURER, `Maker::Previews::Dimensions`, AND IT ADDS NO READING OF
  ANY FORMAT (2026-11-22).** An SVG's size is its Measure payload's job box; a DXF's is measured in
  `Dxf.drawing`, the walk that draws its thumbnail, and pinned equal to `DxfGeometry`'s job box;
  LightBurn's and MillMage's are `Lbrn2.page_metadata`, as their panels always read. The thumbnail
  rows of all four store the same Hash (`"job"`, and `"pages"` for a multi-page file), which the
  facts list and the Material estimate tool read through one `from_metadata`. Storing it on SVG and
  DXF rows was a per-kind THUMBNAIL bump (Svg 1 → 2, Dxf 3 → 4) with no geometry bump, because no
  payload moved.
- **THE DELEGATE RASTERIZE CARRIES NO METADATA.** `Svg.render` stores an `.svg` file's size;
  `Svg.rasterize` is what Dxf, Lbrn2 and Mage call for an SVG they generated, and it must stay
  metadata-free: a size measured off a generated document describes that document. Their own
  `render` merges their metadata over the result, which is exactly why `svg_test.rb`'s
  "the bare rasterize carries no size" is the only assertion that can see this break.
- **THE DXF THUMBNAIL MEASURES IN ITS OWN LEX.** Calling `DxfGeometry` from the thumbnail path
  would lex the file twice per render; `dxf_geometry_test.rb` counts one.
- **METADATA HOLDING ONLY A SIZE IS NOT A RECIPE.** `files/show.html.erb` draws a Laser or CNC
  panel only when `Dimensions.recipe?` — anything besides `job`/`pages` — because an SVG's size-only
  row would otherwise draw an empty "Laser settings" panel. `layers` is not the test: LightBurn's
  metadata compacts it away on a file with no layers.
```

- [ ] **Step 10: Commit**

Stage the eight code/test files and the doc by path; message: "SVG and DXF thumbnails store the
drawing's size, and the shared rasterize stores none".

---

### Task 3: The Dimensions row in the facts list, and the recipe panels

**Files:**
- Modify: `app/helpers/files_helper.rb` (two helpers)
- Modify: `app/views/files/_meta.html.erb` (locals + the row)
- Modify: `app/views/files/show.html.erb:102` (recipe discriminator) and `:221` (pass `dimensions:`)
- Modify: `app/views/files/inspector.html.erb:36` (pass `dimensions:`)
- Modify: `app/views/files/_lbrn_settings.html.erb`, `app/views/files/_mage_settings.html.erb` (drop Job size)
- Modify: `app/views/files/_recipe_pages.html.erb` (both units)
- Modify: `app/assets/stylesheets/pages/files.css` (one rule)
- Test: Create `test/integration/web/file_dimensions_test.rb`; modify `test/integration/web/settings_panel_test.rb`

Depends on Task 1 (`Dimensions.from_metadata`, `recipe?`, `MM_PER_INCH`).

Expected strings (computed): 80 × 40 → `80 × 40 mm · 3.15 × 1.57 in`; 60 × 40 →
`60 × 40 mm · 2.36 × 1.57 in`; 292.1 × 144.6 → `292.1 × 144.6 mm · 11.50 × 5.69 in`;
205 × 50 → `205 × 50 mm · 8.07 × 1.97 in`; 50 × 50 → `50 × 50 mm · 1.97 × 1.97 in`.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Web
  # THE DIMENSIONS ROW (spec 2026-11-22-material-estimate-design.md, Part 1), driven through the
  # real pages: the facts list on the file page and in the Library inspector shows a flat file's
  # drawn size in mm AND inches, read from its thumbnail row (FilesHelper#file_dimensions).
  #
  # Rows here carry a PICTURE, unlike settings_panel_test.rb's: the size is read from a SHOWABLE row
  # only, because a row repointed at new content keeps the previous content's metadata until its
  # render lands, and that size shown as this file's would be the lie `pending` exists to prevent.
  class FileDimensionsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "dims-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))

    def file_with(name, metadata, status: "ready", picture: true)
      node = create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "file", storage_path: name,
                                 content_hash: SecureRandom.hex(8))
      token = FileLayer.current.stat(@user, node_id: node.node_id).content_token
      # THIS BUILD'S revision, so the page's own heal (Enqueue.needs_job?) has nothing to rebuild and
      # the row's status is the one each test names.
      row = @user.maker_previews.create!(node_id: node.node_id, version_id: token, kind: "thumbnail",
                                         status:, metadata:,
                                         renderer_revision: Maker::Previews::Enqueue.revision_for_name(name, "thumbnail"))
      row.asset.attach(io: StringIO.new("\x89PNG".b), filename: "t.png", content_type: "image/png") if picture
      node
    end

    test "an SVG's facts give its drawing's size in mm and inches, and draw no Laser settings panel" do
      node = file_with("plate.svg", Maker::Previews::Dimensions.measure("plate.svg", fixture("plate.svg")))

      get file_path(node.node_id)
      assert_response :success
      assert_select "dl.meta dt", text: "Dimensions"
      assert_select "dl.meta dd.file-dimensions", text: "80 × 40 mm · 3.15 × 1.57 in"
      assert_select ".lbrn-settings", count: 0
    end

    test "a DXF's facts read the same way" do
      node = file_with("plate.dxf", Maker::Previews::Dimensions.measure("plate.dxf", fixture("plate.dxf")))

      get file_path(node.node_id)
      assert_select "dl.meta dd.file-dimensions", text: "80 × 40 mm · 3.15 × 1.57 in"
    end

    test "a LightBurn file's size moves from the Laser settings panel to the facts" do
      meta = Maker::Previews::LbrnMetadata.parse(fixture("nested-plate.lbrn2"))
      node = file_with("plate.lbrn2", meta)

      get file_path(node.node_id)
      assert_select "h2", text: "Laser settings"
      assert_select ".lbrn-settings dt", { text: "Job size", count: 0 }
      assert_select "dl.meta dd.file-dimensions", text: "60 × 40 mm · 2.36 × 1.57 in"
    end

    # The decimals a size actually HAS survive (recipe_num, never .to_i), and a whole number loses
    # its trailing zero — the two halves settings_panel_test.rb pinned on the old Job size line.
    test "a fractional size keeps its decimals and inches always show two" do
      node = file_with("frac.lbrn2", { "app_version" => "1.7.00", "job" => { "width" => 292.1, "height" => 144.6 } })

      get file_path(node.node_id)
      assert_select "dl.meta dd.file-dimensions", text: "292.1 × 144.6 mm · 11.50 × 5.69 in"
    end

    test "a multi-page file lists each page in both units, here and in the Pages table" do
      node = file_with("pages.lbrn2", Maker::Previews::LbrnMetadata.parse(fixture("pages.lbrn2")))

      get file_path(node.node_id)
      assert_select ".file-dimensions-page", text: /\APage 1:\s+205 × 50 mm · 8\.07 × 1\.97 in\z/
      assert_select ".file-dimensions-page", text: /\ABack \(in preview\):\s+50 × 50 mm · 1\.97 × 1\.97 in\z/
      assert_select ".file-dimensions-page", text: /\APage 3:\s+empty\z/
      assert_select ".lbrn-settings tr", text: /Page 1\s+205 × 50 mm · 8\.07 × 1\.97 in/
    end

    test "no row at all where the size is not known" do
      stl = file_with("bracket.stl", nil)
      old_svg = file_with("old.svg", nil) # a revision-1 build: a picture and no size
      repointed = file_with("moved.svg", { "job" => { "width" => 9.0, "height" => 9.0 } },
                            status: "pending", picture: false)

      [ stl, old_svg, repointed ].each do |node|
        get file_path(node.node_id)
        assert_response :success
        assert_select "dl.meta dt", { text: "Dimensions", count: 0 }, node.name
      end
    end

    test "a rebuilding row still shows its size: it is a rebuild of this same content" do
      node = file_with("plate.svg", { "job" => { "width" => 80.0, "height" => 40.0 } }, status: "rebuilding")

      get file_path(node.node_id)
      assert_select "dl.meta dd.file-dimensions", text: "80 × 40 mm · 3.15 × 1.57 in"
    end

    test "the Library inspector shows the same row" do
      node = file_with("plate.svg", { "job" => { "width" => 80.0, "height" => 40.0 } })

      get inspector_file_path(node.node_id)
      assert_response :success
      assert_select "turbo-frame#inspector dl.meta dd.file-dimensions", text: "80 × 40 mm · 3.15 × 1.57 in"
    end
  end
end
```

Edit `test/integration/web/settings_panel_test.rb`:
- In "a MillMage file gets the CNC panel, with its tooling", replace the three comment lines
  starting `# "100 × 60", not "100.0 × 60.0"` and the line `assert_select "dd", text: "100 × 60 mm"` with
  `assert_select ".lbrn-settings dt", { text: "Job size", count: 0 }, "the size is the facts list's now (file_dimensions_test.rb)"`.
- In "a fractional speed or power keeps its decimals", replace
  `assert_select "dd", text: "292.1 × 144.6 mm"` with the same `Job size`-count-0 assertion.

- [ ] **Step 2: Run to see it fail**

Run: `LANG=en_US.UTF-8 LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/file_dimensions_test.rb test/integration/web/settings_panel_test.rb`
Expected: FAIL — no `Dimensions` dt; the SVG test also finds an `.lbrn-settings` panel.

- [ ] **Step 3: Add the helpers** (`app/helpers/files_helper.rb`, beside `recipe_num`)

```ruby
  # A DRAWING'S SIZE IN BOTH UNITS — "120.5 × 80 mm · 4.74 × 3.15 in" — for the facts list and the
  # recipe panels' Pages table (2026-11-22). mm through recipe_num (no trailing zeros); inches at two
  # places always, since 0.01 in is finer than the 0.1 mm a LightBurn size is stored at. nil for
  # anything that is not two numbers.
  def dimensions_text(width, height)
    w = Float(width, exception: false)
    h = Float(height, exception: false)
    return nil if w.nil? || h.nil?

    inches = [ w, h ].map { |mm| format("%.2f", mm / Maker::Previews::Dimensions::MM_PER_INCH) }
    "#{recipe_num(w)} × #{recipe_num(h)} mm · #{inches.join(' × ')} in"
  end

  # The size facts for the file page or the inspector, from the thumbnail row beside them, or nil.
  # SHOWABLE ROWS ONLY: Enqueue repoints a row at new content without clearing its metadata, so a
  # pending row still holds the PREVIOUS content's size until its render lands. A rebuilding row is
  # a rebuild of this same content, and its size is this file's.
  def file_dimensions(thumbnail)
    return nil unless thumbnail&.showable?

    Maker::Previews::Dimensions.from_metadata(thumbnail.metadata)
  end
```

- [ ] **Step 4: The row** — `app/views/files/_meta.html.erb`

Change the first line to `<%# locals: (info:, addon_origin:, library_path:, dimensions: nil) %>` and
insert directly after the `Size` `dt`/`dd` pair:

```erb
  <%# THE DRAWING'S SIZE IN BOTH UNITS (2026-11-22; spec 2026-11-22-material-estimate-design.md), for
      the four flat formats the server measures. `dimensions` is a Maker::Previews::Dimensions::Facts
      or nil (FilesHelper#file_dimensions), and nil renders NO row: a dash would claim the file has no
      size, when the page only does not know it. A multi-page LightBurn or MillMage file gets a line
      per page, the saved page marked as the recipe panel's Pages table marks it. %>
  <% if dimensions %>
    <dt>Dimensions</dt>
    <dd class="file-dimensions">
      <% if dimensions.multi_page? %>
        <% dimensions.pages.each do |page| %>
          <span class="file-dimensions-page"><%= page.name %><% if page.current %> <span class="muted">(in preview)</span><% end %>: <%= page.sized? ? dimensions_text(page.width, page.height) : "empty" %></span>
        <% end %>
      <% else %>
        <%= dimensions_text(dimensions.pages.first.width, dimensions.pages.first.height) %>
      <% end %>
    </dd>
  <% end %>
```

- [ ] **Step 5: Pass it, and the recipe discriminator**

`app/views/files/show.html.erb` line 102 `<% recipe = @thumbnail&.metadata.presence %>` becomes:

```erb
<%# A RECIPE IS METADATA WITH SOMETHING BESIDES A SIZE (2026-11-22). An SVG or DXF thumbnail stores
    only its drawing's size, which the facts list shows; read as a recipe it would draw an empty
    Laser settings panel. Maker::Previews::Dimensions.recipe? owns the size keys. %>
<% recipe = (@thumbnail.metadata.presence if Maker::Previews::Dimensions.recipe?(@thumbnail&.metadata)) %>
```

Both `render "files/meta", …` calls (show.html.erb:221, inspector.html.erb:36) gain
`dimensions: file_dimensions(@thumbnail)` as their last argument.

- [ ] **Step 6: The recipe panels**

`_lbrn_settings.html.erb`: delete the two lines
`<%# A multi-page file has a size per page, in the table above, and no single job size. %>` and the
`<% if meta["pages"].blank? && meta.dig("job", "width") %><dt>Job size</dt>…<% end %>` line, and put
in their place:

```erb
    <%# NO JOB SIZE HERE SINCE 2026-11-22: the facts list below gives the size in mm and inches. %>
```

`_mage_settings.html.erb`: the same two lines (60–61), the same replacement.

`_recipe_pages.html.erb`: the sized cell becomes
`<%= dimensions_text(page["job"]["width"], page["job"]["height"]) %>`.

- [ ] **Step 7: One rule** — inside `@layer pages { … }` in `app/assets/stylesheets/pages/files.css`:

```css
  /* A multi-page file's Dimensions: one page per line (files/_meta). */
  .file-dimensions-page { display: block; }
```

- [ ] **Step 8: Run to see it pass**

Run: `LANG=en_US.UTF-8 LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/file_dimensions_test.rb test/integration/web/settings_panel_test.rb test/integration/web/inspector_test.rb test/integration/web/template_hygiene_test.rb test/css_hygiene_test.rb`
Expected: green.

- [ ] **Step 9: Mutation-check (report each output)**

1. `file_dimensions` drops the `showable?` guard → "no row at all…" goes RED on `moved.svg`.
2. `show.html.erb` back to `@thumbnail&.metadata.presence` → the SVG test goes RED (an
   `.lbrn-settings` panel renders).
3. `dimensions_text` uses `.round(2).to_s` for inches → "11.50" becomes "11.5", RED.
4. `_meta` renders `page.name` without the `(in preview)` span → the Back line goes RED.

- [ ] **Step 10: Commit** — "A flat file's facts give its size in mm and inches, on the file page and in the inspector".

---

### Task 4: `Maker::Material::SheetPack`

**Files:**
- Create: `app/services/maker/material/sheet_pack.rb`
- Test: `test/services/maker/material/sheet_pack_test.rb`

Items are any objects answering `width`, `height` (mm) and `label`. Each copy is its own item.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Maker
  module Material
    # RECTANGLES ONTO SHEETS (spec 2026-11-22, "Packing"). Every expected layout below was worked by
    # hand against MaxRects best-short-side-fit; the property test at the end pins the four promises
    # on random input, so a layout change that breaks one cannot hide behind the hand-checked cases.
    class SheetPackTest < ActiveSupport::TestCase
      Item = Data.define(:label, :width, :height)

      def items(count, width, height, prefix: "p") = Array.new(count) { |i| Item.new(label: "#{prefix}#{i}", width:, height:) }

      def pack(list, w, h, gap: 0, rotate: false) = SheetPack.call(list, sheet_width: w, sheet_height: h, gap:, rotate:)

      test "four squares fill one sheet, corner to corner" do
        result = pack(items(4, 100, 100), 200, 200)

        assert_equal 1, result.sheets.size
        assert_equal [ [ 0.0, 0.0 ], [ 0.0, 100.0 ], [ 100.0, 0.0 ], [ 100.0, 100.0 ] ],
                     result.sheets.first.map { |pl| [ pl.x, pl.y ] }.sort
        assert_empty result.unplaced
      end

      test "a fifth square opens a second sheet" do
        assert_equal [ 4, 1 ], pack(items(5, 100, 100), 200, 200).sheets.map(&:size)
      end

      test "a large part and two small ones share a sheet" do
        list = [ Item.new(label: "lid", width: 200, height: 100) ] + items(2, 100, 100)
        assert_equal 1, pack(list, 200, 200).sheets.size
      end

      # THE GAP IS KEPT BETWEEN PARTS AND FROM EVERY EDGE: two 98 mm squares side by side need
      # 2 + 98 + 2 + 98 + 2 = 202 mm, so a 200 mm sheet holds one with gap 2 — and four with gap 1
      # (1 + 98 + 1 + 98 + 1 = 199).
      test "the gap holds between parts and at the edges" do
        assert_equal 4, pack(items(4, 98, 98), 200, 200, gap: 2).sheets.size
        one = pack(items(4, 98, 98), 200, 200, gap: 1)
        assert_equal 1, one.sheets.size
        assert_equal [ 1.0, 100.0 ], one.sheets.first.map(&:x).uniq.sort
      end

      test "rotation is tried only when allowed" do
        list = items(2, 150, 50)

        rotated = pack(list, 100, 200, rotate: true)
        assert_equal 1, rotated.sheets.size
        assert rotated.sheets.first.all?(&:rotated)
        assert_equal [ [ 50.0, 150.0 ] ], rotated.sheets.first.map { |pl| [ pl.width, pl.height ] }.uniq

        upright = pack(list, 100, 200, rotate: false)
        assert_empty upright.sheets
        assert_equal list, upright.unplaced
      end

      test "a part too big for the sheet is unplaced, by the usable area inside the gap" do
        big = Item.new(label: "big", width: 400, height: 400)
        assert_equal [ big ], pack([ big ], 300, 300).unplaced

        assert_equal 1, pack([ Item.new(label: "fits", width: 296, height: 296) ], 300, 300, gap: 2).sheets.size
        assert_equal 1, pack([ Item.new(label: "no", width: 297, height: 296) ], 300, 300, gap: 2).unplaced.size
      end

      test "the same input lays out the same way every time" do
        list = items(7, 120, 40) + items(5, 60, 60, prefix: "q")
        layout = ->(r) { r.sheets.map { |s| s.map { |pl| [ pl.item.label, pl.x, pl.y, pl.rotated ] } } }

        assert_equal layout.(pack(list, 300, 200, gap: 3, rotate: true)),
                     layout.(pack(list, 300, 200, gap: 3, rotate: true))
      end

      # THE FOUR PROMISES, over random input: inside the usable area, at least `gap` apart, every
      # fitting copy placed exactly once, and nothing else.
      [ true, false ].each do |rotate|
        test "the promises hold on random parts (rotate #{rotate})" do
          rng = Random.new(20261122)
          list = Array.new(80) { |i| Item.new(label: "r#{i}", width: rng.rand(5.0..180.0).round(1), height: rng.rand(5.0..180.0).round(1)) }
          w, h, gap = 300.0, 200.0, 3.0
          result = pack(list, w, h, gap:, rotate:)
          eps = 1e-6

          placed = result.sheets.flatten
          assert_equal list.size, placed.size + result.unplaced.size
          assert_equal placed.size, placed.map { |pl| pl.item.object_id }.uniq.size, "a copy was placed twice"

          result.sheets.each do |sheet|
            sheet.each do |pl|
              assert_operator pl.x, :>=, gap - eps
              assert_operator pl.y, :>=, gap - eps
              assert_operator pl.x + pl.width, :<=, w - gap + eps
              assert_operator pl.y + pl.height, :<=, h - gap + eps
              dims = pl.rotated ? [ pl.item.height, pl.item.width ] : [ pl.item.width, pl.item.height ]
              assert_equal dims, [ pl.width, pl.height ]
            end
            sheet.combination(2).each do |a, b|
              apart = a.x + a.width + gap <= b.x + eps || b.x + b.width + gap <= a.x + eps ||
                      a.y + a.height + gap <= b.y + eps || b.y + b.height + gap <= a.y + eps
              assert apart, "#{a.item.label} and #{b.item.label} are closer than the gap"
            end
          end
          result.unplaced.each do |item|
            fits = [ [ item.width, item.height ], ([ item.height, item.width ] if rotate) ].compact
                    .any? { |(iw, ih)| iw <= w - 2 * gap + eps && ih <= h - 2 * gap + eps }
            refute fits, "#{item.label} fits an empty sheet but was not placed"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run to see it fail** — `NameError: uninitialized constant Maker::Material`.

- [ ] **Step 3: Write the packer**

```ruby
module Maker
  module Material
    # RECTANGLES ONTO SHEETS, for the Material estimate tool (2026-11-22; spec
    # docs/superpowers/specs/2026-11-22-material-estimate-design.md, "Packing").
    #
    # MAXRECTS, BEST SHORT SIDE FIT: every sheet keeps the list of maximal free rectangles; each part
    # goes where the shorter leftover side is smallest, ties to the lower then the leftmost spot. It
    # places a part ANYWHERE on a sheet, which is what a laser or a CNC can cut. The Cut List add-on's
    # guillotine shelves are the right model for a saw and overcount for these machines.
    #
    # THE GAP INFLATES EVERY PART by `gap` on each side's length and packs into a usable sheet of
    # (W - gap) x (H - gap) offset by (gap, gap). That keeps `gap` between neighbours AND from every
    # edge, and a part fits only if w <= W - 2·gap in some allowed orientation.
    #
    # Largest area first, and a part never moves between sheets once placed. Ties in the order break
    # on the longer side, then the label, then input order, so a layout is a function of its input.
    class SheetPack
      EPS = 1e-9

      # x/y/width/height are the PART's own (mm, rotated when `rotated`), on the full sheet.
      Placement = Data.define(:item, :x, :y, :width, :height, :rotated)
      # `sheets` is an Array of Arrays of Placement; `unplaced` the items no sheet can hold.
      Result = Data.define(:sheets, :unplaced)
      Rect = Data.define(:x, :y, :w, :h) do
        def right = x + w
        def bottom = y + h
      end

      def self.call(items, sheet_width:, sheet_height:, gap:, rotate:)
        new(items, sheet_width:, sheet_height:, gap:, rotate:).call
      end

      def initialize(items, sheet_width:, sheet_height:, gap:, rotate:)
        @items = items
        @gap = gap.to_f
        @usable_w = sheet_width.to_f - @gap
        @usable_h = sheet_height.to_f - @gap
        @rotate = rotate
      end

      def call
        sheets = []
        unplaced = []
        ordered.each do |item|
          w = item.width + @gap
          h = item.height + @gap
          unless fits_empty_sheet?(w, h)
            unplaced << item
            next
          end
          next if sheets.any? { |sheet| place(sheet, item, w, h) }

          sheet = { free: [ Rect.new(x: 0.0, y: 0.0, w: @usable_w, h: @usable_h) ], placements: [] }
          place(sheet, item, w, h) or raise "a part that fits an empty sheet did not fit one"
          sheets << sheet
        end
        Result.new(sheets: sheets.map { |s| s[:placements] }, unplaced:)
      end

      private

      def ordered
        @items.each_with_index
              .sort_by { |item, i| [ -(item.width * item.height), -[ item.width, item.height ].max, item.label.to_s, i ] }
              .map(&:first)
      end

      def orientations(w, h)
        @rotate && (w - h).abs > EPS ? [ [ w, h, false ], [ h, w, true ] ] : [ [ w, h, false ] ]
      end

      def fits_empty_sheet?(w, h)
        orientations(w, h).any? { |(ow, oh, _)| ow <= @usable_w + EPS && oh <= @usable_h + EPS }
      end

      # Places `item` (inflated to w x h) on `sheet` at its best free spot. false when none fits.
      def place(sheet, item, w, h)
        best = nil
        sheet[:free].each do |free|
          orientations(w, h).each do |(ow, oh, rotated)|
            next unless ow <= free.w + EPS && oh <= free.h + EPS

            short, long = [ free.w - ow, free.h - oh ].minmax
            score = [ short, long, free.y, free.x ]
            best = [ score, free, ow, oh, rotated ] if best.nil? || (score <=> best[0]).negative?
          end
        end
        return false if best.nil?

        _score, free, ow, oh, rotated = best
        used = Rect.new(x: free.x, y: free.y, w: ow, h: oh)
        sheet[:free] = prune(sheet[:free].flat_map { |f| split(f, used) })
        sheet[:placements] << Placement.new(item:, x: @gap + used.x, y: @gap + used.y,
                                            width: ow - @gap, height: oh - @gap, rotated:)
        true
      end

      # The maximal free rectangles left of `free` once `used` is taken out of it.
      def split(free, used)
        return [ free ] unless overlap?(free, used)

        parts = []
        parts << Rect.new(x: free.x, y: free.y, w: used.x - free.x, h: free.h) if used.x > free.x + EPS
        parts << Rect.new(x: used.right, y: free.y, w: free.right - used.right, h: free.h) if used.right < free.right - EPS
        parts << Rect.new(x: free.x, y: free.y, w: free.w, h: used.y - free.y) if used.y > free.y + EPS
        parts << Rect.new(x: free.x, y: used.bottom, w: free.w, h: free.bottom - used.bottom) if used.bottom < free.bottom - EPS
        parts
      end

      def overlap?(a, b)
        a.x < b.right - EPS && b.x < a.right - EPS && a.y < b.bottom - EPS && b.y < a.bottom - EPS
      end

      def contains?(outer, inner)
        inner.x >= outer.x - EPS && inner.y >= outer.y - EPS &&
          inner.right <= outer.right + EPS && inner.bottom <= outer.bottom + EPS
      end

      # Drops every free rectangle another one contains (keeping the first of two equal ones).
      def prune(rects)
        rects.each_with_index.reject do |rect, i|
          rects.each_with_index.any? { |other, j| i != j && contains?(other, rect) && (!contains?(rect, other) || j < i) }
        end.map(&:first)
      end
    end
  end
end
```

- [ ] **Step 4: Run to see it pass** — `bin/rails test test/services/maker/material/sheet_pack_test.rb` (with the env prefix). Green.

- [ ] **Step 5: Mutation-check (report each output)**

1. In `call`, `w = item.width` and `h = item.height` (no inflation) → "the gap holds…" RED.
2. `orientations` always returns the upright one → "rotation is tried only when allowed" RED.
3. `split` returns `[ free ]` unconditionally → the property tests RED ("closer than the gap").
4. Sort ascending by area instead of descending → report whether any test reds. If none does, add
   to "a large part and two small ones share a sheet" an `assert_equal "lid", first placement's label`
   and re-run the mutation until it does.

- [ ] **Step 6: Commit** — "Parts pack onto sheets with MaxRects, a gap at every edge, rotation when allowed".

---

### Task 5: `Maker::Material::Part` and `Maker::Material::Estimate`

**Files:**
- Create: `app/services/maker/material/part.rb`, `app/services/maker/material/estimate.rb`
- Test: `test/services/maker/material/estimate_test.rb`

Depends on Task 4. The 100 × 50 × 5 on 200 × 100 case: 4 per sheet (worked in Task 4's terms:
(0,0), (100,0), (0,50), (100,50)), so 2 sheets; area 25,000 mm²; use 25,000 ÷ (2 × 20,000) = 62.5 %.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Maker
  module Material
    # ONE ESTIMATE, BUILT FROM ONE REQUEST'S FORM (spec 2026-11-22, "State and requests" and
    # "Limits"). The hidden fields are user-supplied, so every number is re-read here; a forged one
    # only ever changes the forger's own estimate, and these tests pin that it cannot do worse.
    class EstimateTest < ActiveSupport::TestCase
      def row(name: "a.svg", width: "100", height: "50", qty: "1", **rest) = { "name" => name, "width" => width, "height" => height, "qty" => qty }.merge(rest.transform_keys(&:to_s))

      def estimate(rows, **stock)
        parts = rows.each_with_index.to_h { |r, i| [ i.to_s, r ] }
        Estimate.from_params(parts:, stock: { "sheet_width" => "200", "sheet_height" => "100", "gap" => "0",
                                              "unit" => "mm", "rotate" => "0" }.merge(stock.transform_keys(&:to_s)))
      end

      test "a first visit sends nothing and gets the default stock" do
        est = Estimate.from_params(parts: nil, stock: {})
        assert_equal Estimate::DEFAULT_STOCK, est.stock
        assert_empty est.parts
        assert_empty est.errors
      end

      test "parts read in index order, quantities clamped" do
        parts = { "1" => row(name: "b.svg", qty: "9999"), "0" => row(name: "a.svg", qty: "0"), "2" => row(name: "c.svg", qty: "abc") }
        est = Estimate.from_params(parts:, stock: {})

        assert_equal %w[a.svg b.svg c.svg], est.parts.map(&:name)
        assert_equal [ 1, Estimate::MAX_QTY, 1 ], est.parts.map(&:qty)
      end

      test "a forged or unreadable size is refused, never packed" do
        est = estimate([ row(width: "-5"), row(width: "abc"), row(width: "20000"), row(width: "0", height: "0") ])
        assert_equal [ "size could not be read" ], est.parts.map(&:reason).uniq
        assert_empty est.measured_parts
      end

      test "a straight line is a part" do
        assert estimate([ row(width: "50", height: "0") ]).parts.first.measured?
      end

      test "a refused row stays refused, with its reason" do
        part = estimate([ row(reason: "no measurable shapes", width: "", height: "") ]).parts.first
        refute part.measured?
        assert_equal "no measurable shapes", part.reason
      end

      test "five 100 x 50 parts need two 200 x 100 sheets, and the arithmetic adds up" do
        est = estimate([ row(qty: "5") ])

        assert_empty est.errors
        assert_equal 5, est.copies
        assert_equal 2, est.sheets.size
        assert_in_delta 25_000.0, est.total_area_mm2, 1e-6
        assert_in_delta 0.625, est.utilization, 1e-9
      end

      test "inches convert to millimetres for the packer" do
        est = estimate([ row(width: "100", height: "100") ], sheet_width: "12", sheet_height: "12", gap: "0.125", unit: "in")
        assert_in_delta 304.8, est.stock.width_mm, 1e-9
        assert_in_delta 3.175, est.stock.gap_mm, 1e-9
        assert_equal 1, est.sheets.size
      end

      test "a part too big for the sheet is named, kept out of the count and kept in the area" do
        est = estimate([ row(name: "big.svg", width: "400", height: "400", qty: "2") ])
        assert_empty est.sheets
        assert_equal [ [ "big.svg", 2 ] ], est.unplaced.map { |part, n| [ part.name, n ] }
        assert_in_delta 320_000.0, est.total_area_mm2, 1e-6
      end

      test "a bad sheet or gap is an error and nothing is packed" do
        assert_equal [ "Enter the sheet's width and height." ], estimate([ row ], sheet_width: "").errors
        assert_equal [ "Each side of the sheet must be between 1 and 10,000 mm." ], estimate([ row ], sheet_width: "0.5").errors
        assert_equal [ "The gap must be between 0 and 100 mm." ], estimate([ row ], gap: "101").errors
        assert_nil estimate([ row ], gap: "101").pack
      end

      test "more copies than the limit is an error, not a slow request" do
        est = estimate(Array.new(5) { row(qty: "500") })
        assert_equal [ "Too many copies to lay out: 2,500. The limit is 2,000." ], est.errors
        assert_nil est.pack
      end

      test "adding past the list's limit says how many were left out" do
        full = Estimate.new(parts: Array.new(Estimate::MAX_PARTS - 1) { Part.measured(name: "x", width: 1.0, height: 1.0) },
                            stock: Estimate::DEFAULT_STOCK)
        more = Array.new(4) { Part.measured(name: "y", width: 1.0, height: 1.0) }
        added = full.adding(more)

        assert_equal Estimate::MAX_PARTS, added.parts.size
        assert_equal [ "Left out 3 parts: the list holds at most 200." ], added.notes
      end

      test "without removes one row by index and ignores an index that is not one" do
        est = estimate([ row(name: "a.svg"), row(name: "b.svg") ])
        assert_equal [ "b.svg" ], est.without(0).parts.map(&:name)
        assert_equal 2, est.without(7).parts.size
        assert_equal 2, est.without(nil).parts.size
      end
    end
  end
end
```

- [ ] **Step 2: Run to see it fail** — `NameError` for `Estimate`.

- [ ] **Step 3: Write `part.rb`**

```ruby
module Maker
  module Material
    # ONE ROW OF THE MATERIAL ESTIMATE: a measured part (mm, with a quantity) or a refused file with
    # the reason it could not be measured. A refused row stays in the list, greyed, and counts toward
    # nothing — dropping it would make the total quietly describe fewer files than were added.
    Part = Data.define(:name, :node_id, :page, :width, :height, :qty, :reason) do
      def self.measured(name:, width:, height:, node_id: nil, page: nil, qty: 1)
        new(name:, node_id:, page:, width:, height:, qty:, reason: nil)
      end

      def self.refused(name:, reason:, node_id: nil)
        new(name:, node_id:, page: nil, width: nil, height: nil, qty: 1, reason:)
      end

      def measured? = reason.nil?

      def label = page.present? ? "#{name} · #{page}" : name

      def area = measured? ? width * height * qty : 0.0
    end
  end
end
```

- [ ] **Step 4: Write `estimate.rb`**

```ruby
module Maker
  module Material
    # ONE MATERIAL ESTIMATE, BUILT FROM ONE REQUEST (2026-11-22; spec
    # docs/superpowers/specs/2026-11-22-material-estimate-design.md). The server keeps no state: the
    # parts list rides in the form as hidden fields and every request rebuilds the estimate from it.
    # Those fields are user-supplied, so every number is re-read and bounded HERE; a forged value can
    # only change its forger's own estimate, and the limits keep it from tying up the server.
    class Estimate
      MAX_PARTS = 200
      MAX_QTY = 500
      MAX_PLACEMENTS = 2_000
      MAX_SIDE_MM = 10_000.0
      MAX_GAP_MM = 100.0
      UNITS = { "mm" => 1.0, "in" => Maker::Previews::Dimensions::MM_PER_INCH }.freeze

      # The stock as typed, in `unit`; the *_mm readers are what the packer is handed.
      Stock = Data.define(:width, :height, :gap, :unit, :rotate) do
        def scale = UNITS.fetch(unit)
        def width_mm = width && width * scale
        def height_mm = height && height * scale
        def gap_mm = gap * scale
        def area_mm2 = width_mm * height_mm
      end

      DEFAULT_STOCK = Stock.new(width: 300.0, height: 300.0, gap: 2.0, unit: "mm", rotate: true)

      attr_reader :parts, :stock, :notes

      # `parts` is the form's indexed Hash ({"0" => {"name" => …}, …}) or nil; `stock` its stock
      # fields. A stock field the form did not send at all (a first visit) takes the default; one it
      # sent blank or unreadable is an error the page names.
      def self.from_params(parts:, stock:)
        new(parts: parse_parts(parts), stock: parse_stock(stock))
      end

      def self.parse_stock(raw)
        raw = (raw || {}).to_h.stringify_keys
        Stock.new(width: field(raw, "sheet_width", DEFAULT_STOCK.width),
                  height: field(raw, "sheet_height", DEFAULT_STOCK.height),
                  gap: raw.key?("gap") ? (number(raw["gap"]) || 0.0) : DEFAULT_STOCK.gap,
                  unit: UNITS.key?(raw["unit"].to_s) ? raw["unit"].to_s : DEFAULT_STOCK.unit,
                  rotate: raw.key?("rotate") ? raw["rotate"].to_s == "1" : DEFAULT_STOCK.rotate)
      end

      def self.parse_parts(raw)
        rows = raw.is_a?(Hash) ? raw.sort_by { |key, _| key.to_s.to_i }.map(&:last) : Array(raw)
        rows.first(MAX_PARTS).filter_map { |row| part_from(row.to_h.stringify_keys) if row.respond_to?(:to_h) }
      end

      def self.part_from(row)
        name = row["name"].to_s.strip.first(255).presence || "Untitled"
        node_id = row["node_id"].to_s.strip.first(64).presence
        reason = row["reason"].to_s.strip.first(200).presence
        return Part.refused(name:, node_id:, reason:) if reason

        width = number(row["width"])
        height = number(row["height"])
        return Part.refused(name:, node_id:, reason: "size could not be read") unless readable_size?(width, height)

        qty = (Integer(row["qty"].to_s.strip, 10, exception: false) || 1).clamp(1, MAX_QTY)
        Part.measured(name:, node_id:, page: row["page"].to_s.strip.first(255).presence, width:, height:, qty:)
      end

      def self.readable_size?(width, height)
        width && height && !width.negative? && !height.negative? && (width.positive? || height.positive?) &&
          width <= MAX_SIDE_MM && height <= MAX_SIDE_MM
      end

      def self.field(raw, key, default) = raw.key?(key) ? number(raw[key]) : default

      def self.number(value)
        f = Float(value.to_s.strip, exception: false)
        f if f&.finite?
      end

      def initialize(parts:, stock:, notes: [])
        @parts = parts
        @stock = stock
        @notes = notes
      end

      def adding(more, notes: [])
        kept = more.first([ MAX_PARTS - parts.size, 0 ].max)
        extra = more.size - kept.size
        overflow = extra.positive? ? [ "Left out #{extra} #{'part'.pluralize(extra)}: the list holds at most #{MAX_PARTS}." ] : []
        Estimate.new(parts: parts + kept, stock:, notes: self.notes + notes + overflow)
      end

      def without(index)
        return self unless index.is_a?(Integer) && index.between?(0, parts.size - 1)

        Estimate.new(parts: parts.reject.with_index { |_, i| i == index }, stock:, notes:)
      end

      def with_note(note) = Estimate.new(parts:, stock:, notes: notes + [ note ])

      def measured_parts = parts.select(&:measured?)

      def copies = measured_parts.sum(&:qty)

      def total_area_mm2 = measured_parts.sum(&:area)

      def errors
        @errors ||= [].tap do |list|
          if stock.width.nil? || stock.height.nil?
            list << "Enter the sheet's width and height."
          elsif ![ stock.width_mm, stock.height_mm ].all? { |side| side.between?(1.0, MAX_SIDE_MM) }
            list << "Each side of the sheet must be between 1 and #{delimited(MAX_SIDE_MM.to_i)} mm."
          end
          list << "The gap must be between 0 and #{MAX_GAP_MM.to_i} mm." unless stock.gap_mm.between?(0.0, MAX_GAP_MM)
          list << "Too many copies to lay out: #{delimited(copies)}. The limit is #{delimited(MAX_PLACEMENTS)}." if copies > MAX_PLACEMENTS
        end
      end

      def pack
        return nil if errors.any? || measured_parts.empty?

        @pack ||= SheetPack.call(measured_parts.flat_map { |part| Array.new(part.qty, part) },
                                 sheet_width: stock.width_mm, sheet_height: stock.height_mm,
                                 gap: stock.gap_mm, rotate: stock.rotate)
      end

      def sheets = pack&.sheets || []

      # Each part too big for the sheet once, with how many of its copies were refused.
      def unplaced = (pack&.unplaced || []).tally.to_a

      def utilization
        return nil if sheets.empty?

        placed = sheets.sum { |sheet| sheet.sum { |pl| pl.width * pl.height } }
        placed / (sheets.size * stock.area_mm2)
      end

      private

      def delimited(n) = ActiveSupport::NumberHelper.number_to_delimited(n)
    end
  end
end
```

- [ ] **Step 5: Run to see it pass.** Green.

- [ ] **Step 6: Mutation-check (report each output)**

1. `readable_size?` drops `width <= MAX_SIDE_MM` → "a forged or unreadable size…" RED (20000).
2. `errors` drops the copies line → "more copies than the limit…" RED.
3. `parse_parts` drops the `sort_by` → "parts read in index order" RED.
4. `adding` drops the `.first(…)` cap → "adding past the list's limit" RED.

- [ ] **Step 7: Commit** — "A material estimate is rebuilt and bounded from each request's form".

---

### Task 6: `Maker::Material::Sources` — uploads, a project, a folder, a file

**Files:**
- Create: `app/services/maker/material/sources.rb`
- Test: `test/services/maker/material/sources_test.rb`

Depends on Tasks 1 and 5. **Spec note:** folder files are sorted by **name** (then node id), not by
path — chunk_remote nodes have no `storage_path`, and building a path per node is a parent walk
each. Task 10 amends the spec's sentence.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Maker
  module Material
    # WHERE PARTS COME FROM (spec 2026-11-22, "Adding parts, three ways"). Pinned to a fresh share
    # library, as every web-layer suite here is, so a library read is a real file read on every leg.
    class SourcesTest < ActiveSupport::TestCase
      setup do
        @root = use_fresh_share_library!
        @user = User.create!(email: "sources-#{SecureRandom.hex(4)}@example.com", password: "correct horse battery staple",
                             confirmed_at: Time.current)
      end

      # The house stub helper (Minitest 6 has no Object#stub).
      def replacing(owner, name, replacement)
        mod = owner.singleton_class
        own = mod.instance_methods(false).include?(name)
        original = mod.instance_method(name)
        mod.define_method(name, &replacement)
        yield
      ensure
        own ? mod.define_method(name, original) : mod.remove_method(name)
      end

      def fixture_path(name) = Rails.root.join("test/fixtures/files", name)

      def upload(name, from: name) = Rack::Test::UploadedFile.new(fixture_path(from), "application/octet-stream", original_filename: name)

      # A library file with REAL bytes: create_node! writes a placeholder, so overwrite it.
      def place!(name, from: name, parent: nil, user: @user)
        node = create_node!(user, node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent&.node_id,
                                  content_hash: SecureRandom.hex(8))
        @root.join(node.storage_path).binwrite(File.binread(fixture_path(from)))
        node
      end

      def dir!(name, parent: nil, user: @user)
        create_node!(user, node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent&.node_id)
      end

      def sizes(added) = added.parts.map { |p| [ p.name, p.page, p.width, p.height, p.reason ] }

      test "an upload is measured from its bytes; one it cannot measure says why" do
        added = Sources.uploads([ upload("plate.svg"), upload("bracket.stl", from: "plate.svg") ])
        assert_equal [ "plate.svg", nil, 80.0, 40.0, nil ], sizes(added).first
        assert_equal Maker::Previews::Dimensions::UNSUPPORTED, added.parts.second.reason
        assert_empty added.notes
      end

      test "a multi-page upload is one part per page that has something on it" do
        added = Sources.uploads([ upload("pages.lbrn2") ])
        assert_equal [ [ "pages.lbrn2", "Page 1", 205.0, 50.0, nil ], [ "pages.lbrn2", "Back", 50.0, 50.0, nil ] ], sizes(added)
      end

      test "one upload batch measures at most 20 files and says what it left out" do
        added = Sources.uploads(Array.new(23) { |i| upload("p#{i}.svg", from: "plate.svg") })
        assert_equal 20, added.parts.size
        assert_equal [ "Left out 3 files: one upload measures at most 20." ], added.notes
      end

      test "an upload over the byte limit is refused without being read" do
        file = upload("plate.svg")
        def file.read(*) = raise("read an oversized upload")
        replacing(Sources, :max_bytes, -> { 10 }) do
          assert_match(/\Aover the 10 Bytes limit\z/, Sources.uploads([ file ]).parts.first.reason)
        end
      end

      test "a folder adds its flat files, subfolders included, by name, and nothing else" do
        laser = dir!("laser")
        sub = dir!("lids", parent: laser)
        place!("plate.svg", parent: laser)
        place!("a-plate.dxf", from: "plate.dxf", parent: sub)
        place!("bracket.stl", from: "plate.svg", parent: laser)

        added = Sources.folder(@user, laser.node_id)
        assert_equal [ [ "a-plate.dxf", nil, 80.0, 40.0, nil ], [ "plate.svg", nil, 80.0, 40.0, nil ] ], sizes(added)
      end

      test "a folder past the cap adds the first 200 by name and says so" do
        replacing(Sources, :max_folder_files, -> { 1 }) do
          laser = dir!("laser")
          place!("b.svg", from: "plate.svg", parent: laser)
          place!("a.svg", from: "plate.svg", parent: laser)
          added = Sources.folder(@user, laser.node_id)
          assert_equal [ "a.svg" ], added.parts.map(&:name)
          assert_equal [ "Added the first 1 of 2 files from laser." ], added.notes
        end
      end

      test "a project adds its ATTACHED flat files only" do
        project = @user.maker_projects.create!(name: "Desk Lamp")
        attached = place!("plate.svg")
        place!("loose.svg", from: "plate.svg")
        @user.maker_file_attachments.create!(attachable: project, node_id: attached.node_id)

        assert_equal [ "plate.svg" ], Sources.project(@user, project.id).parts.map(&:name)
      end

      test "another user's project, folder or file answers like a missing one" do
        other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: "correct horse battery staple",
                             confirmed_at: Time.current)
        project = other.maker_projects.create!(name: "Theirs")
        folder = dir!("theirs", user: other)
        file = place!("theirs.svg", from: "plate.svg", user: other)

        assert_equal [ "Found no such project." ], Sources.project(@user, project.id).notes
        assert_equal [ "Found no such folder." ], Sources.folder(@user, folder.node_id).notes
        assert_equal [ "Found no such file." ], Sources.file(@user, file.node_id).notes
        [ Sources.project(@user, project.id), Sources.folder(@user, folder.node_id), Sources.file(@user, file.node_id) ]
          .each { |added| assert_empty added.parts }
      end

      # THE STORED SIZE IS USED WHEN ITS ROW IS CURRENT, AND ONLY THEN. The row below claims 12 x 34
      # while the bytes say 80 x 40, so which one comes back says which path ran.
      test "a library file's current thumbnail row is read instead of its bytes" do
        node = place!("plate.svg")
        token = FileLayer.current.stat(@user, node_id: node.node_id).content_token
        row = @user.maker_previews.create!(node_id: node.node_id, version_id: token, kind: "thumbnail", status: "ready",
                                           renderer_revision: Maker::Previews::Svg::THUMBNAIL_REVISION,
                                           metadata: { "job" => { "width" => 12.0, "height" => 34.0 } })
        row.asset.attach(io: StringIO.new("\x89PNG".b), filename: "t.png", content_type: "image/png")

        assert_equal [ 12.0, 34.0 ], Sources.file(@user, node.node_id).parts.first.then { |p| [ p.width, p.height ] }

        row.update!(renderer_revision: 1) # an older build: its size, if any, is not this build's
        assert_equal [ 80.0, 40.0 ], Sources.file(@user, node.node_id).parts.first.then { |p| [ p.width, p.height ] }
      end

      test "an unreachable library is a reason on that part, never a 500" do
        node = place!("plate.svg")
        replacing(FileLayer.current, :read, ->(*, **) { raise FileLayer::FetchError, "unmounted" }) do
          assert_equal Sources::UNREACHABLE, Sources.file(@user, node.node_id).parts.first.reason
        end
      end
    end
  end
end
```

(`User has_many :maker_file_attachments` — checked, `app/models/user.rb:50`.)

- [ ] **Step 2: Run to see it fail** — `NameError` for `Sources`.

- [ ] **Step 3: Write `sources.rb`**

```ruby
module Maker
  module Material
    # WHERE THE MATERIAL ESTIMATE'S PARTS COME FROM (2026-11-22; spec
    # docs/superpowers/specs/2026-11-22-material-estimate-design.md, "Adding parts, three ways").
    #
    # UPLOADS ARE MEASURED AND THROWN AWAY. Their bytes reach `Dimensions.measure` and nothing else:
    # not the port, not the library, not Active Storage, not a preview row. That is a deliberate,
    # scoped departure from §15's "bytes out of Rails", chosen by the owner; Rack's multipart tempfile
    # is the only copy and it dies with the request.
    #
    # A LIBRARY FILE READS ITS STORED SIZE when its thumbnail row is a current build of its current
    # content — a measurement is data, and §14h says a consumer that measures asks `current_build?` —
    # and otherwise reads its bytes through the port and measures them with the same function the
    # thumbnail job uses. Nothing is enqueued from here.
    #
    # Every lookup starts from the user, so another user's project, folder or file answers exactly
    # like a missing one.
    module Sources
      module_function

      MAX_UPLOADS = 20
      MAX_FOLDER_FILES = 200
      GONE = "no longer in the library".freeze
      UNREACHABLE = "library unreachable, try again".freeze
      UNREADABLE = "could not be read".freeze

      Added = Data.define(:parts, :notes)

      def max_bytes = Maker::GeneratePreviewJob::MAX_PREVIEW_BYTES

      def max_folder_files = MAX_FOLDER_FILES

      def uploads(files)
        files = Array(files).select { |f| f.respond_to?(:original_filename) && f.respond_to?(:read) }
        notes = []
        if files.size > MAX_UPLOADS
          left = files.size - MAX_UPLOADS
          notes << "Left out #{left} #{'file'.pluralize(left)}: one upload measures at most #{MAX_UPLOADS}."
          files = files.first(MAX_UPLOADS)
        end
        Added.new(parts: files.flat_map { |file| upload_parts(file) }, notes:)
      end

      def project(user, project_id)
        project = user.maker_projects.find_by(id: project_id)
        return missing("project") if project.nil?

        nodes = measurable(user.nodes.present.where(kind: "file", node_id: project.file_attachments.pluck(:node_id)))
        notes = nodes.empty? ? [ "Found no SVG, LightBurn, DXF or MillMage files attached to #{project.name}." ] : []
        Added.new(parts: library_parts(user, nodes), notes:)
      end

      def folder(user, folder_id)
        folder = user.nodes.present.find_by(node_id: folder_id.to_s, kind: "dir")
        return missing("folder") if folder.nil?

        ids = FileLayer::Subtree.node_ids(user, folder.node_id)
        nodes = measurable(user.nodes.present.where(kind: "file", node_id: ids))
        notes = []
        if nodes.empty?
          notes << "Found no SVG, LightBurn, DXF or MillMage files in #{folder.name}."
        elsif nodes.size > max_folder_files
          notes << "Added the first #{max_folder_files} of #{nodes.size} files from #{folder.name}."
          nodes = nodes.first(max_folder_files)
        end
        Added.new(parts: library_parts(user, nodes), notes:)
      end

      def file(user, node_id)
        node = user.nodes.present.find_by(node_id: node_id.to_s, kind: "file")
        return missing("file") if node.nil?
        unless Maker::Previews::Dimensions.measurable_name?(node.name)
          return Added.new(parts: [ Part.refused(name: node.name, node_id: node.node_id, reason: Maker::Previews::Dimensions::UNSUPPORTED) ],
                           notes: [])
        end

        Added.new(parts: library_parts(user, [ node ]), notes: [])
      end

      def upload_parts(file)
        name = File.basename(file.original_filename.to_s).first(255).presence || "upload"
        return [ Part.refused(name:, reason: Maker::Previews::Dimensions::UNSUPPORTED) ] unless Maker::Previews::Dimensions.measurable_name?(name)
        return [ Part.refused(name:, reason: too_big) ] if file.size.to_i > max_bytes

        parts_for(name, Maker::Previews::Dimensions.measure(name, file.read))
      rescue Maker::Previews::Dimensions::Unmeasurable => e
        [ Part.refused(name:, reason: e.message) ]
      rescue StandardError => e
        Rails.logger.warn("material upload #{name.inspect}: #{e.class}: #{e.message}")
        [ Part.refused(name:, reason: UNREADABLE) ]
      end

      def library_parts(user, nodes)
        return [] if nodes.empty?

        ids = nodes.map(&:node_id)
        infos = FileLayer.current.stat_all(user, node_ids: ids)
        rows = user.maker_previews.where(kind: "thumbnail", node_id: ids).with_attached_asset.index_by(&:node_id)
        nodes.flat_map { |node| library_part(user, node, infos[node.node_id], rows[node.node_id]) }
      end

      def library_part(user, node, info, row)
        return [ Part.refused(name: node.name, node_id: node.node_id, reason: GONE) ] if info.nil?

        parts_for(node.name, stored(row, node, info) || read(user, node, info), node_id: node.node_id)
      rescue Maker::Previews::Dimensions::Unmeasurable => e
        [ Part.refused(name: node.name, node_id: node.node_id, reason: e.message) ]
      rescue FileLayer::FetchError
        [ Part.refused(name: node.name, node_id: node.node_id, reason: UNREACHABLE) ]
      rescue FileLayer::NotFound
        [ Part.refused(name: node.name, node_id: node.node_id, reason: GONE) ]
      rescue StandardError => e
        Rails.logger.warn("material library #{node.node_id}: #{e.class}: #{e.message}")
        [ Part.refused(name: node.name, node_id: node.node_id, reason: UNREADABLE) ]
      end

      # The row's size, when the row is THIS build of THIS content; else nil, and the bytes decide.
      def stored(row, node, info)
        return nil unless row&.current_build?
        return nil unless Maker::Previews::Enqueue.current_preview?(row, name: node.name, version_id: info.content_token)

        row.metadata if Maker::Previews::Dimensions.from_metadata(row.metadata)
      end

      def read(user, node, info)
        raise Maker::Previews::Dimensions::Unmeasurable, too_big if info.size.to_i > max_bytes

        Maker::Previews::Dimensions.measure(node.name,
                                            Maker::FileBytes.read(user, node_id: node.node_id, version_id: info.content_token))
      end

      # A one-page file is one part; a multi-page file one part per page with something on it,
      # since its pages are cut as separate jobs.
      def parts_for(name, metadata, node_id: nil)
        facts = Maker::Previews::Dimensions.from_metadata(metadata)
        return [ Part.refused(name:, node_id:, reason: Maker::Previews::Dimensions::NO_SHAPES) ] if facts.nil?

        pages = facts.multi_page? ? facts.sized_pages : facts.pages
        pages.map do |page|
          Part.measured(name:, node_id:, page: (page.name if facts.multi_page?), width: page.width, height: page.height)
        end
      end

      def measurable(scope)
        scope.select(:node_id, :name).to_a
             .select { |node| Maker::Previews::Dimensions.measurable_name?(node.name) }
             .sort_by { |node| [ node.name.downcase, node.node_id ] }
      end

      def missing(what) = Added.new(parts: [], notes: [ "Found no such #{what}." ])

      def too_big = "over the #{ActiveSupport::NumberHelper.number_to_human_size(max_bytes)} limit"
    end
  end
end
```

- [ ] **Step 4: Run to see it pass.** Green. The oversize test's exact phrase comes from
  `number_to_human_size(10)` → "10 Bytes"; adjust the regex only if that helper answers differently,
  and say so.

- [ ] **Step 5: Mutation-check (report each output)**

1. `stored` drops the `current_preview?` line → the revision-1 half of "a library file's current
   thumbnail row…" RED.
2. `folder` uses `user.nodes.present.where(kind: "file", parent_node_id: folder.node_id)` (no
   subtree) → the folder test RED (the `lids/` file vanishes).
3. `project` drops `.where(node_id: …attachments…)` → "a project adds its ATTACHED…" RED.
4. `upload_parts` reads before checking the size → the oversize test RED ("read an oversized upload").

- [ ] **Step 6: Commit** — "The material estimate takes parts from uploads, a project, a folder or a file".

---

### Task 7: The built-in tool's plumbing — route, pin, rail, gallery card, reserved keys

**Files:**
- Modify: `config/routes.rb` (after `get "tools/open_with"`, line ~550)
- Modify: `app/models/maker/tool_pins.rb`, `app/controllers/tools/pins_controller.rb`
- Modify: `app/views/layouts/_rail.html.erb:88-100`, `app/helpers/shell_helper.rb:206-210`
- Modify: `app/services/maker/addons/registry.rb` (`RESERVED_KEYS`, `problem_with`)
- Modify: `app/views/tools/home/index.html.erb` (a second built-in card)
- Modify: `docs/addon-api-v1.md` (§2 Required keys), `docs/invariants/addons.md` (one bullet)
- Test: `test/services/maker/addons/registry_test.rb`, `test/integration/web/tool_pins_test.rb`

No controller exists until Task 8; nothing in this task requests `/tools/material`.

- [ ] **Step 1: Write the failing tests**

Append to `test/services/maker/addons/registry_test.rb`:

```ruby
      # A BUILT-IN TOOL'S KEY IS NOT AN ADDON'S. `material` has its own page routed above
      # `tools/:key`, so an addon keyed it would be unreachable with nothing to say why; `calculator`
      # is the built-in calculator's pin key. Refused like any other problem: skipped, and reported.
      %w[material calculator].each do |key|
        test "an addon keyed #{key} is skipped and reported, because a built-in tool answers to it" do
          Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("key" => key) ])
          Rails.cache.clear

          assert_empty Registry.all
          assert_equal [ { key:, reason: "key #{key.inspect} is reserved for a built-in tool" } ], Registry.problems
        end
      end
```

(`Registry.problems` answers `{ key:, reason: }` with symbol keys — checked against that file's
"problems reports each skipped manifest by key" test.)

Append to `test/integration/web/tool_pins_test.rb`:

```ruby
    test "the Material estimate is a built-in card on the Tools page, and it pins like the calculator" do
      get tools_path
      assert_select "div.tool-card#material[data-tool-pin-url=?]", tools_pin_path("material") do
        assert_select "a.btn[href=?]", tools_material_path, text: "Open material estimate"
      end

      post tools_pin_path("material")
      assert_equal [ { "key" => "material" } ], @user.reload.pinned_tools,
                   "a built-in's name lives in Maker::ToolPins, never in the row"

      get tools_path
      assert_select "aside.rail a.rail-tool-pin[href=?]", tools_material_path, text: "Material estimate"
    end
```

- [ ] **Step 2: Run to see them fail** — `tools_material_path` is undefined; the registry serves the
  reserved-key addon.

- [ ] **Step 3: Routes** — insert after `get "tools/open_with", …`:

```ruby
  # THE MATERIAL ESTIMATE (2026-11-22; spec 2026-11-22-material-estimate-design.md), a BUILT-IN tool
  # with a page of its own. Two-segment `/tools/*` routes, so ABOVE `tools/:key` for the reason that
  # block states: below it, "material" is read as an addon key. The key is reserved in
  # Maker::Addons::Registry::RESERVED_KEYS, so no addon can be shadowed by these silently.
  get  "tools/material",         to: "tools/materials#show",    as: :tools_material
  post "tools/material",         to: "tools/materials#create"
  post "tools/material/measure", to: "tools/materials#measure", as: :tools_material_measure
```

- [ ] **Step 4: `Maker::ToolPins`**

Replace `CALCULATOR = "calculator".freeze` and the `Pin` definition with:

```ruby
    CALCULATOR = "calculator".freeze
    MATERIAL = "material".freeze

    # THE BUILT-IN TOOLS AND THEIR NAMES. A built-in's name lives here, not in the row, as the
    # calculator's always has; Maker::Addons::Registry::RESERVED_KEYS keeps an addon off these keys.
    BUILT_IN = { CALCULATOR => "Calculator", MATERIAL => "Material estimate" }.freeze

    Pin = Data.define(:key, :title) do
      def calculator? = key == CALCULATOR
      def material? = key == MATERIAL
      def built_in? = BUILT_IN.key?(key)

      # What the rail and the menus call it. An addon falls back to its key only if its copied title
      # was lost.
      def label = BUILT_IN[key] || title.presence || key
    end
```

Update the class comment's first line to say "the built-in calculator and Material estimate and any addon".

- [ ] **Step 5: `Tools::PinsController`**

```ruby
      current_user.tool_pins.pin!(key, title: Maker::ToolPins::BUILT_IN.key?(key) ? nil : title)
```

and in `pinnable_title`:

```ruby
    def pinnable_title(key)
      return Maker::ToolPins::BUILT_IN[key] if Maker::ToolPins::BUILT_IN.key?(key)
```

(the rest of the method unchanged).

- [ ] **Step 6: The rail and its light**

In `_rail.html.erb`, between the calculator branch's `<% end %>` of its `link_to` and the `<% else %>`,
add:

```erb
          <% elsif pin.material? %>
            <%= link_to tools_material_path, class: "rail-link rail-tool-pin", title: pin.label,
                        "aria-current": sidebar_aria([ :tool, pin.key ]), data: tool_menu_data(pin.key, pin.label) do %>
              <%= rail_icon(:tools) %><span class="rail-label"><%= pin.label %></span>
            <% end %>
```

and add one sentence to the comment above the loop: "THE MATERIAL ESTIMATE is a page, so it links
and lights like an addon's, at its own route."

In `shell_helper.rb`'s `when "tools"` arm, after the `key = params[:key]…` line, add:

```ruby
        key = Maker::ToolPins::MATERIAL if controller_path == "tools/materials"
```

and extend the arm's comment: "The Material estimate is a page and lights the same way."

- [ ] **Step 7: Reserved keys** — `app/services/maker/addons/registry.rb`, beside `REQUIRED`:

```ruby
      # KEYS A BUILT-IN TOOL ALREADY ANSWERS TO (Maker::ToolPins::BUILT_IN). `material` has its own
      # page at /tools/material, routed above `tools/:key`, so an addon keyed it would be unreachable
      # with nothing to say why; `calculator` is the built-in calculator's pin key, so pinning an
      # addon keyed it would pin the calculator. Refused like every problem: skipped and reported.
      RESERVED_KEYS = Maker::ToolPins::BUILT_IN.keys.freeze
```

and in `problem_with`, after the `missing` check:

```ruby
        key = manifest["key"].to_s
        return "key #{key.inspect} is reserved for a built-in tool" if RESERVED_KEYS.include?(key)
```

- [ ] **Step 8: The gallery card** — in `tools/home/index.html.erb`, inside the Built in
  `.tools-grid`, after the calculator card's `<% end %>`:

```erb
    <%# THE MATERIAL ESTIMATE (2026-11-22), the second built-in: a PAGE, unlike the calculator's
        modal, so its card links there. `.tool-card`, never `.addon-card`, for the reason above. %>
    <%= tag.div class: "tool-card", id: "material",
                data: tool_menu_data(Maker::ToolPins::MATERIAL, "Material estimate") do %>
      <span class="addon-card-head">
        <span class="addon-icon" aria-hidden="true"><%= rail_icon(:tools) %></span>
        <span class="addon-title" id="tool-title-material">Material estimate</span>
      </span>
      <span class="addon-desc muted">How many sheets of stock a set of SVG, LightBurn, DXF or MillMage
        files needs, with each part's size and the total area.</span>
      <div class="tool-card-actions">
        <%= link_to "Open material estimate", tools_material_path, class: "btn small" %>
        <%= render "tools/home/pin_toggle", key: Maker::ToolPins::MATERIAL, name: "Material estimate",
                                            label_id: "tool-title-material" %>
      </div>
    <% end %>
```

(`.tools-home .tool-card-actions` already shares `.calculator-card-actions`' rule in `pages/tools.css:22`.)

- [ ] **Step 9: Docs**

In `docs/addon-api-v1.md` §2's Required keys, under `key`, add: "**`calculator` and `material` are
reserved** for the host's built-in tools; a manifest using either is skipped and reported by
`addons:check`."

In `docs/invariants/addons.md`, add a bullet: "**A BUILT-IN TOOL'S KEY IS RESERVED
(`Registry::RESERVED_KEYS`, 2026-11-22).** `material` is routed above `tools/:key`, so an addon keyed
it would be shadowed silently; `calculator` is the calculator's pin key. `problem_with` refuses both,
so the skip is reported like any other problem."

- [ ] **Step 10: Run to see them pass**

Run: `LANG=en_US.UTF-8 LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/addons/registry_test.rb test/integration/web/tool_pins_test.rb test/integration/web/calculator_shell_test.rb test/controllers/tools/home_controller_test.rb test/integration/web/shell_chrome_test.rb`
Expected: green.

- [ ] **Step 11: Mutation-check (report each output)**

1. Remove `MATERIAL => …` from `BUILT_IN` → the pin test RED (the title is copied into the row, or
   the pin is refused).
2. Delete the `RESERVED_KEYS` line in `problem_with` → both registry tests RED.
3. Move the three material routes below `get "tools/:key"` → `bin/rails routes -g material` shows
   them after the wildcard; report it. (The request proof that the wildcard wins is Task 8's.)

- [ ] **Step 12: Commit** — "The Material estimate is a built-in tool: a route, a card, a pin, and a reserved key".

---

### Task 8: The page — controller, views, Stimulus, styles

**Files:**
- Create: `app/controllers/tools/materials_controller.rb`
- Create: `app/helpers/materials_helper.rb`
- Create: `app/views/tools/materials/show.html.erb`, `_parts.html.erb`, `_stock.html.erb`,
  `_results.html.erb`, `_sheet.html.erb`, `update.turbo_stream.erb`
- Create: `app/javascript/controllers/material_estimate_controller.js`
- Modify: `app/assets/stylesheets/pages/tools.css` (append a block inside `@layer pages`)
- Modify: `test/integration/web/template_hygiene_test.rb` (page list), `test/system/shell_test.rb:663` (375px list)
- Test: Create `test/integration/web/material_estimate_test.rb`

Depends on Tasks 5, 6, 7. Read `docs/invariants/design-system.md` rules 3, 10, 11, 12, 13 before
styling: no `primary` button on this page, component selectors stay in `components.css`, the table
scrolls inside its own container at 375 px, names use `overflow-wrap: anywhere`.

- [ ] **Step 1: Write the failing request test**

```ruby
require "test_helper"

module Web
  # THE MATERIAL ESTIMATE PAGE (spec 2026-11-22-material-estimate-design.md, Part 2), driven through
  # real requests. What only a browser can see — the debounced re-figure, the upload on change — is
  # test/system/material_estimate_test.rb's.
  class MaterialEstimateTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    # An explicit Accept rather than `as: :turbo_stream`, so a multipart upload body is left exactly
    # as Rack::Test builds it.
    STREAM = { "Accept" => "text/vnd.turbo-stream.html" }.freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "material-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      ActionController::Base.cache_store.clear
    end

    def upload(name) = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files", name), "application/octet-stream")

    def stock(width: "200", height: "100", gap: "0", unit: "mm", rotate: "0") = { sheet_width: width, sheet_height: height, gap:, unit:, rotate: }

    def part(name:, width:, height:, qty: "1", node_id: "", page: "", reason: "") = { name:, width:, height:, qty:, node_id:, page:, reason: }

    test "the page is a signed-in built-in tool, empty, with the default stock" do
      get tools_material_path
      assert_response :success
      assert_select "h1", text: "Material estimate"
      assert_select "form#material-form[action=?][data-controller=?]", tools_material_path, "material-estimate"
      assert_select "#material-parts p.material-empty"
      assert_select "input#sheet_width[value=?]", "300"
      assert_select "select#unit option[selected][value=?]", "mm"
      assert_select "input#rotate[checked]"
      assert_select "button[formaction=?]", tools_material_measure_path

      reset!
      get tools_material_path
      assert_response :redirect
    end

    # THE ROUTE BEATS THE ADDON WILDCARD (Task 7's routes): `tools/:key` would answer this with
    # Tools::AddonsController, a 404 for an unknown addon.
    test "/tools/material is the built-in page, not an addon lookup" do
      get "/tools/material"
      assert_equal "tools/materials", controller.controller_path
    end

    test "uploads are measured and nothing of them is kept" do
      # An Array of lambdas, never one lambda returning an Array: assert_difference adds the expected
      # difference to each value, and Array + 0 raises.
      assert_no_difference [ -> { Node.count }, -> { Maker::Preview.count }, -> { ActiveStorage::Blob.count } ] do
        post tools_material_measure_path, params: { uploads: [ upload("plate.svg"), upload("plate.dxf") ], **stock },
                                          headers: STREAM
      end
      assert_response :success
      assert_empty Dir.children(@root), "an upload reached the library"
      assert_select "turbo-stream[action=replace][target=material-parts]", 1
      assert_select "turbo-stream[action=replace][target=material-results]", 1
      assert_includes response.body, "plate.svg"
      assert_includes response.body, "plate.dxf"
      assert_includes response.body, "80 × 40"
      assert_includes response.body, %(name="parts[1][width]" value="80.0")
    end

    test "a quantity change re-figures the results and leaves the parts list alone" do
      post tools_material_path, params: { parts: { "0" => part(name: "a.svg", width: "100", height: "50", qty: "5") }, **stock },
                                headers: STREAM
      assert_response :success
      assert_select "turbo-stream[action=replace][target=material-parts]", 0
      assert_select "turbo-stream[action=replace][target=material-results]", 1
      assert_includes response.body, %(<dd class="material-sheet-count">2 × 200 × 100 mm</dd>)
      assert_includes response.body, "250 cm² · 38.8 in²"
      assert_includes response.body, "63%"
    end

    test "remove takes one row out and replaces the list" do
      post tools_material_path, params: { remove: "0", parts: { "0" => part(name: "gone.svg", width: "10", height: "10"),
                                                                "1" => part(name: "kept.svg", width: "10", height: "10") }, **stock },
                                headers: STREAM
      assert_select "turbo-stream[action=replace][target=material-parts]", 1
      refute_includes response.body, "gone.svg"
      assert_includes response.body, "kept.svg"
    end

    test "a folder of the user's own adds its files; another user's adds nothing and says so" do
      laser = create_node!(@user, node_id: SecureRandom.uuid, name: "laser", kind: "dir")
      plate = create_node!(@user, node_id: SecureRandom.uuid, name: "plate.svg", kind: "file", parent_node_id: laser.node_id,
                                  content_hash: SecureRandom.hex(8))
      @root.join(plate.storage_path).binwrite(File.binread(Rails.root.join("test/fixtures/files/plate.svg")))

      post tools_material_path, params: { add_folder_id: laser.node_id, **stock }, headers: STREAM
      assert_includes response.body, %(href="#{file_path(plate.node_id)}")

      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs", kind: "dir", mtime: 1, size: 0)
      post tools_material_path, params: { add_folder_id: theirs.node_id, **stock }, headers: STREAM
      assert_includes response.body, "Found no such folder."
    end

    test "a forged hidden size is refused on the row, not packed" do
      post tools_material_path, params: { parts: { "0" => part(name: "x.svg", width: "-5", height: "10") }, **stock },
                                headers: STREAM
      assert_includes response.body, "Nothing to lay out yet."
    end

    test "without JavaScript the same request renders the whole page" do
      post tools_material_path, params: { parts: { "0" => part(name: "a.svg", width: "100", height: "50", qty: "5") }, **stock }
      assert_response :success
      assert_select "h1", text: "Material estimate"
      assert_select "dd.material-sheet-count", text: "2 × 200 × 100 mm"
    end

    test "uploads are rate-limited per user, and the refusal keeps the list" do
      Tools::MaterialsController::UPLOADS_PER_MINUTE.times do
        post tools_material_measure_path, params: { uploads: [ upload("square.svg") ], **stock }, headers: STREAM
        assert_response :success
      end
      post tools_material_measure_path, params: { uploads: [ upload("square.svg") ], **stock,
                                                  parts: { "0" => part(name: "kept.svg", width: "10", height: "10") } },
                                        headers: STREAM
      assert_response :too_many_requests
      assert_includes response.body, "Paused uploads"
    end

    test "a pinned Material estimate lights its rail link on its own page" do
      post tools_pin_path("material")
      get tools_material_path
      assert_select "aside.rail a.rail-tool-pin[href=?][aria-current=page]", tools_material_path
    end
  end
end
```

Expected strings, worked: 5 × 100 × 50 = 25,000 mm² = 250 cm² = 38.75 in², which `round(1)` gives as
38.8; use 62.5 % shows as "63%" through `number_to_percentage(…, precision: 0)` (Ruby rounds half
away from zero). If `square.svg` (an 80 × 80 rect in a 100 px viewBox) measures differently from what
this test assumes, it does not matter: only the response codes are asserted there.

- [ ] **Step 2: Run to see it fail** — `uninitialized constant Tools::MaterialsController`.

- [ ] **Step 3: The controller**

```ruby
module Tools
  # THE MATERIAL ESTIMATE (2026-11-22; spec docs/superpowers/specs/2026-11-22-material-estimate-design.md),
  # a BUILT-IN tool with a page of its own: add flat files, give each a quantity, pick a sheet, and
  # read how many sheets they need, the total area, and a drawing of each sheet.
  #
  # STATELESS. The parts list rides in the form as hidden fields (tools/materials/_parts), so every
  # request rebuilds the estimate from what it sent (Maker::Material::Estimate) and nothing is saved.
  # Under Turbo a request answers with streams for the two regions it changed: the results always,
  # the parts list only when the list itself changed (an add, an upload, a remove) — replacing it on
  # a quantity edit would take the box being typed in away from under the cursor. Without
  # JavaScript the same request renders the whole page.
  #
  # UPLOADS HAVE THEIR OWN ACTION so they carry their own rate limit; re-figuring is arithmetic under
  # Estimate's caps and needs none.
  class MaterialsController < ApplicationController
    PART_FIELDS = %i[name node_id page width height qty reason].freeze
    STOCK_FIELDS = %i[sheet_width sheet_height gap unit rotate].freeze
    UPLOADS_PER_MINUTE = 20

    rate_limit to: UPLOADS_PER_MINUTE, within: 1.minute, by: -> { current_user.id }, only: :measure,
               name: "material-uploads", with: -> { too_many_uploads }

    def show
      @estimate = Maker::Material::Estimate.new(parts: [], stock: Maker::Material::Estimate::DEFAULT_STOCK)
      @projects = projects
    end

    def create
      estimate = submitted_estimate
      changed = false
      if params[:remove].present?
        estimate = estimate.without(Integer(params[:remove].to_s, 10, exception: false))
        changed = true
      end
      library_additions.each do |added|
        estimate = estimate.adding(added.parts, notes: added.notes)
        changed = true
      end
      render_estimate(estimate, parts_changed: changed)
    end

    def measure
      added = Maker::Material::Sources.uploads(params[:uploads])
      render_estimate(submitted_estimate.adding(added.parts, notes: added.notes), parts_changed: true)
    end

    private

    def submitted_estimate
      Maker::Material::Estimate.from_params(parts: params.permit(parts: PART_FIELDS).to_h["parts"],
                                            stock: params.permit(*STOCK_FIELDS).to_h)
    end

    def library_additions
      sources = Maker::Material::Sources
      [
        (sources.project(current_user, params[:add_project_id]) if params[:add_project_id].present?),
        (sources.folder(current_user, params[:add_folder_id]) if params[:add_folder_id].present?),
        (sources.file(current_user, params[:add_file_id]) if params[:add_file_id].present?)
      ].compact
    end

    def render_estimate(estimate, parts_changed:, status: :ok)
      @estimate = estimate
      @parts_changed = parts_changed
      @projects = projects
      respond_to do |format|
        format.turbo_stream { render :update, status: }
        format.html { render :show, status: }
      end
    end

    def too_many_uploads
      note = "Paused uploads: more than #{UPLOADS_PER_MINUTE} batches in a minute. Wait a minute, then add them again."
      render_estimate(submitted_estimate.with_note(note), parts_changed: false, status: :too_many_requests)
    end

    def projects = current_user.maker_projects.where.not(status: "archived").order(:name).pluck(:name, :id)
  end
end
```

- [ ] **Step 4: The helper**

```ruby
# THE MATERIAL ESTIMATE'S NUMBERS IN WORDS (tools/materials/*).
module MaterialsHelper
  SHEETS_DRAWN = 20
  SQ_IN_PER_SQ_FT = 144

  def material_area_text(mm2)
    in2 = mm2 / (Maker::Previews::Dimensions::MM_PER_INCH**2)
    text = "#{material_number(mm2 / 100.0)} cm² · #{material_number(in2)} in²"
    in2 >= SQ_IN_PER_SQ_FT ? "#{text} (#{material_number(in2 / SQ_IN_PER_SQ_FT, 2)} ft²)" : text
  end

  # Rounded, delimited, and without a trailing ".0": "250", "38.8", "1,234.5".
  def material_number(value, places = 1)
    rounded = value.round(places)
    number_with_delimiter(rounded == rounded.to_i ? rounded.to_i : rounded)
  end

  def material_stock_text(stock) = "#{recipe_num(stock.width)} × #{recipe_num(stock.height)} #{stock.unit}"

  def material_inches(width, height)
    [ width, height ].map { |mm| format("%.2f", mm / Maker::Previews::Dimensions::MM_PER_INCH) }.join(" × ")
  end

  # A label that fits inside its part on the drawing, as [text, font size in mm], or nil when the
  # part is too small to carry a readable one (its <title> still names it on hover).
  def material_sheet_label(placement, sheet_width)
    text = placement.item.label.truncate(28)
    size = [ placement.height * 0.4, placement.width / [ text.length * 0.62, 1 ].max, sheet_width / 25.0 ].min
    size >= sheet_width / 120.0 ? [ text, size.round(2) ] : nil
  end
end
```

`recipe_num` comes from `FilesHelper`; Rails includes every helper in every view here. Note
`material_stock_text` in `stock.unit` — `recipe_num(300.0)` → "300".

- [ ] **Step 5: The views**

`show.html.erb`:

```erb
<% content_for :title, "Material estimate — Tinkerex" %>
<div class="page-head"><h1>Material estimate</h1></div>

<%# ONE FORM, THREE REGIONS (Tools::MaterialsController explains the statelessness): the parts list
    and the results are replaced by turbo streams, the stock is never replaced, so the box being
    typed in stays put. `multipart: true` because the upload button submits this same form to
    tools_material_measure_path. `*_tag` helpers throughout, never a form builder's `fields_for`:
    a form with no model and no scope emits bracketed names a builder mangles (§14d). %>
<%= form_with url: tools_material_path, method: :post, multipart: true, id: "material-form",
              class: "material-estimate",
              data: { controller: "material-estimate",
                      action: "turbo:submit-start->material-estimate#submitStart turbo:submit-end->material-estimate#submitEnd" } do %>
  <%= render "tools/materials/parts", estimate: @estimate, projects: @projects %>
  <%= render "tools/materials/stock", stock: @estimate.stock %>
  <%= render "tools/materials/results", estimate: @estimate %>
<% end %>
```

`_parts.html.erb`:

```erb
<%# locals: (estimate:, projects:) %>
<%# THE PARTS LIST. Replaced whenever the list changes and never on a quantity edit. Everything the
    next request needs about a part rides in its row as hidden fields, because the server keeps no
    state; the upload input, the project select and both choosers live in here so the same replace
    clears them and a later re-figure cannot add them twice. A refused file stays, greyed, with its
    reason: dropping it would make the total describe fewer files than were added. %>
<section id="material-parts" class="material-parts" aria-labelledby="material-parts-head">
  <h2 id="material-parts-head">Parts</h2>

  <div class="material-add">
    <span class="material-add-field">
      <label for="material-uploads">Upload files</label>
      <%= file_field_tag "uploads[]", id: "material-uploads", multiple: true,
                         accept: Maker::Previews::Dimensions::EXTENSIONS.map { |ext| ".#{ext}" }.join(","),
                         data: { material_estimate_target: "uploads", action: "change->material-estimate#upload" } %>
      <%= button_tag "Measure uploads", type: "submit", formaction: tools_material_measure_path, class: "btn small",
                     data: { material_estimate_target: "measure" } %>
    </span>
    <% if projects.any? %>
      <label class="material-add-field">Add a project
        <%= select_tag "add_project_id", options_for_select(projects), include_blank: "Choose…",
                       data: { action: "change->material-estimate#add" } %>
      </label>
    <% end %>
    <span class="material-add-field" data-action="filechooser:choose->material-estimate#add">
      <%= render "shared/folder_field", name: "add_folder_id", children_url: library_children_path,
                                        mode: "folder", label: "Add a folder…", root_label: "Library" %>
      <%= render "shared/folder_field", name: "add_file_id", children_url: library_children_path,
                                        mode: "file", label: "Add a file…", root_label: "Library",
                                        extensions: Maker::Previews::Dimensions::EXTENSIONS %>
    </span>
  </div>

  <% if estimate.parts.empty? %>
    <p class="muted material-empty">Add SVG, LightBurn, DXF or MillMage files to see the material they need.</p>
  <% else %>
    <div class="material-table-scroll">
      <table class="material-parts-table">
        <thead>
          <tr><th>File</th><th class="num">Size (mm)</th><th class="num">Size (in)</th><th class="num">Qty</th><th aria-label="Remove"></th></tr>
        </thead>
        <tbody>
          <% estimate.parts.each_with_index do |part, i| %>
            <tr class="<%= "material-part--refused" unless part.measured? %>">
              <td class="material-part-name">
                <%= part.node_id ? link_to(part.name, file_path(part.node_id)) : part.name %>
                <% if part.page %><span class="muted"> · <%= part.page %></span><% end %>
                <% unless part.measured? %><span class="material-reason"><%= part.reason %></span><% end %>
                <%= hidden_field_tag "parts[#{i}][name]", part.name, id: nil %>
                <%= hidden_field_tag "parts[#{i}][node_id]", part.node_id, id: nil %>
                <%= hidden_field_tag "parts[#{i}][page]", part.page, id: nil %>
                <%= hidden_field_tag "parts[#{i}][width]", part.width, id: nil %>
                <%= hidden_field_tag "parts[#{i}][height]", part.height, id: nil %>
                <%= hidden_field_tag "parts[#{i}][reason]", part.reason, id: nil %>
              </td>
              <td class="num"><%= part.measured? ? "#{recipe_num(part.width)} × #{recipe_num(part.height)}" : "—" %></td>
              <td class="num"><%= part.measured? ? material_inches(part.width, part.height) : "—" %></td>
              <td class="num">
                <%= number_field_tag "parts[#{i}][qty]", part.qty, id: nil, min: 1, max: Maker::Material::Estimate::MAX_QTY,
                                     step: 1, class: "material-qty", disabled: !part.measured?,
                                     "aria-label": "Quantity of #{part.label}",
                                     data: { action: "input->material-estimate#refigure" } %>
              </td>
              <td><%= button_tag "Remove", type: "submit", name: "remove", value: i, class: "linkbtn small",
                                 "aria-label": "Remove #{part.label}" %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
  <% end %>
</section>
```

`_stock.html.erb`:

```erb
<%# locals: (stock:) %>
<%# THE STOCK. Never replaced by a stream, so typing here is never interrupted; the page's controller
    remembers these in this browser (localStorage, a convenience) and converts the three numbers when
    the unit changes. The hidden rotate=0 before the checkbox is what makes an untick reach the server. %>
<fieldset class="material-stock">
  <legend>Stock</legend>
  <label>Sheet width
    <%= number_field_tag "sheet_width", stock.width && recipe_num(stock.width), id: "sheet_width", step: "any", min: 0,
                         data: { material_estimate_target: "sheetWidth", action: "input->material-estimate#stockChanged" } %></label>
  <label>Sheet height
    <%= number_field_tag "sheet_height", stock.height && recipe_num(stock.height), id: "sheet_height", step: "any", min: 0,
                         data: { material_estimate_target: "sheetHeight", action: "input->material-estimate#stockChanged" } %></label>
  <label>Gap
    <%= number_field_tag "gap", recipe_num(stock.gap), id: "gap", step: "any", min: 0,
                         data: { material_estimate_target: "gap", action: "input->material-estimate#stockChanged" } %></label>
  <label>Unit
    <%= select_tag "unit", options_for_select([ %w[mm mm], %w[in in] ], stock.unit), id: "unit",
                   data: { material_estimate_target: "unit", action: "change->material-estimate#stockChanged" } %></label>
  <label class="material-rotate">
    <%= hidden_field_tag "rotate", "0", id: nil %>
    <%= check_box_tag "rotate", "1", stock.rotate, id: "rotate",
                      data: { material_estimate_target: "rotate", action: "change->material-estimate#stockChanged" } %>
    Allow rotating parts 90°
  </label>
  <%= button_tag "Update", type: "submit", class: "btn small", data: { material_estimate_target: "update" } %>
</fieldset>
```

`_results.html.erb`:

```erb
<%# locals: (estimate:) %>
<%# THE RESULTS, replaced on every request. `aria-live` so a screen reader hears the new count. %>
<section id="material-results" class="material-results" aria-live="polite" aria-labelledby="material-results-head">
  <h2 id="material-results-head">Material</h2>
  <% estimate.notes.each do |note| %>
    <p class="material-note"><%= note %></p>
  <% end %>

  <% if estimate.errors.any? %>
    <div class="form-errors flash-alert" role="alert">
      <% estimate.errors.each do |error| %><p><%= error %></p><% end %>
    </div>
  <% elsif estimate.measured_parts.empty? %>
    <p class="muted">Nothing to lay out yet.</p>
  <% else %>
    <dl class="material-summary">
      <dt>Sheets</dt><dd class="material-sheet-count"><%= estimate.sheets.size %> × <%= material_stock_text(estimate.stock) %></dd>
      <dt>Part area</dt><dd><%= material_area_text(estimate.total_area_mm2) %></dd>
      <% if estimate.utilization %>
        <dt>Sheet use</dt><dd><%= number_to_percentage(estimate.utilization * 100, precision: 0) %></dd>
      <% end %>
      <dt>Copies</dt><dd><%= estimate.copies %></dd>
    </dl>

    <% if estimate.unplaced.any? %>
      <div class="form-errors flash-alert material-unplaced" role="status">
        <p>Too big for this sheet:</p>
        <ul>
          <% estimate.unplaced.each do |part, count| %>
            <li><%= part.label %> (<%= recipe_num(part.width) %> × <%= recipe_num(part.height) %> mm)<%= " × #{count}" if count > 1 %></li>
          <% end %>
        </ul>
      </div>
    <% end %>

    <div class="material-sheets">
      <% estimate.sheets.first(MaterialsHelper::SHEETS_DRAWN).each_with_index do |placements, i| %>
        <%= render "tools/materials/sheet", placements:, stock: estimate.stock, number: i + 1 %>
      <% end %>
    </div>
    <% if estimate.sheets.size > MaterialsHelper::SHEETS_DRAWN %>
      <p class="muted">Drew the first <%= MaterialsHelper::SHEETS_DRAWN %> of <%= estimate.sheets.size %> sheets.</p>
    <% end %>
    <p class="muted material-caveat">Each part is laid out by its bounding box. Nesting software that
      follows the real outline can often fit round or irregular parts tighter.</p>
  <% end %>
</section>
```

`_sheet.html.erb` (every label is ERB-escaped; never `raw`/`html_safe` — filenames are user input):

```erb
<%# locals: (placements:, stock:, number:) %>
<% w = stock.width_mm %>
<% h = stock.height_mm %>
<figure class="material-sheet">
  <svg class="material-sheet-svg" viewBox="0 0 <%= recipe_num(w) %> <%= recipe_num(h) %>" role="img"
       aria-label="Sheet <%= number %>: <%= pluralize(placements.size, "part") %>">
    <rect class="material-sheet-stock" x="0" y="0" width="<%= recipe_num(w) %>" height="<%= recipe_num(h) %>"/>
    <% placements.each do |pl| %>
      <g class="material-sheet-part">
        <title><%= pl.item.label %>, <%= recipe_num(pl.width) %> × <%= recipe_num(pl.height) %> mm<%= ", rotated" if pl.rotated %></title>
        <rect x="<%= recipe_num(pl.x) %>" y="<%= recipe_num(pl.y) %>" width="<%= recipe_num(pl.width) %>" height="<%= recipe_num(pl.height) %>"/>
        <% if (label = material_sheet_label(pl, w)) %>
          <text x="<%= recipe_num(pl.x + pl.width / 2) %>" y="<%= recipe_num(pl.y + pl.height / 2) %>"
                font-size="<%= label.last %>" text-anchor="middle" dominant-baseline="central"><%= label.first %></text>
        <% end %>
      </g>
    <% end %>
  </svg>
  <figcaption>Sheet <%= number %> · <%= pluralize(placements.size, "part") %></figcaption>
</figure>
```

`update.turbo_stream.erb`:

```erb
<% if @parts_changed %>
  <%= turbo_stream.replace "material-parts", partial: "tools/materials/parts",
                                             locals: { estimate: @estimate, projects: @projects } %>
<% end %>
<%= turbo_stream.replace "material-results", partial: "tools/materials/results", locals: { estimate: @estimate } %>
```

- [ ] **Step 6: The Stimulus controller** — `app/javascript/controllers/material_estimate_controller.js`

```js
import { Controller } from "@hotwired/stimulus"

// THE MATERIAL ESTIMATE PAGE (tools/materials/show; spec 2026-11-22-material-estimate-design.md).
// It submits the one form at the right moments and nothing else — the server does every measurement
// and every sum. A number typed re-figures after a pause; picking files submits them to the measure
// action; a project or a chosen folder or file adds at once.
//
// ONE SUBMISSION AT A TIME. Two in flight can answer out of order, and an older answer landing last
// would put stale results on screen. A re-figure asked for during one is held and sent once it ends.
//
// The stock is remembered in this browser — a convenience, so every read and write is wrapped: a
// private window or blocked storage must leave the page working.
const STOCK_KEY = "tinkerex.material.stock"
const MM_PER = { mm: 1, in: 25.4 }
const PAUSE_MS = 300

export default class extends Controller {
  static targets = [ "sheetWidth", "sheetHeight", "gap", "unit", "rotate", "uploads", "measure", "update" ]

  connect() {
    this.inFlight = false
    this.pending = null
    this.restoreStock()
    this.unit = this.unitTarget.value
  }

  disconnect() { clearTimeout(this.timer) }

  // The no-JavaScript buttons, hidden once this controller can do their job. A target callback, not
  // connect(): the parts list is replaced by a stream and its Measure button comes back with it.
  measureTargetConnected(button) { button.hidden = true }
  updateTargetConnected(button) { button.hidden = true }

  refigure() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.submit(null), PAUSE_MS)
  }

  stockChanged(event) {
    if (event.target === this.unitTarget) this.convertUnit()
    this.saveStock()
    this.refigure()
  }

  add() {
    clearTimeout(this.timer)
    this.submit(null)
  }

  upload() {
    if (!this.uploadsTarget.files.length) return
    clearTimeout(this.timer)
    this.submit(this.measureTarget)
  }

  submitStart() { this.inFlight = true }

  submitEnd() {
    this.inFlight = false
    if (this.pending === null) return
    const submitter = this.pending === "form" ? null : this.pending
    this.pending = null
    this.submit(submitter)
  }

  submit(submitter) {
    if (this.inFlight) {
      // An upload outranks a held re-figure: it is the one carrying something new.
      if (submitter || this.pending === null) this.pending = submitter || "form"
      return
    }
    submitter ? this.element.requestSubmit(submitter) : this.element.requestSubmit()
  }

  convertUnit() {
    const from = MM_PER[this.unit]
    const to = MM_PER[this.unitTarget.value]
    if (from && to && from !== to) {
      for (const input of [ this.sheetWidthTarget, this.sheetHeightTarget, this.gapTarget ]) {
        const value = parseFloat(input.value)
        if (Number.isFinite(value)) input.value = String(Math.round((value * from / to) * 1000) / 1000)
      }
    }
    this.unit = this.unitTarget.value
  }

  restoreStock() {
    let saved = null
    try { saved = JSON.parse(localStorage.getItem(STOCK_KEY) || "null") } catch { saved = null }
    if (!saved || typeof saved !== "object") return

    if (saved.unit in MM_PER) this.unitTarget.value = saved.unit
    const fields = [ [ "width", this.sheetWidthTarget ], [ "height", this.sheetHeightTarget ], [ "gap", this.gapTarget ] ]
    for (const [ key, input ] of fields) {
      if (typeof saved[key] === "string" && saved[key] !== "") input.value = saved[key]
    }
    if (typeof saved.rotate === "boolean") this.rotateTarget.checked = saved.rotate
  }

  saveStock() {
    try {
      localStorage.setItem(STOCK_KEY, JSON.stringify({
        unit: this.unitTarget.value, width: this.sheetWidthTarget.value, height: this.sheetHeightTarget.value,
        gap: this.gapTarget.value, rotate: this.rotateTarget.checked,
      }))
    } catch {
      // Storage refused (a private window, blocked site data): the page works without remembering.
    }
  }
}
```

- [ ] **Step 7: Styles** — append inside `@layer pages { … }` in `app/assets/stylesheets/pages/tools.css`:

```css
  /* --- The Material estimate (built in, /tools/material; 2026-11-22) --- */
  .material-estimate { display: grid; gap: var(--space-5); }
  .material-estimate h2 { margin: 0 0 var(--space-3); font-size: 15px; }
  .material-add { display: flex; flex-wrap: wrap; gap: var(--space-3); align-items: center; margin-bottom: var(--space-3); }
  .material-add-field { display: inline-flex; flex-wrap: wrap; gap: var(--space-2); align-items: center; }
  /* A table keeps its width and scrolls inside its own container at phone width (design-system rule 11). */
  .material-table-scroll { overflow-x: auto; }
  .material-parts-table { width: 100%; border-collapse: collapse; }
  .material-parts-table th, .material-parts-table td { padding: 6px 8px; border-bottom: 1px solid var(--line); text-align: left; vertical-align: top; }
  .material-parts-table .num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .material-part-name { overflow-wrap: anywhere; }
  .material-qty { width: 5.5em; }
  .material-part--refused { color: var(--fg-muted); }
  .material-reason { display: block; font-size: 12px; color: var(--fg-muted); }
  .material-stock { display: flex; flex-wrap: wrap; gap: var(--space-3); align-items: end; margin: 0;
                    padding: var(--space-3); border: 1px solid var(--line); border-radius: var(--radius-panel); }
  .material-stock label { display: inline-flex; flex-direction: column; gap: 4px; font-size: 13px; }
  .material-stock input[type="number"] { width: 7em; }
  .material-stock .material-rotate { flex-direction: row; align-items: center; }
  .material-summary { display: grid; grid-template-columns: max-content 1fr; gap: 4px var(--space-3); margin: 0 0 var(--space-3); }
  .material-summary dd { margin: 0; font-variant-numeric: tabular-nums; }
  .material-note { margin: 0 0 var(--space-2); }
  .material-sheets { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: var(--space-3); }
  .material-sheet { margin: 0; }
  .material-sheet figcaption { font-size: 12px; color: var(--fg-muted); margin-top: 4px; }
  .material-sheet-svg { display: block; width: 100%; height: auto; }
  /* Drawing colours, through tokens so the sheet follows the theme; strokes stay a pixel at any scale. */
  .material-sheet-stock { fill: var(--surface); stroke: var(--fg-muted); stroke-width: 1px; vector-effect: non-scaling-stroke; }
  .material-sheet-part rect { fill: var(--soft); stroke: var(--fg); stroke-width: 1px; vector-effect: non-scaling-stroke; }
  .material-sheet-part text { fill: var(--fg); font-family: var(--font-ui); }
```

- [ ] **Step 8: The page in the cross-page guards**

In `test/integration/web/template_hygiene_test.rb`, add `"material estimate" => tools_material_path,`
beside `"tools gallery" => tools_path,`. In `test/system/shell_test.rb:663`, add
`tools_material_path` to the 375 px page list after `tools_path`.

- [ ] **Step 9: Run to see it pass**

Run: `LANG=en_US.UTF-8 LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/material_estimate_test.rb test/integration/web/template_hygiene_test.rb test/stimulus_hygiene_test.rb test/css_hygiene_test.rb test/notice_grammar_test.rb test/no_emoji_test.rb`
Then: `LANG=en_US.UTF-8 LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/shell_test.rb`
Expected: green. (design-system.md rule 13 names an `accent_spend_test.rb`; no such file exists on
`origin/main` at `909d755a`, so there is no accent guard to register this page with. The page spends
no accent: every button is a plain `.btn`.)

- [ ] **Step 10: Mutation-check (report each output)**

1. `create` sets `changed = true` unconditionally → "a quantity change re-figures the results and
   leaves the parts list alone" RED.
2. Drop `only: :measure` from `rate_limit` → report what goes red (the rate test still passes; the
   request tests of `create` may 429 after 20 posts — none post 20, so expect GREEN, and say so).
3. `Sources.uploads` writes the upload through the port (temporarily add
   `FileLayer.current.write(...)`) → "uploads are measured and nothing of them is kept" RED. Restore.
4. Move the three routes below `get "tools/:key"` → "/tools/material is the built-in page" RED.
5. In `_sheet.html.erb`, print the label with `raw` → `template_hygiene_test` or a new probe: post a
   part named `<b>x</b>.svg` and assert the body holds `&lt;b&gt;`. Add that assertion to
   "a quantity change…" if nothing reds, and re-run the mutation.

- [ ] **Step 11: Commit** — "The Material estimate page measures parts and lays them out on sheets".

---

### Task 9: The browser test

**Files:**
- Create: `test/system/material_estimate_test.rb`

Depends on Task 8. Worked layout: 80 × 40 parts on 200 × 100 with gap 0 and no rotation fit 2
across × 2 down = 4 per sheet. Two uploads → 1 sheet; one quantity set to 5 → 6 copies → 2 sheets;
a 400 mm wide sheet holds 5 × 2 = 10 → 1 sheet.

- [ ] **Step 1: Write the test**

```ruby
require "application_system_test_case"

# THE MATERIAL ESTIMATE IN A BROWSER (spec 2026-11-22). What only a browser can see: that picking
# files submits them to the measure action on its own, that a typed quantity or sheet size re-figures
# after its pause without a click, that the parts list survives a stock edit (it is not replaced),
# and that the stock is remembered across a reload. The arithmetic is estimate_test.rb's and
# sheet_pack_test.rb's; the doors are material_estimate_test.rb's (integration).
class MaterialEstimateTest < ApplicationSystemTestCase
  setup do
    use_fresh_share_library!
    @user = sign_in_as("material-estimate@example.com")
  end

  def fixture(name) = Rails.root.join("test/fixtures/files", name).to_s

  test "uploading two drawings lists them, and a quantity or a sheet size re-figures the sheets" do
    visit tools_material_path
    fill_in "sheet_width", with: "200"
    fill_in "sheet_height", with: "100"
    fill_in "gap", with: "0"
    uncheck "rotate"

    attach_file "material-uploads", [ fixture("plate.svg"), fixture("plate.dxf") ]
    assert_selector ".material-parts-table tbody tr", count: 2
    assert_selector ".material-parts-table", text: "80 × 40"
    assert_selector ".material-sheet-count", text: /\A1 × 200 × 100 mm\z/

    find("input[aria-label='Quantity of plate.svg']").set("5")
    assert_selector ".material-sheet-count", text: /\A2 × 200 × 100 mm\z/
    assert_selector "svg.material-sheet-svg", count: 2

    fill_in "sheet_width", with: "400"
    assert_selector ".material-sheet-count", text: /\A1 × 400 × 100 mm\z/
    assert_selector ".material-parts-table tbody tr", count: 2, wait: 0

    visit tools_material_path
    assert_field "sheet_width", with: "400"
    assert_no_console_errors
  end

  test "a unit switch converts the stock rather than reinterpreting it" do
    visit tools_material_path
    fill_in "sheet_width", with: "254"
    select "in", from: "unit"
    assert_field "sheet_width", with: "10"
    assert_no_console_errors
  end
end
```

- [ ] **Step 2: Run it**

Run: `LANG=en_US.UTF-8 LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/material_estimate_test.rb`
Expected: green.

- [ ] **Step 3: Mutation-check (report each output)**

1. `upload()` returns early always → the first test RED (no rows appear).
2. `refigure()` never submits → RED at the quantity step.
3. `restoreStock()` returns at once → RED at the reload's `assert_field`.
4. `measureTargetConnected` removed → report whether anything reds; if not, assert
   `assert_no_selector "button", text: "Measure uploads"` after the upload and re-run.

- [ ] **Step 4: Commit** — "The Material estimate re-figures in the browser as you type".

---

### Task 10: Close-out

- [ ] **Step 1: Amend the spec** — in
  `docs/superpowers/specs/2026-11-22-material-estimate-design.md`, two sentences the plan refined:
  - "walked by the parent edge (`FileLayer::Subtree`), never under `.git`, sorted by path" →
    "… sorted by name (a chunk_remote node has no stored path, and building one is a parent walk per
    file)".
  - Under "Which row the file page reads": "The facts row reads `@thumbnail.metadata` exactly as the
    recipe panel beside it does today" → "The facts row reads a **showable** row's metadata only
    (`FilesHelper#file_dimensions`): Enqueue repoints a row at new content without clearing its
    metadata, so a pending row still holds the previous content's size. A rebuilding row is a
    rebuild of the same content and shows."

- [ ] **Step 2: Sweep** — `grep -rn "Job size" app test docs` and `grep -rn "Svg.render" app docs`;
  every hit must describe the new behaviour.

- [ ] **Step 3: Full gates** — from the worktree, with the sibling sync repo:

```bash
TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci
```

Run it last and read its own ✅/❌ lines, not a trailing exit code (memory: background bin/ci hides
its exit code). All three backend legs must report identical RUN counts; `bin/ci` compares them.

- [ ] **Step 4: Finish** — `/finish-branch` (commit, push, open the PR stating what was and was not
  verified), then `bin/log arc --from-pr <n>`. Merging needs the owner's go-ahead.
