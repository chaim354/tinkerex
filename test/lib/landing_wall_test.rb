require "test_helper"

# THE LANDING'S WALL IS RENDERED, NEVER DRAWN (Tinkerex::Landing; spec 2026-10-16 §3). These pin the
# refusals -- a wall with a hole in it, or a tile left over from an older run, is the failure to fear
# -- and that a tile is byte-for-byte what the library's own renderer makes of the file.
class LandingWallTest < ActiveSupport::TestCase
  SVG = %(<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="#1b1c19"/></svg>).freeze

  setup do
    @seed = Pathname(Dir.mktmpdir("seed"))
    @out = Pathname(Dir.mktmpdir("wall"))
  end

  teardown do
    FileUtils.remove_entry(@seed)
    FileUtils.remove_entry(@out)
  end

  def tile(source) = Tinkerex::Landing::Tile.new(source:, alt: "a tile")

  def seed!(rel, body)
    @seed.join(rel).dirname.mkpath
    @seed.join(rel).write(body)
  end

  test "a tile's extension and asset come from its source file's name" do
    t = tile("Projects/catan/laser/Hex Tiles.LBRN2")
    assert_equal "lbrn2", t.ext
    assert_equal "landing/wall/hex-tiles-lbrn2.png", t.asset
  end

  test "a source missing from the seed is refused by name" do
    err = assert_raises(Tinkerex::Landing::Error) do
      Tinkerex::Landing.render_wall(seed_dir: @seed, out_dir: @out, tiles: [ tile("Laser/missing.svg") ])
    end
    assert_match "Laser/missing.svg", err.message
    assert_empty @out.children
  end

  test "an extension no renderer claims is refused" do
    seed!("Laser/notes.xyz", "x")
    err = assert_raises(Tinkerex::Landing::Error) do
      Tinkerex::Landing.render_wall(seed_dir: @seed, out_dir: @out, tiles: [ tile("Laser/notes.xyz") ])
    end
    assert_match(/no preview renderer claims Laser\/notes\.xyz/, err.message)
  end

  test "a tile is the library's own render of the file, written as <name>-<ext>.png" do
    skip "resvg is not on this machine" unless Maker::Previews::Svg.available?
    seed!("Laser/a.svg", SVG)

    paths = Tinkerex::Landing.render_wall(seed_dir: @seed, out_dir: @out, tiles: [ tile("Laser/a.svg") ])

    assert_equal [ @out.join("a-svg.png") ], paths
    expected = Maker::Previews::Registry.render(Maker::Previews::Svg, SVG, ext: "svg", kind: "thumbnail",
                                                size: Tinkerex::Landing::SIZE)[:bytes]
    assert_equal expected.b, @out.join("a-svg.png").binread
  end

  test "a refused tile writes nothing, not even the tiles before it" do
    skip "resvg is not on this machine" unless Maker::Previews::Svg.available?
    seed!("Laser/a.svg", SVG)

    assert_raises(Tinkerex::Landing::Error) do
      Tinkerex::Landing.render_wall(seed_dir: @seed, out_dir: @out, tiles: [ tile("Laser/a.svg"), tile("Laser/missing.svg") ])
    end
    assert_empty @out.children, "a refused run left a partial wall behind"
  end

  test "the landing is on exactly when demo mode is" do
    prior = ENV["DEMO_ACCOUNT_EMAIL"]
    ENV.delete("DEMO_ACCOUNT_EMAIL")
    assert_not Tinkerex::Landing.enabled?
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    assert Tinkerex::Landing.enabled?
  ensure
    prior.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = prior
  end

  # THE COMMITTED WALL IS COMPLETE. Every tile names a file the seed holds and a PNG
  # `bin/rails landing:wall` wrote, so a tile added to TILES without a render -- or a sample removed
  # from the seed -- is red here before the landing renders a broken image.
  test "the wall is twelve tiles, each a seed file with a rendered PNG and alt text" do
    tiles = Tinkerex::Landing::TILES
    assert_equal 12, tiles.size
    assert_equal tiles.size, tiles.map(&:asset).uniq.size, "two tiles would write one PNG"
    tiles.each do |t|
      assert Tinkerex::Landing::SEED_DIR.join(t.source).file?, "#{t.source} is not in db/seeds/demo"
      assert Rails.root.join("app/assets/images", t.asset).file?, "#{t.asset} is not rendered: bin/rails landing:wall"
      assert_predicate t.alt, :present?
    end
  end
end
