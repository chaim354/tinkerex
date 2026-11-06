# The README panel with live regions — implementation plan

> **For agentic workers:** this repo's `.claude/commands/execute-plan.md` is the way to run this plan
> (batched by file ownership, parallel where file sets are disjoint, one capped quality review per
> task, bare `bin/ci` at the end). Steps use checkbox (`- [ ]`) syntax for tracking.

**Source:** `docs/superpowers/specs/2026-11-05-readme-panel-live-regions-design.md` (approved by the
owner, 2026-11-05; every section number below cites it). **Branch:** `claude/readme-live-regions`,
in the main checkout. **Method:** `.claude/commands/execute-plan.md`.

**Goal:** the project folder's README becomes a panel of its own, and may hold live regions — HTML
comment markers around a generated snapshot — that draw on the files in a folder, the bill of
materials, the tasks, the build log, or one project file by identity.

**Architecture:** `Maker::Readme::Live` parses regions, expands each through one markdown emitter
per directive against a `Context`, and splices the result back; the same expansion writes the
snapshot on Save (`:file` mode) and feeds the page (`:page` mode), after which the existing
`Maker::Readme.render_markdown` renders as it always has. `readme` joins the panel vocabulary and
the public page's panel map; the maker's image arm becomes node-aware so a picture of a non-image
file is its ready thumbnail.

**Tech stack:** Rails 8, kramdown GFM, Hotwire/Stimulus, the vendored CodeMirror bundle, the
Miller-columns `lib/file_chooser`. No new gems, no new importmap pins.

**Dependencies between tasks:** 1 → 2 → {3, 5} → 4 → 6. Tasks 3 and 5 touch disjoint files and
run in parallel; Task 4 waits for Task 3 because both touch `pages/projects.css` and
`readme_edit_test.rb`.

## Rules every task follows

1. **Only edit the files your task owns** (listed per task). If a fix needs a file outside your
   list, write down exactly what is needed and report it. Other implementers may be editing the
   other files right now.
2. **Never** `git checkout`, `git stash`, `git reset`, `git commit`, or switch branches. Restore a
   mutation by editing the exact original text back with the Edit tool. The orchestrator commits.
3. **Read before editing:** CLAUDE.md §14a (the port), §14d (the maker web layer), §14e, §15, the
   spec, and `docs/invariants/git-editing.md`'s README section (Task 4), `design-system.md` (Tasks 3
   and 4).
4. **Tests:** run ONLY your task's test files, never the bare suite, with your own database:
   `env LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) DATABASE_URL=sqlite3:storage/test_<slug>.sqlite3 PARALLEL_WORKERS=2 bin/rails test <files>`.
   Also run the hygiene tests your change can trip: `test/css_hygiene_test.rb`,
   `test/stimulus_hygiene_test.rb`, `test/no_emoji_test.rb`, `test/integration/web/template_hygiene_test.rb`,
   `test/integration/web/page_query_budget_test.rb`, `test/architecture_invariants_test.rb`,
   `test/docs_hygiene_test.rb`; and `bin/rubocop <changed .rb files>`.
5. **Every new test that FORBIDS something gets mutation-checked**: break the code it guards, run
   it, paste the actual red output in your report, restore the exact original text, run green.
   Clear `tmp/cache/bootsnap*` after restoring an equal-length mutation.
6. **A change that invalidates documented behaviour sweeps every file documenting it**, in the same
   task: grep for the old wording (comments, docs/) and fix them all. `docs/superpowers/plans/*` and
   `docs/audit-*` are history and are NOT swept.
7. **Report:** files changed; each step → what you did; tests run with their counts; mutation outputs
   verbatim; anything that needs a file you do not own; anything you could not verify.
