require "test_helper"

module Web
  # The flat by-extension view: "show me every .stl in my library, wherever it lives."
  # BACKEND-NEUTRAL by construction — it filters `nodes.name`, which all three adapters populate.
  class FilesTypeFilterTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "ext-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)

      #   /root.stl
      #   /notes.pdf
      #   /cad/                     (dir-cad)
      #   /cad/deep.stl             <- the one a folder view would hide
      #   /cad/part.3mf
      #   /cad/sub/                 (dir-sub)
      #   /cad/sub/tiny.stl
      @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir")
      @user.nodes.create!(node_id: "dir-sub", name: "sub", kind: "dir", parent_node_id: "dir-cad")
      file("root.stl",  nil)
      file("notes.pdf", nil)
      file("deep.stl",  "dir-cad")
      file("part.3mf",  "dir-cad")
      file("tiny.stl",  "dir-sub")
    end

    def file(name, parent)
      @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file",
                          parent_node_id: parent, mtime: 1_000_000_000, size: 5)
    end

    # The type dropdown's real options as { ext => count-as-rendered }. The disabled placeholder is
    # excluded by `[value]:not([value=''])` — it is a label, not an option anyone can choose. The
    # count is read out of the LABEL rather than recomputed, so these tests assert what the user
    # sees rather than re-deriving it from the same data the view used.
    def ext_options
      css_select(".ext-picker option[value]").reject { |o| o["value"].blank? }
                                             .to_h { |o| [ o["value"], o.text[/\((.+)\)/, 1] ] }
    end

    # The flat view's Folder column, keyed by file name. Third cell: Name, Type, Folder — see
    # files/_list.html.erb, where the column is emitted only when @flat.
    def folder_labels
      css_select("table.files tbody tr").to_h do |row|
        cells = row.css("td")
        name = (cells[0].at_css(".file-name") || cells[0].at_css("a")).text.strip
        [ name, cells[2].text.strip ]
      end
    end

    # Same reader as files_sort_test.rb — a thumbnailable file's link contains the thumbnail cell
    # as well as the name, so read the .file-name span when there is one.
    def listed_names
      css_select("table.files tbody tr td:first-child").map do |cell|
        (cell.at_css(".file-name") || cell.at_css("a")).text.strip
      end
    end

    test "one extension lists every match in the library, at any depth" do
      get files_path(ext: "stl")
      assert_equal %w[deep.stl root.stl tiny.stl], listed_names.sort
    end

    test "several extensions compose" do
      get files_path(ext: "stl,3mf")
      assert_equal %w[deep.stl part.3mf root.stl tiny.stl], listed_names.sort
    end

    test "the filter ignores ?folder= — flat means the whole library" do
      get files_path(folder: "dir-sub", ext: "stl")
      assert_equal %w[deep.stl root.stl tiny.stl], listed_names.sort
      # And the page SAYS so rather than merely behaving so: the breadcrumb is back at the root,
      # and the in-page links carry the filter instead of the folder the request threw away.
      assert_select "nav.breadcrumb a", text: "Files", count: 1
      assert_select "nav.breadcrumb a[href=?]", files_path(folder: "dir-sub"), count: 0
      assert_select "th a[href=?]", files_path(ext: "stl", sort: "type", dir: "asc")
    end

    test "directories never appear in a type view" do
      # A DIRECTORY NAMED LIKE A FILE is what proves the kind filter is doing the work: "cad"
      # would never match "%.stl" on its name alone, so without this row the assertion below holds
      # whether or not the scope filters on kind at all.
      @user.nodes.create!(node_id: "dir-trap", name: "old-versions.stl", kind: "dir")
      get files_path(ext: "stl")
      assert_select "a.dir", count: 0
      assert_not_includes listed_names, "cad"
      assert_not_includes listed_names, "old-versions.stl"
    end

    test "another user's files never appear in a type view" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      other.nodes.create!(node_id: "theirs", name: "secret.stl", kind: "file", mtime: 1, size: 1)

      get files_path(ext: "stl")
      assert_not_includes listed_names, "secret.stl"
      assert_no_match(/secret\.stl/, response.body)
      # THE COUNT MUST NOT LEAK EITHER, and it is the only place an unscoped query would still
      # show: the rows themselves are filtered a second time against stat_all, which is per-user,
      # so a cross-user scope here renders nothing extra and only the total gives it away.
      with_flat_limit(1) do
        get files_path(ext: "stl")
        assert_select ".truncated", text: /first 1 of 3/i
      end
    end

    test "a tombstoned file never appears in a type view" do
      @user.nodes.find_by!(node_id: "n-deep.stl").update!(deleted: true)
      get files_path(ext: "stl")
      assert_equal %w[root.stl tiny.stl], listed_names.sort
      # Same second look as the cross-user case, for the same reason: stat_all is also `present`,
      # so a scope that forgot the tombstone filter is invisible in the rows and visible in the
      # total.
      with_flat_limit(1) do
        get files_path(ext: "stl")
        assert_select ".truncated", text: /first 1 of 2/i
      end
    end

    test "matching is case-insensitive on the extension" do
      file("SHOUTY.STL", nil)
      get files_path(ext: "stl")
      assert_includes listed_names, "SHOUTY.STL"
    end

    # THE ONE TEST HERE THAT READS THE SQL, AND THE REASON IS THAT NO LEG CAN SEE ANY OF IT. All
    # three legs run SQLite; every clause below is a place SQLite and Postgres answer differently,
    # so each one is a production-only bug that a behavioural assertion stays green through. This
    # is the same class of gap FilesController#show records for its two sort collations — the
    # difference is that here there IS something to pin, so pin it.
    #
    #   LOWER(name) LIKE  — SQLite's LIKE is ASCII-case-insensitive, Postgres' is not, so the bare
    #                       form finds SHOUTY.STL on self-host and misses it on managed. The
    #                       case-insensitivity test directly above passes either way.
    #   ESCAPE '\'        — Postgres treats backslash as LIKE's escape by default; SQLite has NO
    #                       default escape, so without this clause the backslash sanitize_sql_like
    #                       inserts is matched literally and `_` stays a wildcard. Verified on this
    #                       connection: 'x.st\l' LIKE '%.st\_' is 1 without it and 0 with it.
    #   COALESCE(mtime,0) — a NULL sorts FIRST on SQLite and LAST on Postgres. sort_key reads a nil
    #                       mtime as 0, and this is what makes the SQL agree with it.
    test "the query's cross-database clauses are present, which no test leg can otherwise reveal" do
      sql = captured_sql { get files_path(ext: "stl") }
      assert(sql.any? { |q| q.match?(/LOWER\(name\)\s+LIKE/i) },
             "the extension match must lowercase `name`, or it is case-sensitive on Postgres")
      assert(sql.any? { |q| q.include?("ESCAPE '\\'") },
             "the LIKE needs an explicit ESCAPE, or sanitize_sql_like does nothing on SQLite")

      sorted = captured_sql { get files_path(ext: "stl", sort: "modified", dir: "asc") }
      assert(sorted.any? { |q| q.match?(/COALESCE\(mtime, ?0\)/i) },
             "a NULL mtime must be coalesced, or the two databases order it differently")
    end

    test "an extension is matched at the END of the name, not anywhere in it" do
      file("stl-notes.txt", nil)
      get files_path(ext: "stl")
      assert_not_includes listed_names, "stl-notes.txt"
    end

    test "junk extensions are dropped, not queried" do
      get files_path(ext: "../etc,%,thisiswaytoolong,st l")
      assert_response :success
      # Nothing valid survived the whitelist, so this is an ordinary folder view.
      assert_includes listed_names, "cad"
    end

    # LIKE'S TWO WILDCARDS, ASKED ABOUT TWICE, AND THE ORDER OF THE TWO ASSERTIONS IS DELIBERATE:
    # Minitest stops a test at the first failure, so the one that DIAGNOSES has to come before the
    # one that merely notices.
    #
    # `%` and `_` are stopped by two layers — EXT_RE drops them outright, and sanitize_sql_like's
    # backslash plus the ESCAPE clause would neutralise them if the whitelist were ever loosened
    # to \w. The "we are still in folder view" assertion is SENSITIVE BUT NOT SPECIFIC: it does go
    # red on a real widening, but it also goes red on a harmless loosening, where EXT_RE admits
    # `_`, the escape defuses it, nothing matches, and all that changed is which mode the page is
    # in. On its own it cannot tell you which happened.
    #
    # The empty-folder probe is the specific one. Browsing a folder with nothing in it makes the
    # fallback render no rows either way, so a row appearing there means — and can only mean — the
    # wildcard reached the query. Verified by mutation: loosening EXT_RE alone leaves the probe
    # green and reddens only the mode assertion; removing both layers reddens the probe.
    test "a LIKE metacharacter cannot widen the match" do
      @user.nodes.create!(node_id: "dir-empty", name: "empty", kind: "dir")

      get files_path(folder: "dir-empty", ext: "s%l")
      assert_response :success
      assert_empty listed_names, "'%' reached the LIKE and matched .stl files"

      get files_path(ext: "s%l")
      assert_includes listed_names, "cad", "an escaped-away filter must fall back to folder view"
    end

    test "an underscore cannot widen the match either" do
      # '_' is LIKE's single-character wildcard and, unlike '%', it looks innocuous enough to
      # survive a whitelist someone loosens to \w — at which point `%.st_` matches every .stl.
      @user.nodes.create!(node_id: "dir-empty", name: "empty", kind: "dir")

      get files_path(folder: "dir-empty", ext: "st_")
      assert_response :success
      assert_empty listed_names, "'_' reached the LIKE and matched .stl files"

      get files_path(ext: "st_")
      assert_includes listed_names, "cad", "an underscore must not become a wildcard"
    end

    # PINNED FROM BOTH SIDES. Only asserting that the 9th is dropped would stay green if the cap
    # were tightened to 2, silently throwing away six of the user's chips; only asserting that the
    # 8th survives would stay green if the cap were removed entirely.
    test "exactly MAX_EXTS extensions are honoured, and no more" do
      eighth = %w[aa bb cc dd ee ff gg stl]
      get files_path(ext: eighth.join(","))
      assert_equal %w[deep.stl root.stl tiny.stl], listed_names.sort,
                   "the 8th extension was dropped — the cap is below MAX_EXTS"

      ninth = %w[aa bb cc dd ee ff gg hh stl]
      get files_path(ext: ninth.join(","))
      assert_response :success
      assert_empty listed_names, "the 9th extension was queried despite MAX_EXTS = 8"
    end

    test "no matches renders an empty state, not an error" do
      get files_path(ext: "dxf")
      assert_response :success
      assert_select ".empty", text: /No files match/i
    end

    test "the flat list shows which folder each file is in" do
      get files_path(ext: "stl")
      assert_select "th", text: "Folder"
      # The nested one names its full path, and the link goes to that folder — the flat view
      # doubles as a way to FIND things.
      assert_select "table.files tbody tr td a[href=?]", files_path(folder: "dir-sub"),
                    text: "cad/sub"
      # A file at the library root has no folder path; it must still say something navigable.
      assert_select "table.files tbody tr td a", text: "Files"
    end

    # A REACHABLE COMBINATION, not a curiosity: `view` is cookie-persisted, so anyone who has ever
    # chosen grid meets this the first time they click a chip. The grid has no Folder column (cards
    # have no columns), but its sort form still has to carry the filter or the first use of that
    # form silently drops it.
    test "the grid honours the filter too, since the view choice is cookie-persisted" do
      get files_path(view: "grid", ext: "stl")
      assert_response :success
      assert_select ".files-grid .grid-card", count: 3
      assert_select "form.sort-form input[type=hidden][name=ext][value=stl]"
    end

    test "the folder column is absent from an ordinary folder view" do
      get files_path
      assert_select "th", text: "Folder", count: 0
    end

    # THE FOLDER COLUMN COSTS ONE QUERY FOR THE WHOLE PAGE, NOT ONE PER ROW. A flat view is the
    # one page in this app whose row count is the size of the library, so a parent walk per row is
    # the N+1 that page cannot afford — and it is the obvious way to write this. Asserted as
    # CONSTANT IN N rather than against a literal, for the same reason the port's stat_all contract
    # is: a literal would pin one backend's query shape into a test all three run.
    test "the folder column does not add a query per row" do
      few = count_queries { get files_path(ext: "stl") }
      12.times { |i| file("bulk#{i}.stl", "dir-sub") }
      many = count_queries { get files_path(ext: "stl") }

      assert_operator listed_names.size, :>=, 15, "the second page must really be bigger"
      assert_equal few, many, "the flat view's query count grew with the number of rows"
    end

    # A corrupt parent chain must not take the page down. `folder_paths_for` asks
    # Maker::LibraryTree, whose walk carries the cycle guard; folder_crumbs carries its own for the
    # same reason.
    #
    # THE RENDERED CELL IS ASSERTED, NOT JUST THE STATUS. `assert_response :success` alone cannot
    # see what the column says, and what it said before the shared index was "…/sub/tiny" — a
    # literal ellipsis spliced into a path, offered to the user as where their file lives.
    test "a cycle in the parent chain does not blow the stack" do
      @user.nodes.find_by!(node_id: "dir-cad").update!(parent_node_id: "dir-sub")
      get files_path(ext: "stl")
      assert_response :success
      assert_includes listed_names, "tiny.stl"
      assert_equal "Files", folder_labels["tiny.stl"],
                   "an unresolvable chain must read as the root, not as a path with a hole in it"
    end

    # THE OTHER UNRESOLVABLE SHAPE, and the ordinary one: a live folder whose parent row has been
    # tombstoned. The bare leaf this used to print ("sub") claims a top-level folder that is not
    # there — the link still goes to the right folder either way, so only the label moves.
    test "a file under a folder whose parent row is gone reads as the root" do
      @user.nodes.find_by!(node_id: "dir-cad").update!(deleted: true)
      get files_path(ext: "stl")
      assert_response :success
      assert_equal "Files", folder_labels["tiny.stl"]
      # and the resolvable rows are untouched
      assert_equal "Files", folder_labels["root.stl"]
    end

    # --- the type dropdown ------------------------------------------------------

    # THE POINT OF THE CONTROL, IN ONE ASSERTION: the options are what the LIBRARY holds, not what
    # the vocabulary knows. The chip row this replaced iterated `ROLE_BY_EXT` and offered ~35 types
    # — `.sldasm`, `.ngc`, `.fcstd` — to a user who owns none of them.
    test "the dropdown offers exactly the extensions the library actually holds" do
      get files_path
      assert_equal %w[3mf pdf stl], ext_options.keys.sort
    end

    # THE OTHER HALF, and it is what retires the free-text escape hatch: an extension the curated
    # vocabulary has never heard of is offered anyway, because it can only appear here if the user
    # already has a file with it. `.kicad` is in no ROLE_BY_EXT entry.
    test "an extension the vocabulary has never heard of is offered under Other" do
      file("board.kicad", nil)
      get files_path
      assert_includes ext_options.keys, "kicad"
      assert_select ".ext-picker optgroup[label=Other] option[value=kicad]"
      # And it really filters, rather than merely appearing.
      get files_path(add_ext: "kicad")
      assert_equal %w[board.kicad], listed_names
    end

    # The counts are the evidence the list is derived rather than curated — a hard-coded option
    # cannot carry one.
    test "each option carries how many files of that type the library holds" do
      get files_path
      assert_equal({ "stl" => "3", "3mf" => "1", "pdf" => "1" }, ext_options)
    end

    # An OPTION whose extension the controller then drops is a control that looks live and does
    # nothing: it renders, it submits, and it silently returns the ordinary folder view. Every
    # option is driven for real here, which is what keeps ext_facets and EXT_RE from drifting.
    test "every option in the dropdown is an extension the controller actually accepts" do
      file("board.kicad", nil)
      file("sketch.f3d", nil)
      get files_path
      exts = ext_options.keys
      assert_operator exts.size, :>=, 5

      exts.each do |ext|
        get files_path(add_ext: ext)
        # The chosen type comes back ACTIVE — the one signal that works whatever the library holds.
        assert_select ".ext-filter a.chip.active", { count: 1 },
                      "add_ext=#{ext} rendered an option the filter then ignored"
      end
    end

    # Directories and symlinks are not file TYPES. `old-versions.stl` as a DIRECTORY is the row that
    # proves the kind filter runs here too — without it the assertion holds whether or not
    # ext_facets filters on kind at all, exactly as in the listing test below.
    test "the dropdown counts files only, never folders or symlinks" do
      @user.nodes.create!(node_id: "dir-trap", name: "old-versions.stl", kind: "dir")
      @user.nodes.create!(node_id: "n-alias", name: "alias.stl", kind: "symlink",
                          mtime: 1_000_000_000, size: 1)
      get files_path
      assert_equal "3", ext_options["stl"], "a folder or symlink was counted as a file of its type"
    end

    test "a tombstoned file drops out of the dropdown" do
      @user.nodes.find_by!(node_id: "n-part.3mf").update!(deleted: true)
      get files_path
      assert_not_includes ext_options.keys, "3mf"
    end

    test "another user's extensions never appear in the dropdown" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      other.nodes.create!(node_id: "theirs", name: "secret.kicad", kind: "file", mtime: 1, size: 1)

      get files_path
      assert_not_includes ext_options.keys, "kicad"
    end

    # An empty library must not render a select whose only entry is a disabled placeholder — a
    # control that cannot be used is the thing this row has already been fixed for twice.
    test "an empty library says so instead of rendering an unusable select" do
      @user.nodes.destroy_all
      get files_path
      assert_select ".ext-picker select", count: 0
      assert_select ".ext-picker .muted", text: "no files yet"
    end

    test "chips mark the active extensions and toggle them off" do
      get files_path(ext: "stl")
      assert_select ".ext-filter a.chip.active", text: /stl/
      # The state is announced, not just coloured — and on a LINK that means aria-current, which
      # is valid there, rather than aria-pressed, which is not.
      assert_select ".ext-filter a.chip[aria-current=true]", text: /stl/, count: 1
      assert_select ".ext-filter a.chip[aria-current]", count: 1
      # Clicking the active chip removes it. No sort params ride along — the sort lives in a
      # cookie, so pinning it here would bake a stale choice into any copied chip URL.
      assert_select ".ext-filter a.chip.active[href=?]", files_path
    end

    # TWO CONTROLS, ONE JOB EACH: the select ADDS, the chips REMOVE. Adding is a union rather than a
    # replacement, and the hidden `ext` field carrying the current set is what makes it one.
    test "choosing from the dropdown adds to the active set rather than replacing it" do
      get files_path(ext: "stl")
      assert_select ".ext-picker input[type=hidden][name=ext][value=stl]"
      assert_includes ext_options.keys, "3mf"

      get files_path(ext: "stl", add_ext: "3mf")
      assert_equal %w[deep.stl part.3mf root.stl tiny.stl], listed_names.sort
    end

    # An ACTIVE type is absent from the dropdown: `add_ext` unions into `ext`, so re-choosing one
    # would be an option whose selection changes nothing. It is a chip instead, and the chip removes.
    test "an active type leaves the dropdown and becomes a removable chip" do
      get files_path(ext: "stl")
      assert_not_includes ext_options.keys, "stl"
      assert_select ".ext-active a.chip.active[href=?]", files_path
      assert_select ".ext-active a.chip.active .chip-x"
    end

    test "a chip URL carries no sort, so the cookie's sort still applies through it" do
      get files_path(ext: "stl", sort: "modified", dir: "desc")
      href = css_select(".ext-filter a.chip.active").first["href"]
      assert_equal files_path, href
      # Following it clears the filter and keeps the sort the user chose, from the cookie.
      get href
      assert_select "th[aria-sort=descending]", text: /Modified/
    end

    test "add_ext filters on its own, the way the dropdown submits it" do
      file("model.f3d", nil)
      get files_path(add_ext: "f3d")
      assert_equal %w[model.f3d], listed_names
    end

    test "sorting still applies inside a filtered view" do
      get files_path(ext: "stl", sort: "name", dir: "desc")
      assert_equal %w[tiny.stl root.stl deep.stl], listed_names
    end

    test "the sort headers carry the filter, so sorting does not clear it" do
      get files_path(ext: "stl")
      assert_select "th a[href=?]", files_path(ext: "stl", sort: "type", dir: "asc")
    end

    test "the result set is bounded and says so when it truncates" do
      with_flat_limit(2) do
        get files_path(ext: "stl")
        assert_equal 2, listed_names.size
        assert_select ".truncated", text: /first 2 of 3/i
      end
    end

    test "an untruncated result set says nothing" do
      get files_path(ext: "stl")
      assert_select ".truncated", count: 0
    end

    # THE TRUNCATED PAGE MUST BE THE FIRST N OF THE FULL PAGE — under the user's OWN sort, not
    # under the one the query happened to be in. The page query is what the LIMIT slices, so
    # ordering it by name and re-sorting the slice in Ruby showed the alphabetical head of the
    # library beneath a banner reading "the first 5". Measured before the fix, with exactly these
    # fixtures: `?ext=stl&sort=modified&dir=asc` rendered aa04…aa00 — the five NEWEST — and called
    # them the first five oldest.
    #
    # The expectation is READ FROM THE UNTRUNCATED PAGE rather than written out by hand, so the
    # test cannot drift from what the sort actually means and cannot be satisfied by a hand-copied
    # order that is itself wrong.
    test "a truncated page is the first N under the user's sort, whichever sort that is" do
      # Name order and mtime order are exact opposites, so an alphabetical selection and a
      # modified selection can never coincide by luck.
      30.times do |i|
        @user.nodes.create!(node_id: format("t%02d", i), name: format("aa%02d.stl", i),
                            kind: "file", mtime: (100 - i) * 1_000_000_000, size: 1)
      end

      %w[name type modified].each do |key|
        %w[asc desc].each do |direction|
          get files_path(ext: "stl", sort: key, dir: direction)
          full = listed_names
          assert_equal 33, full.size

          with_flat_limit(5) do
            get files_path(ext: "stl", sort: key, dir: direction)
            assert_equal full.first(5), listed_names,
                         "sort=#{key}&dir=#{direction}: the truncated page is not the full page's first 5"
            assert_select ".truncated", text: /first 5 of 33/i
          end
        end
      end
    end

    # THE TWO ORDERING AUTHORITIES MUST MEAN THE SAME THING. Flat mode orders in SQL because there
    # the ORDER BY is what the LIMIT selects with; the folder view orders in Ruby because its
    # extensions are unbounded (§5.2). Ask for the same files both ways and the answer must not
    # depend on which door you came through. Mixed case is in the fixture on purpose: it is what
    # forces LOWER() on the SQL side, and a bare `ORDER BY name` would file "Bracket" before
    # "apple" here while Ruby's downcase would not.
    test "the flat view's SQL order and the folder view's Ruby order agree, key for key" do
      @user.nodes.create!(node_id: "dir-both", name: "both", kind: "dir")
      # Two extensions (so `type` has something to order), and a deliberate mtime tie between
      # apple and echo (so the tiebreak is exercised, not just the key).
      [ [ "Bracket.f3d", 5 ], [ "apple.scad", 2 ], [ "Zebra.f3d", 9 ],
        [ "mid.scad", 7 ], [ "echo.f3d", 2 ] ].each_with_index do |(name, mtime), i|
        @user.nodes.create!(node_id: "nb-#{i}", name:, kind: "file", parent_node_id: "dir-both",
                            mtime: mtime * 1_000_000_000, size: 1)
      end

      %w[name type modified].each do |key|
        %w[asc desc].each do |direction|
          get files_path(folder: "dir-both", sort: key, dir: direction)
          in_folder = listed_names
          assert_equal 5, in_folder.size

          get files_path(ext: "f3d,scad", sort: key, dir: direction)
          assert_equal in_folder, listed_names,
                       "sort=#{key}&dir=#{direction}: flat and folder disagree about the same files"
        end
      end
    end

    # WHICH ROW LANDS ON THE BOUNDARY MUST NOT BE THE QUERY PLANNER'S CHOICE. Names repeat across
    # folders, so the old `order(:name)` had no total order and the cut fell wherever the rows
    # happened to come back. These three are inserted in DESCENDING node_id order, so rowid order
    # and node_id order disagree: without the `node_id ASC` tiebreak the page follows insertion
    # order instead.
    test "duplicate names are cut at a deterministic boundary" do
      # "aaa" so they are the ones the name sort puts at the head, and so the boundary falls
      # between them rather than between them and the setup's files.
      %w[dup-c dup-b dup-a].each do |id|
        @user.nodes.create!(node_id: id, name: "aaa.stl", kind: "file", mtime: 1, size: 1)
      end

      with_flat_limit(2) do
        get files_path(ext: "stl")
        # Both rows are named "same.stl", so identity has to be read off the row's own links.
        ids = css_select("table.files tbody tr td.row-actions a").map { |a| a["href"][%r{files/([^/]+)/blob}, 1] }
        assert_equal %w[dup-a dup-b], ids
      end
    end

    # THE COST OF THE PAGE, NOT JUST OF ONE METHOD, AND THE FIXTURES ARE WHY. An earlier version of
    # this test seeded bare `nodes` rows: with no content token, stat_all reports no content,
    # the backfill skips every row, and the assertion could not see the per-row work it
    # exists to forbid. With production-shaped rows the same assertion read few=17 many=44 —
    # and on a 2500-file library one uncapped load ran 6008 queries and enqueued 2000 jobs.
    #
    # Constant IN N, not against a literal, for the reason the port's stat_all contract gives: a
    # literal would pin one backend's query shape into a test all three legs run.
    test "the flat view's cost does not grow with the number of rows" do
      with_backfill_limit(2) do
        6.times { |i| stl_with_content("small#{i}.stl") }
        few = count_queries { get files_path(ext: "stl") }

        12.times { |i| stl_with_content("bulk#{i}.stl") }
        many = count_queries { get files_path(ext: "stl") }

        assert_operator listed_names.size, :>=, 21, "the second page must really be bigger"
        assert_equal few, many, "the flat view's query count grew with the number of rows"
      end
    end

    # THE BACKFILL IS A BUDGET, AND IT STILL DRAINS. Capping it would be no good if the backlog
    # then never cleared, so both halves are asserted: one load enqueues at most the cap, and the
    # NEXT load takes the next slice rather than re-offering the same one.
    test "one page load enqueues at most BACKFILL_LIMIT thumbnails, and the backlog still drains" do
      with_backfill_limit(3) do
        10.times { |i| stl_with_content("m#{i}.stl") }

        assert_difference -> { @user.maker_previews.count }, 3 do
          get files_path(ext: "stl")
        end
        assert_difference -> { @user.maker_previews.count }, 3 do
          get files_path(ext: "stl")
        end
      end
    end

    test "the view toggle keeps the filter" do
      get files_path(ext: "stl")
      assert_select ".view-toggle a[href=?]", files_path(ext: "stl", view: "grid")
      assert_select ".view-toggle a[href=?]", files_path(ext: "stl", view: "list")
    end

    # ONE CONTROL NOW, so the bound has one place to be honoured — where the chips and the free-text
    # field beside them were two controls answering one condition, and shipped answering it
    # differently (the field accepted a ninth type and silently dropped it, two inches from a chip
    # correctly rendered inert for that exact reason).
    #
    # BOTH HALVES MATTER. Asserting only "disabled when full" passes for a control that is ALWAYS
    # disabled, so the not-full case is asserted too; and the sentence is read from `ext_limit_title`
    # rather than retyped, so a literal here cannot drift from the string the app shows.
    test "with the type limit reached, the dropdown goes inert rather than dropping a ninth type" do
      full = %w[stl 3mf obj step stp svg dxf lbrn2]
      assert_equal FilesController::MAX_EXTS, full.size
      title = Object.new.extend(FilesHelper).ext_limit_title

      get files_path(ext: full.join(","))
      assert_select ".ext-active a.chip.active", count: 8
      assert_select ".ext-picker select[disabled]"
      assert_select ".ext-picker select[title=?]", title
      # Turning one off is still offered, or the row would be a dead end.
      assert_select ".ext-active a.chip.active[href=?]", files_path(ext: (full - [ "stl" ]).join(","))

      # One slot free: a working control again. `disabled` is a BOOLEAN attribute, so the obvious
      # `disabled="<%= !slots_left %>"` spelling renders `disabled="false"` and disables it forever
      # — this is the assertion that catches that.
      get files_path(ext: full.take(7).join(","))
      assert_select ".ext-picker select"
      assert_select ".ext-picker select[disabled]", count: 0
    end

    # A ninth extension arriving in a HAND-EDITED URL is still dropped silently, deliberately: that
    # is EXT_RE's standing rule for everything arriving in a query string ("anything else is
    # dropped, not rejected"). The bound above is about a CONTROL; this is about input.
    test "a ninth extension in the URL is dropped without an error page" do
      nine = %w[stl 3mf obj step stp svg dxf lbrn2 pdf]
      get files_path(ext: nine.join(","))
      assert_response :success
      assert_select ".ext-active a.chip.active", count: FilesController::MAX_EXTS
    end

    # A SYMLINK IS NOT A FILE TYPE, and the flat filter's `kind: "file"` says so deliberately —
    # spec §6.3 argues only the DIRECTORY case, so this is the sentence that was missing. The
    # divergence from the folder view is the point of the test: the folder view lists the symlink
    # (it is really there), the type view does not (it is not an STL — its content is a path).
    test "the type filter excludes symlinks, which the folder view still lists" do
      @user.nodes.create!(node_id: "n-alias", name: "alias.stl", kind: "symlink",
                          mtime: 1_000_000_000, size: 1)

      get files_path
      assert_includes listed_names, "alias.stl"

      get files_path(ext: "stl")
      assert_equal %w[deep.stl root.stl tiny.stl], listed_names.sort
      assert_not_includes listed_names, "alias.stl"
    end

    private

    # The SQL a block really issues. SCHEMA/TRANSACTION and PRAGMA are excluded exactly as
    # attach_model_bundle_test.rb and test/services/file_layer/adapter_contract.rb exclude them:
    # they are cost by accident of being first, not cost of the code under test.
    def captured_sql
      seen = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
          seen << payload[:sql]
        end
      end
      yield
      seen
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    def count_queries(&) = captured_sql(&).size

    # Swap one of FilesController's bounds for the duration of a block. Seeding 2001 files to reach
    # FLAT_LIMIT, or 101 to reach BACKFILL_LIMIT, would cost more than the whole rest of this file;
    # shrinking the constant is the cheap honest way to reach the branch.
    #
    # SAFE HERE BECAUSE THE SUITE PARALLELISES BY PROCESS, NOT BY THREAD (test_helper's
    # `parallelize(workers: ...)` forks — the comment there about per-worker databases is the
    # giveaway), and Minitest runs the tests inside one worker serially: nothing calls
    # `parallelize_me!`. A threaded runner would make this a race that reorders another test's
    # results, so if that ever changes, this helper is the thing to revisit.
    def with_const(owner, name, value)
      original = owner.const_get(name)
      owner.send(:remove_const, name)
      owner.const_set(name, value)
      yield
    ensure
      owner.send(:remove_const, name)
      owner.const_set(name, original)
    end

    def with_flat_limit(limit, &) = with_const(FilesController, :FLAT_LIMIT, limit, &)

    # The cap lives on `Maker::Previews::ThumbnailMap`, not this controller — the 3D models and
    # Projects pages back onto the same class and get the same budget. Both tests below still
    # drive a real `GET /files`, which is the point: they measure the PAGE, not the method.
    def with_backfill_limit(limit, &)
      with_const(Maker::Previews::ThumbnailMap, :BACKFILL_LIMIT, limit, &)
    end

    # A file shaped like one in a real library: a content token, so stat_all reports content and
    # the thumbnail paths actually run. Bare `nodes` rows have none, which is how the first version
    # of the query-count test below managed to pass while the page it measured ran 6008 queries.
    def stl_with_content(name, parent = nil)
      @user.nodes.create!(node_id: "c-#{name}", name:, kind: "file", parent_node_id: parent,
                          mtime: 1_000_000_000, size: 5,
                          content_hash: "h-#{name}", current_version_id: "v-#{name}")
    end
  end
end
