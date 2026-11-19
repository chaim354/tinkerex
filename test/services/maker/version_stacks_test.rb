require "test_helper"

module Maker
  # THE STACK-GROUPING GUARD (shop-manual spec §10): the wrong groups on the catan names go red.
  # The rule is written out in Maker::VersionStacks' header; this names the groups it must give,
  # member by member, rather than counting them — a count holds over two wrong groups that swap a
  # file. Rows-only where it touches the database, so it runs identically on all three legs.
  class VersionStacksTest < ActiveSupport::TestCase
    # catan's files as the demo seed holds them (db/seeds/demo/Projects/catan), VERBATIM, including
    # the trailing space in `tile test .svg` and the narrow no-break space (U+202F) macOS writes
    # before a screenshot's AM/PM. The seed-list test below keeps this list the seed's own.
    CATAN = [
      "cnc/desert+any.mage",
      "cnc/edge test 7-20-26.mage",
      "cnc/edge test 7-20-26_backup.mage",
      "design/boxv1-5.svg",
      "design/boxv2-6.svg",
      "design/boxv3.svg",
      "design/boxv5.svg",
      "design/carboxv1.svg",
      "design/fidget-box-tray-plan.svg",
      "design/fidget-box-tray.svg",
      "design/gamebox-v6-plan.svg",
      "design/gamebox-v6.svg",
      "design/gamebox-v7-plan.svg",
      "design/gamebox-v7.svg",
      "design/harbor-number-v2.svg",
      "design/harbor-number-v3.svg",
      "design/harbor-number-v4.svg",
      "design/harbor-number-v5.svg",
      "design/history-test.svg",
      "design/jig for pieces box.svg",
      "design/jig for pieces.dxf",
      "design/test1-4.svg",
      "design/tile nesting v1.svg",
      "design/tile test .svg",
      "design/tile.svg",
      "design/tokenbox-tests-1.svg",
      "design/tokens-and-harbors-v1.svg",
      "docs/box.txt",
      "harbor-number-v4.svg",
      "images/Screenshot 2024-07-05 at 1.57.56\u202FPM.png",
      "images/Screenshot 2024-07-07 at 11.47.39\u202FPM.png",
      "images/Screenshot 2024-07-16 at 10.34.40\u202FAM.png",
      "images/Screenshot 2024-07-16 at 10.35.23\u202FAM.png",
      "images/Screenshot 2024-07-16 at 10.35.28\u202FAM.png",
      "laser/dice robber holder.lbrn2",
      "laser/edge test 7-20-26.lbrn2",
      "laser/edge test 7-3.lbrn2",
      "laser/edge test 7-5.lbrn2",
      "laser/game box 2.lbrn2",
      "laser/game box v1.lbrn2",
      "laser/game box.lbrn2",
      "laser/game test.lbrn2",
      "laser/game top.lbrn2",
      "laser/gamebox v7.lbrn2",
      "laser/harbor number box v2.lbrn2",
      "laser/hex tiles.lbrn2",
      "laser/hex tiles_backup.lbrn2",
      "laser/longest road.lbrn2",
      "laser/number tokens.lbrn2",
      "laser/numbers and harbors v1.lbrn2",
      "laser/piecies card.lbrn2",
      "laser/reference card.lbrn2",
      "laser/ship token.lbrn2",
      "laser/stacking card v1.lbrn2",
      "laser/stacking card v2.lbrn2",
      "laser/tiles to dxf.lbrn2",
      "models/CREDITS.md",
      "models/Screenshot 2024-07-16 at 10.35.23\u202FAM.stl",
      "models/pieces jig v1.3mf",
      "models/robber.3mf"
    ].freeze

    # [folder, key, members]: the nine stacks, 23 files, and nothing else.
    CATAN_STACKS = [
      [ "cnc", "edge test", [ "edge test 7-20-26.mage", "edge test 7-20-26_backup.mage" ] ],
      [ "design", "box", %w[boxv1-5.svg boxv2-6.svg boxv3.svg boxv5.svg] ],
      [ "design", "gamebox", %w[gamebox-v6.svg gamebox-v7.svg] ],
      [ "design", "gamebox plan", %w[gamebox-v6-plan.svg gamebox-v7-plan.svg] ],
      [ "design", "harbor number", %w[harbor-number-v2.svg harbor-number-v3.svg harbor-number-v4.svg
                                      harbor-number-v5.svg] ],
      [ "laser", "edge test", [ "edge test 7-20-26.lbrn2", "edge test 7-3.lbrn2", "edge test 7-5.lbrn2" ] ],
      [ "laser", "game box", [ "game box v1.lbrn2", "game box.lbrn2" ] ],
      [ "laser", "hex tiles", [ "hex tiles.lbrn2", "hex tiles_backup.lbrn2" ] ],
      [ "laser", "stacking card", [ "stacking card v1.lbrn2", "stacking card v2.lbrn2" ] ]
    ].freeze

    setup do
      @user = User.create!(email: "stacks-#{SecureRandom.hex(4)}@example.com")
      @folder = @user.nodes.create!(node_id: SecureRandom.uuid, name: "laser", kind: "dir")
    end

    # One Entry per path; the folder is the parent id, the path the node id.
    def entries(paths, mtimes: {})
      paths.map do |path|
        VersionStacks::Entry.new(node_id: path, parent_node_id: File.dirname(path), name: File.basename(path),
                                 kind: "file", mtime: mtimes[path])
      end
    end

    def groups(result)
      result.stacks.map { |s| [ s.parent_node_id, s.key, s.members.map(&:name).sort ] }.sort
    end

    def stacks_of(*paths, **opts) = VersionStacks.group(entries(paths), **opts)

    # --- catan --------------------------------------------------------------------------------

    test "catan's names give exactly the nine expected stacks" do
      assert_equal CATAN_STACKS, groups(VersionStacks.group(entries(CATAN)))
    end

    test "every other catan file stands alone" do
      result = VersionStacks.group(entries(CATAN))
      alone = [
        "harbor-number-v4.svg",               # the design/ harbor numbers' name, in another folder
        "design/carboxv1.svg",                # `carbox`, not `box`
        "design/tile.svg", "design/tile nesting v1.svg", "design/tile test .svg",
        "design/test1-4.svg", "design/tokenbox-tests-1.svg", "design/tokens-and-harbors-v1.svg",
        "design/fidget-box-tray.svg", "design/fidget-box-tray-plan.svg",
        "docs/box.txt",                       # `box`, but another folder AND another type
        "laser/game box 2.lbrn2",             # a part number: a different part from `game box`
        "laser/gamebox v7.lbrn2",             # `gamebox` is not `game box`, and design/ is not laser/
        "laser/harbor number box v2.lbrn2", "laser/numbers and harbors v1.lbrn2",
        "models/pieces jig v1.3mf",
        "models/Screenshot 2024-07-16 at 10.35.23\u202FAM.stl",
        *CATAN.grep(%r{\Aimages/Screenshot})
      ]
      alone.each { |path| assert_nil result.stack_for(path), "#{path} must stand alone" }
      assert_equal CATAN.size - 23, CATAN.count { |path| !result.stacked?(path) }
    end

    # Every catan file carries the same mtime here, so the natural-order tie-break decides.
    test "a stack is named for its latest member, in that member's spelling" do
      result = VersionStacks.group(entries(CATAN))
      named = result.stacks.to_h { |s| [ [ s.parent_node_id, s.key ], [ s.name, s.latest.name ] ] }
      assert_equal [ "harbor-number", "harbor-number-v5.svg" ], named[[ "design", "harbor number" ]]
      assert_equal [ "gamebox-plan", "gamebox-v7-plan.svg" ], named[[ "design", "gamebox plan" ]]
      assert_equal [ "box", "boxv5.svg" ], named[[ "design", "box" ]]
      assert_equal [ "edge test", "edge test 7-20-26.lbrn2" ], named[[ "laser", "edge test" ]]
      assert_equal [ "game box", "game box v1.lbrn2" ], named[[ "laser", "game box" ]]
      assert_equal [ "hex tiles", "hex tiles.lbrn2" ], named[[ "laser", "hex tiles" ]], "the backup is never latest"
    end

    test "the catan list is the demo seed's own" do
      root = Rails.root.join("db/seeds/demo/Projects/catan")
      on_disk = Dir.glob("**/*", base: root).select { |p| root.join(p).file? }.sort
      assert_operator on_disk.size, :>=, 50, "the seed is missing, so this would compare nothing"
      assert_equal CATAN.sort, on_disk, "the seed changed: update CATAN and re-derive CATAN_STACKS by the rule"
    end

    # --- the rule, case by case ----------------------------------------------------------------

    test "a stack never crosses file types, and the type compares case-insensitively" do
      assert_empty stacks_of("p/bracket v1.stl", "p/bracket v2.step").stacks
      assert_equal [ [ "p", "bracket", [ "bracket v1.STL", "bracket v2.stl" ] ] ],
                   groups(stacks_of("p/bracket v1.STL", "p/bracket v2.stl"))
    end

    test "a stack never crosses folders" do
      assert_empty stacks_of("a/box v1.svg", "b/box v2.svg").stacks
    end

    test "game box and game box 2 are different parts" do
      assert_empty stacks_of("laser/game box.lbrn2", "laser/game box 2.lbrn2").stacks
      assert_empty stacks_of("d/tokenbox-tests-1.svg", "d/tokenbox-tests-2.svg").stacks
    end

    test "screenshots never stack: a date that is not the last token is part of the name" do
      assert_empty stacks_of("i/Screenshot 2024-07-16 at 10.35.23\u202FAM.png",
                             "i/Screenshot 2024-07-16 at 10.35.28\u202FAM.png").stacks
      assert_empty stacks_of("i/Screenshot 2024-07-16.png", "i/Screenshot 2024-07-17.png").stacks,
                   "the 07-16 tail of an ISO date is not a trailing m-d"
      assert_empty stacks_of("i/edge 7-3 test.svg", "i/edge 7-5 test.svg").stacks
    end

    test "a trailing date is a version, after a space, an underscore or a dot" do
      assert_equal [ [ "l", "edge test", [ "edge test 7-3.lbrn2", "edge test.7-5.lbrn2", "edge test_7-20-2026.lbrn2" ] ] ],
                   groups(stacks_of("l/edge test 7-3.lbrn2", "l/edge test_7-20-2026.lbrn2", "l/edge test.7-5.lbrn2"))
      assert_empty stacks_of("l/edge test 13-3.lbrn2", "l/edge test 14-3.lbrn2").stacks, "no thirteenth month"
    end

    test "a version marker is taken off on its own, mid-name, or glued after letters" do
      assert_equal [ [ "d", "gamebox plan", %w[gamebox-v6-plan.svg gamebox_v8.1_plan.svg] ] ],
                   groups(stacks_of("d/gamebox-v6-plan.svg", "d/gamebox_v8.1_plan.svg"))
      assert_equal [ [ "d", "box", [ "Box V2.svg", "boxv1-5.svg" ] ] ], groups(stacks_of("d/boxv1-5.svg", "d/Box V2.svg"))
      assert_empty stacks_of("d/box2v1.svg", "d/box2v2.svg").stacks, "after a digit, `v1` is not a marker"
    end

    test "separators fold together and runs collapse" do
      assert_equal [ [ "d", "harbor number", [ "harbor - number v3.svg", "harbor-number-v4.svg", "harbor_number v2.svg" ] ] ],
                   groups(stacks_of("d/harbor_number v2.svg", "d/harbor - number v3.svg", "d/harbor-number-v4.svg"))
      assert_equal [ [ "d", "box", [ "box v2.svg", "box\u00A0v1.svg" ] ] ], groups(stacks_of("d/box\u00A0v1.svg", "d/box v2.svg")),
                   "a no-break space is a space"
    end

    test "a marker that would leave nothing is not a marker" do
      assert_empty stacks_of("d/v1.svg", "d/v2.svg").stacks
      assert_empty stacks_of("d/(1).svg", "d/(2).svg").stacks
    end

    test "backup and copy markers stack with the original as copies" do
      names = [ "hex tiles.lbrn2", "hex tiles (1).lbrn2", "hex tiles copy.lbrn2", "hex tiles copy 2.lbrn2",
                "hex tiles_backup.lbrn2", "hex tiles-old.lbrn2", "hex tiles bak.lbrn2", "hex tiles v2 copy (3).lbrn2" ]
      result = stacks_of(*names.map { |n| "l/#{n}" })
      assert_equal [ [ "l", "hex tiles", names.sort ] ], groups(result)
      copies = result.stacks.first.members.select(&:copy?).map(&:name)
      assert_equal names - [ "hex tiles.lbrn2" ], copies.sort_by { |n| names.index(n) }
    end

    test "a copy is never latest while a version exists, however new it is; copies go last" do
      paths = [ "l/hex tiles v1.lbrn2", "l/hex tiles v2.lbrn2", "l/hex tiles v2 (1).lbrn2", "l/hex tiles copy.lbrn2" ]
      mtimes = { paths[0] => 100, paths[1] => 200, paths[2] => 900, paths[3] => 800 }
      stack = VersionStacks.group(entries(paths, mtimes:)).stacks.sole
      assert_equal "hex tiles v2.lbrn2", stack.latest.name
      assert_equal [ "hex tiles v2.lbrn2", "hex tiles v1.lbrn2", "hex tiles v2 (1).lbrn2", "hex tiles copy.lbrn2" ],
                   stack.members.map(&:name), "versions newest first, then copies newest first"
    end

    test "a stack of copies alone takes its newest copy as latest" do
      paths = [ "l/foo copy.svg", "l/foo (1).svg" ]
      stack = VersionStacks.group(entries(paths, mtimes: { paths[0] => 1, paths[1] => 2 })).stacks.sole
      assert_equal "foo (1).svg", stack.latest.name
      assert_equal "foo", stack.name
    end

    test "latest is the newest by modified time, not the highest version" do
      paths = [ "l/stacking card v1.lbrn2", "l/stacking card v2.lbrn2" ]
      stack = VersionStacks.group(entries(paths, mtimes: { paths[0] => 2_000, paths[1] => 1_000 })).stacks.sole
      assert_equal "stacking card v1.lbrn2", stack.latest.name
    end

    test "only files stack" do
      dirs = [ "p/parts v1", "p/parts v2" ].map do |path|
        VersionStacks::Entry.new(node_id: path, parent_node_id: "p", name: File.basename(path), kind: "dir", mtime: 0)
      end
      assert_empty VersionStacks.group(dirs).stacks
    end

    test "a pulled-out file stands alone, and a stack needs two members after pull-outs" do
      three = %w[d/boxv1.svg d/boxv2.svg d/boxv3.svg]
      result = stacks_of(*three, excluded: [ "d/boxv2.svg" ])
      assert_equal [ [ "d", "box", %w[boxv1.svg boxv3.svg] ] ], groups(result)
      assert_nil result.stack_for("d/boxv2.svg")

      assert_empty stacks_of("d/boxv1.svg", "d/boxv2.svg", excluded: [ "d/boxv2.svg" ]).stacks
    end

    test "a name that is not valid UTF-8 stands alone and does not raise" do
      bad = "box v1 \xFF.svg".dup.force_encoding(Encoding::UTF_8)
      worse = "box v2 \xFE.svg".dup.force_encoding(Encoding::UTF_8)
      entries = [ bad, worse, "box v3.svg" ].map.with_index do |name, i|
        VersionStacks::Entry.new(node_id: "n#{i}", parent_node_id: "p", name:, kind: "file", mtime: 0)
      end
      assert_empty VersionStacks.group(entries).stacks
    end

    test "collapse puts each stack once, where its first member stood" do
      paths = %w[d/a.svg d/boxv2.svg d/b.svg d/boxv1.svg d/c.svg]
      result = VersionStacks.group(entries(paths))
      collapsed = result.collapse(paths)
      assert_equal [ "d/a.svg", :stack, "d/b.svg", "d/c.svg" ], collapsed.map { |e| e.is_a?(String) ? e : :stack }
      assert_equal %w[d/boxv1.svg d/boxv2.svg], collapsed[1].node_ids.sort
    end

    # --- the entry points -----------------------------------------------------------------------

    def file!(name, user: @user, parent: @folder, **attrs)
      user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent&.node_id, **attrs)
    end

    test "for_nodes groups the given live files of this user's library" do
      v1 = file!("game box v1.lbrn2", mtime: 1)
      v0 = file!("game box.lbrn2", mtime: 2)
      part = file!("game box 2.lbrn2")
      gone = file!("game box v2.lbrn2", deleted: true)
      theirs = file!("game box v3.lbrn2", user: User.create!(email: "o-#{SecureRandom.hex(4)}@example.com"), parent: nil)

      result = VersionStacks.for_nodes(@user, [ v1, v0, part, gone, theirs ].map(&:node_id))
      stack = result.stacks.sole
      assert_equal [ v0.node_id, v1.node_id ], stack.node_ids, "newest first; no tombstone, no stranger's file"
      assert_equal "game box", stack.name
      assert_nil result.stack_for(part.node_id)
    end

    test "in_folder groups one folder's visible files and nothing beside it" do
      a = file!("stacking card v1.lbrn2")
      b = file!("stacking card v2.lbrn2")
      file!(".stacking card v3.lbrn2")
      file!("stacking card v4.lbrn2", parent: @user.nodes.create!(node_id: SecureRandom.uuid, name: "cnc", kind: "dir"))
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "stacking card v5", kind: "dir", parent_node_id: @folder.node_id)

      assert_equal [ a.node_id, b.node_id ].sort, VersionStacks.in_folder(@user, @folder.node_id).stacks.sole.node_ids.sort
    end

    test "a stored pull-out is honoured, and only this user's" do
      a = file!("hex tiles.lbrn2")
      b = file!("hex tiles_backup.lbrn2")
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: b.node_id, name: "theirs.svg", kind: "file")
      Maker::StackExclusion.pull_out!(other, b.node_id)

      assert_equal 1, VersionStacks.in_folder(@user, @folder.node_id).stacks.size, "their pull-out is not mine"
      assert_equal 1, VersionStacks.for_nodes(@user, [ a.node_id, b.node_id ]).stacks.size

      Maker::StackExclusion.pull_out!(@user, b.node_id)
      assert_empty VersionStacks.in_folder(@user, @folder.node_id).stacks
      assert_empty VersionStacks.for_nodes(@user, [ a.node_id, b.node_id ]).stacks

      Maker::StackExclusion.put_back!(@user, b.node_id)
      assert_equal 1, VersionStacks.in_folder(@user, @folder.node_id).stacks.size
    end

    def count_queries
      n = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        n += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
      end
      yield
      n
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # CONSTANT IN N, asserted as constancy rather than a literal (§14e): two files and twelve, all
    # of them in stacks and one in three pulled out, cost the same.
    test "the entry points cost the same number of queries for two files and for twelve" do
      costs = [ 2, 12 ].map do |n|
        folder = @user.nodes.create!(node_id: SecureRandom.uuid, name: "f#{n}", kind: "dir")
        ids = (1..n).map { |i| file!("part #{(i + 1) / 2} v#{i}.svg", parent: folder).node_id }
        ids.each_slice(3) { |slice| Maker::StackExclusion.pull_out!(@user, slice.first) }
        [ count_queries { VersionStacks.in_folder(@user, folder.node_id).stacks },
          count_queries { VersionStacks.for_nodes(@user, ids).stacks } ]
      end
      assert_equal costs.first, costs.last, "queries for [in_folder, for_nodes] at 2 and 12 files: #{costs.inspect}"
      assert_operator costs.first.max, :>, 0, "nothing was measured"
    end
  end
end
