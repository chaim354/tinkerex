require "test_helper"

module Maker
  # FIGURE NUMBERS (the Shop manual spec §9 and §11.3): the core numbers figures where they first
  # appear, and the project page's walk hands it the page's figures in the page's order. Both pure:
  # the walk is driven with in-memory rows, dirs and a real Layout, no database and no port, so the
  # three backend legs run it the same. What the RENDERED page draws against this numbering is
  # test/integration/web/figure_numbers_test.rb's.
  class FigureNumbersTest < ActiveSupport::TestCase
    # --- the core ------------------------------------------------------------------------------

    test "a figure takes the next number where it first appears, and every member takes it" do
      numbers = FigureNumbers.build do |f|
        assert_equal 1, f.figure([ "a" ])
        assert_equal 2, f.figure(%w[b c d])
        assert_equal 3, f.figure([ "e" ])
      end
      assert_equal [ 1, 2, 2, 2, 3 ], %w[a b c d e].map { |id| numbers.number(id) }
      assert_equal 3, numbers.size
      assert_nil numbers.number("never-drawn")
    end

    test "a file drawn twice keeps the number of its first drawing, and takes no second" do
      numbers = FigureNumbers.build do |f|
        f.figure([ "cover" ], place: "hero")
        f.figure([ "a" ], place: "folder:x")
        assert_equal 1, f.figure([ "cover" ], place: "folder:x"), "the cover again, in its panel"
        f.figure([ "b" ], place: "folder:x")
      end
      assert_equal({ "cover" => 1, "a" => 2, "b" => 3 }, %w[cover a b].index_with { |id| numbers.number(id) })
      assert_equal %w[hero folder:x], numbers.places
    end

    test "a stack one of whose members is already numbered takes that member's number" do
      numbers = FigureNumbers.build do |f|
        f.figure([ "v2" ])
        f.figure([ "x" ])
        assert_equal 1, f.figure(%w[v3 v2 v1]), "the stack is the figure v2 already was"
      end
      assert_equal [ 1, 1, 1, 2 ], %w[v3 v2 v1 x].map { |id| numbers.number(id) }
      assert_equal 2, numbers.size
    end

    test "nothing numbers nothing" do
      numbers = FigureNumbers.build { |f| assert_nil f.figure([ nil ]) }
      assert numbers.empty?
      assert_not FigureNumbers.build.any?
    end

    # --- the project page's walk -----------------------------------------------------------------

    Node = Struct.new(:node_id, :name, :parent_node_id, :kind, :mtime, :size, keyword_init: true)
    Listing = Struct.new(:folder_id, :loose, :backups, :tree, keyword_init: true) do
      def all_rows = loose + backups + tree.flat_map { |d| flatten(d) }
      def row_for(id) = all_rows.find { |r| r.node_id == id }
      def flatten(dir) = dir.files + dir.children.flat_map { |c| flatten(c) }
    end
    Block = Struct.new(:kind, :node_id, keyword_init: true)

    ROOT = "root".freeze

    def row(id, name, parent, section: "")
      node = Node.new(node_id: id, name:, parent_node_id: parent, kind: "file", mtime: 1, size: 1)
      Maker::ProjectFolderListing::Row.new(node:, attachment: nil, linked: false, section:)
    end

    def dir(id, name, files: [], children: [], repo: false)
      Maker::ProjectFolderListing::Dir.new(node_id: id, name:, path: "Projects/p/#{name}", repo?: repo,
                                           children:, files:)
    end

    # A project folder holding two loose files, `laser/` (a stack of two versions and a file),
    # `design/` (a nested `design/old/` section and a nested repository) and `images/`.
    setup do
      @loose = [ row("readme", "README.md", ROOT), row("notes", "notes.txt", ROOT) ]
      @laser = dir("d-laser", "laser", files: [ row("box", "box.lbrn2", "d-laser", section: "laser"),
                                                row("box1", "box v1.lbrn2", "d-laser", section: "laser"),
                                                row("tile", "tile.lbrn2", "d-laser", section: "laser") ])
      old = dir("d-old", "old", files: [ row("plan", "plan.svg", "d-old", section: "design/old") ])
      repo = dir("d-fw", "firmware", repo: true, files: [ row("main", "main.c", "d-fw", section: "design/firmware") ])
      @design = dir("d-design", "design", files: [ row("cover", "cover.svg", "d-design", section: "design") ],
                                          children: [ old, repo ])
      @images = dir("d-images", "images", files: [ row("photo", "photo.png", "d-images", section: "images") ])
      @listing = Listing.new(folder_id: ROOT, loose: @loose, backups: [], tree: [ @laser, @design, @images ])
      @stacks = Maker::VersionStacks.group(
        @listing.all_rows.map { |r| Maker::VersionStacks::Entry.new(r.node_id, r.node.parent_node_id, r.node.name, "file", 1) }
      )
    end

    def layout(overrides = {})
      folders = [ [ "d-laser", false, nil ], [ "d-design", false, nil ], [ "d-images", false, nil ] ]
      Maker::ProjectKind.layout_for(kind: "other", overrides:, folders:)
    end

    def walk(layout: self.layout, cover_id: nil, photo_rows: [ @images.files.first ], stacks: @stacks, generated: {},
             linked_rows: [], blocks_by_key: {}, page_nodes: {})
      Maker::ProjectFigures.new(layout:, listing: @listing, cover_id:, generated:, readme_row_id: "readme", stacks:,
                                stacked_backups: {}, linked_rows:, photo_rows:, blocks_by_key:, page_nodes:).numbers
    end

    def numbered(numbers) = @listing.all_rows.map(&:node_id).index_with { |id| numbers.number(id) }.compact

    test "the page is numbered by panel order, then each panel's file order, a stack as one figure" do
      numbers = walk
      # Files: notes (the README is the README panel's); laser: the box stack, tile; design: cover,
      # then its nested old/ section; images: photo. Photos draws photo again, and it keeps its number.
      assert_equal({ "notes" => 1, "box" => 2, "box1" => 2, "tile" => 3, "cover" => 4, "plan" => 5, "photo" => 6 },
                   numbered(numbers))
      assert_equal 6, numbers.size
      assert_nil numbers.number("readme"), "the README panel renders the README; no panel draws it as a figure"
      assert_nil numbers.number("main"), "a repository nested in a panel is a closed browser, and draws no figure"
    end

    test "the cover is Fig. 1, and keeps 1 where its panel draws it again" do
      numbers = walk(cover_id: "cover")
      assert_equal 1, numbers.number("cover")
      assert_equal %w[notes box tile plan photo].map { |id| numbers.number(id) }, [ 2, 3, 4, 5, 6 ]
    end

    test "moving a panel moves its numbers: positional, never stored" do
      numbers = walk(layout: layout("order" => [ "readme", "folder:d-images", "attachments", "folder:d-laser", "folder:d-design" ]))
      assert_equal({ "photo" => 1, "notes" => 2, "box" => 3, "box1" => 3, "tile" => 4, "cover" => 5, "plan" => 6 },
                   numbered(numbers))
    end

    test "a panel with its stacks off numbers every version on its own" do
      unstacked = Maker::VersionStacks::EMPTY
      numbers = walk(layout: layout("unstacked" => [ "folder:d-laser" ]), stacks: unstacked)
      assert_equal [ 2, 3, 4 ], %w[box box1 tile].map { |id| numbers.number(id) }
    end

    test "a hidden panel and a panel in the browser draw no figure, and the numbers close up" do
      numbers = walk(layout: layout("hidden" => [ "folder:d-laser" ], "views" => { "folder:d-design" => "browser" }))
      assert_equal({ "notes" => 1, "photo" => 2 }, numbered(numbers))
    end

    test "an image the folder panels never draw is numbered where Photos draws it" do
      numbers = walk(layout: layout("hidden" => [ "folder:d-images" ]))
      assert_equal 6, numbers.number("photo")
      assert_equal "photos", numbers.figures.last.place
    end

    test "Generated, Backups and Linked follow Loose in the Files panel, in that order" do
      backup = row("bak", "tile_backup.lbrn2", "d-laser", section: "laser")
      @listing = Listing.new(folder_id: ROOT, loose: @loose, backups: [ backup ], tree: [ @laser, @design, @images ])
      linked = Maker::ProjectFolderListing::Row.new(node: Node.new(node_id: "far", name: "far.stl", parent_node_id: "elsewhere",
                                                                   kind: "file", mtime: 1, size: 1),
                                                   attachment: nil, linked: true, section: "Elsewhere")
      numbers = walk(generated: { "plan" => :state }, linked_rows: [ linked ],
                     layout: layout("order" => [ "attachments", "folder:d-laser", "folder:d-design", "folder:d-images" ]))
      assert_equal [ 1, 2, 3, 4 ], %w[notes plan bak far].map { |id| numbers.number(id) }
      assert_equal 5, numbers.number("box"), "the folder panels come after the whole Files panel"
    end

    test "an empty panel and an on-demand panel number nothing, and an image block numbers its picture" do
      blocks = { "block:pic" => Block.new(kind: "image", node_id: "plan"), "block:gone" => Block.new(kind: "image", node_id: "dead") }
      lay = Maker::ProjectKind.layout_for(kind: "other",
                                          overrides: { "order" => [ "block:pic", "block:gone", "tasks", "bom", "attachments" ] },
                                          folders: [ [ "d-laser", false, nil ], [ "d-design", false, nil ], [ "d-images", false, nil ] ],
                                          blocks: [ [ "pic", "image" ], [ "gone", "image" ] ])
      numbers = walk(layout: lay, blocks_by_key: blocks, page_nodes: { "plan" => :live })
      assert_equal 1, numbers.number("plan"), "the image block is first on the page"
      assert_equal 2, numbers.number("notes")
      assert_nil numbers.number("dead"), "a picture that is not live draws no block"
    end
  end
end
