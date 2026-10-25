require "test_helper"

module Maker
  module Previews
    # PAGES — LightBurn 2.2 and MillMage 0.9 hold several designs in one file (see Lbrn2.pages).
    #
    # `pages.lbrn2` is a real LightBurn 2.2.00 save; its header lists the three hand edits. Its
    # second page sits OUTSIDE the first page's box on purpose: stacked, the three pages measure
    # 355 x 50 mm, page 1 alone 205 x 50 and page 2 alone 50 x 50, so a walk that still stacks the
    # pages cannot pass an assertion about any one of them by coincidence.
    class LbrnPagesTest < ActiveSupport::TestCase
      setup do
        @bytes = File.binread(Rails.root.join("test/fixtures/files/pages.lbrn2"))
        @doc = Lbrn2.parse_document(@bytes)
      end

      test "reads the root's shapes as page 1 and each SubType=Page group as a page after it" do
        pages = Lbrn2.pages(@doc)
        assert_equal [ [ 0, "Page 1" ], [ 1, "Back" ], [ 2, "Page 3" ] ], pages.map { |p| [ p.index, p.name ] }
        assert_equal "LightBurnProject", pages[0].node.name
        assert_equal "Children", pages[1].node.name
      end

      test "a file without pages is one page named Page 1, and its walk is unchanged" do
        doc = Lbrn2.parse_document(File.binread(Rails.root.join("test/fixtures/files/real-export.lbrn2")))
        assert_equal [ "Page 1" ], Lbrn2.pages(doc).map(&:name)
        assert_equal 0, Lbrn2.current_page(doc)
        assert_equal Lbrn2.job_size(doc), Lbrn2.job_size(doc, page: 0)
      end

      test "the saved page comes from CurrentPage, and an index naming no page falls back to the first" do
        assert_equal 1, Lbrn2.current_page(@doc)
        %w[7 -1 x].each do |bad|
          doc = Lbrn2.parse_document(@bytes.sub('CurrentPage="1"', %(CurrentPage="#{bad}")))
          assert_equal 0, Lbrn2.current_page(doc), "CurrentPage=#{bad.inspect}"
        end
      end

      # THE BUG THIS FIXES: a page group read as an ordinary Group, so every page was drawn into
      # page 1's coordinate space. Each yield names its page, and no page's shape reaches another's.
      test "each_geometry tags every shape with its page and never walks a page as a group of page 1" do
        seen = []
        Lbrn2.each_geometry(@doc) do |cut, points, _closed, _ellipse, _image, _id, _segments, page|
          seen << [ page, cut, points.map(&:first).minmax.map(&:round) ]
        end
        assert_equal [ [ 0, "0", [ 70, 130 ] ], [ 0, "2", [ 225, 275 ] ], [ 1, "2", [ 375, 425 ] ] ], seen
      end

      # The copy's circle has no <VertList> of its own: VertID="0" instances page 1's. A
      # GeometryIndex built per page would drop it, and page 2 would read as empty.
      test "instancing reaches across pages" do
        assert_equal({ "width" => 50.0, "height" => 50.0 }, Lbrn2.job_size(@doc, page: 1))
      end

      test "page sizes are measured per page, and an empty page has none" do
        assert_equal({ 0 => { "width" => 205.0, "height" => 50.0 },
                       1 => { "width" => 50.0, "height" => 50.0 },
                       2 => nil }, Lbrn2.page_sizes(@doc))
        assert_equal({ "width" => 355.0, "height" => 50.0 }, Lbrn2.job_size(@doc),
                     "page: nil still measures every page together")
      end

      # LightBurn's own embedded thumbnail pictures the saved page alone, so the fallback that
      # stands in for it must too. Page 2 is one circle; stacked, the drawing held three shapes.
      test "the outline thumbnail draws only the saved page" do
        svg = Lbrn2.to_svg(@bytes)
        assert_equal 1, svg.scan(/<(?:polygon|polyline|ellipse|path)\b/).length
        assert_match(/viewBox="373 -227 54 54"/, svg, "framed on page 2's circle at x 375..425")
      end

      test "a page group is not counted as a shape" do
        assert_equal 3, Lbrn2.shape_count(@doc)
      end

      test "LightBurn metadata lists each page with its size and marks the saved one" do
        meta = LbrnMetadata.parse(@bytes)
        assert_equal [ { "name" => "Page 1", "job" => { "width" => 205.0, "height" => 50.0 } },
                       { "name" => "Back", "job" => { "width" => 50.0, "height" => 50.0 }, "current" => true },
                       { "name" => "Page 3" } ], meta["pages"]
        assert_equal({ "width" => 50.0, "height" => 50.0 }, meta["job"],
                     "the job size is the saved page's — the page the thumbnail beside it pictures")
        assert_equal 3, meta["shape_count"]
      end

      test "a one-page file's metadata carries no pages key" do
        meta = LbrnMetadata.parse(File.binread(Rails.root.join("test/fixtures/files/laser-settings.lbrn2")))
        assert_not meta.key?("pages")
      end

      test "the geometry payload carries each page's own job box and tags every shape with its page" do
        payload = JSON.parse(LbrnGeometry.render(@bytes)[:bytes])
        assert_equal 1, payload["page"]
        assert_equal [ "Page 1", "Back", "Page 3" ], payload["pages"].map { |p| p["name"] }
        assert_equal [ [ 205.0, 50.0 ], [ 50.0, 50.0 ], [ 0.0, 0.0 ] ],
                     payload["pages"].map { |p| [ p["job"]["w"], p["job"]["h"] ] }
        assert_equal [ 0, 0, 1 ], payload["shapes"].map { |s| s["pg"] }
        assert_equal 355.0, payload["job"]["w"], "the top-level job stays the union of every shape"
      end

      # THE ONE-TRAVERSAL RULE, PER PAGE: each page's shapes union to that page's job box, and that
      # box agrees with the size the panel reports for the same page.
      test "each page's shapes union to its own job box, and to the panel's size for that page" do
        payload = JSON.parse(LbrnGeometry.render(@bytes)[:bytes])
        sizes = Lbrn2.page_sizes(@doc)
        payload["pages"].each_with_index do |page, i|
          boxes = payload["shapes"].select { |s| s["pg"] == i }.map { |s| s["b"] }
          next assert_nil(sizes[i], "page #{i} has no shapes") if boxes.empty?

          assert_equal [ boxes.map { |b| b[0] }.min, boxes.map { |b| b[1] }.min ], [ page["job"]["x"], page["job"]["y"] ]
          assert_equal [ sizes[i]["width"], sizes[i]["height"] ], [ page["job"]["w"], page["job"]["h"] ]
        end
      end

      test "a one-page payload carries no pages, no page and no pg — its bytes are what they were" do
        payload = JSON.parse(LbrnGeometry.render(File.binread(Rails.root.join("test/fixtures/files/real-export.lbrn2")))[:bytes])
        assert_equal %w[v job colors shapes], payload.keys
        assert payload["shapes"].none? { |s| s.key?("pg") }
      end

      # HAND-WRITTEN on LightBurn's layout (see the fixture's header) — this pins that MillMage goes
      # through the same reading, not that MillMage writes it this way.
      test "MillMage metadata and payload read pages the same way" do
        bytes = File.binread(Rails.root.join("test/fixtures/files/pages.mage"))
        meta = MageMetadata.parse(bytes)
        assert_equal [ { "name" => "Top", "job" => { "width" => 100.0, "height" => 60.0 }, "current" => true },
                       { "name" => "Bottom", "job" => { "width" => 20.0, "height" => 20.0 } } ], meta["pages"]
        assert_equal 2, meta["shape_count"]

        payload = JSON.parse(LbrnGeometry.render(bytes)[:bytes])
        assert_equal 0, payload["page"]
        assert_equal [ 0, 1 ], payload["shapes"].map { |s| s["pg"] }
        assert_equal({}, payload["colors"], "MillMage still gets no LightBurn palette")
      end
    end
  end
end
