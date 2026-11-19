require "test_helper"

module Maker
  class Readme
    # LIVE REGIONS (2026-11-05; docs/superpowers/specs/2026-11-05-readme-panel-live-regions-design.md
    # §3–§4). The grammar, the splice in both modes, each emitter over a real share folder, and the
    # one place the file and the page differ (a non-photo `image` region).
    #
    # A FRESH SHARE LIBRARY PER TEST, PINNED BEFORE ANY NODE IS CREATED: `files_at`/`relative_path`
    # read the listing's tree, which readme_test.rb's `project_folder!` shape gives us without a
    # single port write (the rows plus the directory they claim to be).
    class LiveTest < ActiveSupport::TestCase
      setup do
        @root = use_fresh_share_library!
        @user = User.create!(email: "live-#{SecureRandom.hex(4)}@example.com",
                             confirmed_at: Time.current, omniauth_signup: true)
        @project = @user.maker_projects.create!(name: "Desk Lamp")
        @folder = project_folder!(@user, @project)
      end

      def project_folder!(user, project)
        folder = project_folder_rows!(user, project)
        user.nodes.find_by!(node_id: folder.parent_node_id).update!(storage_path: Maker::ProjectFolders::ROOT)
        folder.update!(storage_path: File.join(Maker::ProjectFolders::ROOT, project.slug))
        @root.join(folder.storage_path).mkpath
        folder
      end

      def dir!(name, parent)
        create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "dir",
                     parent_node_id: parent.node_id, mtime: 1, size: 0)
      end

      # mtime in NANOSECONDS, as the catalog stores it: 2026-07-20 12:00 UTC.
      MTIME = Time.utc(2026, 7, 20, 12).to_i * 1_000_000_000

      def file!(name, parent, size: 51_200, mtime: MTIME)
        create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "file",
                     parent_node_id: parent.node_id, mtime:, size:)
      end

      def listing = Maker::ProjectFolderListing.new(@user, @project)

      def context(**kw)
        Maker::Readme::Live::Context.new(user: @user, project: @project, listing:, **kw)
      end

      def expand(text, mode:, **kw) = Maker::Readme::Live.expand(text, context: context(**kw), mode:)

      # --- the grammar --------------------------------------------------------------------------

      test "a closed region, an unclosed one and prose are told apart, with arguments trimmed" do
        text = "# Lamp\n\n<!-- tinkerex:files  laser  -->\n\nold body\n\n<!-- /tinkerex -->\nmore\n<!-- tinkerex:tasks -->\nprose after\n"
        regions = Maker::Readme::Live.regions(text)

        assert_equal 2, regions.size
        assert_equal [ "files", "laser", 2, 6 ], regions[0].to_h.values_at(:directive, :args, :open_line, :close_line)
        assert regions[0].closed?
        assert_equal [ "tasks", "", 8, nil ], regions[1].to_h.values_at(:directive, :args, :open_line, :close_line)
        refute regions[1].closed?
      end

      test "a second opener before a closer ends the first region empty; a stray closer is prose" do
        text = "<!-- tinkerex:bom -->\n<!-- tinkerex:tasks -->\n\nbody\n\n<!-- /tinkerex -->\n<!-- /tinkerex -->\n"
        regions = Maker::Readme::Live.regions(text)

        assert_equal %w[bom tasks], regions.map(&:directive)
        refute regions[0].closed?
        assert_equal 1, regions[1].open_line
        assert_equal 5, regions[1].close_line
      end

      test "an image region names its node id for the thumbnail union; the others name none" do
        regions = Maker::Readme::Live.regions("<!-- tinkerex:image abc123 The robber -->\n<!-- tinkerex:bom -->\n")
        assert_equal [ "abc123", nil ], regions.map(&:node_id)
      end

      test "CRLF line endings are regions too" do
        regions = Maker::Readme::Live.regions("<!-- tinkerex:tasks -->\r\n\r\n- [ ] a\r\n\r\n<!-- /tinkerex -->\r\n")
        assert_equal 1, regions.size
        assert regions[0].closed?
      end

      # --- the splice ---------------------------------------------------------------------------

      test "file mode rewrites a recognised region as marker, blank, body, blank, marker and closes an open one" do
        @project.tasks.create!(user: @user, title: "Cut the base", status: "done", position: 0)
        out = expand("# Lamp\n\n<!-- tinkerex:tasks -->\nTail prose.\n", mode: :file)

        assert_equal "# Lamp\n\n<!-- tinkerex:tasks -->\n\n- [x] Cut the base\n\n<!-- /tinkerex -->\nTail prose.\n", out
      end

      test "file mode replaces whatever a maker typed inside a region" do
        @project.tasks.create!(user: @user, title: "Cut the base", status: "todo", position: 0)
        out = expand("<!-- tinkerex:tasks -->\n\nmy own notes\n\n<!-- /tinkerex -->\n", mode: :file)

        assert_equal "<!-- tinkerex:tasks -->\n\n- [ ] Cut the base\n\n<!-- /tinkerex -->\n", out
        refute_includes out, "my own notes"
      end

      test "page mode emits the body alone, with no markers anywhere" do
        @project.tasks.create!(user: @user, title: "Cut the base", status: "todo", position: 0)
        out = expand("# Lamp\n\n<!-- tinkerex:tasks -->\n\nstale\n\n<!-- /tinkerex -->\n", mode: :page)

        assert_equal "# Lamp\n\n\n- [ ] Cut the base\n\n", out
        refute_includes out, "<!--"
      end

      test "an unrecognised directive is verbatim in the file and loses only its markers on the page" do
        text = "<!-- tinkerex:weather zurich -->\n\nsunny\n\n<!-- /tinkerex -->\n"

        assert_equal text, expand(text, mode: :file)
        assert_equal "\nsunny\n\n", expand(text, mode: :page)
      end

      test "a directive with bad arguments is treated as unrecognised" do
        text = "<!-- tinkerex:log many -->\n"
        assert_equal text, expand(text, mode: :file)
        assert_equal "", expand(text, mode: :page)
      end

      test "with no context every region is left as written, markers stripped on the page" do
        text = "<!-- tinkerex:tasks -->\n\n- [ ] saved\n\n<!-- /tinkerex -->\n"
        assert_equal text, Maker::Readme::Live.expand(text, context: nil, mode: :file)
        assert_equal "\n- [ ] saved\n\n", Maker::Readme::Live.expand(text, context: nil, mode: :page)
      end

      test "regions past the twentieth are left as written" do
        text = ([ "<!-- tinkerex:tasks -->" ] * 21).join("\n") + "\n"
        out = expand(text, mode: :file)

        assert_equal 20, out.scan("<!-- /tinkerex -->").size
        assert_equal 21, out.scan("<!-- tinkerex:tasks -->").size
      end

      test "mode is checked" do
        assert_raises(ArgumentError) { expand("x", mode: :html) }
      end

      # --- files --------------------------------------------------------------------------------

      test "files lists one folder's own files, sorted, with role label, size and date, linking relative paths" do
        laser = dir!("laser", @folder)
        file!("game box.lbrn2", laser, size: 51_200)
        file!("Harbor tokens.lbrn2", laser, size: 2_048)
        file!("box.svg", laser, size: 100, mtime: nil)
        file!("box_backup.lbrn2", laser) # a backup (Maker::FileAttachment.backup?): diverted out of the folder's files
        inner = dir!("old", laser)
        file!("v1.lbrn2", inner)       # not descended into

        out = expand("<!-- tinkerex:files laser -->\n", mode: :page)

        assert_equal <<~MD.strip, out.strip
          | File | Kind | Size | Modified |
          |---|---|---|---|
          | [box.svg](laser/box.svg) | Vector | 100 Bytes | — |
          | [game box.lbrn2](laser/game box.lbrn2) | Laser | 50 KB | 2026-07-20 |
          | [Harbor tokens.lbrn2](laser/Harbor tokens.lbrn2) | Laser | 2 KB | 2026-07-20 |
        MD
      end

      test "files . lists the root's loose files and leaves the README itself out" do
        file!("README.md", @folder)
        file!("notes.txt", @folder)

        out = expand("<!-- tinkerex:files . -->\n", mode: :page)

        assert_includes out, "| [notes.txt](notes.txt) |"
        refute_includes out, "README.md"
      end

      test "files reaches a nested folder by path, and a path that climbs out or matches nothing says so" do
        models = dir!("models", @folder)
        printed = dir!("printed", models)
        file!("robber.3mf", printed)

        assert_includes expand("<!-- tinkerex:files models/printed -->\n", mode: :page), "[robber.3mf](models/printed/robber.3mf)"
        assert_equal "*No folder “../etc” in this project.*", expand("<!-- tinkerex:files ../etc -->\n", mode: :page).strip
        assert_equal "*No folder “cnc” in this project.*", expand("<!-- tinkerex:files cnc -->\n", mode: :page).strip
        assert_equal "*No files in “models” yet.*", expand("<!-- tinkerex:files models -->\n", mode: :page).strip
      end

      test "files with no argument is unrecognised" do
        assert_equal "<!-- tinkerex:files -->\n", expand("<!-- tinkerex:files -->\n", mode: :file)
      end

      test "a table past 200 rows is cut with a count" do
        laser = dir!("laser", @folder)
        205.times { |i| file!(format("p%03d.svg", i), laser) }

        out = expand("<!-- tinkerex:files laser -->\n", mode: :page)

        assert_equal 200, out.scan("](laser/").size
        assert_includes out, "*… and 5 more*"
      end

      test "a name that would break a row or a link renders as itself" do
        laser = dir!("laser", @folder)
        file!("odd |]_* name.svg", laser)

        seen = nil
        html = Maker::Markdown.render(expand("<!-- tinkerex:files laser -->\n", mode: :page)) do |href|
          seen = href
          "/x/#{href}"
        end

        assert_includes html, ">odd |]_* name.svg</a>"
        # The destination's pipe is escaped `\|` in the row and reaches the RESOLVER bare, spaces raw too —
        # the folder resolver indexes raw catalog paths, so this is the string that has to match. (The
        # sanitiser then percent-encodes the spaces in the href it emits, `odd%20|]_*%20name.svg` — the
        # browser's spelling of the same path, probed against Loofah 2.25.3.)
        assert_equal "laser/odd |]_* name.svg", seen
        assert_includes html, 'href="/x/laser/odd%20|]_*%20name.svg"'
        # Four cells in the one data row: a pipe that was not escaped would have split it into five.
        assert_equal 4, Nokogiri::HTML5.fragment(html).css("tbody tr").first.css("td").size
      end

      # --- bom ----------------------------------------------------------------------------------

      test "bom lists Ref, Part, Qty and Supplier over the current revision, by target kind" do
        acme = @user.maker_suppliers.create!(name: "Acme")
        item = @user.maker_inventory_items.create!(name: "M3 x 10 screw", unit: "each", quantity_cached: 40)
        models = dir!("models", @folder)
        base = file!("base.stl", models)
        bom = @project.boms.create!(user: @user)
        bom.lines.create!(user: @user, reference: "H1", inventory_item: item, quantity: 4, unit: "each", position: 0)
        bom.lines.create!(user: @user, reference: "P1", node_id: base.node_id, quantity: 1, unit: "each", position: 1)
        bom.lines.create!(user: @user, reference: "W1", part_name: "Walnut 6 mm", quantity: 0.5, unit: "sheet", supplier: acme, position: 2)

        out = expand("<!-- tinkerex:bom -->\n", mode: :page)

        assert_equal <<~MD.strip, out.strip
          | Ref | Part | Qty | Supplier |
          |---|---|---|---|
          | H1 | M3 x 10 screw | 4 each |  |
          | P1 | [base.stl](models/base.stl) | 1 each |  |
          | W1 | Walnut 6 mm | 0.5 sheet | Acme |
        MD
      end

      test "bom with no revision or no lines says so" do
        assert_equal "*No bill of materials yet.*", expand("<!-- tinkerex:bom -->\n", mode: :page).strip
        @project.boms.create!(user: @user)
        assert_equal "*No bill of materials yet.*", expand("<!-- tinkerex:bom -->\n", mode: :page).strip
      end

      test "bom reads the lines the caller hands it instead of querying" do
        bom = @project.boms.create!(user: @user)
        line = bom.lines.create!(user: @user, part_name: "Given", quantity: 1, unit: "each", position: 0)

        out = expand("<!-- tinkerex:bom -->\n", mode: :page, bom_lines: [ line ])
        assert_includes out, "| Given |"
      end

      # --- tasks --------------------------------------------------------------------------------

      test "tasks is a checklist in position order, done ticked, doing marked" do
        @project.tasks.create!(user: @user, title: "Sand", status: "doing", position: 1)
        @project.tasks.create!(user: @user, title: "Cut", status: "done", position: 0)
        @project.tasks.create!(user: @user, title: "Oil", status: "todo", position: 2)

        assert_equal "- [x] Cut\n- [ ] Sand *(doing)*\n- [ ] Oil", expand("<!-- tinkerex:tasks -->\n", mode: :page).strip
        assert_equal "*No tasks yet.*", expand("<!-- tinkerex:tasks -->\n", mode: :page, tasks: []).strip
      end

      # --- log ----------------------------------------------------------------------------------

      def entry!(body, at:, type: "note")
        @project.build_log_entries.create!(user: @user, entry_type: type, logged_at: at, body:)
      end

      test "log lists the newest N entries with a date and a gist, milestones marked" do
        entry!("<div>Glued the base.<br>Second line.</div>", at: Time.utc(2026, 7, 1, 12))
        entry!("<div>First light</div>", at: Time.utc(2026, 7, 3, 12), type: "milestone")
        entry!("<div>#{'x' * 200}</div>", at: Time.utc(2026, 6, 1, 12))

        out = expand("<!-- tinkerex:log 2 -->\n", mode: :page)

        assert_equal <<~MD.strip, out.strip
          | Date | Entry |
          |---|---|
          | 2026-07-03 | **Milestone:** First light |
          | 2026-07-01 | Glued the base. Second line. |
        MD
        full = expand("<!-- tinkerex:log -->\n", mode: :page)
        assert_equal 3, full.scan("| 2026-").size
        assert_includes full, "x" * 117 + "..."
      end

      test "log caps at 50 and refuses a count under one" do
        60.times { |i| entry!("<div>e#{i}</div>", at: Time.utc(2026, 1, 1) + i.hours) }
        assert_equal 50, expand("<!-- tinkerex:log 99 -->\n", mode: :page).scan("| 2026-").size
        assert_equal "<!-- tinkerex:log 0 -->\n", expand("<!-- tinkerex:log 0 -->\n", mode: :file)
        assert_equal "*No build log entries yet.*", expand("<!-- tinkerex:log -->\n", mode: :page, entries: []).strip
      end

      # --- image --------------------------------------------------------------------------------

      # What the context asks of a thumbnail map: `thumb(id)` answering something with `showable?`.
      FakeThumb = Class.new { def showable? = true }
      FakeThumbs = Struct.new(:ready) do
        def thumb(id) = ready.include?(id) ? FakeThumb.new : nil
      end

      test "a photo is an image in both modes, captioned by the argument or the name" do
        photos = dir!("photos", @folder)
        pic = file!("Lamp on.jpg", photos)

        assert_equal "![Lamp on.jpg](photos/Lamp on.jpg)", expand("<!-- tinkerex:image #{pic.node_id} -->\n", mode: :page).strip
        # `:file` mode wraps the body in its markers; line 2 is the body (opener, blank, body, blank, closer).
        assert_equal "![Lit, at night](photos/Lamp on.jpg)", expand("<!-- tinkerex:image #{pic.node_id} Lit, at night -->\n", mode: :file).lines[2].strip
      end

      test "any other file is a link in the file, an image on the page once its thumbnail is ready, and a link until then" do
        models = dir!("models", @folder)
        robber = file!("robber.stl", models)
        directive = "<!-- tinkerex:image #{robber.node_id} The robber -->\n"

        # `:file` mode wraps the body in its markers; line 2 is the body (opener, blank, body, blank, closer).
        assert_equal "[The robber](models/robber.stl)", expand(directive, mode: :file, thumbs: FakeThumbs.new([ robber.node_id ])).lines[2].strip
        assert_equal "![The robber](models/robber.stl)", expand(directive, mode: :page, thumbs: FakeThumbs.new([ robber.node_id ])).strip
        assert_equal "[The robber](models/robber.stl)", expand(directive, mode: :page, thumbs: FakeThumbs.new([])).strip
        assert_equal "[The robber](models/robber.stl)", expand(directive, mode: :page).strip
      end

      test "a node that is not live in the folder says so in both modes, and no id is unrecognised" do
        assert_equal "*This file is no longer in the project.*", expand("<!-- tinkerex:image nope -->\n", mode: :page).strip
        assert_equal "*This file is no longer in the project.*", expand("<!-- tinkerex:image nope -->\n", mode: :file).lines[2].strip
        assert_equal "<!-- tinkerex:image -->\n", expand("<!-- tinkerex:image -->\n", mode: :file)
      end

      test "the image split is the ONLY difference between file and page output over a README holding every directive" do
        laser = dir!("laser", @folder)
        box = file!("box.lbrn2", laser)
        photos = dir!("photos", @folder)
        pic = file!("pic.png", photos)
        @project.tasks.create!(user: @user, title: "Cut", status: "done", position: 0)
        bom = @project.boms.create!(user: @user)
        bom.lines.create!(user: @user, part_name: "Walnut", quantity: 1, unit: "each", position: 0)
        entry!("<div>Glued</div>", at: Time.utc(2026, 7, 1))
        text = "# Lamp\n\n<!-- tinkerex:files laser -->\n<!-- tinkerex:bom -->\n<!-- tinkerex:tasks -->\n<!-- tinkerex:log -->\n" \
               "<!-- tinkerex:image #{pic.node_id} -->\n<!-- tinkerex:image #{box.node_id} -->\n"
        thumbs = FakeThumbs.new([ box.node_id ])

        file = expand(text, mode: :file, thumbs:)
        page = expand(text, mode: :page, thumbs:)
        # Strip the markers and the blank lines around each body from the file; what remains must be the page.
        stripped = file.gsub(/^<!-- (?:tinkerex:[^>]*|\/tinkerex) -->\n/, "")

        # The image line stands alone on its line; the files table's row with the same link starts with "| ".
        stripped = stripped.sub(/^\[box\.lbrn2\]\(laser\/box\.lbrn2\)$/, "![box.lbrn2](laser/box.lbrn2)")
        assert_equal page.gsub(/\n{2,}/, "\n"), stripped.gsub(/\n{2,}/, "\n")
      end

      # --- the review's findings (2026-11-05) -----------------------------------------------------

      test "an unbalanced parenthesis in a name still links, in a table and on an image line" do
        models = dir!("models", @folder)
        box = file!("box (final.stl", models)
        list = listing
        resolve = Maker::Markdown.folder_resolver(list.path, list.path_index) { |id| "/f/#{id}" }

        assert_equal "<models/box (final.stl>", Maker::Readme::Live.destination("models/box (final.stl")
        table = Maker::Markdown.render(expand("<!-- tinkerex:files models -->\n", mode: :page), &resolve)
        assert_includes table, %(href="/f/#{box.node_id}")
        picture = Maker::Markdown.render(expand("<!-- tinkerex:image #{box.node_id} -->\n", mode: :page,
                                                thumbs: FakeThumbs.new([ box.node_id ])), &resolve)
        assert_includes picture, %(<img src="/f/#{box.node_id}")
      end

      test "a BOM design-file line pointing outside the folder names the file; a tombstoned one says it is gone" do
        outside = create_node!(@user, node_id: SecureRandom.uuid, name: "stock.stl", kind: "file",
                               parent_node_id: @folder.parent_node_id, mtime: 1, size: 3)
        gone = create_node!(@user, node_id: SecureRandom.uuid, name: "gone.stl", kind: "file",
                            parent_node_id: @folder.parent_node_id, mtime: 1, size: 3)
        bom = @project.boms.create!(user: @user)
        bom.lines.create!(user: @user, reference: "S1", node_id: outside.node_id, quantity: 1, unit: "each", position: 0)
        bom.lines.create!(user: @user, reference: "G1", node_id: gone.node_id, quantity: 1, unit: "each", position: 1)
        gone.update!(deleted: true)

        out = expand("<!-- tinkerex:bom -->\n", mode: :page)

        assert_includes out, "| S1 | stock.stl | 1 each |"
        assert_includes out, "| G1 | a file no longer in the library | 1 each |"
        refute_includes out, "](stock.stl)"
      end

      test "an angle bracket in a name renders as text, never as an element" do
        laser = dir!("laser", @folder)
        file!("<em>loud</em>.svg", laser)

        html = Maker::Markdown.render(expand("<!-- tinkerex:files laser -->\n", mode: :page)) { |href| "/x/#{href}" }

        assert_includes html, "&lt;em&gt;loud&lt;/em&gt;.svg</a>"
        assert_no_match(/<em>/, html)
      end

      test "an SVG is a picture in the file as on the page, like a photo" do
        design = dir!("design", @folder)
        plate = file!("plate.svg", design)

        assert Maker::Readme::Live.picture?("plate.svg")
        assert Maker::Readme::Live.picture?("pic.PNG")
        refute Maker::Readme::Live.picture?("robber.stl")
        assert_equal "![plate.svg](design/plate.svg)", expand("<!-- tinkerex:image #{plate.node_id} -->\n", mode: :file).lines[2].strip
      end
    end
  end
end
