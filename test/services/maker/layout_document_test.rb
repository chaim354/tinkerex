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

    test "parse merges into the base draft when one is given, so an unsaved change survives Apply" do
      d = doc
      base = d.from_draft("layout" => 1, "panels" => [ { "key" => "tasks", "hidden" => true, "width" => "full" } ]).draft

      result = d.parse("layout: 1\npanels:\n  - panel: bom\n    hidden: true\n", base: base)

      assert result.ok?, result.errors.inspect
      assert entry(result, "tasks")["hidden"], "the base's unsaved hide survives"
      assert_equal "full", entry(result, "tasks")["width"]
      assert entry(result, "bom")["hidden"]
      assert_equal "bom", result.draft["panels"].first["key"]
    end

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
        # BOTH DISCRIMINATOR MESSAGES NAME ALL THREE SINCE `block:` JOINED THEM (2026-09-09,
        # content blocks): one condition, one answer — a message per pair would be the shape §14a
        # forbids, and "neither `panel` nor `folder`" would send a reader looking for the third.
        "layout: 1\npanels:\n  - panel: tasks\n    folder: models\n"      => /Entry 1 names more than one of `panel`, `folder` and `block`/,
        "layout: 1\npanels:\n  - panel: photos\n    view: list\n"         => /Entry 1: Photos has no view/,
        "layout: 1\npanels:\n  - panel: attachments\n    view: browser\n" => /Entry 1: Files does not offer the browser view/,
        "layout: 1\npanels:\n  - panel: tasks\n    width: wide\n"         => /Entry 1: width must be full or half/,
        "layout: 1\npanels:\n  - panel: tasks\n    title: #{'x' * 61}\n"  => /Entry 1: the title is over 60 characters/,
        "layout: 1\npanels:\n  - panel: tasks\n    intro: #{'x' * 201}\n" => /Entry 1: the intro is over 200 characters/,
        "layout: 1\npanels:\n  - panel: tasks\n    hidden: yes please\n"  => /Entry 1: hidden must be true or false/,
        "layout: 1\npanels:\n  - tasks\n"                                 => /Entry 1 is not a mapping/,
        "layout: 1\npanels:\n  - width: full\n"                           => /Entry 1 names none of `panel`, `folder` or `block`/,
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

    # --- blocks and the page (2026-09-09, content blocks; spec §5) -------------------------------

    BlockRow = Struct.new(:key, :kind, :heading, :body, :url, :line, :caption, :node_id, keyword_init: true)
    IMG_SIDE = "n-side".freeze
    IMG_FRONT = "n-front".freeze
    IMAGES = { IMG_SIDE => "photos/side.jpg", IMG_FRONT => "photos/lamp-front.jpg" }.freeze

    def rows
      [ BlockRow.new(key: "aaaaaaaaaaaa", kind: "text", heading: "Why a printed shade", body: "A paper shade yellows.\n\n- two walls"),
        BlockRow.new(key: "bbbbbbbbbbbb", kind: "link", heading: "Printables page", url: "https://www.printables.com/model/1", line: "Sliced files."),
        BlockRow.new(key: "cccccccccccc", kind: "image", node_id: IMG_SIDE, caption: "Side on.") ]
    end

    def bkey(id) = Maker::ProjectKind.block_key(id)

    def blocks_layout(overrides = nil)
      Maker::ProjectKind.layout_for(kind: "other", overrides:, folders: FOLDERS, blocks: rows.map { |r| [ r.key, r.kind ] })
    end

    def bdoc(overrides = nil, page: { "description" => "A desk lamp.", "cover" => IMG_FRONT })
      Maker::LayoutDocument.new(blocks_layout(overrides), NAMES, blocks: rows, images: IMAGES, page:)
    end

    test "the draft carries the page and each block's content, with a link's title and an image's file" do
      d = bdoc.draft
      assert_equal({ "description" => "A desk lamp.", "cover" => IMG_FRONT }, d["page"])
      text = d["panels"].find { |e| e["key"] == bkey("aaaaaaaaaaaa") }
      assert_equal({ "key" => bkey("aaaaaaaaaaaa"), "kind" => "text", "hidden" => false, "width" => "full",
                     "heading" => "Why a printed shade", "body" => "A paper shade yellows.\n\n- two walls" }, text)
      link = d["panels"].find { |e| e["key"] == bkey("bbbbbbbbbbbb") }
      assert_equal "Printables page", link["title"]
      assert_equal "https://www.printables.com/model/1", link["url"]
      assert_equal "half", link["width"]
      image = d["panels"].find { |e| e["key"] == bkey("cccccccccccc") }
      assert_equal IMG_SIDE, image["file"]
      assert_equal "Side on.", image["caption"]
      refute d["panels"].find { |e| e["key"] == "attachments" }.key?("kind")
    end

    test "to_yaml writes page and blocks with ids and paths, and a cover outside the folder becomes a comment" do
      text = bdoc.to_yaml(project_name: "Lamp")
      assert_includes text, "page:\n  description: A desk lamp.\n  cover: photos/lamp-front.jpg\n"
      assert_includes text, "- block: text\n  id: aaaaaaaaaaaa\n  heading: Why a printed shade\n  body: |-\n    A paper shade yellows.\n\n    - two walls\n  width: full\n"
      assert_includes text, "- block: link\n  id: bbbbbbbbbbbb\n  url: https://www.printables.com/model/1\n  title: Printables page\n  line: Sliced files.\n  width: half\n"
      assert_includes text, "- block: image\n  id: cccccccccccc\n  file: photos/side.jpg\n  caption: Side on.\n  width: full\n"
      refute_includes text, IMG_SIDE

      outside = bdoc(page: { "description" => nil, "cover" => "n-elsewhere" }).to_yaml(project_name: "Lamp")
      assert_includes outside, "# cover: set from a file outside the project folder; the picker cannot name it\n"
      # THE COMMENT ITSELF SPELLS `cover:`, so the pin is that no `page` MAPPING was written — the
      # plan's `refute_includes outside, "cover:"` can never pass beside the line above it.
      refute_includes outside, "page:"
      refute_includes outside, "description:"
    end

    test "export then parse is the identity with blocks and page" do
      d = bdoc({ "hidden" => [ bkey("bbbbbbbbbbbb") ], "widths" => { bkey("aaaaaaaaaaaa") => "half" } })
      result = d.parse(d.to_yaml(project_name: "Lamp"))
      assert result.ok?, result.errors.inspect
      assert_equal [], result.notes
      assert_equal d.draft, result.draft
    end

    test "parse: a known id updates, an unknown or missing id creates, unmentioned blocks keep their place" do
      yaml = <<~YAML
        layout: 1
        panels:
          - block: text
            id: aaaaaaaaaaaa
            heading: New heading
          - block: link
            id: zzzzzzzzzzzz
            url: https://example.com/x
            title: Elsewhere
          - block: image
            file: photos/lamp-front.jpg
            caption: Front.
      YAML
      result = bdoc.parse(yaml)
      assert result.ok?, result.errors.inspect
      updated = entry(result, bkey("aaaaaaaaaaaa"))
      assert_equal "New heading", updated["heading"]
      assert_equal "A paper shade yellows.\n\n- two walls", updated["body"], "an absent attribute keeps the block's body"
      new_link = result.draft["panels"].find { |e| e["kind"] == "link" && e["key"] != bkey("bbbbbbbbbbbb") }
      assert_match(/\Ablock:new-\d+\z/, new_link["key"])
      assert_equal "Elsewhere", new_link["title"]
      new_image = result.draft["panels"].find { |e| e["kind"] == "image" && e["file"] == IMG_FRONT }
      assert_match(/\Ablock:new-\d+\z/, new_image["key"])
      assert_equal "Front.", new_image["caption"]
      assert_includes result.draft["panels"].map { |e| e["key"] }, bkey("bbbbbbbbbbbb"), "the unmentioned link keeps its place"
      assert_equal 3 + 2, result.draft["panels"].count { |e| e["kind"] }
    end

    test "parse: new keys do not collide with the base draft's own new blocks" do
      base = bdoc.from_draft("layout" => 1, "panels" => [ { "key" => "block:new-1", "kind" => "text", "body" => "unsaved", "hidden" => false, "width" => "full" } ]).draft
      result = bdoc.parse("layout: 1\npanels:\n  - block: text\n    body: pasted\n", base: base)
      assert result.ok?, result.errors.inspect
      keys = result.draft["panels"].map { |e| e["key"] }
      assert_includes keys, "block:new-1"
      assert_includes keys, "block:new-2"
    end

    test "parse: the page section replaces what is given, keeps what is absent, and notes a cover it cannot find" do
      result = bdoc.parse("layout: 1\npage:\n  description: Rewritten.\npanels: []\n")
      assert result.ok?
      assert_equal({ "description" => "Rewritten.", "cover" => IMG_FRONT }, result.draft["page"])

      result = bdoc.parse("layout: 1\npage:\n  cover: photos/nope.jpg\npanels: []\n")
      assert result.ok?
      assert_equal IMG_FRONT, result.draft["page"]["cover"]
      assert_equal [ "No image at “photos/nope.jpg” in the project folder; the cover was left as it is." ], result.notes

      result = bdoc.parse("layout: 1\npage:\n  cover: ~\npanels: []\n")
      assert result.ok?
      assert_nil result.draft["page"]["cover"], "an explicit null clears the cover"
    end

    test "parse: block errors name their entry and block Apply" do
      cases = {
        "layout: 1\npanels:\n  - block: video\n    url: https://x\n"                    => /Entry 1: unknown block kind “video”/,
        "layout: 1\npanels:\n  - block: link\n    title: t\n    url: ftp://x\n"             => /Entry 1: url must be an http or https URL/,
        "layout: 1\npanels:\n  - block: link\n    url: https://x.example\n"                 => /Entry 1: a link needs a title/,
        "layout: 1\npanels:\n  - block: link\n    title: t\n    url: https://a.example/#{'x' * Maker::ProjectBlock::URL_MAX}\n" => /Entry 1: the url is over 2048 characters/,
        "layout: 1\npanels:\n  - block: image\n    file: photos/nope.jpg\n"                => /Entry 1: no image at “photos\/nope.jpg”/,
        "layout: 1\npanels:\n  - block: text\n    heading: #{'x' * 81}\n"                  => /Entry 1: the heading is over 80 characters/,
        "layout: 1\npanels:\n  - block: text\n    view: list\n"                            => /Entry 1: unknown attribute “view”/,
        "layout: 1\npanels:\n  - block: text\n    body: x\n    panel: tasks\n"             => /Entry 1 names more than one of `panel`, `folder` and `block`/,
        "layout: 1\npanels:\n  - block: text\n"                                             => /Entry 1: a text block needs a heading or a body/,
        "layout: 1\npage: nope\npanels: []\n"                                              => /`page` must be a mapping/,
        "layout: 1\npage:\n  look: dark\npanels: []\n"                                     => /Unknown key “look” under `page`/
      }
      cases.each do |text, message|
        result = bdoc.parse(text)
        refute result.ok?, "expected an error for #{text.inspect[0, 60]}"
        assert_match message, result.errors.join(" "), text.inspect[0, 60]
      end
    end

    # THE BODY CAP IS REACHABLE FROM THE DRAFT AND NOT FROM YAML, and the plan's YAML case for it
    # could not have gone green: BODY_MAX (20 KB) is LARGER than the text cap parse applies first
    # (MAX_BYTES, 16 KB), so a body over 20 KB in a pasted layout is answered by the text cap.
    test "a body over 20 KB is an error from the draft; through YAML the 16 KB text cap answers first" do
      big = "x" * (Maker::ProjectBlock::BODY_MAX + 1)
      result = bdoc.from_draft("layout" => 1, "panels" => [ { "key" => "block:new-1", "kind" => "text", "body" => big } ])
      refute result.ok?
      assert_match(/Entry 1: the body is over 20 KB/, result.errors.join(" "))

      assert_match(/over 16 KB/, bdoc.parse("layout: 1\npanels:\n  - block: text\n    body: #{big}\n").errors.join(" "))
    end

    test "parse: an existing image block whose file is not in the folder is a note, not an error" do
      result = bdoc.parse("layout: 1\npanels:\n  - block: image\n    id: cccccccccccc\n    file: photos/nope.jpg\n")
      assert result.ok?
      assert_equal IMG_SIDE, entry(result, bkey("cccccccccccc"))["file"]
      assert_equal [ "No image at “photos/nope.jpg” in the project folder; the block keeps its picture." ], result.notes
    end

    test "the cap: a text that would leave more than CAP blocks is an error" do
      many = (1..38).map { |i| "  - block: text\n    body: b#{i}\n" }.join
      result = bdoc.parse("layout: 1\npanels:\n#{many}")
      refute result.ok?
      assert_match(/more than #{Maker::ProjectBlock::CAP} blocks/, result.errors.join(" "))
    end

    test "a duplicated entry that also misspells an attribute reports both, as slice 1 did" do
      result = doc.parse("layout: 1\npanels:\n  - panel: tasks\n  - panel: tasks\n    hiden: true\n")
      refute result.ok?
      assert_includes result.errors, "Entry 2: unknown attribute “hiden”."
      assert_includes result.errors, "Entry 2 names Tasks a second time."
    end

    test "an image block whose picture is not in the folder is left out of the text and said so in the header" do
      d = Maker::LayoutDocument.new(blocks_layout, NAMES, blocks: rows, images: { IMG_FRONT => "photos/lamp-front.jpg" }, page: {})
      text = d.to_yaml(project_name: "Lamp")
      refute_includes text, "- block: image"
      assert_includes text, "# image block cccccccccccc: its picture is outside the project folder or gone; left out of this text\n"
      assert d.parse(text).ok?, "what it exports it can read back"
    end

    test "a block's width and hidden are applied and checked like a panel's" do
      result = bdoc.parse("layout: 1\npanels:\n  - block: text\n    id: aaaaaaaaaaaa\n    width: half\n    hidden: true\n")
      assert result.ok?, result.errors.inspect
      assert_equal [ "half", true ], entry(result, bkey("aaaaaaaaaaaa")).values_at("width", "hidden")
      assert_match(/width must be full or half/, bdoc.parse("layout: 1\npanels:\n  - block: text\n    id: aaaaaaaaaaaa\n    width: wide\n").errors.join(" "))
      assert_match(/hidden must be true or false/, bdoc.parse("layout: 1\npanels:\n  - block: text\n    id: aaaaaaaaaaaa\n    hidden: yes please\n").errors.join(" "))
    end

    test "an unsaved block exports without an id, and a known id under another kind creates rather than converts" do
      base = bdoc.from_draft("layout" => 1, "panels" => [ { "key" => "block:new-1", "kind" => "text", "body" => "unsaved", "hidden" => false, "width" => "full" } ]).draft
      text = bdoc.to_yaml(base, project_name: "Lamp")
      assert_includes text, "- block: text\n  body: unsaved\n"
      refute_includes text, "id: new-1"

      result = bdoc.parse("layout: 1\npanels:\n  - block: link\n    id: aaaaaaaaaaaa\n    url: https://a.example\n    title: A\n")
      assert result.ok?, result.errors.inspect
      assert_equal "text", entry(result, bkey("aaaaaaaaaaaa"))["kind"], "the text block is untouched"
      assert result.draft["panels"].any? { |e| e["kind"] == "link" && e["key"].start_with?("block:new-") }, "a new link was created instead"
    end

    test "from_draft refuses a page that is not a mapping, and names a strange block key as a block" do
      refute bdoc.from_draft("layout" => 1, "page" => "nope", "panels" => []).ok?
      result = bdoc.from_draft("layout" => 1, "panels" => [ { "key" => "block:dddddddddddd", "kind" => "text", "body" => "x" } ])
      assert_match(/unknown block “block:dddddddddddd”/, result.errors.join(" "))
    end

    test "from_draft accepts new-keyed blocks and validates them like YAML" do
      result = bdoc.from_draft("layout" => 1, "page" => { "description" => " Two  lines\nhere ", "cover" => nil },
                               "panels" => [ { "key" => "block:new-1", "kind" => "link", "url" => "https://a.example", "title" => "A", "hidden" => false, "width" => "half" } ])
      assert result.ok?, result.errors.inspect
      assert_equal "Two  lines\nhere", result.draft["page"]["description"], "stripped, never collapsed: a description keeps its lines"
      assert_nil result.draft["page"]["cover"]
      assert_equal "A", entry(result, "block:new-1")["title"]

      bad = bdoc.from_draft("layout" => 1, "panels" => [ { "key" => "block:new-1", "kind" => "link", "url" => "javascript:x", "title" => "A" } ])
      refute bad.ok?
      unknown = bdoc.from_draft("layout" => 1, "panels" => [ { "key" => "block:dddddddddddd", "kind" => "text", "body" => "x" } ])
      refute unknown.ok?, "a block key that is neither new nor a row of this project is refused"
    end

    test "blocks_from and page_from hand Save what it writes" do
      result = bdoc.parse(<<~YAML)
        layout: 1
        page:
          description: Rewritten.
          cover: photos/side.jpg
        panels:
          - block: link
            url: https://a.example
            title: A
            line: one
          - block: text
            id: aaaaaaaaaaaa
            body: changed
      YAML
      assert result.ok?, result.errors.inspect
      blocks = bdoc.blocks_from(result.draft)
      assert_equal 4, blocks.size
      new_link = blocks.find { |b| b["key"].start_with?("block:new-") }
      assert_equal({ "kind" => "link", "heading" => "A", "url" => "https://a.example", "line" => "one", "body" => nil, "caption" => nil, "node_id" => nil },
                   new_link.except("key"))
      assert_equal "changed", blocks.find { |b| b["key"] == bkey("aaaaaaaaaaaa") }["body"]
      assert_equal({ "description" => "Rewritten.", "cover_node_id" => IMG_SIDE }, bdoc.page_from(result.draft))
      assert_nil bdoc.page_from("layout" => 1, "panels" => []), "no page section, nothing to write"
    end

    test "the six-map column still ignores block content and keeps block keys in order, hidden and widths" do
      d = bdoc({ "hidden" => [ bkey("aaaaaaaaaaaa") ] })
      column = d.column(d.draft)
      assert_includes column["order"], bkey("aaaaaaaaaaaa")
      assert_equal [ bkey("aaaaaaaaaaaa") ], column["hidden"]
      assert_equal "half", column["widths"][bkey("bbbbbbbbbbbb")]
      refute column.key?("blocks")
      # A LINK'S `title` IS THE LINK'S LABEL, NOT A PANEL TITLE OVERRIDE: the sparse text maps are
      # built from the non-block entries, or every Save would write block content into the layout.
      refute column["titles"].key?(bkey("bbbbbbbbbbbb"))
      assert_equal({}, column["titles"])
    end
  end
end
