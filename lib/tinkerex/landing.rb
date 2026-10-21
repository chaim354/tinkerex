module Tinkerex
  # THE MARKETING LANDING (2026-10-16; docs/superpowers/specs/2026-10-16-landing-format-wall-design.md).
  #
  # ON EXACTLY WHEN DEMO MODE IS. `/` shows the landing to a signed-out visitor only where
  # DEMO_ACCOUNT_EMAIL is set -- the public box alone (deploy_hygiene_test.rb). A self-hosted box has
  # nobody to pitch to, and the page's one action IS the demo. Read per request, never memoized, as
  # Tinkerex::Demo is: a test flips the variable between requests.
  #
  # THE WALL IS RENDERED, NEVER DRAWN. Each tile is the app's own preview of one file in the demo
  # seed, so the picture a stranger sees is the picture the library draws for that file, and the demo
  # they click into holds the same files. `render_wall` runs every tile's source through
  # Maker::Previews::Registry -- the calls GeneratePreviewJob makes -- and writes the PNGs the view
  # serves. It REFUSES rather than skips (a missing source, an extension no renderer claims, a
  # toolchain absent on this machine, a non-PNG result), and it writes NOTHING unless every tile
  # rendered: a wall with a hole in it, or one tile left over from an older run, is the failure to
  # fear. `bin/rails "landing:wall"` is the door; the recipe with every toolchain is Task 4 of
  # docs/superpowers/plans/2026-10-16-landing-format-wall.md.
  module Landing
    Error = Class.new(StandardError)

    INSTALL_URL = "https://github.com/chaim354/tinkerex/blob/main/docs/INSTALL.md".freeze
    SOURCE_URL = "https://github.com/chaim354/tinkerex".freeze

    # A tile's PNG is named for its source file, `<name>-<ext>.png`, so six LightBurn files are six
    # tiles and not one overwritten six times.
    Tile = Data.define(:source, :alt) do
      def ext = File.extname(source).delete_prefix(".").downcase
      def asset = "landing/wall/#{File.basename(source, ".*").parameterize}-#{ext}.png"
    end

    # Twice the tile's largest displayed size (about 128px), so it stays sharp on a 2x screen.
    SIZE = 256

    SEED_DIR = Rails.root.join("db/seeds/demo").freeze
    OUT_DIR = Rails.root.join("app/assets/images/landing/wall").freeze

    # Twelve files from the owner's `catan` project, a laser-cut board-game set (2026-10-16). Every
    # file of the project is in the demo seed; these are the twelve the wall shows.
    TILES = [
      Tile.new(source: "Projects/catan/laser/hex tiles.lbrn2",
               alt: "A LightBurn file: the hex tiles for every resource, each engraved with its own pattern"),
      Tile.new(source: "Projects/catan/laser/number tokens.lbrn2",
               alt: "A LightBurn file: the number tokens, 2 to 12, with their probability dots"),
      Tile.new(source: "Projects/catan/laser/longest road.lbrn2",
               alt: "A LightBurn file: three award cards, Longest Road, Largest Army and Longest Turn"),
      Tile.new(source: "Projects/catan/laser/ship token.lbrn2",
               alt: "A LightBurn file: the harbor tokens, 3:1 and 2:1, and the resource symbols"),
      Tile.new(source: "Projects/catan/laser/reference card.lbrn2",
               alt: "A LightBurn file: two building-cost reference cards and three harbor tokens"),
      Tile.new(source: "Projects/catan/laser/gamebox v7.lbrn2",
               alt: "A LightBurn file: the game box's finger-jointed panels, the lid engraved with the name"),
      Tile.new(source: "Projects/catan/design/tile.svg",
               alt: "An SVG file: the whole set in one drawing, the board of numbered hex tiles ringed by harbors, the cards below"),
      Tile.new(source: "Projects/catan/design/tile nesting v1.svg",
               alt: "An SVG file: a hexagonal tray with slots for the cards and wells for the tokens"),
      Tile.new(source: "Projects/catan/design/jig for pieces.dxf",
               alt: "A DXF file: a hexagonal jig that holds pieces while they are engraved"),
      Tile.new(source: "Projects/catan/cnc/desert+any.mage",
               alt: "A MillMage file: a hexagonal frame and its pieces, for the CNC"),
      Tile.new(source: "Projects/catan/models/robber.3mf",
               alt: "A 3MF file: the robber, ready to slice"),
      # macOS writes a NARROW NO-BREAK SPACE (U+202F) before AM/PM in a screenshot's name.
      Tile.new(source: "Projects/catan/models/Screenshot 2024-07-16 at 10.35.23\u202FAM.stl",
               alt: "An STL file: a robber figure as a print mesh")
    ].freeze

    def self.enabled? = Tinkerex::Demo.enabled?

    # Renders every tile, THEN writes them all, so a refusal leaves the wall as it was.
    def self.render_wall(seed_dir: SEED_DIR, out_dir: OUT_DIR, tiles: TILES, size: SIZE)
      rendered = tiles.map { |tile| [ tile, render_tile(tile, seed_dir: Pathname(seed_dir), size:) ] }
      out_dir = Pathname(out_dir)
      out_dir.mkpath
      rendered.map { |tile, bytes| out_dir.join(File.basename(tile.asset)).tap { |path| path.binwrite(bytes) } }
    end

    def self.render_tile(tile, seed_dir:, size:)
      path = seed_dir.join(tile.source)
      raise Error, "#{tile.source} is not in #{seed_dir}" unless path.file?

      renderer = Maker::Previews::Registry.for_filename(path.basename.to_s)
      raise Error, "no preview renderer claims #{tile.source}" if renderer.nil?
      unless Maker::Previews::Registry.available_for?(renderer, "thumbnail")
        raise Error, "#{renderer.name}'s toolchain is not on this machine, so #{tile.source} cannot render here"
      end

      # A renderer's own failure is re-raised NAMING THE TILE, so `landing:wall` says which file broke.
      # StandardError, never Exception: NotImplementedError is a ScriptError and stays loud (§14a).
      result = begin
        Maker::Previews::Registry.render(renderer, path.binread, ext: tile.ext, kind: "thumbnail", size:)
      rescue StandardError => e
        raise Error, "#{tile.source} could not be rendered: #{e.class}: #{e.message}"
      end
      raise Error, "#{tile.source} rendered #{result[:content_type].inspect}, not a PNG" unless result[:content_type] == "image/png"
      raise Error, "#{tile.source} rendered no bytes" if result[:bytes].to_s.empty?

      result[:bytes]
    end
  end
end
