require "test_helper"

class FilesHelperTest < ActiveSupport::TestCase
  # The existing tests here only read constants; `recipe_num` is an instance method, so mix the
  # module in rather than moving the whole file to ActionView::TestCase for one helper.
  include FilesHelper

  # THE TEST THAT MAKES "ONE VOCABULARY" A PROPERTY RATHER THAN A COINCIDENCE. Before this, the
  # chips and the project panel headings were two hand-written lists that named overlapping files
  # differently (.svg was "2D / laser" on one page and "Vector" on the other) and left the five
  # cad_source extensions with no chip at all. A hand-written family re-added later fails here.
  test "every chip extension comes from the role vocabulary" do
    assert_equal Maker::FileAttachment::ROLE_BY_EXT.keys.sort,
                 FilesHelper::EXT_FAMILIES.values.flatten.sort
  end

  test "every chip family is a role label" do
    assert_empty FilesHelper::EXT_FAMILIES.keys - Maker::FileAttachment::ROLE_LABELS.values
  end

  # `other` is a FALLBACK for unrecognised extensions, not an extension set — it has nothing to
  # render chips from, and a family with no extensions would render an empty labelled row.
  test "the other role contributes no family" do
    assert_not_includes FilesHelper::EXT_FAMILIES.keys, "Other"
    assert FilesHelper::EXT_FAMILIES.values.none?(&:empty?)
  end

  test "the families follow ROLE_LABELS order" do
    expected = Maker::FileAttachment::ROLE_LABELS.values & FilesHelper::EXT_FAMILIES.keys
    assert_equal expected, FilesHelper::EXT_FAMILIES.keys
  end

  # The complaint this item started from.
  test "cad_source extensions now have a chip" do
    assert_includes FilesHelper::EXT_FAMILIES["CAD source"], "scad"
    assert_includes FilesHelper::EXT_FAMILIES["CAD source"], "sldprt"
  end

  # STAGE 4, S4-2. The three formats the bench produces reached the vocabulary, so the dropdown's
  # optgroups follow for free — `CNC design` is a NEW family here, and a role whose extensions were
  # all in `other/` had no group at all.
  test "the bench formats have a filter chip family" do
    assert_includes FilesHelper::EXT_FAMILIES["Vector"], "ai"
    assert_includes FilesHelper::EXT_FAMILIES["Laser"],  "lbrn"
    assert_includes FilesHelper::EXT_FAMILIES["CNC design"], "mage"
  end

  # Every chip extension must be one FilesController will actually accept, or the chip is a control
  # that renders, links and silently does nothing. `markdown` is exactly 8 characters — the bound.
  test "every chip extension satisfies the controller's EXT_RE" do
    FilesHelper::EXT_FAMILIES.values.flatten.each do |ext|
      assert_match FilesController::EXT_RE, ext, "#{ext} would be dropped by the controller"
    end
  end

  # RECIPE NUMBERS. The laser/CNC panels used `.to_i`, which TRUNCATES: a layer cut at 6.67 mm/s
  # rendered "6 mm/s" — a 10 % error on the number the machine actually runs, shown as though it
  # were the setting. Every checked-in .lbrn2 fixture uses whole speeds and powers, so no test
  # could see it; the value that exposed it came off a real file.
  #
  # The other half is that the raw float is not printable either — a metadata Hash holds 50.0 and
  # 13.0, and "50.0 mm/s" is noise. So: round (never truncate), then drop a trailing zero that
  # carries no information.
  test "recipe_num keeps the decimals a value actually has" do
    assert_equal "6.67",  recipe_num(6.67)
    assert_equal "3.175", recipe_num(3.175)
    assert_equal "14.8",  recipe_num(14.8)
    assert_equal "0.5",   recipe_num(0.5)
  end

  test "recipe_num drops a meaningless trailing zero" do
    assert_equal "50",    recipe_num(50.0)
    assert_equal "13",    recipe_num(13.0)
    assert_equal "20000", recipe_num(20000.0)
    assert_equal "0",     recipe_num(0.0)
  end

  # MillMage stores 1/8" as 3.1749999523162842 and a feed rate as 14.800000190734863. Three
  # decimals is what MageMetadata already rounds tool values to, so the panel agrees with the
  # stored Hash instead of printing sixteen digits of binary noise.
  test "recipe_num rounds float noise to three decimals rather than showing it" do
    assert_equal "3.175", recipe_num(3.1749999523162842)
    assert_equal "14.8",  recipe_num(14.800000190734863)
  end

  # The metadata Hash comes out of a JSON column and is best-effort by design (LbrnMetadata omits
  # what it cannot read), so the panel has to survive a missing or junk value without rendering
  # the word "nil" next to a unit.
  test "recipe_num answers nil for anything that is not a number" do
    assert_nil recipe_num(nil)
    assert_nil recipe_num("")
    assert_nil recipe_num("fast")
  end

  test "recipe_num accepts a numeric string, since JSON round-trips are not guaranteed" do
    assert_equal "6.67", recipe_num("6.67")
    assert_equal "15",   recipe_num("15")
  end

  # --- ext_facet_groups: the type dropdown's optgroups ------------------------

  # THE INVERSION THAT IS THE WHOLE FEATURE: membership comes from the LIBRARY (`facets`), and
  # EXT_FAMILIES is consulted only for grouping and order. The chip row this replaced had it the
  # other way round and offered every extension in the vocabulary to everyone.
  test "ext_facet_groups offers only what the library holds, grouped by family" do
    groups = ext_facet_groups({ "stl" => 3, "svg" => 1 }, [])

    assert_equal [ [ "Models", [ [ "stl", 3 ] ] ], [ "Vector", [ [ "svg", 1 ] ] ] ], groups
  end

  # A family with nothing in it renders nothing — no empty labelled row.
  test "ext_facet_groups omits a family the library has no files for" do
    labels = ext_facet_groups({ "stl" => 1 }, []).map(&:first)

    assert_equal [ "Models" ], labels
    assert_not_includes labels, "G-code"
  end

  # THE FREE-TEXT ESCAPE HATCH'S REPLACEMENT. An extension no ROLE_BY_EXT entry names still has to
  # be reachable — and here it is strictly better than the field was, because the user does not have
  # to know it exists: it can only appear if they already own a file with it.
  test "ext_facet_groups files an unknown extension under Other, last" do
    groups = ext_facet_groups({ "stl" => 1, "kicad" => 2 }, [])

    assert_equal [ "Models", "Other" ], groups.map(&:first)
    assert_equal [ [ "kicad", 2 ] ], groups.last.last
  end

  # The dropdown ADDS and the chips REMOVE. `add_ext` unions into `ext`, so offering an active type
  # would be an option whose selection changes nothing.
  test "ext_facet_groups excludes types that are already active" do
    groups = ext_facet_groups({ "stl" => 3, "3mf" => 1 }, [ "stl" ])

    assert_equal [ [ "Models", [ [ "3mf", 1 ] ] ] ], groups
  end

  test "ext_facet_groups is empty when every type the library holds is already active" do
    assert_empty ext_facet_groups({ "stl" => 3 }, [ "stl" ])
  end

  # Within a family, alphabetical — a picker whose order changes as files are added is one you
  # cannot build muscle memory for.
  test "ext_facet_groups sorts within a family by extension, not by count" do
    groups = ext_facet_groups({ "stl" => 1, "3mf" => 99, "obj" => 5 }, [])

    assert_equal [ "3mf", "obj", "stl" ], groups.first.last.map(&:first)
  end

  # --- the file-cell data builders -------------------------------------------
  #
  # `file_menu_data` and `thumb_cell_data` need route helpers; the module is mixed in above, so mix
  # those in too rather than moving the whole file to ActionView::TestCase.
  include Rails.application.routes.url_helpers

  # An UNSAVED node is all the builders read: its id, its name and its parent.
  def menu_node(name = "widget.stl", parent: "d-1")
    Node.new(node_id: "n-1", name:, parent_node_id: parent)
  end

  # A NIL ORIGIN MUST YIELD nil, NOT "". Rails renders `data: { x: nil }` as NO attribute and
  # `data: { x: "" }` as `data-x=""` — and the regression net over these surfaces
  # (file_menu_wiring_test.rb, addon_origin_surfaces_test.rb) matches on ATTRIBUTE PRESENCE, so a
  # blank would be counted as a cell offering an addon link and break tests asserting exact sets.
  # (It would NOT, as one might assume, put an entry with no href in the menu: `""` is falsy in JS
  # and filemenu_controller.js is truthiness-guarded, so it produces no entry either way. The test
  # net is the reason, not the menu.)
  test "file_menu_data omits the addon keys entirely when no addon made the file" do
    data = file_menu_data(menu_node, nil)

    assert_nil data[:addon_open_url],
               "a blank renders data-addon-open-url=\"\", which the presence selectors count as a link"
    assert_nil data[:addon_open_label]
  end

  # THE PAIR TRAVELS TOGETHER, out of the one hash AddonOrigins builds — a cell carrying the url
  # with no label puts "undefined" in the menu.
  test "file_menu_data carries both addon keys when one is present" do
    data = file_menu_data(menu_node, { url: "/tools/boxes?state=7", label: "Edit in Box Generator" })

    assert_equal "/tools/boxes?state=7", data[:addon_open_url]
    assert_equal "Edit in Box Generator", data[:addon_open_label]
  end

  # THE MENU'S GATE IS NO LONGER note_url. It read `if (!noteUrl) return` until 2026-09-10 and now
  # asks whether there is ANY entry (`!noteUrl && !deleteUrl`), because a folder carries the delete
  # url alone. download_url must still force the attachment rather than trust the browser's
  # `download` attribute — on chunk_remote and s3 the endpoint 302s to a presigned CROSS-ORIGIN URL,
  # where `download` is ignored.
  test "file_menu_data always carries the note url, a forcing download url and where to delete" do
    data = file_menu_data(menu_node, nil)

    assert_equal file_notes_path("n-1"), data[:note_url]
    assert_includes data[:download_url], "download=1"
    assert_equal file_path("n-1"), data[:delete_url]
    assert_equal "widget.stl", data[:node_name]
    assert_equal "contextmenu->filemenu#open", data[:action]
  end

  # DETAILS IS THE LIBRARY WITH THIS FILE SELECTED (2026-10-21), built here like every other entry so
  # filemenu_controller.js never assembles a URL. The FOLDER is the file's parent, because
  # FilesController#index honours `selected` only for a file in the listing it renders; a file at
  # the library root has no parent, and its URL carries no folder.
  test "file_menu_data's details url opens the Library on the file's own folder with it selected" do
    assert_equal files_path(folder: "d-1", selected: "n-1"), file_menu_data(menu_node, nil)[:details_url]
    assert_equal files_path(selected: "n-1"), file_menu_data(menu_node(parent: nil), nil)[:details_url]
  end

  # APPENDED, NEVER REPLACED: the file menu's contextmenu action and the selection hooks share the
  # attribute. An absent new-tab url must render NO attribute (Rails drops a nil data value, but the
  # key must not even be there for an exact-hash caller).
  test "file_open_data appends the fileopen action and names a new-tab url only when given one" do
    data = file_open_data({ action: "contextmenu->filemenu#open", node_id: "n-1" })
    assert_equal "contextmenu->filemenu#open click->fileopen#click", data[:action]
    assert_equal "n-1", data[:node_id]
    refute data.key?(:fileopen_new_tab_url)
    assert_equal({ action: "click->fileopen#click" }, file_open_data)
    assert_equal "/files/n-1", file_open_data({}, new_tab: "/files/n-1")[:fileopen_new_tab_url]
  end

  # A FOLDER'S WHOLE MENU, ASSERTED AS AN EXACT HASH rather than key by key. The claim is not "it has
  # a delete url" but "it has NOTHING ELSE": a note url would open a popover POSTing to an endpoint
  # no directory has, a download url would put a dead entry on every folder, and a `node_id` would
  # enrol folders in the thumbnail poll. An exact comparison is the only shape that catches a key
  # someone adds by copying `file_menu_data`.
  test "folder_menu_data is the action, the name and the delete url, and nothing else" do
    assert_equal({ action: "contextmenu->filemenu#open", node_name: "cad", delete_url: file_path("dir-1") },
                 folder_menu_data("dir-1", "cad"))
  end

  # `node_name` IS THE CALLER'S, NEVER LOOKED UP. The menu's `confirm` reads it, and a lookup here
  # would be a query per row on a page rendering hundreds: `folder_menu_data` takes the name as an
  # argument, and `file_menu_data` reads it off the node its caller already holds (since 2026-10-21,
  # when Details needed the parent too).
  test "node_name passes through verbatim on both builders" do
    assert_equal "Bracket v2.stl", file_menu_data(menu_node("Bracket v2.stl"), nil)[:node_name]
    assert_equal "Bracket v2.stl", folder_menu_data("n-1", "Bracket v2.stl")[:node_name]
  end

  # `ext_label` IS AN ARGUMENT, NEVER DERIVED FROM THE NAME. `models/_hero_poster` passes "" and
  # `projects/_log_entry` passes "IMG"; neither is any file's extension, so a builder that derived
  # it would break both — and would put a second copy of the extension vocabulary in this file
  # beside EXT_FAMILIES, which is derived from ROLE_BY_EXT precisely so there is only one.
  test "thumb_cell_data passes its ext label through verbatim" do
    assert_equal({ thumbs_target: "cell", node_id: "n-1", ext: "IMG" },
                 thumb_cell_data("n-1", "IMG"))
    assert_equal "", thumb_cell_data("n-1", "")[:ext]
  end
end
