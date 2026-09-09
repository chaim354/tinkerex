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

    # --- the folders ----------------------------------------------------------------------------
    #
    # FOLDER PANELS (2026-09-08; spec decisions 3, 5, 6). `folders:` is `[[node_id, repo?], …]` in
    # disk order — Maker::ProjectFolderListing#panel_folders — and the vocabulary is PANELS plus a
    # `folder:<node_id>` for each. Pure arithmetic like the cases above, so most of these pass the
    # pairs directly; the first drives the real listing, because "depth one" is the LISTING's half
    # of the contract and a layout test cannot see a nested folder it is never handed.

    # A pair of plain ids, in the disk order a listing would report them.
    MODELS = "d-models".freeze
    FIRMWARE = "d-firmware".freeze
    FOLDERS = [ [ FIRMWARE, true ], [ MODELS, false ] ].freeze

    def key(id) = Maker::ProjectKind.folder_key(id)

    test "panel_folders reports the DEPTH-ONE folders with their repo flags, and a nested folder never enters the vocabulary" do
      models = dir("models")
      firmware = dir("firmware")
      dir(".git", parent: firmware.node_id)
      nested = dir("old", parent: models.node_id)

      folders = Maker::ProjectFolderListing.new(@user, @project).panel_folders

      assert_equal [ [ firmware.node_id, true ], [ models.node_id, false ] ], folders,
                   "depth one, in disk order, with the working tree flagged"

      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: { "order" => [ key(nested.node_id) ] },
                                             folders:)
      refute_includes layout.order, key(nested.node_id), "a nested folder is a section inside its parent, never a panel"
      assert_includes layout.order, key(models.node_id)
    end

    test "a folder the stored order does not name lands immediately after Files, in disk order" do
      [ nil, { "hidden" => %w[tasks] }, { "order" => Maker::Project::PANELS } ].each do |overrides|
        order = Maker::ProjectKind.layout_for(kind: "other", overrides:, folders: FOLDERS).order

        assert_equal [ "attachments", key(FIRMWARE), key(MODELS), "photos" ], order.first(4), overrides.inspect
        assert_equal (Maker::Project::PANELS + [ key(FIRMWARE), key(MODELS) ]).sort, order.sort, overrides.inspect
      end
    end

    test "a stored order that interleaves a folder among the fixed panels is honoured" do
      stored = %w[attachments photos] + [ key(FIRMWARE) ] + %w[build_log tasks]

      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: { "order" => stored }, folders: FOLDERS)

      assert_equal [ "attachments", key(MODELS), "photos", key(FIRMWARE) ], layout.order.first(4),
                   "the maker's placement of firmware wins; the folder they did not name lands after Files"
      assert_equal %w[build_log tasks], layout.order[4, 2]
    end

    # TOTALITY AGAINST THE FOLDERS THAT EXIST NOW. A folder can be deleted between two page views,
    # so this is the case no write-time validation could have caught, and an order carrying its key
    # would hand `render` a panel with no Dir behind it.
    test "a stored key for a folder that is gone drops out of order, hidden and views" do
      gone = key("d-vanished")
      layout = Maker::ProjectKind.layout_for(
        kind: "other",
        overrides: { "order" => [ "attachments", gone, "photos" ], "hidden" => [ gone ],
                     "views" => { gone => "list", key(MODELS) => "list" } },
        folders: FOLDERS
      )

      refute_includes layout.order, gone
      refute_includes layout.hidden, gone
      refute layout.views.key?(gone)
      assert_equal "list", layout.views[key(MODELS)], "a key whose folder IS there survives"
      assert_equal "tiles", layout.view_for(gone), "and the stale key still answers, never raises"
    end

    test "a folder can be hidden, and the always-shown panels still cannot be" do
      layout = Maker::ProjectKind.layout_for(kind: "other",
                                             overrides: { "hidden" => [ key(MODELS), "attachments", "bom" ] },
                                             folders: FOLDERS)

      assert layout.hidden?(key(MODELS))
      refute layout.visible?(key(MODELS))
      assert layout.visible?(key(FIRMWARE))
      Maker::ProjectKind::ALWAYS.each { |k| assert layout.visible?(k), k }
      assert_equal [ key(MODELS), "bom" ].to_set, layout.hidden.to_set
    end

    test "views keeps only vocabulary keys with values in VIEWS, stringified" do
      layout = Maker::ProjectKind.layout_for(
        kind: "other",
        overrides: { "views" => { key(MODELS) => "list", key("d-gone") => "tiles", "attachments" => "browser",
                                  "nope" => "list", "bom" => "gallery", "photos" => nil, :tasks => :list } },
        folders: FOLDERS
      )

      assert_equal({ key(MODELS) => "list", "attachments" => "browser", "tasks" => "list" }, layout.views)
    end

    test "junk in views is filtered rather than raised on, exactly as the order and hidden keys are" do
      [ nil, "browser", [], { "views" => "browser" }, 7 ].each do |junk|
        layout = Maker::ProjectKind.layout_for(kind: "other", overrides: { "views" => junk }, folders: FOLDERS)

        assert_equal({}, layout.views, junk.inspect)
        assert_equal "tiles", layout.view_for(key(MODELS)), junk.inspect
      end
    end

    # TODAY'S PAGE, WRITTEN DOWN: a working tree opened in the browser and everything else in tiles
    # before folder panels existed, and a maker who has chosen nothing must still see that.
    test "view_for defaults to the browser for a working tree and tiles for everything else, and a stored view wins" do
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: nil, folders: FOLDERS)

      assert_equal "browser", layout.view_for(key(FIRMWARE))
      assert_equal "tiles", layout.view_for(key(MODELS))
      assert_equal "tiles", layout.view_for("attachments")
      assert_equal "tiles", layout.view_for("photos")

      chosen = Maker::ProjectKind.layout_for(
        kind: "other",
        overrides: { "views" => { key(FIRMWARE) => "tiles", key(MODELS) => "browser", "attachments" => "list" } },
        folders: FOLDERS
      )

      assert_equal "tiles", chosen.view_for(key(FIRMWARE)), "the maker's answer beats the repository default"
      assert_equal "browser", chosen.view_for(key(MODELS))
      assert_equal "list", chosen.view_for("attachments")
    end

    test "folder? and folder_id name the same key the vocabulary was built from" do
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: nil, folders: FOLDERS)

      assert layout.folder?(key(MODELS))
      assert_equal MODELS, layout.folder_id(key(MODELS))
      Maker::Project::PANELS.each { |k| refute layout.folder?(k), k }
      assert_equal [ FIRMWARE ], layout.repo_ids
    end

    # `folders: []` IS THE DEFAULT, which is what lets every caller holding no listing keep working
    # unchanged. Asserted against the expectations the cases ABOVE make, over the matrix of kinds
    # and the override shapes those cases use — not against a fresh guess at what they should be.
    # NAMED FOR WHAT IT CHECKS (review of Task A): `folders:` DEFAULTS to `[]`, so this compares the
    # default against an explicit empty list — it pins the default, not the pre-change layout. The
    # pre-change layouts are pinned by the literal-order tests above (they went red when the default
    # was mutated to a folder list); a 102-pair old-versus-new comparison in review found 0 differences.
    test "the folders default is an empty list, so a caller with no listing gets the fixed keys alone" do
      [ nil, { "order" => %w[tasks build_log] }, { "hidden" => [] }, { "hidden" => %w[tasks] } ].each do |overrides|
        Maker::Project::KINDS.each do |kind|
          layout = Maker::ProjectKind.layout_for(kind:, overrides:, folders: [])

          assert_equal Maker::ProjectKind.layout_for(kind:, overrides:).order, layout.order, "#{kind} #{overrides.inspect}"
          assert_equal Maker::Project::PANELS.sort, layout.order.sort, "#{kind} #{overrides.inspect}"
          assert_operator Maker::Project::PANELS.to_set, :superset?, layout.hidden.to_set, "#{kind} #{overrides.inspect}"
          assert_equal({}, layout.views)
          assert_equal [], layout.repo_ids
        end
      end

      other = Maker::ProjectKind.layout_for(kind: "other", overrides: nil, folders: [])
      assert_equal Maker::Project::PANELS, other.order
      assert_equal [], other.hidden
      assert_equal Maker::Project::PANELS, other.visible
      assert_equal %w[attachments photos schematics wiring build_log],
                   Maker::ProjectKind.layout_for(kind: "electronics", overrides: nil, folders: []).visible.first(5)
    end

    # --- what a panel offers --------------------------------------------------------------------

    test "offered_views: a folder offers all three, Files two, and a fixed panel with no view none" do
      assert_equal %w[tiles list browser], Maker::ProjectKind.offered_views("folder:d-models")
      assert_equal %w[tiles list], Maker::ProjectKind.offered_views("attachments")
      assert_equal %w[tiles list], Maker::ProjectKind.offered_views(:attachments)
      assert_empty Maker::ProjectKind.offered_views("tasks")
      assert_empty Maker::ProjectKind.offered_views(nil)
    end

    # --- widths, titles, intros (2026-09-09, the page editor; spec §3) -------------------------

    test "default_width: Files, Photos and every folder are full, the rest half — today's CSS rule as data" do
      assert_equal "full", Maker::ProjectKind.default_width("attachments")
      assert_equal "full", Maker::ProjectKind.default_width("photos")
      assert_equal "full", Maker::ProjectKind.default_width(key(MODELS))
      %w[schematics build_log tasks bom wiring releases sheets publish].each do |k|
        assert_equal "half", Maker::ProjectKind.default_width(k), k
      end
    end

    test "width_for answers the stored width, else the default, and filters junk" do
      layout = Maker::ProjectKind.layout_for(
        kind: "other",
        overrides: { "widths" => { "tasks" => "full", "photos" => "half", key(MODELS) => "wide",
                                   "nope" => "full", :bom => :full } },
        folders: FOLDERS
      )

      assert_equal "full", layout.width_for("tasks")
      assert_equal "half", layout.width_for("photos")
      assert_equal "full", layout.width_for(:bom), "symbol keys and values are stringified"
      assert_equal "full", layout.width_for(key(MODELS)), "a value outside WIDTHS falls back to the default"
      refute layout.widths.key?("nope"), "a key outside the vocabulary is dropped"
      assert_equal "half", layout.width_for("wiring")
    end

    test "titles and intros are plain one-line text, capped, and blank means absent" do
      long = "x" * 100
      layout = Maker::ProjectKind.layout_for(
        kind: "other",
        overrides: { "titles" => { key(MODELS) => "  Prints ", "tasks" => "", "nope" => "Gone", "bom" => long },
                     "intros" => { key(MODELS) => "Line one\nline two", "photos" => "   " } },
        folders: FOLDERS
      )

      assert_equal "Prints", layout.title_for(key(MODELS), "models")
      assert_equal "Tasks", layout.title_for("tasks", "Tasks"), "an empty title is no title"
      assert_equal "Prints", layout.titles[key(MODELS)]
      refute layout.titles.key?("nope")
      assert_equal Maker::ProjectKind::TITLE_MAX, layout.title_for("bom", "BOM").length
      assert_equal "Line one line two", layout.intro_for(key(MODELS)), "newlines collapse to one line"
      assert_nil layout.intro_for("photos")
      assert_nil layout.intro_for("tasks")
    end

    test "junk in widths, titles and intros is filtered rather than raised on" do
      layout = Maker::ProjectKind.layout_for(kind: "other",
                                             overrides: { "widths" => "full", "titles" => [ 1 ], "intros" => 7 },
                                             folders: FOLDERS)
      assert_equal({}, layout.widths)
      assert_equal({}, layout.titles)
      assert_equal({}, layout.intros)
    end

    test "a stored key for a folder that is gone drops out of widths, titles and intros too" do
      gone = key("d-vanished")
      layout = Maker::ProjectKind.layout_for(kind: "other",
                                             overrides: { "widths" => { gone => "full" }, "titles" => { gone => "X" },
                                                          "intros" => { gone => "Y" } },
                                             folders: FOLDERS)
      refute layout.widths.key?(gone)
      refute layout.titles.key?(gone)
      refute layout.intros.key?(gone)
      assert_equal "full", layout.width_for(gone), "the stale key still answers a default, never raises"
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
