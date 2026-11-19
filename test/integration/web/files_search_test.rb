require "test_helper"

module Web
  # The library search (spec §9): ?q= is a flat, whole-library, case-insensitive name match that
  # composes with the type filter, survives every link the page builds, is bounded and escaped,
  # and says what it searched for when nothing matches. Nodes are created directly, as
  # files_type_filter_test.rb does — a listing test is about the query, not the bytes.
  class FilesSearchTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "q-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir")
      @user.nodes.create!(node_id: "dir-sub", name: "Lamp parts", kind: "dir", parent_node_id: "dir-cad")
      file("root.stl", nil)
      file("Lamp-Base.stl", "dir-cad")
      file("lamp shade.3mf", "dir-cad")
      file("notes.pdf", "dir-sub")
      file("100%-done.txt", nil)
    end

    def file(name, parent)
      @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file",
                          parent_node_id: parent, mtime: 1_000_000_000, size: 5)
    end

    def listed_names
      css_select("table.files tbody tr td:first-child").map do |cell|
        (cell.at_css(".file-name") || cell.at_css("a")).text.strip
      end
    end

    test "a search matches names case-insensitively across the whole library, folders included" do
      get files_path(q: "lamp")
      assert_response :success
      assert_equal [ "Lamp parts", "Lamp-Base.stl", "lamp shade.3mf" ], listed_names.sort
    end

    test "a search composes with the type filter" do
      get files_path(q: "lamp", ext: "stl")
      assert_equal [ "Lamp-Base.stl" ], listed_names
    end

    test "a search is flat: the folder is ignored and the breadcrumb says so" do
      get files_path(folder: "dir-sub", q: "stl")
      assert_equal [ "Lamp-Base.stl", "root.stl" ], listed_names.sort
      assert_select "header.topbar nav.breadcrumb [aria-current='page']", text: /Search “stl”/
      assert_select "nav.breadcrumb a[href=?]", files_path(folder: "dir-sub"), count: 0
      # THE FILES PAGE'S OWN SEARCH BOX, not the top bar's -- the top bar now posts to
      # SearchController (stage 2, S2-5) and no longer echoes this page's own @q (shell_layout_test.rb
      # pins the top bar's own contract; _topbar.html.erb explains why it must not reuse this ivar).
      assert_select ".files-toolbar form.files-search input[name='q'][value='stl']"
    end

    test "the search rides along on the view toggle, the type picker and the sort headers" do
      get files_path(q: "lamp")
      assert_select ".view-toggle a[href=?]", files_path(q: "lamp", view: "grid")
      assert_select "form.ext-picker input[type='hidden'][name='q'][value='lamp']"
      assert_select "th a[href=?]", files_path(q: "lamp", sort: "name", dir: "desc")
      get files_path(q: "lamp", ext: "stl")
      assert_select ".ext-active a.chip[href=?]", files_path(q: "lamp")
      assert_select ".ext-active a.clear-filter[href=?]", files_path(q: "lamp")
    end

    test "LIKE metacharacters are literal, not wildcards" do
      get files_path(q: "%")
      assert_equal [ "100%-done.txt" ], listed_names
      get files_path(q: "_")
      assert_equal [], listed_names
    end

    test "a blank query is no query, and a long one is bounded" do
      get files_path(q: "   ")
      assert_select "nav.breadcrumb [aria-current='page']", count: 0
      assert_equal %w[100%-done.txt cad root.stl], listed_names.sort
      get files_path(q: "a" * 100)
      assert_select ".files-toolbar form.files-search input[name='q'][value=?]", "a" * 80
    end

    # STAGE 4, S4-2, STORY 4.8 — AND THIS IS THE DOOR WHERE THE DIRECTORY HALF OF THE RULE CAN
    # ACTUALLY FAIL. The flat `?q=` view lists FOLDERS as well as files (the first test in this
    # file says so in its name), so a `node_modules` row genuinely reaches this page and is kept
    # off it by Node.visible_entries and nothing else. The sitewide SearchController filters
    # `kind: "file"` on top of the same scope, so a build DIRECTORY is excluded there twice over
    # and that assertion could not go red — which is why it lives here.
    #
    # THE ESCAPING RIDES ALONG FOR FREE: `node_modules` and `__pycache__` are full of LIKE
    # metacharacters, so these queries only find their rows because sanitize_sql_like + ESCAPE is
    # doing its job (the "LIKE metacharacters are literal" test above owns that rule).
    test "a build-output directory is not a search result, while build/ still is" do
      @user.nodes.create!(node_id: "dir-nm", name: "node_modules", kind: "dir")
      @user.nodes.create!(node_id: "dir-pyc", name: "__pycache__", kind: "dir")
      @user.nodes.create!(node_id: "dir-build", name: "build", kind: "dir")

      get files_path(q: "node_modules")
      assert_equal [], listed_names
      get files_path(q: "__pycache__")
      assert_equal [], listed_names

      # `build/` IS NOT BUILD OUTPUT (amendment 1) — a maker's own folder, kept.
      get files_path(q: "build")
      assert_equal [ "build" ], listed_names

      # A DISPLAY RULE, GATED LIKE A DOT-DIR: the row still exists and "Show hidden" is the way in.
      get files_path(q: "node_modules", hidden: "1")
      assert_equal [ "node_modules" ], listed_names
    end

    # THE RULE ASKS ABOUT DIRECTORIES. A FILE named `node_modules` is somebody's file and lists.
    # Both rows are created so the assertion distinguishes "the file survived" from "nothing
    # matched at all": exactly one row comes back, and dropping the `kind` clause makes it zero.
    test "a FILE named node_modules is still a search result" do
      @user.nodes.create!(node_id: "dir-nm2", name: "node_modules", kind: "dir")
      file("node_modules", nil)

      get files_path(q: "node_modules")
      assert_equal [ "node_modules" ], listed_names
    end

    test "an empty result says what was searched" do
      get files_path(q: "zzz")
      assert_select ".empty", text: /No files match “zzz”/
      get files_path(q: "zzz", ext: "stl")
      assert_select ".empty", text: /No files match “zzz” among \.stl/
    end
  end
end
