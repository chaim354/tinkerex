require "test_helper"

module Web
  # The flat by-extension view: "show me every .stl in my library, wherever it lives."
  # BACKEND-NEUTRAL by construction — it filters `nodes.name`, which all three adapters populate.
  class FilesTypeFilterTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "ext-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }

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

    # Same reader as files_sort_test.rb — a thumbnailable file's link contains the thumbnail cell
    # as well as the name, so read the .file-name span when there is one.
    def listed_names
      css_select("table.files tbody tr td:first-child").map do |cell|
        (cell.at_css(".file-name") || cell.at_css("a")).text.strip.delete_prefix("📁 ")
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

    # THE ONE ASSERTION HERE THAT READS THE SQL, AND THE REASON IS THAT NO LEG CAN SEE THIS.
    # SQLite's LIKE is ASCII-case-insensitive and Postgres' is not, so `name LIKE '%.stl'` finds
    # SHOUTY.STL on self-host and silently misses it on managed — the case-insensitivity test
    # directly above stays green on all three legs with LOWER() deleted, because all three run
    # SQLite. This is the same class of gap FilesController#show records for its two sort
    # collations; the difference is that here there IS something to pin, so pin it.
    test "the match lowercases the column, which only Postgres would otherwise reveal" do
      sql = captured_sql { get files_path(ext: "stl") }
      assert(sql.any? { |q| q.match?(/LOWER\(name\)\s+LIKE/i) },
             "the extension match must lowercase `name`, or it is case-sensitive on Postgres")
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

    # LIKE'S TWO WILDCARDS, AND THE PROBE IS RUN FROM AN EMPTY FOLDER ON PURPOSE. `%` and `_` are
    # stopped by TWO layers — EXT_RE drops them, and sanitize_sql_like would escape them if the
    # whitelist were ever loosened to \w — and a test that asserts "we fell back to folder view"
    # only pins the OUTER one: loosen EXT_RE and it goes red even though the wildcard is still
    # neutralised, while a genuinely widened match would slip past unremarked at the root, where
    # folder view lists root.stl anyway. Browsing an EMPTY folder makes the fallback render
    # nothing, so any row at all means the wildcard reached the query.
    test "a LIKE metacharacter cannot widen the match" do
      @user.nodes.create!(node_id: "dir-empty", name: "empty", kind: "dir")

      get files_path(ext: "s%l")
      assert_response :success
      assert_includes listed_names, "cad", "an escaped-away filter must fall back to folder view"

      get files_path(folder: "dir-empty", ext: "s%l")
      assert_empty listed_names, "'%' reached the LIKE and matched .stl files"
    end

    test "an underscore cannot widen the match either" do
      # '_' is LIKE's single-character wildcard and, unlike '%', it looks innocuous enough to
      # survive a whitelist someone loosens to \w — at which point `%.st_` matches every .stl.
      @user.nodes.create!(node_id: "dir-empty", name: "empty", kind: "dir")

      get files_path(ext: "st_")
      assert_response :success
      assert_includes listed_names, "cad", "an underscore must not become a wildcard"

      get files_path(folder: "dir-empty", ext: "st_")
      assert_empty listed_names, "'_' reached the LIKE and matched .stl files"
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

    # A corrupt parent chain must not take the page down. `folder_paths_for` walks parents to build
    # "cad/sub", and folder_crumbs already carries the same guard for the same reason.
    test "a cycle in the parent chain does not blow the stack" do
      @user.nodes.find_by!(node_id: "dir-cad").update!(parent_node_id: "dir-sub")
      get files_path(ext: "stl")
      assert_response :success
      assert_includes listed_names, "tiny.stl"
    end

    # A chip whose extension the controller then drops is a control that looks live and does
    # nothing: it renders, it links, and clicking it silently returns the ordinary folder view.
    # This is what keeps FilesHelper::EXT_FAMILIES and FilesController::EXT_RE from drifting.
    test "every chip in the row is an extension the controller actually accepts" do
      get files_path
      hrefs = css_select(".ext-filter a.chip").map { |a| a["href"] }
      assert_equal FilesHelper::EXT_FAMILIES.values.flatten.size, hrefs.size

      hrefs.each do |href|
        get href
        # The clicked chip comes back ACTIVE — the one signal that works whether or not the
        # library happens to hold a file of that type.
        assert_select ".ext-filter a.chip.active", { count: 1 },
                      "#{href} rendered a chip the filter then ignored"
      end
    end

    test "chips mark the active extensions and toggle them off" do
      get files_path(ext: "stl")
      assert_select ".ext-filter a.chip.active", text: /stl/
      # The state is announced, not just coloured — and on a LINK that means aria-current, which
      # is valid there, rather than aria-pressed, which is not.
      assert_select ".ext-filter a.chip[aria-current=true]", text: /stl/, count: 1
      assert_select ".ext-filter a.chip[aria-current]", count: 1
      # Clicking the active chip removes it.
      assert_select ".ext-filter a.chip.active[href=?]", files_path(sort: "name", dir: "asc")
    end

    test "an inactive chip adds itself to the active set rather than replacing it" do
      get files_path(ext: "stl")
      assert_select ".ext-filter a.chip[href=?]", files_path(ext: "stl,3mf", sort: "name", dir: "asc")
    end

    test "the free-text field adds an extension the chip list doesn't know" do
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

    # Swap FLAT_LIMIT for the duration of a block. Seeding 2001 files to exercise the bound would
    # cost more than the whole rest of this file; swapping the constant is the cheap honest way to
    # reach the branch.
    #
    # SAFE HERE BECAUSE THE SUITE PARALLELISES BY PROCESS, NOT BY THREAD (test_helper's
    # `parallelize(workers: ...)` forks — the comment there about per-worker databases is the
    # giveaway), and Minitest runs the tests inside one worker serially: nothing calls
    # `parallelize_me!`. A threaded runner would make this a race that reorders another test's
    # results, so if that ever changes, this helper is the thing to revisit.
    def with_flat_limit(limit)
      original = FilesController::FLAT_LIMIT
      FilesController.send(:remove_const, :FLAT_LIMIT)
      FilesController.const_set(:FLAT_LIMIT, limit)
      yield
    ensure
      FilesController.send(:remove_const, :FLAT_LIMIT)
      FilesController.const_set(:FLAT_LIMIT, original)
    end
  end
end
