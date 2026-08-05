require "test_helper"

module Web
  # Folder paging. NOT PINNED TO A BACKEND, like files_sort_test.rb and for the same reason: names
  # and kinds come from `nodes`, which all three adapters populate, so bare seeded rows prove this
  # is backend-neutral. Must stay green on chunk, share and s3.
  #
  # WHY THE FOLDER VIEW NEEDED A BOUND AT ALL: flat mode was capped at FLAT_LIMIT on the reasoning
  # that "a folder is self-limiting and a whole-library view is not" — true of a tidy library,
  # false of a NAS directory with ten thousand children. Measured at 2000 children the page was
  # 225–307 ms of which 175–278 ms was ERB, on ~0 ms of database: the cost is per-ROW rendering, so
  # the only fix is rendering fewer rows.
  class FilesPaginationTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    PER = FilesController::FOLDER_PAGE

    setup do
      @user = User.create!(email: "pag-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    def file(name)
      @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file", mtime: 1, size: 10)
    end

    def listed_names
      css_select("table.files tbody tr td:first-child").map do |cell|
        (cell.at_css(".file-name") || cell.at_css("a")).text.strip.delete_prefix("📁 ")
      end
    end

    # A folder small enough to fit shows no pager at all — this bounds huge directories, it must
    # not put a widget on every ordinary page.
    test "a folder that fits on one page renders no pager" do
      3.times { |i| file("f#{i}.stl") }

      get files_path
      assert_response :success
      assert_equal 3, listed_names.size
      assert_select "nav.pager", count: 0
    end

    test "a folder larger than a page renders one page plus a pager" do
      (PER + 10).times { |i| file(format("f%04d.stl", i)) }

      get files_path
      assert_response :success
      assert_equal PER, listed_names.size, "the whole point is that fewer rows are rendered"
      assert_select "nav.pager"
      assert_select ".pager-next"
      assert_select ".pager-prev", { count: 0 }, "there is no page before the first"
    end

    # THE ASSERTION THE WHOLE FEATURE RESTS ON. Paging is only correct if the SQL ORDER BY that
    # SELECTS the rows is the same order the page DISPLAYS — otherwise a row falls between two
    # pages or appears on both, and the user simply never sees a file that is right there.
    #
    # THE NAMES MUST MAKE BYTE ORDER AND CASE-INSENSITIVE ORDER DISAGREE, and getting that wrong is
    # how the first version of this test passed against a deliberately broken implementation.
    #
    # SQL's `name ASC` is byte-ordered — every uppercase letter sorts before every lowercase one —
    # while the Ruby comparator this replaced downcases. `Alpha…`/`beta…` does NOT expose that:
    # 'A' < 'b' in bytes and 'a' < 'b' downcased, so both orders agree and a missing LOWER() sails
    # through. `Zeta…`/`apple…` is the pair that conflicts: bytes put every Zeta first ('Z' is 90,
    # 'a' is 97), downcasing puts every apple first. Under a byte-ordered LIMIT the page boundary
    # falls in a completely different place than the display order, which is exactly how a file
    # ends up on no page at all — mutation-checked by removing LOWER() and watching this go red.
    test "every child appears exactly once across all pages, with mixed-case names" do
      expected = []
      (PER + 40).times do |i|
        name = i.even? ? format("Zeta%04d.stl", i) : format("apple%04d.stl", i)
        file(name)
        expected << name
      end

      seen = []
      pages = ((PER + 40) / PER.to_f).ceil
      (1..pages).each do |page|
        get files_path(page: page)
        assert_response :success
        seen.concat(listed_names)
      end

      assert_equal expected.size, seen.size, "no row may be dropped or repeated across pages"
      assert_equal expected.sort_by(&:downcase), seen, "the pages must join into ONE sorted list"
      assert_equal seen.uniq, seen, "a row appearing on two pages is the other half of the bug"
    end

    # Directories sort LAST within the listing (sort_nodes ended `files + dirs`), and the SQL order
    # has to reproduce that or paging silently reorders the folder as a side effect of bounding it.
    # EXACTLY PER files, so the two directories fall entirely onto page 2. Their names sort BEFORE
    # every file name, so if the SQL order forgot the dirs-last rule they would be the first two
    # rows of page 1 — which is both the assertion and the reason the fixture is shaped this way.
    test "directories still sort after files, across a page boundary" do
      PER.times { |i| file(format("f%04d.stl", i)) }
      @user.nodes.create!(node_id: "d-1", name: "aaa-folder", kind: "dir")
      @user.nodes.create!(node_id: "d-2", name: "bbb-folder", kind: "dir")

      get files_path
      names = listed_names
      assert_equal PER, names.size
      assert_equal [], names & [ "aaa-folder", "bbb-folder" ],
                   "directories must not be pulled onto page 1 by their names"

      get files_path(page: 2)
      assert_equal [ "aaa-folder", "bbb-folder" ], listed_names
    end

    # An out-of-range page must land on a real page. A blank page is how a paged list gets reported
    # as "my files vanished".
    test "an out-of-range or garbage page number is clamped, never blank" do
      (PER + 5).times { |i| file(format("f%04d.stl", i)) }

      get files_path(page: 999)
      assert_response :success
      assert_equal 5, listed_names.size, "clamped to the LAST page, not an empty one"

      get files_path(page: 0)
      assert_equal PER, listed_names.size, "clamped up to the first page"

      get files_path(page: "not-a-number")
      assert_equal PER, listed_names.size
    end

    # The pager links must carry sort and dir. Those are omitted from in-page links elsewhere
    # because they are cookie-persisted, but "page 2" only means something under the ordering that
    # produced it — a link that dropped them could hand the next request a different page 2.
    test "pager links carry the sort that produced the page" do
      (PER + 5).times { |i| file(format("f%04d.stl", i)) }

      get files_path(sort: "name", dir: "desc")
      assert_response :success
      assert_select ".pager-next" do |links|
        href = links.first["href"]
        assert_includes href, "sort=name"
        assert_includes href, "dir=desc"
        assert_includes href, "page=2"
      end
    end

    # The stated limit, asserted rather than left implicit: `type` and `modified` cannot be
    # expressed as a SQL ORDER BY over `nodes` (one is computed with a symlink special case, the
    # other reads the PORT's mtime), so those sorts keep the full-folder load. If someone later
    # makes them pageable, this test should be updated deliberately — not discovered as a surprise.
    test "the type and modified sorts are NOT paged" do
      (PER + 5).times { |i| file(format("f%04d.stl", i)) }

      %w[type modified].each do |sort|
        get files_path(sort:, dir: "asc")
        assert_response :success
        assert_equal PER + 5, listed_names.size, "#{sort} still loads the whole folder"
        assert_select "nav.pager", count: 0
      end
    end
  end
end
