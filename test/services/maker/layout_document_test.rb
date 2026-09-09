require "test_helper"

module Maker
  # THE ONE GRAMMAR (2026-09-09, the page editor; spec §4). Pure arithmetic over a Layout and a
  # folder-name map — no rows, no port — so every rule here runs identically on the three legs.
  class LayoutDocumentTest < ActiveSupport::TestCase
    MODELS = "d-models".freeze
    FIRMWARE = "d-firmware".freeze
    FOLDERS = [ [ FIRMWARE, true ], [ MODELS, false ] ].freeze
    NAMES = { FIRMWARE => "firmware", MODELS => "models" }.freeze

    def key(id) = Maker::ProjectKind.folder_key(id)

    def layout(overrides = nil, kind: "other")
      Maker::ProjectKind.layout_for(kind:, overrides:, folders: FOLDERS)
    end

    def doc(overrides = nil, kind: "other") = Maker::LayoutDocument.new(layout(overrides, kind:), NAMES)

    def entry(result, key) = result.draft["panels"].find { |e| e["key"] == key }

    # --- the draft -----------------------------------------------------------------------------

    test "the draft lists every panel in order with hidden, width, and a view only where offered" do
      d = doc({ "hidden" => %w[tasks], "views" => { key(MODELS) => "list" },
                "widths" => { "photos" => "half" }, "titles" => { key(MODELS) => "Prints" } }).draft

      assert_equal 1, d["layout"]
      assert_equal layout.order, d["panels"].map { |e| e["key"] }
      files = d["panels"].find { |e| e["key"] == "attachments" }
      assert_equal({ "key" => "attachments", "hidden" => false, "width" => "full", "view" => "tiles" }, files)
      models = d["panels"].find { |e| e["key"] == key(MODELS) }
      assert_equal "list", models["view"]
      assert_equal "Prints", models["title"]
      refute models.key?("intro"), "an unset intro is absent, not nil"
      tasks = d["panels"].find { |e| e["key"] == "tasks" }
      assert tasks["hidden"]
      refute tasks.key?("view"), "Tasks offers no view, so the draft carries none"
      assert_equal "half", d["panels"].find { |e| e["key"] == "photos" }["width"]
    end

    # --- export ----------------------------------------------------------------------------------

    test "to_yaml names folders by name, writes width always, view where offered, title/intro/hidden when set" do
      text = doc({ "hidden" => %w[wiring], "views" => { key(MODELS) => "list" },
                   "titles" => { key(MODELS) => "Prints" },
                   "intros" => { key(MODELS) => "Everything you need to print: sliced." } }).to_yaml(project_name: "Desk Lamp")

      assert text.start_with?("# Desk Lamp, page layout."), text.lines.first
      assert_includes text, "layout: 1\n"
      assert_includes text, "- panel: attachments\n  width: full\n  view: tiles\n"
      # The QUOTE STYLE is Psych's to choose (single today; a version bump could pick double), so
      # the structural pin is the entry shape and the durable guard is the round trip below.
      assert_match(/- folder: models\n  title: Prints\n  intro: .Everything you need to print: sliced\..\n  width: full\n  view: list\n/, text)
      assert_includes text, "- panel: wiring\n  width: half\n  hidden: true\n"
      assert_includes text, "- panel: tasks\n  width: half\n"
      refute_includes text, "d-models", "a node id never appears in the shareable form"
      refute_includes text, "hidden: false"
    end

    # TOTAL LIKE THE LAYOUT (found in review): the names map and the layout are built from one
    # listing in production, but the export must not be the one path that raises when they differ.
    test "to_yaml leaves out a folder it has no name for rather than raising" do
      d = Maker::LayoutDocument.new(layout, { FIRMWARE => "firmware" })

      text = d.to_yaml(project_name: "Lamp")

      assert_includes text, "- folder: firmware\n"
      refute_includes text, "models"
      refute_includes text, MODELS
      assert d.parse(text).ok?, "what it exports it can read back"
    end

    test "export then parse is the identity on a layout with every attribute set" do
      d = doc({ "order" => [ "attachments", key(MODELS), "photos", "tasks", "build_log", key(FIRMWARE) ] + %w[schematics bom wiring releases sheets publish],
                "hidden" => %w[wiring sheets], "views" => { key(MODELS) => "list", "attachments" => "list" },
                "widths" => { "tasks" => "full", "photos" => "half" },
                "titles" => { key(MODELS) => "Prints", "tasks" => "To do" },
                "intros" => { key(MODELS) => "Sliced for 0.2 mm." } })

      result = d.parse(d.to_yaml(project_name: "Lamp"))

      assert result.ok?, result.errors.inspect
      assert_equal [], result.notes
      assert_equal d.draft, result.draft
    end

    # --- parse: the grammar -----------------------------------------------------------------------

    test "parse: a folder is looked up by name and becomes its key" do
      result = doc.parse("layout: 1\npanels:\n  - folder: models\n    title: Prints\n")

      assert result.ok?, result.errors.inspect
      assert_equal key(MODELS), result.draft["panels"].first["key"]
      assert_equal "Prints", entry(result, key(MODELS))["title"]
    end

    test "parse: listed entries take the order given, unlisted panels follow in their current relative order" do
      result = doc.parse("layout: 1\npanels:\n  - panel: tasks\n  - panel: bom\n")

      assert result.ok?
      order = result.draft["panels"].map { |e| e["key"] }
      assert_equal %w[tasks bom], order.first(2)
      rest = layout.order - %w[tasks bom]
      assert_equal rest, order[2..], "the unmentioned keep their relative order"
    end

    test "parse: an attribute not given keeps the draft's current value; a given one replaces it" do
      result = doc({ "titles" => { "tasks" => "To do" }, "widths" => { "tasks" => "full" } })
                 .parse("layout: 1\npanels:\n  - panel: tasks\n    width: half\n")

      assert result.ok?
      assert_equal "To do", entry(result, "tasks")["title"]
      assert_equal "half", entry(result, "tasks")["width"]
    end

    test "parse: a folder this project lacks is skipped with a note, and the rest applies" do
      result = doc.parse("layout: 1\npanels:\n  - folder: enclosure\n    width: half\n  - panel: tasks\n    width: full\n")

      assert result.ok?
      assert_equal [ "This project has no folder named “enclosure”; that entry was skipped." ], result.notes
      assert_equal "full", entry(result, "tasks")["width"]
      assert_equal layout.order.size, result.draft["panels"].size
    end

    test "parse: hidden on an always-shown panel is ignored with a note" do
      result = doc.parse("layout: 1\npanels:\n  - panel: attachments\n    hidden: true\n")

      assert result.ok?
      refute entry(result, "attachments")["hidden"]
      assert_equal [ "Files is always shown; `hidden` was ignored." ], result.notes
    end

    test "parse: publish listed anywhere but last is moved to the end with a note" do
      result = doc.parse("layout: 1\npanels:\n  - panel: publish\n  - panel: tasks\n")

      assert result.ok?
      assert_equal "publish", result.draft["panels"].last["key"]
      assert_equal "tasks", result.draft["panels"].first["key"]
      assert_equal [ "Publish is always last; it was moved to the end." ], result.notes
    end

    test "parse: each error names its entry and blocks Apply" do
      cases = {
        "layout: 1\npanels:\n  - panel: tsaks\n"                          => /Entry 1: unknown panel “tsaks”/,
        "layout: 1\npanels:\n  - panel: tasks\n    hiden: true\n"         => /Entry 1: unknown attribute “hiden”/,
        "layout: 1\npanels:\n  - panel: tasks\n    folder: models\n"      => /Entry 1 names both `panel` and `folder`/,
        "layout: 1\npanels:\n  - panel: photos\n    view: list\n"         => /Entry 1: Photos has no view/,
        "layout: 1\npanels:\n  - panel: attachments\n    view: browser\n" => /Entry 1: Files does not offer the browser view/,
        "layout: 1\npanels:\n  - panel: tasks\n    width: wide\n"         => /Entry 1: width must be full or half/,
        "layout: 1\npanels:\n  - panel: tasks\n    title: #{'x' * 61}\n"  => /Entry 1: the title is over 60 characters/,
        "layout: 1\npanels:\n  - panel: tasks\n    intro: #{'x' * 201}\n" => /Entry 1: the intro is over 200 characters/,
        "layout: 1\npanels:\n  - panel: tasks\n    hidden: yes please\n"  => /Entry 1: hidden must be true or false/,
        "layout: 1\npanels:\n  - tasks\n"                                 => /Entry 1 is not a mapping/,
        "layout: 1\npanels:\n  - width: full\n"                           => /Entry 1 names neither `panel` nor `folder`/,
        "layout: 1\npanels:\n  - panel: tasks\n  - panel: tasks\n"        => /Entry 2 names Tasks a second time/,
        "layout: 2\npanels: []\n"                                         => /newer than this server/,
        "layout: 2.0\npanels: []\n"                                       => /newer than this server/,
        "panels: []\n"                                                    => /`layout: 1` is required/,
        "layout: 1\npanels: {}\n"                                         => /`panels` must be a list/,
        "layout: 1\npanels: []\nlook: dark\n"                             => /Unknown key “look” at the top level/,
        "- just\n- a list\n"                                              => /must be a mapping/,
        "layout: 1\npanels:\n  - panel: tasks\n   width: [\n"             => /Line \d+, column \d+/,
        "x" * (16 * 1024 + 1)                                             => /over 16 KB/,
        # 8,193 CHARACTERS but 16,386 BYTES: the cap is bytes, and a `length` would let this through
        # while the ASCII case above stayed green (found in review).
        "é" * (8 * 1024 + 1)                                              => /over 16 KB/
      }
      cases.each do |text, message|
        result = doc.parse(text)
        refute result.ok?, "expected an error for #{text.inspect[0, 60]}"
        assert_match message, result.errors.join(" "), text.inspect[0, 60]
      end
    end

    test "parse: safe_load refuses tags and aliases rather than instantiating anything" do
      refute doc.parse("layout: 1\npanels: !ruby/object:Object {}\n").ok?
      refute doc.parse("a: &x 1\nlayout: 1\npanels: *x\n").ok?
    end

    # --- from_draft: the browser's document ------------------------------------------------------

    test "from_draft validates like parse and drops a folder key that is no longer in the vocabulary, with a note" do
      result = doc.from_draft("layout" => 1, "panels" => [
        { "key" => "tasks", "hidden" => true, "width" => "full" },
        { "key" => key("d-vanished"), "hidden" => false, "width" => "full" },
        { "key" => "attachments", "hidden" => true, "width" => "full", "view" => "list", "title" => "Stuff" }
      ])

      assert result.ok?, result.errors.inspect
      assert_equal %w[tasks attachments], result.draft["panels"].map { |e| e["key"] }.first(2)
      assert entry(result, "tasks")["hidden"]
      refute entry(result, "attachments")["hidden"]
      assert_equal "list", entry(result, "attachments")["view"]
      assert_includes result.notes, "A folder changed on disk while you were editing; its panel keeps its defaults."
      assert_includes result.notes, "Files is always shown; `hidden` was ignored."
    end

    test "from_draft refuses a fixed key it does not know and anything that is not a draft" do
      refute doc.from_draft("layout" => 1, "panels" => [ { "key" => "../../etc" } ]).ok?
      refute doc.from_draft("nope").ok?
      refute doc.from_draft("layout" => 1, "panels" => "x").ok?
    end

    # --- the column ----------------------------------------------------------------------------

    test "column writes the six maps the layout reads back, and only the set values" do
      result = doc.parse(<<~YAML)
        layout: 1
        panels:
          - folder: models
            title: Prints
            intro: Sliced.
            view: list
          - panel: tasks
            hidden: true
      YAML
      column = doc.column(result.draft)

      assert_equal layout.order.size, column["order"].size
      assert_equal [ key(MODELS), "tasks" ], column["order"].first(2)
      assert_equal %w[tasks], column["hidden"]
      assert_equal "list", column["views"][key(MODELS)]
      assert_equal({ key(MODELS) => "Prints" }, column["titles"])
      assert_equal({ key(MODELS) => "Sliced." }, column["intros"])
      assert_equal "full", column["widths"][key(MODELS)]
      assert_equal "half", column["widths"]["tasks"]

      round = Maker::ProjectKind.layout_for(kind: "other", overrides: column, folders: FOLDERS)
      assert_equal result.draft, Maker::LayoutDocument.new(round, NAMES).draft, "the column reads back as the same draft"
    end
  end
end
