require "test_helper"

module Maker
  # STAGE 4, S4-7 (decision D4): what a project's folder says it is, and what that presets.
  #
  # THE SUGGESTION IS A PURE FUNCTION over Maker::ProjectFolderListing — roles from filenames
  # (Row#role) plus one boolean (#root_repo?) — so it is table-driven here rather than probed
  # through a sweep, and it needs no library on disk and no port on any of the three legs.
  class ProjectKindTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pk-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Sample")
      @folder = project_folder_rows!(@user, @project)
    end

    def file(name, parent: @folder.node_id)
      @user.nodes.create!(node_id: "n-#{SecureRandom.hex(4)}", name:, kind: "file",
                          parent_node_id: parent, mtime: 1, size: 1)
    end

    def dir(name, parent: @folder.node_id)
      @user.nodes.create!(node_id: "d-#{SecureRandom.hex(4)}", name:, kind: "dir",
                          parent_node_id: parent, mtime: 1, size: 0)
    end

    def suggest = Maker::ProjectKind.suggest(Maker::ProjectFolderListing.new(@user, @project))

    # THE TABLE. Each row is a folder shaped like one on the bench, and the expected kind is what
    # the page it presets has to be right about. `mixed` is what a SECOND strong family means, and
    # "strong" is measured against the leader rather than against the folder's total, so a project
    # with forty photos and two SVGs is still a laser project.
    CASES = {
      "a LightBurn folder is laser" => [ %w[box.lbrn2 lid.lbrn panel.svg tray.dxf shot.png notes.md], "laser" ],
      "meshes and CAD are print"    => [ %w[base.stl shade.3mf clip.step body.f3d readme.md], "print" ],
      "toolpaths and MillMage are cnc" => [ %w[pocket.nc roughing.gcode job.mage stock.png], "cnc" ],
      "sources and Gerbers are electronics" => [ %w[main.c board.gtl board.drl config.yml], "electronics" ],
      "two strong families are mixed" => [ %w[panel.svg lid.svg cut.dxf base.stl body.step clip.stl], "mixed" ],
      "photos and documents alone are other" => [ %w[shot.png plan.pdf notes.md bolts.csv], "other" ],
      "an empty folder is other" => [ [], "other" ]
    }.freeze

    CASES.each do |name, (names, expected)|
      test "suggest: #{name}" do
        names.each { |n| file(n) }
        assert_equal expected, suggest
      end
    end

    # THE WORKING TREE IS WEAK EVIDENCE, MEASURED: a read-only probe of the share deployment found a
    # `.git` in six of nine project folders, across laser, print and electronics. So the bonus is an
    # amplifier for a folder that already holds code or board files, never a vote of its own.
    test "a bare working tree with nothing recognisable in it reads as other" do
      file("README.md")
      dir(Library::RepoMetadata::DIR_NAME)

      assert_equal "other", suggest
    end

    test "a working tree with a few sources tips to electronics on the repository's weight" do
      # One source against one model is a tie (mixed) without the bonus; the repository breaks it.
      %w[main.c enclosure.stl].each { |n| file(n) }
      dir(Library::RepoMetadata::DIR_NAME)

      assert_equal "electronics", suggest
    end

    test "a working tree full of laser files is still laser, and so is one with only four" do
      %w[box.lbrn2 lid.lbrn panel.svg tray.dxf].each { |n| file(n) }
      dir(Library::RepoMetadata::DIR_NAME)

      assert_equal "laser", suggest
    end

    # KICAD BY NAME (found in review): the role map does not know .kicad_* on purpose, so without
    # this a board project with no Gerbers and no firmware suggested `other`.
    test "a KiCad-only folder reads as electronics" do
      %w[board.kicad_pcb board.kicad_sch shot.png].each { |n| file(n) }

      assert_equal "electronics", suggest
    end

    test "a project with no live folder suggests other rather than raising" do
      orphan = @user.maker_projects.create!(name: "Folderless")

      assert_equal "other", Maker::ProjectKind.suggest(Maker::ProjectFolderListing.new(@user, orphan))
    end

    # THE DOOR EVERY WRITER USES, and the reason it exists: it can be asked about a folder before
    # the project row exists, so `kind:` is part of the create! rather than an update_column after
    # it (Maker::ProjectDiscovery, S4-6's adoption).
    test "suggest_for answers for a folder node with no project row at all" do
      %w[base.stl body.step clip.stl].each { |n| file(n) }

      assert_equal "print", Maker::ProjectKind.suggest_for(user: @user, folder_node_id: @folder.node_id)
      assert_equal "other", Maker::ProjectKind.suggest_for(user: @user, folder_node_id: nil)
    end

    # --- the presets --------------------------------------------------------------------------

    # TOTALITY, the shape project_folders_test.rb's "every role has a folder" already has: a kind
    # with no preset would fall back to `other`'s silently, and a preset naming a panel that does
    # not exist is a MissingPartial on the maker's own page.
    test "every kind has a preset, and every key in every preset is a real panel" do
      assert_equal Maker::Project::KINDS.to_set, Maker::ProjectKind::PRESETS.keys.to_set
      assert_equal Maker::Project::KINDS.to_set, Maker::ProjectKind::LABELS.keys.to_set
      assert_equal Maker::Project::PANELS.to_set, Maker::Project::PANEL_LABELS.keys.to_set

      panels = Maker::Project::PANELS.to_set
      Maker::ProjectKind::PRESETS.each do |kind, preset|
        assert_operator panels, :superset?, preset[:first].to_set,  "#{kind}: unknown key in first"
        assert_operator panels, :superset?, preset[:hidden].to_set, "#{kind}: unknown key in hidden"
        assert_empty preset[:hidden] & Maker::ProjectKind::ALWAYS, "#{kind} hides an always-shown panel"
      end
    end

    test "every kind's order is a permutation of PANELS, and every kind opens with Files then Photos" do
      Maker::Project::KINDS.each do |kind|
        order = Maker::ProjectKind.layout_for(kind:, overrides: nil).order
        assert_equal Maker::Project::PANELS.sort, order.sort, "#{kind} drops or invents a panel"
        assert_equal Maker::ProjectKind::LEAD, order.first(Maker::ProjectKind::LEAD.size), "#{kind}"
      end
    end

    test "other reproduces today's page exactly" do
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: nil)

      assert_equal Maker::Project::PANELS, layout.order
      assert_equal [], layout.hidden
      assert_equal Maker::Project::PANELS, layout.visible
    end

    test "laser hides the three story 6.1 names, and electronics lifts schematics and wiring" do
      laser = Maker::ProjectKind.layout_for(kind: "laser", overrides: nil)
      refute laser.visible?("bom")
      refute laser.visible?("wiring")
      refute laser.visible?("releases")
      assert laser.visible?("build_log")

      electronics = Maker::ProjectKind.layout_for(kind: "electronics", overrides: nil)
      assert_equal %w[attachments photos schematics wiring build_log], electronics.visible.first(5)
    end

    test "an unknown kind falls back to other's preset rather than raising" do
      assert_equal Maker::Project::PANELS, Maker::ProjectKind.layout_for(kind: "wormhole", overrides: nil).order
    end

    # --- the overrides ------------------------------------------------------------------------

    test "an override's order wins, and a panel it does not name keeps its preset place" do
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: { "order" => %w[tasks build_log] })

      assert_equal %w[tasks build_log], layout.order.first(2)
      assert_equal Maker::Project::PANELS.sort, layout.order.sort,
                   "a key the override did not name must be appended, never dropped"
    end

    test "an override's hidden set REPLACES the preset's, including an empty one" do
      shown = Maker::ProjectKind.layout_for(kind: "laser", overrides: { "hidden" => [] })
      assert_equal [], shown.hidden, "unhiding everything a preset hid must survive the merge"

      partial = Maker::ProjectKind.layout_for(kind: "laser", overrides: { "hidden" => %w[tasks] })
      assert_equal %w[tasks], partial.hidden
      assert partial.visible?("bom"), "the preset's hidden set is replaced, not merged into"
    end

    test "an override that names no hidden key at all keeps the preset's" do
      layout = Maker::ProjectKind.layout_for(kind: "laser", overrides: { "order" => %w[tasks] })

      refute layout.visible?("bom")
    end

    # THE READ IS TOTAL. The column is JSON nothing validates on the way in (the v1 API, a console,
    # a later migration), and an unknown key reaches `render "projects/#{key}"` as a MissingPartial
    # — a 500 on the maker's own page. Filtering here is the guard that cannot be bypassed.
    test "garbage in the column is filtered, never raised on" do
      [ nil, {}, "nonsense", [], { "order" => "notalist" },
        { "order" => %w[attachments ../../etc/passwd tasks], "hidden" => %w[bom nope] } ].each do |junk|
        layout = Maker::ProjectKind.layout_for(kind: "other", overrides: junk)
        assert_equal Maker::Project::PANELS.sort, layout.order.sort, junk.inspect
        assert_operator Maker::Project::PANELS.to_set, :superset?, layout.hidden.to_set, junk.inspect
      end
    end

    test "the three always-shown panels cannot be hidden by an override" do
      layout = Maker::ProjectKind.layout_for(kind: "other",
                                             overrides: { "hidden" => Maker::Project::PANELS })

      Maker::ProjectKind::ALWAYS.each { |key| assert layout.visible?(key), key }
    end

    # --- the hero -----------------------------------------------------------------------------

    test "hero_roles is a preference list per kind, and other's is today's derivation" do
      assert_equal %w[image model], Maker::ProjectKind.hero_roles("other")
      assert_equal %w[model image], Maker::ProjectKind.hero_roles("print")
      assert_equal %w[pcb image model], Maker::ProjectKind.hero_roles("electronics")
      assert_equal %w[image model], Maker::ProjectKind.hero_roles("wormhole")
    end
  end
end