8. Error copy is for a maker, not an operator: name the thing and the next step, never a class.
9. Run Ruby one-liners with `LANG=en_US.UTF-8 ruby -Eutf-8:utf-8` (the Bash tool's locale is ASCII).

---

### Task 1: `Maker::Readme::Live` — the parser, the splice, the context and the five emitters

**Files:**
- Create: `app/services/maker/readme/live.rb`
- Create: `app/services/maker/readme/live/context.rb`
- Create: `app/services/maker/readme/live/files_table.rb`
- Create: `app/services/maker/readme/live/bom_table.rb`
- Create: `app/services/maker/readme/live/task_list.rb`
- Create: `app/services/maker/readme/live/log_table.rb`
- Create: `app/services/maker/readme/live/image_line.rb`
- Test: `test/services/maker/readme/live_test.rb`

Why these files: `Maker::Readme` is a class in `app/services/maker/readme.rb`; Zeitwerk treats the
`readme/` directory as that class's namespace, so `Maker::Readme::Live` and `Maker::Readme::Live::Context`
autoload with nothing to register. Reopen the class WITHOUT its superclass (`class Readme` alone) —
Ruby allows that for a class already defined, and `readme.rb` always loads first.

- [ ] **Step 1: Write the failing test file**

```ruby
# test/services/maker/readme/live_test.rb
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

        html = Maker::Markdown.render(expand("<!-- tinkerex:files laser -->\n", mode: :page)) { |href| "/x/#{href}" }

        assert_includes html, ">odd |]_* name.svg</a>"
        assert_includes html, "/x/laser/odd |]_* name.svg" # the destination's pipe is escaped `\|` in the row and arrives bare
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
        bom.lines.create!(user: @user, reference: "W1", part_name: "Walnut 6 mm", quantity: 0.5, unit: "m2", supplier: acme, position: 2)

        out = expand("<!-- tinkerex:bom -->\n", mode: :page)

        assert_equal <<~MD.strip, out.strip
          | Ref | Part | Qty | Supplier |
          |---|---|---|---|
          | H1 | M3 x 10 screw | 4 each |  |
          | P1 | [base.stl](models/base.stl) | 1 each |  |
          | W1 | Walnut 6 mm | 0.5 m2 | Acme |
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
        assert_equal "![Lit, at night](photos/Lamp on.jpg)", expand("<!-- tinkerex:image #{pic.node_id} Lit, at night -->\n", mode: :file).strip
      end

      test "any other file is a link in the file, an image on the page once its thumbnail is ready, and a link until then" do
        models = dir!("models", @folder)
        robber = file!("robber.stl", models)
        directive = "<!-- tinkerex:image #{robber.node_id} The robber -->\n"

        assert_equal "[The robber](models/robber.stl)", expand(directive, mode: :file, thumbs: FakeThumbs.new([ robber.node_id ])).strip
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
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `env LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) DATABASE_URL=sqlite3:storage/test_live.sqlite3 PARALLEL_WORKERS=2 bin/rails test test/services/maker/readme/live_test.rb`
Expected: errors naming `uninitialized constant Maker::Readme::Live`.

- [ ] **Step 3: Write `app/services/maker/readme/live.rb`**

```ruby
module Maker
  class Readme
    # LIVE REGIONS IN A README (2026-11-05; docs/superpowers/specs/2026-11-05-readme-panel-live-regions-design.md).
    #
    # A region is two HTML comments on their own lines around a GENERATED body:
    #
    #   <!-- tinkerex:files laser -->
    #
    #   | File | Kind | Size | Modified |
    #   ...
    #
    #   <!-- /tinkerex -->
    #
    # The body is regenerated on every render (`:page` mode, markers stripped, body alone) and every
    # Save from the project page (`:file` mode, marker / blank / body / blank / marker), so the file
    # holds a plain-markdown snapshot of what the page shows live — which is what the owner chose over
    # an app that rewrites the file on every scan, BOM edit or task change (spec §6). THE BLANK LINES
    # ARE LOAD-BEARING: kramdown swallows a table that starts directly under a comment into one
    # paragraph (probed while writing the spec).
    #
    # WHAT IS GENERATED IS PLAIN GFM, and it goes through Maker::Markdown's sanitiser like prose does,
    # so nothing an emitter writes can reach the page as markup. ONE emitter per directive answers for
    # the file and the page alike; `ImageLine` is the one place the two differ, and it says so.
    #
    # THE GRAMMAR, written once here and mirrored by readme_controller.js's collapse: an opener line,
    # then — if a closer appears before the next opener or the end — a closed region whose body is the
    # lines between; otherwise an UNCLOSED region that is the opener line alone, with the lines after it
    # ordinary prose. A closer with no open region is prose. Regions never nest. An unrecognised
    # directive, a directive whose arguments do not parse (`BadArgs`), and every region past
    # MAX_REGIONS are left as written in the file and lose only their markers on the page — a typo
    # never destroys what someone wrote.
    module Live
      DIRECTIVES = %w[files bom tasks log image].freeze
      MAX_REGIONS = 20
      MAX_ROWS = 200
      MODES = %i[page file].freeze
      # `\r?` on both: a README written on Windows arrives with CRLF, and a marker that fails to match
      # for its carriage return would silently demote a region to prose.
      OPEN_RE  = /\A[ \t]*<!--[ \t]*tinkerex:([a-z]+)(?:[ \t]+(.*?))?[ \t]*-->[ \t]*\r?\z/
      CLOSE_RE = %r{\A[ \t]*<!--[ \t]*/tinkerex[ \t]*-->[ \t]*\r?\z}
      CLOSER = "<!-- /tinkerex -->".freeze

      # An emitter raises this for arguments it cannot read; `expand` then treats the region as
      # unrecognised rather than guessing.
      class BadArgs < StandardError; end

      Region = Data.define(:directive, :args, :open_line, :close_line) do
        def closed? = !close_line.nil?
        def recognised? = DIRECTIVES.include?(directive)
        # The node id an `image` region names — what the page folds into its one thumbnail query
        # (spec §5) — and nil for every other directive.
        def node_id = directive == "image" ? args.to_s.split(/\s+/, 2).first : nil
      end

      def self.regions(text)
        lines = text.to_s.split("\n", -1)
        found = []
        i = 0
        while i < lines.size
          if (m = OPEN_RE.match(lines[i]))
            j = i + 1
            j += 1 while j < lines.size && !OPEN_RE.match?(lines[j]) && !CLOSE_RE.match?(lines[j])
            closed = j < lines.size && CLOSE_RE.match?(lines[j])
            found << Region.new(directive: m[1], args: m[2].to_s.strip, open_line: i, close_line: closed ? j : nil)
            i = closed ? j + 1 : i + 1
          else
            i += 1
          end
        end
        found
      end

      # `context` nil is a caller with nothing to expand against (a nested repository's card, the
      # file page): every region is then "unrecognised" — verbatim in the file, markers off on the page.
      def self.expand(text, context:, mode:)
        raise ArgumentError, "mode must be :page or :file, got #{mode.inspect}" unless MODES.include?(mode)

        lines = text.to_s.split("\n", -1)
        out = []
        cursor = 0
        regions(text).each_with_index do |region, index|
          out.concat(lines[cursor...region.open_line])
          last = region.closed? ? region.close_line : region.open_line
          body = context && index < MAX_REGIONS && region.recognised? ? emit(region, context:, mode:) : nil
          if body.nil?
            kept = lines[region.open_line..last]
            if mode == :page
              kept = kept.drop(1)                       # the opener
              kept = kept[0...-1] if region.closed?     # and the closer
            end
            out.concat(kept)
          elsif mode == :file
            out << lines[region.open_line].chomp("\r") << "" << body << "" << CLOSER
          else
            out << "" << body << ""
          end
          cursor = last + 1
        end
        out.concat(lines[cursor..] || [])
        out.join("\n")
      end

      def self.emit(region, context:, mode:)
        emitter_for(region.directive).call(region.args, context:, mode:)
      rescue BadArgs
        nil
      end

      def self.emitter_for(directive)
        case directive
        when "files" then FilesTable
        when "bom"   then BomTable
        when "tasks" then TaskList
        when "log"   then LogTable
        when "image" then ImageLine
        end
      end

      # --- what the emitters write with -----------------------------------------------------------

      # Text that is safe inside a table cell, a list item and a link's text: a pipe would end the
      # cell, a bracket the link, and `*`/`_`/backtick would start emphasis or code mid-name. A row
      # is one line, so whitespace is squished. (Probed against kramdown: `\|` and `\]` render as the
      # bare character.) The link DESTINATION is left as the catalog spells it except for a pipe,
      # escaped `\|` so it cannot end the cell — kramdown accepts spaces and parentheses there and
      # hands the pipe back bare (probed), and the folder resolver indexes RAW paths, so a
      # percent-encoded destination would resolve to nothing.
      def self.cell(text) = text.to_s.gsub(/\s+/, " ").strip.gsub(/[\\`*_\[\]|]/) { |c| "\\#{c}" }
      def self.link(text, path) = "[#{cell(text)}](#{path.to_s.gsub('|', '\\|')})"
      def self.note(text) = "*#{text}*"
      def self.size(bytes) = bytes ? ActiveSupport::NumberHelper.number_to_human_size(bytes) : "—"
      # The catalog's mtime is nanoseconds; the date is in the app's zone like every other timestamp.
      def self.date(nanos) = nanos ? Time.zone.at(nanos / 1_000_000_000).strftime("%Y-%m-%d") : "—"

      # A GFM table over pre-escaped cells, cut at MAX_ROWS with a count — a 2000-file folder must not
      # turn a README into a 2000-row file on Save.
      def self.table(headers, rows)
        lines = [ "| #{headers.join(' | ')} |", "|#{'---|' * headers.size}" ]
        rows.first(MAX_ROWS).each { |cells| lines << "| #{cells.join(' | ')} |" }
        lines << "" << note("… and #{rows.size - MAX_ROWS} more") if rows.size > MAX_ROWS
        lines.join("\n")
      end
    end
  end
end
```

- [ ] **Step 4: Write `app/services/maker/readme/live/context.rb`**

```ruby
module Maker
  class Readme
    module Live
      # WHAT THE EMITTERS READ (spec §5). Wraps what the page already loaded and fills the gaps lazily,
      # one query each, memoised — so a README holding every directive costs a constant number of
      # queries whatever the project holds (page_query_budget_test.rb). The project page passes its own
      # ivars; a hidden BOM panel means it passes nothing and the lines are loaded here, once.
      #
      # `thumbs` is the page's ThumbnailMap (or anything answering `thumb(id)` with something answering
      # `showable?`), nil for a caller that built none; then no non-photo picture is ever "ready" and
      # ImageLine writes its link form. PATHS ARE STRING ARITHMETIC OVER THE LISTING'S TREE — the disk
      # is never touched, so `..` climbs to nothing rather than out of the folder.
      class Context
        attr_reader :user, :project, :listing

        def initialize(user:, project:, listing:, bom_lines: nil, tasks: nil, entries: nil, thumbs: nil)
          @user = user
          @project = project
          @listing = listing
          @bom_lines = bom_lines
          @tasks = tasks
          @entries = entries
          @thumbs = thumbs
        end

        def bom_lines
          @bom_lines ||= (bom = project.current_bom) ? bom.lines.includes(:inventory_item, :supplier).to_a : []
        end

        def tasks = @tasks ||= project.tasks.order(:position, :created_at).to_a

        def entries
          @entries ||= project.build_log_entries.includes(:rich_text_body).reorder(logged_at: :desc).to_a
        end

        # The listing's row for a node id, or nil when the node is not live inside this project's folder.
        def row(node_id) = listing.available? ? listing.row_for(node_id) : nil

        # A row's path relative to the project folder: "laser/box.lbrn2", or "README.md" at the root.
        # `listing.path_for` is the FULL library path of the row's directory, and the listing's own
        # path is the folder's.
        def relative_path(row)
          dir = listing.path_for(row.node)
          dir == listing.path ? row.node.name : "#{dir.delete_prefix("#{listing.path}/")}/#{row.node.name}"
        end

        # The rows a `files` argument names: the root's loose rows for ".", one nested Dir's own files
        # for "a/b", nil when nothing matches. The README's own row leaves the root listing — a table
        # of files that lists the file it sits in reads as a bug.
        def files_at(arg)
          return nil unless listing.available?

          rel = Pathname.new(arg.to_s).cleanpath.to_s
          return listing.loose.reject { |r| Maker::Readme::NAMES.include?(r.node.name) } if rel == "."
          return nil if rel.start_with?("/", "..")

          dirs = listing.tree
          found = nil
          rel.split("/").each do |segment|
            found = dirs.find { |d| d.name == segment } or return nil
            dirs = found.children
          end
          found.files
        end

        def thumb_ready?(node_id) = !!@thumbs&.thumb(node_id)&.showable?
      end
    end
  end
end
```

- [ ] **Step 5: Write the five emitters**

`app/services/maker/readme/live/files_table.rb`:

```ruby
module Maker
  class Readme
    module Live
      # `files <path>` (spec §4): the files directly under one folder of the project, as File / Kind /
      # Size / Modified, sorted by name. Kind is the role label the Files panel groups by; backups are
      # left out as the panel leaves them out; subfolders are not descended — the directive names one
      # folder and lists its own files.
      module FilesTable
        HEADERS = %w[File Kind Size Modified].freeze

        def self.call(args, context:, mode:)
          raise BadArgs, "files needs a folder path" if args.blank?

          rows = context.files_at(args)
          return Live.note("No folder “#{Live.cell(args)}” in this project.") if rows.nil?

          rows = rows.reject(&:backup?).sort_by { |r| r.node.name.downcase }
          return Live.note("No files in “#{Live.cell(args)}” yet.") if rows.empty?

          Live.table(HEADERS, rows.map do |row|
            [ Live.link(row.node.name, context.relative_path(row)),
              Maker::FileAttachment::ROLE_LABELS.fetch(row.role, "Other"),
              Live.size(row.node.size),
              Live.date(row.node.mtime) ]
          end)
        end
      end
    end
  end
end
```

`app/services/maker/readme/live/bom_table.rb`:

```ruby
module Maker
  class Readme
    module Live
      # `bom` (spec §4): Ref / Part / Qty / Supplier over the current revision's lines, in position
      # order. Part is the line's target (BomLine#target_kind): the inventory item's name, a design file
      # linked by its relative path when it is in the folder, or the free-text name.
      module BomTable
        HEADERS = %w[Ref Part Qty Supplier].freeze

        def self.call(_args, context:, mode:)
          lines = context.bom_lines
          return Live.note("No bill of materials yet.") if lines.empty?

          Live.table(HEADERS, lines.map do |line|
            [ Live.cell(line.reference), part(line, context),
              Live.cell("#{quantity(line)} #{line.unit}"), Live.cell(line.supplier&.name) ]
          end)
        end

        def self.part(line, context)
          case line.target_kind
          when :inventory_item then Live.cell(line.inventory_item&.name || line.part_name)
          when :design_file
            row = context.row(line.node_id)
            row ? Live.link(row.node.name, context.relative_path(row)) : Live.cell("a file outside the project folder")
          else Live.cell(line.part_name)
          end
        end

        # 4.000 reads as 4 and 0.500 as 0.5 — the BOM panel's own spelling (projects/_bom_lines).
        def self.quantity(line)
          ActiveSupport::NumberHelper.number_to_rounded(line.quantity, precision: 3, strip_insignificant_zeros: true)
        end
      end
    end
  end
end
```

`app/services/maker/readme/live/task_list.rb`:

```ruby
module Maker
  class Readme
    module Live
      # `tasks` (spec §4): a GFM task list in position order — `- [x]` done, `- [ ]` open, a "doing"
      # task open and marked. kramdown's GFM parser renders these as disabled checkboxes (probed).
      module TaskList
        def self.call(_args, context:, mode:)
          tasks = context.tasks
          return Live.note("No tasks yet.") if tasks.empty?

          tasks.map do |task|
            box = task.status == "done" ? "x" : " "
            "- [#{box}] #{Live.cell(task.title)}#{' *(doing)*' if task.status == 'doing'}"
          end.join("\n")
        end
      end
    end
  end
end
```

`app/services/maker/readme/live/log_table.rb`:

```ruby
module Maker
  class Readme
    module Live
      # `log [N]` (spec §4): Date / Entry over the newest N build-log entries (default 10, at most 50).
      # Entry is the body's plain text, squished and cut, with "Milestone:" ahead of a milestone's. NO
      # anchor links: the renderer rewrites `#fragment` into the README's own namespace, so a link to an
      # entry would not land.
      module LogTable
        HEADERS = %w[Date Entry].freeze
        DEFAULT = 10
        MAX = 50
        GIST = 120

        def self.call(args, context:, mode:)
          count = args.blank? ? DEFAULT : Integer(args, exception: false)
          raise BadArgs, "log takes a count" if count.nil? || count < 1

          entries = context.entries.first([ count, MAX ].min)
          return Live.note("No build log entries yet.") if entries.empty?

          Live.table(HEADERS, entries.map { |entry| [ entry.logged_at.in_time_zone.strftime("%Y-%m-%d"), gist(entry) ] })
        end

        def self.gist(entry)
          text = Live.cell(entry.body.to_plain_text.squish.truncate(GIST))
          entry.entry_type == "milestone" ? "**Milestone:** #{text}" : text
        end
      end
    end
  end
end
```

`app/services/maker/readme/live/image_line.rb`:

```ruby
module Maker
  class Readme
    module Live
      # `image <node_id> [caption]` (spec §4): one project file BY IDENTITY, so a rename follows. The
      # caption defaults to the file's name.
      #
      # THE ONE PLACE THE FILE AND THE PAGE DIFFER. A photo (Maker::FileAttachment.inline_image?) is an
      # image in both. Any other file is a LINK in the file — an image tag whose source is an STL is a
      # broken picture on GitHub — and an image on the page once its thumbnail is ready, which the
      # maker's node-aware image arm (ProjectsHelper#maker_image_link) resolves to that thumbnail. With
      # no thumbnail ready yet the page gets the link form too; the next load, after the render job,
      # shows the picture.
      module ImageLine
        def self.call(args, context:, mode:)
          node_id, caption = args.to_s.split(/\s+/, 2)
          raise BadArgs, "image needs a node id" if node_id.blank?

          row = context.row(node_id)
          return Live.note("This file is no longer in the project.") if row.nil?

          text = caption.presence || row.node.name
          path = context.relative_path(row)
          picture = Maker::FileAttachment.inline_image?(row.node.name) || (mode == :page && context.thumb_ready?(node_id))
          picture ? "![#{Live.cell(text)}](#{path})" : Live.link(text, path)
        end
      end
    end
  end
end
```

- [ ] **Step 6: Run the test file to verify it passes**

Run the Step 2 command. Expected: every test passes. If `maker_suppliers` / `maker_inventory_items`
association names differ, read `app/models/user.rb` for the `has_many` spellings and fix the TEST.

- [ ] **Step 7: Mutation checks (report each actual output)**

1. In `expand`, drop the `""` before `body` in the `:file` arm → "file mode rewrites…" red.
2. In `regions`, change `i = closed ? j + 1 : i + 1` to `i = j + 1` → "a second opener before a closer…" red (the second region is swallowed).
3. In `ImageLine`, remove `|| (mode == :page && context.thumb_ready?(node_id))` → "any other file is a link in the file, an image on the page…" red.
4. In `Live.cell`, remove `|` from the character class → "a name that would break a row…" red.

Restore each exact original, re-run green. Run `bin/rubocop app/services/maker/readme test/services/maker/readme`.

- [ ] **Step 8: Report** (the orchestrator commits: `git add app/services/maker/readme test/services/maker/readme && git commit`).

---

### Task 2: `Maker::Readme` reads then renders; the node-aware image arm; `RepoCard` without a README; `MarkdownFile`

**Files:**
- Modify: `app/services/maker/readme.rb`
- Modify: `app/services/maker/repo_card.rb`
- Modify: `app/services/maker/markdown_file.rb`
- Modify: `app/helpers/projects_helper.rb` (the `project_markdown` helper and a new `maker_image_link`)
- Test: `test/services/maker/readme_test.rb`

Depends on Task 1.

- [ ] **Step 1: Add the failing tests to `test/services/maker/readme_test.rb`** (inside the class, after the existing tests)

```ruby
    # --- live regions (2026-11-05) ----------------------------------------------------------------

    test "source reads and parses once; render expands against a context and renders" do
      laser = dir!("laser", @folder)
      file!("box.lbrn2", laser, body: "x")
      file!("README.md", @folder, body: "# Lamp\n\n<!-- tinkerex:files laser -->\n\nold\n\n<!-- /tinkerex -->\n")
      list = listing
      source = Maker::Readme.source(user: @user, rows: list.loose)

      assert_equal [ "files" ], source.regions.map(&:directive)
      assert_equal [], source.image_node_ids
      context = Maker::Readme::Live::Context.new(user: @user, project: @project, listing: list)
      readme = Maker::Readme.render(source, base_path: list.path, index: list.path_index, link: LINK, context:)

      box = @user.nodes.present.find_by!(name: "box.lbrn2")
      assert_includes readme.html, "<table>"
      assert_includes readme.html, %(href="/u/ada/desk-lamp/files/#{box.node_id}") # the caller's link lambda ran
      assert_includes readme.html, ">box.lbrn2</a>"
      refute_includes readme.html, "old"
      refute_includes readme.html, "<!--"
    end

    test "source names the image regions' node ids, and a too-large or unreadable README has none" do
      file!("README.md", @folder, body: "<!-- tinkerex:image abc -->\n<!-- tinkerex:image def A caption -->\n<!-- tinkerex:bogus x -->\n")
      assert_equal %w[abc def], Maker::Readme.source(user: @user, rows: listing.loose).image_node_ids

      file!("README.markdown", @folder, body: "x", size: Maker::Readme::READ_LIMIT + 1)
      @user.nodes.present.find_by!(name: "README.md").update!(deleted: true)
      big = Maker::Readme.source(user: @user, rows: listing.loose)
      assert_nil big.text
      assert_equal [], big.image_node_ids
      assert_match(/too large/, big.note)
    end

    test "for with no context renders a region's saved body and strips the markers" do
      file!("README.md", @folder, body: "<!-- tinkerex:tasks -->\n\n- [x] saved\n\n<!-- /tinkerex -->\n")
      html = readme_for.html

      assert_includes html, "saved"
      assert_includes html, "checked"
      refute_includes html, "<!--"
      refute_includes html, "tinkerex"
    end

    test "render_markdown drops a picture whose image arm answers nil instead of leaving a blank src" do
      models = dir!("models", @folder)
      file!("base.stl", models, body: "x")
      list = listing
      html = Maker::Readme.render_markdown("![base](models/base.stl) and [base](models/base.stl)", base_path: list.path,
                                           index: list.path_index, link: LINK, image_link: ->(_id) { nil })

      assert_no_match(/<img/, html)
      assert_includes html, ">base</a>"
    end

    test "RepoCard.for can be told to leave the README to the panel" do
      file!("README.md", @folder, body: "# Lamp\n")
      list = listing
      dir = Maker::ProjectFolderListing::Dir.new(node_id: @folder.node_id, name: @project.name, path: list.path,
                                                 repo?: true, children: list.tree, files: list.loose)
      root = @user.nodes.present.find_by!(node_id: @folder.node_id)
      caps = FileLayer.current.capabilities

      with = Maker::RepoCard.for(user: @user, dir:, root_node: root, listing: list, capabilities: caps)
      without = Maker::RepoCard.for(user: @user, dir:, root_node: root, listing: list, capabilities: caps, readme: false)

      assert_includes with.readme_html, "Lamp"
      assert_nil without.readme_html
      assert_nil without.readme_note
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `env LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) DATABASE_URL=sqlite3:storage/test_readme.sqlite3 PARALLEL_WORKERS=2 bin/rails test test/services/maker/readme_test.rb`
Expected: `NoMethodError: undefined method 'source'`, `unknown keyword: :readme`, and the nil-src test red.

- [ ] **Step 3: Edit `app/services/maker/readme.rb`**

Add, after `READ_LIMIT = CAP * 4`:

```ruby
    # STEP ONE OF TWO (2026-11-05, live regions; spec §5): find and READ the README, capped, and parse
    # its regions — but render nothing yet. The project page needs the `image` regions' node ids
    # BEFORE it builds its one thumbnail query and the rendered HTML AFTER, so the two steps are two
    # calls; `.for` below is both in one for every caller with no such ordering to respect. nil means
    # "this listing holds no README". `text` is nil, and `note` says why, when the file was not read.
    Source = Data.define(:row, :text, :note, :regions) do
      def image_node_ids = regions.select(&:recognised?).filter_map(&:node_id)
    end
```

Replace the whole `def self.for(...) ... end` (from `def self.for(user:, rows:, base_path:, listing:, link:, image_link: default_image_link(link))` through the `rescue FileLayer::NotFound` arm's `end`) with:

```ruby
    def self.source(user:, rows:)
      row = row_in(rows)
      return nil if row.nil?
      if row.node.size.to_i > READ_LIMIT
        return Source.new(row:, text: nil, regions: [],
                          note: "README too large to show here (#{row.node.size.to_i / 1024} KB); open the file instead.")
      end

      bytes = FileLayer.current.read(user, node_id: row.node_id)
      truncated = bytes.bytesize > CAP
      # `.scrub` after forcing UTF-8: a byte cap can split a multi-byte character at the tail, and a
      # NAS file is not guaranteed to be valid UTF-8 to begin with (§14b makes the same point about
      # filenames) — either way this must degrade to a replacement character, never raise
      # Encoding::InvalidByteSequenceError out of a panel into a 500 for the whole page.
      text = (truncated ? bytes.byteslice(0, CAP) : bytes).dup.force_encoding(Encoding::UTF_8).scrub
      Source.new(row:, text:, regions: Live.regions(text),
                 note: (truncated ? "Showing the first #{CAP / 1024} KB of this README." : nil))
    # TWO ARMS, ONE NOTE. The store not answering is an outage the layout's banner names
    # (app/models/current.rb); a README that is gone is not, so its arm raises nothing.
    rescue FileLayer::FetchError
      Current.library_unreachable = true
      Source.new(row:, text: nil, regions: [], note: "README unavailable.")
    rescue FileLayer::NotFound
      Source.new(row:, text: nil, regions: [], note: "README unavailable.")
    end

    # STEP TWO: expand the live regions against `context` (Maker::Readme::Live::Context; nil is a
    # caller with nothing to expand against — a nested repository's card, the file page — and then
    # the markers go and the saved bodies stay) and render the markdown. THE ONE FOLDER RESOLVER
    # (Maker::Markdown.folder_resolver, through #render_markdown): a content block resolves against the
    # project folder with the same arithmetic, so the two cannot drift.
    def self.render(source, base_path:, index:, link:, image_link: default_image_link(link), context: nil)
      return new(html: nil, note: source.note) if source.text.nil?

      text = Live.expand(source.text, context:, mode: :page)
      new(html: render_markdown(text, base_path:, index:, link:, image_link:), note: source.note)
    end

    def self.for(user:, rows:, base_path:, listing:, link:, image_link: default_image_link(link), context: nil)
      source = source(user:, rows:)
      return nil if source.nil?

      render(source, base_path:, index: listing.path_index, link:, image_link:, context:)
    end
```

In `render_markdown`, replace `pictures.each { |img| img["src"] = image_link.call(issued.fetch(img["src"])) }` with:

```ruby
      # nil FROM THE ARM DROPS THE PICTURE (2026-11-05): the node-aware maker arm answers nil for a
      # non-image file with no ready thumbnail, and an <img> with a blank src is a broken picture
      # that also fetches the page itself.
      pictures.each do |img|
        url = image_link.call(issued.fetch(img["src"]))
        url ? img["src"] = url : img.remove
      end
```

Update the class comment's first paragraph to say the reader is now two steps (`source` then `render`)
and that `.for` is both; keep every other sentence.

- [ ] **Step 4: Edit `app/services/maker/repo_card.rb`**

Change the signature and the README line:

```ruby
    # `readme: false` (2026-11-05, live regions; spec §2): the ROOT card is built without one — the
    # project's README is its own panel now, and the card keeps only its git facts. Nested
    # repositories' cards keep theirs: a nested repo's README is not the project's.
    def self.for(user:, dir:, root_node:, listing:, capabilities:, link: DEFAULT_LINK, readme: true)
      head, tags, refusal = git_facts(user:, dir:, root_node:, capabilities:)
      # `dir.path` is the repo dir's FULL library path — the shape `listing.path_index` keys on, and
      # what a relative href in this README resolves against (Maker::Readme's own rule).
      card_readme = readme ? Maker::Readme.for(user:, rows: dir.files, base_path: dir.path, listing:, link:) : nil
      new(dir:, head:, tags:, readme_html: card_readme&.html, readme_note: card_readme&.note, refusal:)
    end
```

- [ ] **Step 5: Edit `app/services/maker/markdown_file.rb`**

Replace `html = Maker::Readme.render_markdown(text, base_path: base.to_s, index:,` … with:

```ruby
      # A README's live regions show their SAVED bodies here, markers off (2026-11-05): this page has
      # no project to expand against, and the snapshot is exactly what the file holds for a reader
      # outside the project page.
      html = Maker::Readme.render_markdown(Maker::Readme::Live.expand(text, context: nil, mode: :page),
                                           base_path: base.to_s, index:,
                                           link: Maker::RepoCard::DEFAULT_LINK,
                                           image_link: Maker::Readme::MAKER_IMAGE_LINK)
```

- [ ] **Step 6: Edit `app/helpers/projects_helper.rb`**

Replace `project_markdown` with, and add `maker_image_link` beneath it:

```ruby
  def project_markdown(text, listing)
    Maker::Readme.render_markdown(text.to_s, base_path: listing.path, index: listing.path_index,
                                  link: Maker::RepoCard::DEFAULT_LINK, image_link: maker_image_link(listing, @page_thumbs))
  end

  # THE MAKER'S PICTURE OF A FILE, BY NODE (2026-11-05, live regions; spec §5). An image file is its
  # bytes — the blob route, the door the hero and an image block already load from; any other file is
  # its READY thumbnail, where `![x](models/base.stl)` used to render the model's bytes as a broken
  # picture. nil DROPS the <img> (Maker::Readme.render_markdown), which is why Live::ImageLine writes
  # a LINK rather than an image while no thumbnail is ready. `listing` says which node a resolved id
  # is; `thumbs` is the page's one ThumbnailMap (nil on a render that built none — then every
  # non-image picture is dropped rather than broken). A node the listing does not hold cannot have
  # been resolved by the folder resolver at all, so that arm is defensive, not reachable.
  def maker_image_link(listing, thumbs)
    lambda do |id|
      row = listing.row_for(id)
      next blob_file_path(id) if row.nil? || Maker::FileAttachment.inline_image?(row.node.name)

      thumb = thumbs&.thumb(id)
      thumb&.showable? ? preview_src(thumb) : nil
    end
  end
```

- [ ] **Step 7: Run the readme test file, then the existing dependants**

Run the Step 2 command, then:
`env LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) DATABASE_URL=sqlite3:storage/test_readme.sqlite3 PARALLEL_WORKERS=2 bin/rails test test/services/maker/readme_test.rb test/services/maker/public_project_test.rb test/integration/web/project_repo_card_test.rb test/integration/web/markdown_file_page_test.rb test/integration/web/project_hub_audit_test.rb`
Expected: all green (nothing in this task changes a page yet).

- [ ] **Step 8: Mutation checks**

1. In `render_markdown`, put back `pictures.each { |img| img["src"] = image_link.call(issued.fetch(img["src"])) }` → "render_markdown drops a picture…" red.
2. In `Maker::Readme.render`, pass `context: nil` regardless of the argument → "source reads and parses once; render expands…" red (`old` renders).

Restore, re-run green, `bin/rubocop` the four Ruby files. Report.

---

### Task 3: The README panel — vocabulary, controller, views, CSS, and every test that named the card

**Files:**
- Modify: `app/models/maker/project.rb` (`PANELS`, `PANEL_LABELS`)
- Modify: `app/services/maker/project_kind.rb` (`LEAD`, `FULL_BY_DEFAULT`)
- Modify: `app/controllers/projects_controller.rb` (`#show`)
- Create: `app/views/projects/_readme.html.erb`
- Delete: `app/views/projects/_readme_card.html.erb`
- Modify: `app/views/projects/_attachments.html.erb`
- Modify: `app/views/projects/_repo_card.html.erb`
- Modify: `app/assets/stylesheets/pages/projects.css`
- Modify tests: `test/services/maker/project_kind_test.rb`, `test/integration/web/project_repo_card_test.rb`,
  `test/integration/web/readme_edit_test.rb` (selectors only), `test/integration/web/library_unreachable_test.rb`,
  `test/integration/web/project_hub_audit_test.rb`, `test/integration/web/template_hygiene_test.rb` (comments),
  `test/system/readme_editor_test.rb` (selectors only)
- Create test: `test/integration/web/readme_panel_test.rb`

Depends on Task 2. Does NOT touch `projects/_readme_editor.html.erb`, `readme_controller.js` or
`Projects::ReadmesController` (Task 4's).

- [ ] **Step 1: Write the failing panel test**

```ruby
# test/integration/web/readme_panel_test.rb
require "test_helper"

module Web
  # THE README PANEL (2026-11-05; spec 2026-11-05-readme-panel-live-regions-design.md §2, §5): the
  # project folder's README as a panel of the layout, rendered live.
  #
  # A FRESH SHARE LIBRARY PER TEST, PINNED BEFORE ANY FIXTURE RUNS (readme_edit_test.rb's reason):
  # these pages read real bytes through the port, and the three backend legs must report identical
  # RUN counts.
  class ReadmePanelTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "panel-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    # A scanned project folder holding a README and a laser/ subfolder with two files.
    def project!(readme:, files: { "laser/box.lbrn2" => "x", "laser/tokens.lbrn2" => "yy" })
      project = @user.maker_projects.create!(name: "Lamp")
      project.ensure_library_folder!(@user)
      dir = @root.join("Projects", project.slug)
      files.each { |rel, body| dir.join(rel).dirname.mkpath; dir.join(rel).write(body) }
      dir.join("README.md").write(readme)
      Library::ScanJob.new.perform(user_id: @user.id)
      project
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

    test "the README is its own panel, first on the page, with a live files table and the editor door" do
      project = project!(readme: "# Lamp\n\n<!-- tinkerex:files laser -->\n\nstale\n\n<!-- /tinkerex -->\n")

      get project_path(project)

      assert_response :success
      assert_select ".project-panels .panel-slot:first-child #project-readme.readme-panel"
      assert_select "#project-readme .panel-head h2", text: "README"
      assert_select "#project-readme .markdown h1", text: "Lamp"
      assert_select "#project-readme .markdown table td a", text: "box.lbrn2"
      assert_select "#project-readme .markdown table td a", text: "tokens.lbrn2"
      assert_select "#project-readme .markdown", text: /stale/, count: 0
      assert_select "#project-readme .readme-editor[data-controller=readme]"
      assert_select ".attachments-panel .readme-card", 0
      assert_select ".readme-card", 0
    end

    test "a hidden README panel costs no port read; a shown one costs exactly one" do
      project = project!(readme: "# Lamp\n")
      reads = 0
      original = FileLayer.current.method(:read)
      counting = ->(*args, **kw) { reads += 1; original.call(*args, **kw) }

      replacing(FileLayer.current, :read, counting) { get project_path(project) }
      assert_equal 1, reads
      assert_select "#project-readme"

      project.update!(panels: { "hidden" => [ "readme" ] })
      reads = 0
      replacing(FileLayer.current, :read, counting) { get project_path(project) }
      assert_response :success
      assert_equal 0, reads
      assert_select "#project-readme", 0
    end

    test "layout-edit mode renders the panel without the editor door" do
      project = project!(readme: "# Lamp\n")

      get edit_layout_project_path(project)

      assert_response :success
      assert_select "#project-readme .markdown h1", text: "Lamp"
      assert_select "#project-readme .readme-editor", 0
    end

    test "a non-image picture in the README is dropped until its thumbnail is ready, and an image file loads its bytes" do
      project = project!(readme: "![box](laser/box.lbrn2)\n\n![pic](photos/pic.png)\n",
                         files: { "laser/box.lbrn2" => "x", "photos/pic.png" => "\x89PNG\r\n\x1a\n".b })
      pic = @user.nodes.present.find_by!(name: "pic.png")

      get project_path(project)

      assert_select "#project-readme .markdown img[src=?]", blob_file_path(pic.node_id)
      assert_select "#project-readme .markdown img", count: 1
    end

    test "a README holding every directive costs a constant number of queries" do
      project = project!(readme: "<!-- tinkerex:files laser -->\n<!-- tinkerex:bom -->\n<!-- tinkerex:tasks -->\n<!-- tinkerex:log -->\n")
      bom = project.boms.create!(user: @user)
      seed = lambda do |n|
        n.times do |i|
          bom.lines.create!(user: @user, part_name: "part #{i}", quantity: 1, unit: "each", position: i)
          project.tasks.create!(user: @user, title: "task #{i}", status: "todo", position: i)
          project.build_log_entries.create!(user: @user, entry_type: "note", logged_at: Time.current - i.hours, body: "<div>e#{i}</div>")
          @root.join("Projects", project.slug, "laser", "f#{i}.svg").write("<svg/>")
        end
        Library::ScanJob.new.perform(user_id: @user.id)
      end

      seed.call(2)
      get project_path(project)
      small = count_queries { get project_path(project) }
      seed.call(6)
      get project_path(project)
      large = count_queries { get project_path(project) }

      assert_equal small, large, "the README panel grows with the data: #{small} queries at the small size, #{large} at the large"
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `env LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) DATABASE_URL=sqlite3:storage/test_panel.sqlite3 PARALLEL_WORKERS=2 bin/rails test test/integration/web/readme_panel_test.rb`
Expected: red — no `#project-readme`.

- [ ] **Step 3: The vocabulary**

`app/models/maker/project.rb`: `PANELS` becomes
`%w[readme attachments photos models schematics build_log tasks bom wiring releases sheets calculations].freeze`
with a comment line above it: `# \`readme\` (2026-11-05): the folder's README as its own panel — projects/_readme, Maker::Readme::Live.`
`PANEL_LABELS` gains `"readme" => "README",` as its first pair, and its comment's "four of the twelve disagree" becomes "five of the thirteen disagree" with `readme` ("README", not "Readme") added to the list.

`app/services/maker/project_kind.rb`: `LEAD = %w[readme attachments photos].freeze` — update its comment:
"The panels that open EVERY project page whatever its kind: the README first (2026-11-05 — the
project's own description), then the folder, then its pictures …". `FULL_BY_DEFAULT = %w[readme attachments photos].freeze`
with one added sentence: "a README is a document, and half a column is where a table in it stops being readable."
`ALWAYS` is unchanged — say so in a sentence under it: "`readme` is deliberately NOT here (2026-11-05): a maker with no README may not want the Write-a-README door on every visit, and the layout editor brings the panel back."

- [ ] **Step 4: The controller**

In `app/controllers/projects_controller.rb#show`, replace the block from `@root_card = nil` through the
`end` that closes `if @listing.available?` (the one just above the `# THE README THE EDITOR EDITS` comment) with:

```ruby
    @root_card = nil
    @readme_source = nil
    # THE README IS READ ONLY WHEN ITS PANEL SHOWS (2026-11-05, live regions; spec §2) — a port read,
    # and a WAN one on chunk_remote, which the page used to pay whether or not anyone looked. READ
    # HERE, RENDERED BELOW: `Maker::Readme.source` reads and parses, so the `image` regions' node ids
    # can ride the page's ONE thumbnail query, and `Maker::Readme.render` runs after that query.
    readme_shown = @panel_layout.visible?("readme")
    if @listing.available?
      if @listing.root_repo?
        root_dir = Maker::ProjectFolderListing::Dir.new(node_id: @listing.folder_id, name: @project.name,
                                                        path: @listing.path, repo?: true,
                                                        children: @listing.tree, files: @listing.loose)
        # `readme: false`: the root card keeps its git facts; the README is the panel's.
        @root_card = Maker::RepoCard.for(user: current_user, dir: root_dir, root_node: repo_roots[@listing.folder_id],
                                         listing: @listing, capabilities:, readme: false)
      end
      @readme_source = Maker::Readme.source(user: current_user, rows: @listing.loose) if readme_shown
    end
```

Then update the preceding comment block ("THE ROOT'S OWN CARD …") so its last two sentences read:
"A plain folder's README used to render through the same reader with no git facts; since 2026-11-05 the README is its own panel (projects/_readme) on every project, repository or not, and the root card carries git facts alone."

In the `@page_thumbs = Maker::Previews::ThumbnailMap.for(` call, add `+ Array(@readme_source&.image_node_ids)` after `block_thumb_ids`, and a comment line above the call:
`# THE README'S LIVE PICTURES (2026-11-05): an \`image\` region's node joins the union so its thumbnail is one query and one backfill with everything else this page paints.`

Immediately after `@sheets = @project.sheets.to_a`, add:

```ruby
    # THE README, RENDERED (2026-11-05, live regions; spec §5) — after @page_thumbs, which its pictures
    # read, and after @tasks, which its `tasks` region reads. The context carries what this page loaded;
    # `bom_lines` is nil when the BOM panel is hidden, so a `bom` region loads the lines itself, once.
    @readme = if @readme_source
      context = Maker::Readme::Live::Context.new(user: current_user, project: @project, listing: @listing,
                                                 bom_lines: (bom_shown ? @bom_lines : nil), tasks: @tasks,
                                                 entries: @entries, thumbs: @page_thumbs)
      Maker::Readme.render(@readme_source, base_path: @listing.path, index: @listing.path_index,
                           link: Maker::RepoCard::DEFAULT_LINK,
                           image_link: helpers.maker_image_link(@listing, @page_thumbs), context:)
    end
```

(`bom_shown` is the local the BOM block above already defines.)

- [ ] **Step 5: The views**

Create `app/views/projects/_readme.html.erb`:

```erb
<%#
  THE README PANEL (2026-11-05; docs/superpowers/specs/2026-11-05-readme-panel-live-regions-design.md
  §2): the project folder's own README, rendered LIVE — Maker::Readme::Live expands its regions
  against this page's data in ProjectsController#show — and the door that writes it. A panel of the
  layout like any other: first by default, full width, hideable (and unread when hidden). It was a
  card inside the Files panel (`projects/_readme_card`, deleted) and the README half of the root
  repository card, which now carries its git facts alone.

  Reads @readme (a Maker::Readme, or nil with no README or a hidden panel), @readme_row,
  @readme_editable, @project, @listing, @editing, @panel_layout.

  IN LAYOUT-EDIT MODE THE DOOR IS LEFT OUT: that mode arranges the page, and a form inside a slot the
  editor drags is not wanted. The editor partial takes `listing:` for its Insert menu (Task 4).
%>
<section class="panel readme-panel" id="project-readme">
  <div class="panel-head">
    <h2><%= panel_title(@panel_layout, "readme") %></h2>
  </div>
  <%= panel_intro(@panel_layout, "readme") %>
  <% if @readme&.html.present? %>
    <div class="markdown"><%= @readme.html %></div>
  <% end %>
  <% if @readme&.note %>
    <p class="muted readme-note"><%= @readme.note %></p>
  <% end %>
  <% if @readme_editable && !@editing %>
    <%= render "projects/readme_editor", project: @project, row: @readme_row, listing: @listing %>
  <% end %>
</section>
```

Delete `app/views/projects/_readme_card.html.erb` (`git rm` is the orchestrator's; just delete the file).

In `app/views/projects/_attachments.html.erb`, replace the block

```erb
  <% if @root_card %>
    <%= render "projects/repo_card", card: @root_card, project: @project,
               readme_row: @readme_row, editable: @readme_editable %>
  <% elsif @readme || @readme_editable %>
    <%= render "projects/readme_card", readme: @readme, editable: @readme_editable,
               readme_row: @readme_row, project: @project %>
  <% end %>
```

with

```erb
  <% if @root_card %>
    <%= render "projects/repo_card", card: @root_card %>
  <% end %>
```

and rewrite the two comments that described the card: the header's "THE PANEL OPENS WITH THE FOLDER'S OWN CARD …" paragraph becomes
"THE PANEL OPENS WITH THE REPOSITORY CARD when the folder IS a working tree (`projects/_repo_card` over ProjectsController#show's @root_card: latest commit, tag, Commits/History) — its git facts alone, since 2026-11-05: the README is its own panel (projects/_readme). Neither is inside the \"no files yet\" check below.";
the inline comment above the render ("repository card when the folder itself is a working tree (README, latest commit, tag) …") becomes
"THE REPOSITORY CARD, when the folder itself is a working tree: latest commit, tag, Commits and History. The README it used to carry is the README panel's (2026-11-05)."; and the
"THE README THE CARD ABOVE RENDERS IS NOT LOOSE" comment becomes "THE README THE README PANEL RENDERS IS NOT LOOSE". The `loose` filter line itself is unchanged.

In `app/views/projects/_repo_card.html.erb`, remove both `<%= render "projects/readme_editor" … %>` branches and their `local_assigns[:editable]` conditions, so the README region is:

```erb
  <% if card.readme_html.present? %>
    <details class="readme" open>
      <summary>README</summary>
      <div class="markdown"><%= card.readme_html %></div>
      <% if card.readme_note %>
        <p class="muted readme-note"><%= card.readme_note %></p>
      <% end %>
    </details>
  <% elsif card.readme_note %>
    <p class="muted readme-note"><%= card.readme_note %></p>
  <% end %>
```

and replace the header's "STAGE 4, S4-4: the ROOT card also carries the README editor …" paragraph and the `Local:` line with:
"THE ROOT CARD CARRIES NO README AND NO EDITOR SINCE 2026-11-05: the project's README is its own panel (projects/_readme), and ProjectsController#show builds the root card with `readme: false`. A NESTED repository's card still renders its own README here, read-only — that README is not the project's.
Local: card (Maker::RepoCard)."

- [ ] **Step 6: CSS** — in `app/assets/stylesheets/pages/projects.css`, inside the `@layer pages { … }` block, directly above the `.readme-editor { margin-top: 10px; }` line, add:

```css
  /* --- The README panel (2026-11-05): a document, not a card, so its markdown gets the room a
     table needs; the generic .markdown cap (360px, above) is the card's. --- */
  .readme-panel .markdown { max-height: 70vh; margin-top: 0; }
  .readme-panel .readme-editor { margin-top: 12px; }
```

- [ ] **Step 7: Update the tests that named the card**

`test/services/maker/project_kind_test.rb`: rename the test "every kind's order is a permutation of PANELS, and every kind opens with Files then Photos" to "… opens with README, Files then Photos"; change
`assert_equal %w[attachments photos schematics wiring models build_log], electronics.visible.first(6)` to
`assert_equal %w[readme attachments photos schematics wiring models], electronics.visible.first(6)`, and its comment "`models` (2026-10-21) is third in PANELS" to "fourth in PANELS since `readme` led it (2026-11-05)".

`test/integration/web/project_repo_card_test.rb`:
- in "a project whose own folder is the repository gets the card…": replace `assert_select ".attachments-panel .repo-card .markdown h1", text: "Lamp"` with
  `assert_select "#project-readme .markdown h1", text: "Lamp"` and add `assert_select ".attachments-panel .repo-card .markdown", 0`.
- in "a plain folder's README renders on the private page…": replace the two `.attachments-panel .readme-card …` assertions with
  `assert_select "#project-readme .markdown h1", text: "Tray"` and `assert_select "#project-readme .repo-facts", count: 0`, and the test name's "…with no git facts and no Commits link" stays true.

`test/integration/web/readme_edit_test.rb`: `.readme-card .readme-editor[data-controller=readme]` → `.readme-panel .readme-editor[data-controller=readme]`; in "a root working tree gets the editor inside its repo card…": rename to "a root working tree gets the editor in the README panel, and the save records a pending edit", replace `assert_select ".repo-card .readme-editor[data-controller=readme]"` with `assert_select ".readme-panel .readme-editor[data-controller=readme]"` and add `assert_select ".repo-card .readme-editor", 0`. Any other `.readme-card` in this file → `.readme-panel`.

`test/integration/web/library_unreachable_test.rb`: every `.readme-card` → `.readme-panel` (four places).

`test/integration/web/project_hub_audit_test.rb`: the three `.readme-card` selectors → `.readme-panel`; the mutation note above the test becomes "MUTATION-CHECKED: making ProjectsHelper#maker_image_link return nil for every id reddens this with `Expected at least 1 element matching ".readme-panel .markdown img[src=\"/files/<id>/blob\"]`, found 0.`"

`test/integration/web/template_hygiene_test.rb`: the comment "A README AT THE FOLDER'S OWN ROOT, or `projects/_readme_card` never renders" → "or `projects/_readme`'s note branch never renders"; "the private page takes the `@readme` branch rather than the root-repository card" → "the private page renders the README panel over a plain folder". No code change.

`test/system/readme_editor_test.rb`: both `.readme-card` → `.readme-panel`.

Sweep: `grep -rn "readme_card\|readme-card" app/ test/ docs/invariants docs/user-stories.md CLAUDE.md` must list nothing in `app/` or `test/`; in `docs/user-stories.md` row 2.9 change "(`projects/_readme_card.html.erb`, `_repo_card` for a root repo)" to "(`projects/_readme.html.erb`, its own panel since 2026-11-05)".

- [ ] **Step 8: Run the task's tests**

`env LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) DATABASE_URL=sqlite3:storage/test_panel.sqlite3 PARALLEL_WORKERS=2 bin/rails test test/integration/web/readme_panel_test.rb test/services/maker/project_kind_test.rb test/integration/web/project_repo_card_test.rb test/integration/web/readme_edit_test.rb test/integration/web/library_unreachable_test.rb test/integration/web/project_hub_audit_test.rb test/integration/web/template_hygiene_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/project_page_test.rb test/integration/web/project_attachments_test.rb test/services/maker/layout_document_test.rb test/css_hygiene_test.rb test/stimulus_hygiene_test.rb test/no_emoji_test.rb test/architecture_invariants_test.rb`
Expected: green. If `page_query_budget_test.rb` reports growth, the README render is reading something per row — check that the context receives `@tasks`, `@entries` and `@bom_lines`.
Then the system test: `env LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) DATABASE_URL=sqlite3:storage/test_panel.sqlite3 bin/rails test test/system/readme_editor_test.rb`.

- [ ] **Step 9: Mutation checks**

1. Put the README card render back into `_attachments.html.erb` (`<%= render "projects/readme_card" … %>` cannot — the partial is deleted — so instead render the markdown inside `.attachments-panel`: add `<div class="readme-card"><%= @readme&.html %></div>` under the root card) → "the README is its own panel…" red on `.readme-card, 0`.
2. In the controller, drop `if readme_shown` → "a hidden README panel costs no port read" red (`1` reads where `0` expected).
3. In `_readme.html.erb`, drop `&& !@editing` → "layout-edit mode renders the panel without the editor door" red.
4. In `maker_image_link`, return `blob_file_path(id)` for every row → "a non-image picture…is dropped…" red (two `img`s).

Restore each, re-run green, `bin/rubocop` the Ruby files. Report.

---

### Task 4: The Save writes the snapshot; the editor gets its Insert bar

**Files:**
- Modify: `app/controllers/projects/readmes_controller.rb`
- Modify: `app/views/projects/_readme_editor.html.erb`
- Modify: `app/javascript/controllers/readme_controller.js`
- Modify: `app/assets/stylesheets/pages/projects.css` (after Task 3)
- Modify: `docs/invariants/git-editing.md` (one sentence)
- Test: `test/integration/web/readme_edit_test.rb` (new tests appended), `test/system/readme_editor_test.rb` (one new test)

Depends on Tasks 2 and 3.

- [ ] **Step 1: Append the failing request tests to `test/integration/web/readme_edit_test.rb`** (before the class's final `end`)

```ruby
    # --- live regions (2026-11-05; spec §6, §7) ----------------------------------------------------

    def project_with_files!(user, readme:, files:)
      project = user.maker_projects.create!(name: "Desk Lamp")
      project.ensure_library_folder!(user)
      dir = Pathname.new(library_root).join("Projects", project.slug)
      files.each { |rel, body| dir.join(rel).dirname.mkpath; dir.join(rel).write(body) }
      dir.join("README.md").write(readme)
      Library::ScanJob.new.perform(user_id: user.id)
      project
    end

    def readme_on_disk(project) = File.read(File.join(library_root, "Projects", project.slug, "README.md"))

    test "a save fills a hand-typed region with its table and closes it; the page renders it live" do
      user = sign_in
      project = project_with_files!(user, readme: "# Lamp\n", files: { "models/base.stl" => "solid\nendsolid\n" })
      node = readme_node(user, project)

      patch project_readme_path(project),
            params: { content: "# Lamp\n\n<!-- tinkerex:files models -->\n", base_token: token_for(user, node) }

      assert_redirected_to project_path(project)
      on_disk = readme_on_disk(project)
      assert_includes on_disk, "<!-- tinkerex:files models -->\n\n| File | Kind | Size | Modified |\n"
      assert_includes on_disk, "| [base.stl](models/base.stl) | Models |"
      assert_includes on_disk, "\n\n<!-- /tinkerex -->\n"
      follow_redirect!
      assert_select "#project-readme .markdown table td a", text: "base.stl"
      assert_select "#project-readme .markdown", text: /tinkerex/, count: 0
    end

    test "a save replaces whatever was posted inside a region" do
      user = sign_in
      project = project_with_files!(user, readme: "# Lamp\n", files: {})
      project.tasks.create!(user:, title: "Sand", status: "done", position: 0)
      node = readme_node(user, project)

      patch project_readme_path(project),
            params: { content: "<!-- tinkerex:tasks -->\n\n- [ ] my own line\n\n<!-- /tinkerex -->\n", base_token: token_for(user, node) }

      on_disk = readme_on_disk(project)
      assert_includes on_disk, "- [x] Sand"
      refute_includes on_disk, "my own line"
    end

    test "the size cap applies to the expanded file, and the draft is what was typed" do
      user = sign_in
      project = project_with_files!(user, readme: "# Lamp\n", files: { "models/base.stl" => "solid\nendsolid\n" })
      node = readme_node(user, project)
      prose = "x" * (FilesController::EDITABLE_MAX_BYTES - 60)
      draft = "#{prose}\n<!-- tinkerex:files models -->\n"

      patch project_readme_path(project), params: { content: draft, base_token: token_for(user, node) }

      assert_response :unprocessable_entity
      assert_select ".readme-editor .composer-error", text: /too large to edit here once its live tables are filled in/
      assert_select ".readme-editor textarea[name=content]", text: draft
      assert_equal "# Lamp\n", readme_on_disk(project)
    end

    test "the editor carries the Insert bar, hidden until the script enables it, with the folder menu and the chooser's root" do
      user = sign_in
      project = project_with_files!(user, readme: "# Lamp\n", files: { "laser/a.svg" => "<svg/>", "models/b.stl" => "solid\nendsolid\n" })
      folder_id = project.reload.folder_node_id

      get project_path(project)

      assert_select ".readme-editor[data-readme-children-url-value=?]", library_children_path
      assert_select ".readme-editor[data-readme-folder-id-value=?]", folder_id
      assert_select ".readme-editor .readme-insert[hidden]"
      assert_select ".readme-insert .menu-item[data-path='.']", text: "Root files"
      assert_select ".readme-insert .menu-item[data-path=laser]", text: "laser"
      assert_select ".readme-insert .menu-item[data-path=models]", text: "models"
      %w[bom tasks log].each { |d| assert_select ".readme-insert button[data-directive=?]", d }
      assert_select ".readme-insert button[data-action='readme#insertImage']", text: "Image"
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `env LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) DATABASE_URL=sqlite3:storage/test_edit.sqlite3 PARALLEL_WORKERS=2 bin/rails test test/integration/web/readme_edit_test.rb`
Expected: the four new tests red (no table on disk, no `.readme-insert`).

- [ ] **Step 3: The controller** — in `app/controllers/projects/readmes_controller.rb#update`, replace from `body = params[:content].to_s` through the `result = Maker::TextSave.call(` block with:

```ruby
      draft = params[:content].to_s
      row = listing.available? ? Maker::Readme.row_in(listing.loose) : nil
      return refuse(project, row, draft, "This project has no folder in the library yet, so the README has nowhere to go.") unless listing.available?
      # A BLANK BODY IS REFUSED RATHER THAN WRITTEN, and it is the SERVER half of the editor's
      # `disabled` textarea: without JavaScript, or with the bundle failing to load, the buffer is
      # empty and a Save would otherwise blank a README that took an hour to write. Emptying a file
      # to zero bytes is not a thing anyone asks for; deleting it is, in the Library.
      return refuse(project, row, draft, "A README needs some text. To remove it, delete the file in the Library.") if draft.strip.empty?
      return refuse(project, row, draft, "This README is too large to edit here.") if
        row && row.node.size.to_i > FilesController::EDITABLE_MAX_BYTES

      # THE SNAPSHOT IS WRITTEN HERE (2026-11-05, live regions; spec §6): every region's body is
      # regenerated from the project's current data before the bytes go down, so the file reads as the
      # table or picture the page shows at the moment of this Save, and a hand-typed directive is
      # filled and closed. The cap is checked on the EXPANDED text, because that is what lands in the
      # file; the draft handed back on a refusal is what the maker TYPED, never the expansion.
      context = Maker::Readme::Live::Context.new(user: current_user, project:, listing:)
      body = Maker::Readme::Live.expand(draft, context:, mode: :file)
      return refuse(project, row, draft, "This README is too large to edit here once its live tables are filled in.") if
        body.bytesize > FilesController::EDITABLE_MAX_BYTES

      result = Maker::TextSave.call(
```

and every later `refuse(project, row, body, …)` in the method → `refuse(project, row, draft, …)` (the stale/removed arm and the two `rescue` arms). Add to the class comment: "SINCE 2026-11-05 THE SAVE EXPANDS THE README'S LIVE REGIONS (Maker::Readme::Live, `:file` mode) BEFORE WRITING — the snapshot in the file is as fresh as the Save, and the only writer of it."

- [ ] **Step 4: The editor partial** — in `app/views/projects/_readme_editor.html.erb`:

Add `listing` to the `Locals:` line of the header: "listing (the Maker::ProjectFolderListing, for the Insert menu's folders and the chooser's root; optional — a refusal passes it too)". Add a paragraph:

"THE INSERT BAR (2026-11-05, live regions; spec §7) sits above the buffer and starts `hidden`: readme_controller.js reveals it once the editor is live, so without JavaScript the inserts are simply absent and a directive can still be typed by hand. Its Files-table menu lists the root and each first-level subfolder off `listing`; Image opens the Miller-columns chooser rooted at the project folder."

Change the opening `<details …>` tag to:

```erb
<% listing = local_assigns[:listing] %>
<details class="composer readme-editor" id="readme-editor" data-controller="readme" data-action="toggle->readme#reveal"
         data-readme-url-value="<%= row && !drafting ? blob_file_path(row.node_id) : "" %>"
         data-readme-draft-value="<%= drafting %>"
         data-readme-children-url-value="<%= library_children_path %>"
         data-readme-folder-id-value="<%= listing&.folder_id %>"
         data-readme-folder-name-value="<%= project.name %>" <%= "open" if local_assigns[:open] %>>
```

and insert, inside the form directly above `<div class="readme-mount" …>`:

```erb
    <div class="readme-insert" data-readme-target="insert" hidden>
      <span class="muted readme-insert-label">Insert</span>
      <details class="menu" data-controller="menu">
        <summary class="btn small">Files table</summary>
        <div class="menu-list">
          <button type="button" class="menu-item" data-action="readme#insertFiles" data-path=".">Root files</button>
          <% Array(listing&.tree).each do |dir| %>
            <button type="button" class="menu-item" data-action="readme#insertFiles" data-path="<%= dir.name %>"><%= dir.name %></button>
          <% end %>
        </div>
      </details>
      <button type="button" class="btn small" data-action="readme#insertDirective" data-directive="bom">Bill of materials</button>
      <button type="button" class="btn small" data-action="readme#insertDirective" data-directive="tasks">Tasks</button>
      <button type="button" class="btn small" data-action="readme#insertDirective" data-directive="log">Build log</button>
      <button type="button" class="btn small" data-action="readme#insertImage">Image</button>
    </div>
```

In `Projects::ReadmesController#refuse`, add `listing:` to the locals: `locals: { project:, row:, draft: body, base_token: params[:base_token].to_s, error:, listing: }` — `refuse` must receive it: change its signature to `def refuse(project, row, body, error, listing:)` and pass `listing:` at every call in `update` (`listing` is built on the method's second line, so every refusal has one; an unavailable listing renders an empty folder menu, which is right).

- [ ] **Step 5: The Stimulus controller** — replace `app/javascript/controllers/readme_controller.js` with:

```js
import { Controller } from "@hotwired/stimulus"
import { chooseFile } from "lib/file_chooser"

// The README editor on the project page (stage 4, S4-4; story 5.3). Upgrades a plain <textarea> to
// CodeMirror and copies the buffer back into it on submit — the form is an ordinary PATCH that
// redirects, so there is no JSON and no token roll-forward here. That is the difference from
// editor_controller.js, which must stay on the file page and therefore fetches. A REFUSED save
// comes back as this editor again (Projects::ReadmesController, 2026-11-02), open, with the error
// rendered in it and the DRAFT in the textarea: `draft` is true then, and the README is not
// fetched, because the bytes it would fetch are the ones the draft was refused against.
//
// LAZY, ON THE <details> TOGGLE. The bytes are fetched the first time the editor is opened and
// never on a page nobody edits, which is what keeps the project page's port reads (and its query
// budget) exactly where S4-1 left them.
//
// THE FIELDS ARE ENABLED ONLY ONCE THE BUFFER HOLDS THE REAL BYTES. Rendered disabled by the
// partial: a bundle that fails to load, or a fetch that 503s on an unmounted NAS, must not leave a
// Save button that posts an empty document over the file. The server refuses a blank body too —
// this is the courteous half, the same split FilesController::EDITABLE_MAX_BYTES already has.
//
// LIVE REGIONS (2026-11-05; spec §7). A fetched README has its regions COLLAPSED to their opening
// line before it reaches the buffer: the bodies are generated (Maker::Readme::Live), editing them is
// wasted, and the server regenerates them on Save whatever was posted — so the collapse is a
// courtesy, not a rule, and a draft (already the maker's own text) is left alone. The Insert bar
// writes a region at the cursor: opener, blank line, closer; the Save fills it. Image opens the
// Miller-columns chooser ROOTED AT THE PROJECT FOLDER, so a pick cannot leave the project.
const MAX_BYTES = 200_000
// The grammar, mirrored from Maker::Readme::Live (OPEN_RE / CLOSE_RE): an opener, then a closer
// before the next opener closes the region; an opener with no such closer is the opener line alone.
const OPEN = /^[ \t]*<!--[ \t]*tinkerex:[a-z]+(?:[ \t]+[^\n]*?)?[ \t]*-->[ \t]*\r?$/
const CLOSE = /^[ \t]*<!--[ \t]*\/tinkerex[ \t]*-->[ \t]*\r?$/

export function collapseRegions(text) {
  const lines = text.split("\n")
  const out = []
  for (let i = 0; i < lines.length; i++) {
    out.push(lines[i])
    if (!OPEN.test(lines[i])) continue
    let j = i + 1
    while (j < lines.length && !OPEN.test(lines[j]) && !CLOSE.test(lines[j])) j++
    if (j < lines.length && CLOSE.test(lines[j])) i = j // skip the body and the closer
  }
  return out.join("\n")
}

export default class extends Controller {
  static targets = ["input", "mount", "status", "submit", "insert"]
  static values = { url: String, draft: Boolean, childrenUrl: String, folderId: String, folderName: String }

  connect() {
    this.loaded = false
    this.disconnected = false
    this.abort = new AbortController()
    // An editor left open by a Turbo restore must still load its bytes.
    if (this.element.open) this.reveal()
  }

  async reveal() {
    if (!this.element.open || this.loaded) return
    this.loaded = true

    // A DECLARED-BUT-EMPTY VALUE IS THE "no README yet" CASE, and `hasUrlValue` is true for it —
    // Stimulus reports a declared String value as present however empty. The template is already
    // in the textarea then, so there is nothing to fetch.
    if (this.urlValue && !this.draftValue) {
      try {
        const res = await fetch(this.urlValue, { credentials: "same-origin", signal: this.abort.signal })
        if (!res.ok) throw new Error(`fetch failed (${res.status})`)
        const text = await res.text()
        if (this.disconnected) return
        if (text.length > MAX_BYTES) {
          this.statusTarget.textContent = "This README is too large to edit here."
          return
        }
        this.inputTarget.value = collapseRegions(text)
      } catch (e) {
        if (this.disconnected) return
        // NOT LOADED AFTER ALL: `loaded` went true at the top so a second toggle during the fetch
        // could not start a second one; a failed fetch hands the flag back, so closing and
        // re-opening the editor retries (an unmounted NAS answers 503 for a while, then not).
        this.loaded = false
        this.statusTarget.textContent = `Could not load the README: ${e.message}. Open again to retry.`
        return
      }
    }

    this.inputTarget.disabled = false
    if (this.hasSubmitTarget) this.submitTarget.disabled = false
    if (this.hasInsertTarget) this.insertTarget.hidden = false
    await this.mountEditor()
  }

  async mountEditor() {
    let cm, languages, theme
    try {
      ;[cm, languages, theme] = await Promise.all([
        import("codemirror"),
        import("lib/codemirror_languages"),
        import("lib/codemirror_theme")
      ])
    } catch (e) {
      // The plain textarea is already editable and already holds the bytes; that IS the degraded
      // state, and it is a working one. Same posture codeview/editor take with their <pre>.
      console.warn("[readme] keeping the plain textarea:", e)
      return
    }
    if (this.disconnected) return

    // `languageFor("md")` is already `cm.markdown()` — the bundle exports @codemirror/lang-markdown
    // (vendor/javascript/codemirror-entry.js). NO NEW PIN AND NO REBUILD: CodeMirror is ONE bundle
    // and exactly one importmap pin (§14d).
    const extensions = [cm.basicSetup, ...theme.themeExtensions(cm)]
    const language = languages.languageFor("md", cm)
    if (language) extensions.push(language)

    this.view = new cm.EditorView({
      state: cm.EditorState.create({ doc: this.inputTarget.value, extensions }),
      parent: this.mountTarget
    })
    this.inputTarget.hidden = true
  }

  // --- the Insert bar ---------------------------------------------------------------------------

  insertFiles(event) {
    this.insertRegion("files", event.currentTarget.dataset.path)
    this.element.querySelector(".readme-insert details.menu")?.removeAttribute("open")
  }

  insertDirective(event) {
    this.insertRegion(event.currentTarget.dataset.directive, "")
  }

  async insertImage() {
    const picked = await chooseFile({
      childrenUrl: this.childrenUrlValue,
      rootId: this.folderIdValue || null,
      rootLabel: this.folderNameValue || "Project folder"
    })
    if (!picked || picked.kind !== "file") return
    const name = picked.path.split("/").pop()
    this.insertRegion("image", `${picked.nodeId} ${name}`)
  }

  insertRegion(directive, args) {
    const opener = `<!-- tinkerex:${directive}${args ? " " + args : ""} -->`
    this.insertText(`${opener}\n\n<!-- /tinkerex -->`)
  }

  // At the cursor, on a line of its own, with a blank line after it; the textarea gets the same at
  // its selection end when CodeMirror never mounted.
  insertText(text) {
    if (this.view) {
      const pos = this.view.state.selection.main.to
      const line = this.view.state.doc.lineAt(pos)
      const before = pos === line.from ? "" : "\n"
      const snippet = `${before}${text}\n`
      this.view.dispatch({ changes: { from: pos, insert: snippet }, selection: { anchor: pos + snippet.length } })
      this.view.focus()
      return
    }
    const field = this.inputTarget
    const at = field.selectionEnd ?? field.value.length
    const before = at === 0 || field.value[at - 1] === "\n" ? "" : "\n"
    const snippet = `${before}${text}\n`
    field.value = field.value.slice(0, at) + snippet + field.value.slice(at)
    field.selectionStart = field.selectionEnd = at + snippet.length
    field.focus()
  }

  // THE BUFFER GOES BACK INTO THE FIELD THE FORM ACTUALLY POSTS. Without this the form submits
  // whatever the textarea held when CodeMirror mounted — every edit silently discarded, with a
  // successful save and a redirect to prove it worked.
  sync() {
    if (this.view) this.inputTarget.value = this.view.state.doc.toString()
  }

  disconnect() {
    this.disconnected = true
    this.abort?.abort()
    this.view?.destroy()
    this.view = null
  }
}
```

- [ ] **Step 6: CSS** — in `pages/projects.css`, directly under the `.readme-editor .readme-form { … }` line, add:

```css
  .readme-editor .readme-insert { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
  .readme-editor .readme-insert-label { font-size: 12px; margin-right: 2px; }
```

- [ ] **Step 7: The system test** — append to `test/system/readme_editor_test.rb` (inside the class):

```ruby
  # LIVE REGIONS (2026-11-05): what no request test can see — that the Insert bar writes into the
  # CodeMirror buffer, that a filled region loads COLLAPSED, and that the Save then fills it.
  test "Insert writes a tasks region at the cursor, the save fills it, and it reopens collapsed" do
    @project.tasks.create!(user: @user, title: "Sand the base", status: "done", position: 0)
    visit project_path(@project)
    find(".readme-editor summary", text: /edit readme/i).click
    assert_selector ".readme-editor .cm-editor", wait: 10
    assert_selector ".readme-insert:not([hidden])"

    content = find(".readme-editor .cm-content")
    content.click
    content.send_keys(:control, :end)
    click_on "Tasks"
    assert_selector ".readme-editor .cm-content", text: "<!-- tinkerex:tasks -->"
    click_on "Save README"

    assert_selector ".flash-notice", text: "Saved the README."
    assert_selector "#project-readme .markdown .task-list-item", text: "Sand the base"
    assert_includes File.read(@path), "- [x] Sand the base"

    # Reopened, the region is one line again: the generated body is not offered for editing.
    find(".readme-editor summary", text: /edit readme/i).click
    assert_selector ".readme-editor .cm-editor", wait: 10
    assert_selector ".readme-editor .cm-content", text: "<!-- tinkerex:tasks -->"
    assert_no_selector ".readme-editor .cm-content", text: "Sand the base"

    assert_no_console_errors
  end
```

(`send_keys(:control, :end)` moves to the document end on Linux Chrome; if the CI runner leaves the
cursor mid-document the region still inserts on its own line, which is all the assertions need.)

- [ ] **Step 8: `docs/invariants/git-editing.md`** — in the Markdown-exception section, after the sentence ending "…at the project folder's root.", add:

"**Since 2026-11-05 that door also EXPANDS the README's live regions before writing** (`Maker::Readme::Live`, `:file` mode; `docs/superpowers/specs/2026-11-05-readme-panel-live-regions-design.md` §6): the snapshot between a region's markers is regenerated on every Save from the project page, and nowhere else — a save from the Files page or an edit in Finder keeps the old snapshot until the next Save there."

- [ ] **Step 9: Run** `env LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) DATABASE_URL=sqlite3:storage/test_edit.sqlite3 PARALLEL_WORKERS=2 bin/rails test test/integration/web/readme_edit_test.rb test/integration/web/readme_panel_test.rb test/stimulus_hygiene_test.rb test/css_hygiene_test.rb test/docs_hygiene_test.rb test/integration/web/template_hygiene_test.rb`, then `env LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) DATABASE_URL=sqlite3:storage/test_edit.sqlite3 bin/rails test test/system/readme_editor_test.rb`. Expected: green.

- [ ] **Step 10: Mutation checks**

1. In the controller, write `draft` instead of `body` to `Maker::TextSave` → "a save fills a hand-typed region…" red (no table on disk).
2. Check the size cap against `draft.bytesize` instead of `body.bytesize` → "the size cap applies to the expanded file" red (the save lands).
3. In `collapseRegions`, return `text` unchanged → the system test's "reopens collapsed" assertion red.
4. In `insertFiles`, read `data-directive` instead of `data-path` → the request test still passes (it is markup) — note that the system test covers Tasks only; report that the Files-table menu and Image chooser were exercised by hand in the browser (`bin/rails server`, open a project, Insert → Files table → a folder; Insert → Image → pick a file) and paste what landed in the buffer.

Restore, re-run green, `bin/rubocop app/controllers/projects/readmes_controller.rb`. Report.

---

### Task 5: The public page renders the README as a panel, live

**Files:**
- Modify: `app/services/maker/public_project.rb`
- Modify: `app/views/public/projects/_page.html.erb`
- Create: `app/views/public/projects/_readme.html.erb`
- Test: `test/integration/web/public_project_test.rb` (new tests appended)

Depends on Task 2. Independent of Tasks 3 and 4 (disjoint files); runs in parallel with Task 3.

- [ ] **Step 1: Append the failing tests to `test/integration/web/public_project_test.rb`**, in the "4. the README" section after the existing README test:

```ruby
    test "the README is a panel in the layout's order, headed, and leaves the page when hidden" do
      get path
      assert_select ".panel-slot .readme-panel .panel-head h2", text: "README"
      # Photos ahead of the README: the visitor sees the owner's order.
      @project.update!(panels: { "order" => %w[photos readme attachments] })
      get path
      slots = css_select(".project-panels .panel-slot .panel").map { |p| p["class"] }
      assert_operator slots.index { |c| c.include?("photos-panel") }, :<, slots.index { |c| c.include?("readme-panel") }

      @project.update!(panels: { "hidden" => [ "readme" ] })
      get path
      assert_select ".readme-panel", 0
    end

    test "a live files region renders through the public seam, and a live picture of a model is a link until its thumbnail is ready" do
      folder = @user.nodes.present.find_by!(node_id: @project.folder_node_id)
      readme = @user.nodes.present.find_by!(name: "README.md", parent_node_id: folder.node_id)
      body = "# Desk Lamp\n\n<!-- tinkerex:files models -->\n\n<!-- tinkerex:image #{@f[:base].node_id} The base -->\n\n" \
             "<!-- tinkerex:image #{@f[:pic].node_id} -->\n"
      @root.join(readme.storage_path).write(body)
      readme.update!(size: body.bytesize)

      get path

      assert_select ".readme-panel .markdown table td a[href=?]", public_file_path("ada", @project.slug, @f[:base].node_id), text: "base.stl"
      assert_select ".readme-panel .markdown a[href=?]", public_file_path("ada", @project.slug, @f[:base].node_id), text: "The base"
      assert_select ".readme-panel .markdown img[src=?]", public_file_path("ada", @project.slug, @f[:pic].node_id)
      assert_select ".readme-panel .markdown img", count: 1
      assert_select ".readme-panel .markdown", text: /tinkerex/, count: 0
      # NEVER the maker's own routes on a visitor's page (the seam guard's third arm).
      assert_select ".readme-panel [src^='/files/'], .readme-panel [href^='/files/']", 0
    end
```

(`@f[:base]` is `models/base.stl` and `@f[:pic]` is `photos/pic.png` in `PublicFixture#seed_public_project!`; `@root` is the share root the suite's setup pins. If the fixture's hash keys differ, read `test/support/public_fixture.rb` and use its names.)

- [ ] **Step 2: Run to verify they fail**

Run: `env LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) DATABASE_URL=sqlite3:storage/test_public.sqlite3 PARALLEL_WORKERS=2 bin/rails test test/integration/web/public_project_test.rb`
Expected: the two new tests red (no `.panel-slot .readme-panel`, `<!-- tinkerex` text in the markdown).

- [ ] **Step 3: `app/services/maker/public_project.rb`**

Replace the `readme` method with:

```ruby
    # STEP ONE OF THE README (2026-11-05, live regions): read and parse, so `#thumbs` can fold the
    # `image` regions' node ids into the page's one thumbnail query. `defined?` rather than `||=`
    # because nil is a real answer here (no README at all).
    def readme_source
      return @readme_source if defined?(@readme_source)

      @readme_source = Maker::Readme.source(user: owner, rows: listing.loose)
    end

    # The FOLDER's own README, rendered LIVE through the public seam, or nil when it holds none.
    #
    # `base_path` IS THE FOLDER'S OWN LIBRARY PATH, NOT "": `listing.path_index` keys on full
    # library paths ("Projects/desk-lamp/models/base.stl"), so a README at the folder root
    # resolves `models/base.stl` against `listing.path` ("Projects/desk-lamp"). A base that is
    # not the README's real directory resolves NOTHING and the links quietly become plain text —
    # pinned in test/services/maker/readme_test.rb ("a base_path that is not the README's own
    # directory resolves nothing").
    #
    # EVERY DIRECTIVE RENDERS HERE, tasks included (spec §5): the maker put the region in the README
    # on purpose, and the bundle already ships the file with its snapshot. The links are the public
    # byte and preview URLs; a BOM part that is an inventory item is a name, never a link.
    def readme
      return @readme if defined?(@readme)

      source = readme_source
      @readme = source && Maker::Readme.render(
        source, base_path: listing.path, index: listing.path_index,
        link: ->(id) { file_url_for(id) }, image_link: ->(id) { image_url_for(id) },
        context: Maker::Readme::Live::Context.new(user: owner, project:, listing:, bom_lines:, tasks:, entries:, thumbs:)
      )
    end

    def tasks = @tasks ||= project.tasks.order(:position, :created_at).to_a
```

Change `bom_lines` to include the supplier the `bom` emitter reads (one eager load, not a query per line):

```ruby
    def bom_lines
      @bom_lines ||= (bom = project.current_bom) ? bom.lines.includes(:inventory_item, :supplier).to_a : []
    end
```

Add, beside `preview_url_for`:

```ruby
    # THE VISITOR'S PICTURE OF A FILE, BY NODE (2026-11-05, live regions; spec §5) — the public twin
    # of ProjectsHelper#maker_image_link: an image file is its byte URL, any other file its READY
    # thumbnail through the preview route, and nil (the picture is dropped) while none is ready.
    def image_url_for(node_id)
      row = listing.row_for(node_id)
      return file_url_for(node_id) if row.nil? || Maker::FileAttachment.inline_image?(row.node.name)

      thumbs.thumb(node_id)&.showable? ? preview_url_for(node_id) : nil
    end
```

In `thumbs`, add a term to the union, after the blocks term: `+ (panel_visible?("readme") ? Array(readme_source&.image_node_ids) : [])`, with a comment line: `# THE README'S LIVE PICTURES, only when its panel shows — a hidden README is never read here.`

- [ ] **Step 4: The views**

Create `app/views/public/projects/_readme.html.erb`:

```erb
<%#
  THE README, PUBLIC (2026-11-05, live regions; spec §2): where the maker placed it, through the
  layout like every other panel — it was pinned above the hero before, whatever the order said.
  Rendered LIVE through the public seam (Maker::PublicProject#readme: byte and preview URLs, the
  owner's BOM, tasks and build log), so a visitor sees the tables the maker does. A README that is
  gone or unreadable renders its note, as before. Nothing here names a maker route (the seam
  guard's third arm, test/architecture_invariants_test.rb).
  Local: pub (Maker::PublicProject).
%>
<% readme = pub.readme %>
<% if readme&.html.present? || readme&.note %>
  <section class="panel readme-panel">
    <div class="panel-head">
      <h2><%= panel_title(pub.layout, "readme") %></h2>
    </div>
    <%= panel_intro(pub.layout, "readme") %>
    <% if readme.html.present? %>
      <div class="markdown"><%= readme.html %></div>
    <% end %>
    <% if readme.note %>
      <p class="muted readme-note"><%= readme.note %></p>
    <% end %>
  </section>
<% end %>
```

In `app/views/public/projects/_page.html.erb`: delete the block from `<% readme = pub.readme %>` through its final `<% end %>` (the `.readme-panel` section and the `elsif readme&.note` arm), and add `"readme" => "public/projects/readme",` as the FIRST pair of the `public_panels` map. In the comment above the map, the sentence "`tasks`, `sheets` and `publish` are absent from it…" stays; add: "`readme` joined it on 2026-11-05 — the README used to be pinned above the hero outside this loop."

- [ ] **Step 5: Run** the Step 2 command plus `test/services/maker/public_project_test.rb test/integration/web/public_bundle_test.rb test/integration/web/public_preview_test.rb test/integration/web/page_query_budget_test.rb test/architecture_invariants_test.rb test/integration/web/template_hygiene_test.rb`. Expected: green; the public budget stays constant (the README's BOM, tasks, entries and thumbs are the page's own memoised readers).

- [ ] **Step 6: Mutation checks**

1. In `_page.html.erb`, remove the `"readme" => …` map entry → "the README is a panel in the layout's order…" red.
2. In `image_url_for`, return `file_url_for(node_id)` unconditionally → "…a live picture of a model is a link until its thumbnail is ready" red (an `<img>` pointing at STL bytes, count 2).
3. In `readme`, pass `context: nil` → the same test red (`tinkerex` text absent but no table; the `td a` assertion fails).

Restore, re-run green, `bin/rubocop app/services/maker/public_project.rb`. Report.

---

### Task 6: Close-out — docs sweep, the gates, the PR, the record

**Files:** whatever the sweep names; no new code.

- [ ] **Step 1: Sweep documentation** that described the card or the pinned public README:
  `grep -rn "readme_card\|readme-card\|above the hero" app/ test/ docs/invariants docs/user-stories.md docs/DEPLOY.md CLAUDE.md` → fix every live hit (plans and audits under `docs/superpowers/plans`, `docs/audit-*` are history: leave them). Check `docs/user-stories.md` rows 2.9 and 3.4 read true ("README links resolve only on the project and public pages" still holds).
- [ ] **Step 2: The gates.** From the main checkout on `claude/readme-live-regions`: bare `bin/ci`. It runs
  `setup style scan test test-s3 test-chunk-remote system` and compares the three backend legs' RUN
  counts itself (§15). Expected: every gate green, identical RUN counts. The chunk_remote leg needs
  `../tinkerex-sync` (CLAUDE.md §13). If a leg differs in RUNS, a test depends on the ambient backend:
  every new test here pins share through `use_fresh_share_library!`, so look at the test that does not.
- [ ] **Step 3: After any cancelled or errored subagent**, `git diff --stat origin/main -- app/ lib/ config/ db/` before committing anything (execute-plan.md §4).
- [ ] **Step 4: `/finish-branch`** — commit, push, open the PR. The PR body states what was verified (the
  gates, the mutation outputs, the manual check of the Image chooser) and what was not (no deploy).
- [ ] **Step 5: The record** — `bin/log status` (must exit 0), then `bin/log arc --from-pr <n>`. The arc
  closes at merge with `bin/log close <n>`, never before.

---

## Self-review against the spec

- §2 panel, label, width, lead, hideable, unread when hidden, root card without README, nested cards kept, public map, edit mode without the door → Task 3 (+ Task 5 for the public map). `panel_has_rows?("readme")` is NOT implemented: `readme` is not an on-demand panel (it always has the editor door for the maker), so `?add=readme` is never offered and the method has no case to answer — a deliberate narrowing of one sentence of the spec, noted here.
- §3 grammar, five directives, regeneration, unclosed regions, unrecognised verbatim, caps, cap on the expanded size → Tasks 1 and 4.
- §4 emitters, escaping, the image split → Task 1.
- §5 `Live`, `Context`, read-before-thumbs / render-after, the node-aware arm on both pages, every directive public, file page and MCP unchanged → Tasks 2, 3, 5.
- §6 the Save expands, cap on the expanded text, the one-door rule, git-editing.md line → Task 4.
- §7 the Insert bar, the chooser rooted at the folder, collapse on load, no-JS fallback → Task 4.
- §8 edge cases: gone source, markers out of shape, path arithmetic, node ids, caps, thumbnails not ready, nested/file page/MCP never expand → Tasks 1, 2.
- §10 tests: live_test (grammar, caps, escaping, order, missing source, image split as the only difference), controller (snapshot on disk, tampered body replaced, unclosed closed, cap on expanded, stale/blank untouched), page (panel at its id with a live table, hidden costs no read, repo-root split, edit mode, constancy in N), public (order, hidden, public URLs, image split), vocabulary tests, mutation checks → Tasks 1–5.

Type consistency: `Maker::Readme::Live.regions/expand/emit/cell/link/note/size/date/table`,
`Live::Context#bom_lines/tasks/entries/row/relative_path/files_at/thumb_ready?`,
`Maker::Readme.source/render/for`, `Source#image_node_ids`, `Region#closed?/recognised?/node_id`,
`RepoCard.for(readme:)`, `ProjectsHelper#maker_image_link(listing, thumbs)`,
`PublicProject#readme_source/readme/tasks/image_url_for`, `collapseRegions` — each name is used
identically wherever it appears above.
