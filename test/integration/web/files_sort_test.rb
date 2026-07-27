require "test_helper"

module Web
  # Column sorting in the file browser. DELIBERATELY NOT PINNED TO A BACKEND: name and kind come
  # from `nodes`, and mtime comes from stat_all, which answers it from `nodes` on all three
  # adapters (Chunk/Share/S3#file_info all read `node.mtime`) — so bare seeded rows prove this is
  # backend-neutral. Must stay green on `bin/rails test`, `LIBRARY_BACKEND=share` and
  # `LIBRARY_BACKEND=s3`.
  class FilesSortTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "sort-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }

      # Names, extensions and mtimes deliberately disagree, so each sort key produces a DIFFERENT
      # order and no assertion can pass by accident.
      #   name A→Z:   alpha.stl, beta.3mf, gamma.pdf
      #   type A→Z:   beta.3mf (3mf), gamma.pdf (pdf), alpha.stl (stl)
      #   modified ↑: gamma.pdf, alpha.stl, beta.3mf
      file("alpha.stl", 2_000)
      file("beta.3mf",  3_000)
      file("gamma.pdf", 1_000)
      @user.nodes.create!(node_id: "d-1", name: "zeta-folder", kind: "dir")
    end

    def file(name, mtime_seconds)
      @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file",
                          mtime: mtime_seconds * 1_000_000_000, size: 10)
    end

    # The rendered order of the file names, in document order.
    #
    # PREFER .file-name, FALL BACK TO THE LINK. A file the app can thumbnail renders its name in a
    # `<span class="file-name">` inside a link that ALSO contains the thumbnail cell — so reading
    # the `<a>`'s text would return "STL alpha.stl" for those rows and "gamma.pdf" for the rest,
    # and every ordering assertion below would be comparing against markup instead of names.
    def listed_names
      css_select("table.files tbody tr td:first-child").map do |cell|
        (cell.at_css(".file-name") || cell.at_css("a")).text.strip.delete_prefix("📁 ")
      end
    end

    test "defaults to name ascending" do
      get files_path
      assert_equal %w[alpha.stl beta.3mf gamma.pdf zeta-folder], listed_names
    end

    test "name descending reverses the files but keeps folders grouped last" do
      get files_path(sort: "name", dir: "desc")
      assert_equal %w[gamma.pdf beta.3mf alpha.stl zeta-folder], listed_names
    end

    test "sorts by type (extension), not by name" do
      get files_path(sort: "type", dir: "asc")
      assert_equal %w[beta.3mf gamma.pdf alpha.stl zeta-folder], listed_names
    end

    test "sorts by modified, and mtime is read as NANOSECONDS" do
      get files_path(sort: "modified", dir: "asc")
      assert_equal %w[gamma.pdf alpha.stl beta.3mf zeta-folder], listed_names

      get files_path(sort: "modified", dir: "desc")
      assert_equal %w[beta.3mf alpha.stl gamma.pdf zeta-folder], listed_names
    end

    # THE HEADER AND THE CELL UNDER IT MUST NAME THE SAME THING. This column used to be headed
    # "Kind" and render `node.kind` — "file" on every file row. Making it the sortable "Type"
    # header without changing the cell would leave a column whose every visible value is the same
    # word while the rows around it reorder: the sort would read as broken, and the header would
    # be lying about what it sorts by (FilesController#sort_key's "type" branch is the extension).
    test "the Type column shows the extension the Type header sorts by" do
      # An extension-less file is the case with nothing to show; it must read as the same em-dash
      # every other empty cell in this table uses, not as a blank the eye reads as a broken cell.
      @user.nodes.create!(node_id: "n-make", name: "Makefile", kind: "file",
                          mtime: 4_000_000_000_000, size: 1)
      get files_path

      assert_select "table.files thead th", text: /\AType/
      assert_select "table.files thead th", text: /\AKind/, count: 0
      types = css_select("table.files tbody tr").map { |row| row.css("td")[1].text.strip }
      # alpha.stl, beta.3mf, gamma.pdf, Makefile (no extension), zeta-folder — name order.
      assert_equal %w[STL 3MF PDF — Folder], types
    end

    # RUBY'S sort_by IS NOT STABLE, and this is the fixture that proves the index tiebreak in
    # FilesController#sort_nodes is load-bearing rather than decorative. Ties alone are not enough
    # to show it (an all-equal array comes back in order), so this is a REALISTIC shape: a folder
    # of 18 files whose extensions cycle through three values. Drop the `, i` from the first
    # sort_by and the groups come back internally scrambled — f16 before f01 — which on a real
    # library means the list reshuffles under the user on every page load.
    #
    # The order asserted is the one the tiebreak preserves: the input order, which is the query's
    # `name: :asc`. So within one extension, files stay alphabetical.
    #
    # BOTH PASSES ARE COVERED, which is why there is a directory in here too. A directory has no
    # extension, so the type sort places it FIRST, and the grouping pass then has to move it to
    # the end without disturbing the eighteen files it steps over — an all-but-one-equal array,
    # which is the shape that makes the SECOND sort_by's tiebreak load-bearing as well.
    test "files sharing a sort key keep a stable, deterministic order" do
      @user.nodes.create!(node_id: "d-tie", name: "many", kind: "dir")
      @user.nodes.create!(node_id: "d-tie-sub", name: "nested", kind: "dir",
                          parent_node_id: "d-tie")
      exts = %w[stl 3mf pdf]
      names = (0...18).map { |i| format("f%02d.%s", i, exts[i % 3]) }
      names.each_with_index do |name, i|
        @user.nodes.create!(node_id: "n-tie-#{i}", name:, kind: "file",
                            parent_node_id: "d-tie", mtime: 1, size: 1)
      end

      get files_path(folder: "d-tie", sort: "type", dir: "asc")
      assert_equal names.sort_by { |n| [ File.extname(n), n ] } + %w[nested], listed_names
    end

    test "the choice persists in a cookie across a request with no params" do
      get files_path(sort: "type", dir: "asc")
      get files_path
      assert_equal %w[beta.3mf gamma.pdf alpha.stl zeta-folder], listed_names
    end

    # THE ORDER ALONE CANNOT PROVE THE WHITELIST, which is why both of these also read the header.
    # sort_key's `else` branch is the name sort, so an unrecognised key falls through to the same
    # ORDER the default produces whether or not resolve_sort ever whitelisted it — an order-only
    # assertion here would stay green with SORTS deleted. What the whitelist alone decides is the
    # value @sort carries into the view: junk marks NO column active, the default marks Name.
    test "junk sort and dir params fall back to the default" do
      get files_path(sort: "'; DROP TABLE nodes; --", dir: "sideways")
      assert_response :success
      assert_equal %w[alpha.stl beta.3mf gamma.pdf zeta-folder], listed_names
      assert_select "th[aria-sort=ascending]", text: /Name/

      # A VALID key with a junk direction reaches a DIFFERENT branch (DIRS, not SORTS), and the
      # order cannot see it either: an unrecognised direction does not reverse, so it looks exactly
      # like ascending. What it changes is the state the column reports and the link it offers —
      # an unwhitelisted "sideways" makes the header announce "descending" and offer to sort
      # ascending, i.e. a toggle that no longer toggles.
      get files_path(sort: "type", dir: "sideways")
      assert_equal %w[beta.3mf gamma.pdf alpha.stl zeta-folder], listed_names
      assert_select "th[aria-sort=ascending]", text: /Type/
      assert_select "th a[href=?]", files_path(sort: "type", dir: "desc")
    end

    test "a tampered cookie falls back to the default" do
      cookies[:files_sort] = "size:ascending"
      get files_path
      assert_equal %w[alpha.stl beta.3mf gamma.pdf zeta-folder], listed_names
      assert_select "th[aria-sort=ascending]", text: /Name/
    end

    # A junk `?sort=` must not be REMEMBERED either: persisting it would leave every later page
    # load carrying a key the whitelist then rejects again, and no column ever marked active.
    test "junk is not written to the cookie" do
      get files_path(sort: "type", dir: "desc")
      get files_path(sort: "nonsense")
      get files_path
      assert_equal %w[alpha.stl gamma.pdf beta.3mf zeta-folder], listed_names
      assert_select "th[aria-sort=descending]", text: /Type/
    end

    test "the headers are links that toggle direction and carry aria-sort" do
      get files_path(sort: "name", dir: "asc")
      assert_select "th[aria-sort=ascending]", text: /Name/
      # Only the ACTIVE column announces a sort; the rest must say "none", or a screen reader is
      # told the table is sorted three ways at once.
      assert_select "th[aria-sort=ascending]", count: 1
      assert_select "th[aria-sort=none]", text: /Type/
      # Clicking the ACTIVE column flips it; an inactive one starts ascending.
      assert_select "th a[href=?]", files_path(sort: "name", dir: "desc")
      assert_select "th a[href=?]", files_path(sort: "type", dir: "asc")
    end

    test "sorting inside a folder keeps the folder" do
      dir = @user.nodes.create!(node_id: "d-2", name: "cad", kind: "dir")
      @user.nodes.create!(node_id: "n-in", name: "inner.stl", kind: "file",
                          parent_node_id: dir.node_id, mtime: 1)

      get files_path(folder: "d-2", sort: "type", dir: "asc")
      assert_equal %w[inner.stl], listed_names
      assert_select "th a[href=?]", files_path(folder: "d-2", sort: "name", dir: "asc")
    end

    test "the view toggle keeps the folder and the sort survives it in the cookie" do
      @user.nodes.create!(node_id: "d-3", name: "laser", kind: "dir")
      get files_path(folder: "d-3", sort: "type", dir: "desc")
      # Switching list<->grid must not dump the user back at the library root.
      assert_select ".view-toggle a[href=?]", files_path(folder: "d-3", view: "grid")
    end

    test "grid view offers the same sort as a select" do
      get files_path(view: "grid", sort: "type", dir: "desc")
      # `[selected]`, NOT `[selected=selected]`: Rails 8 parses the response with Nokogiri's HTML5
      # parser, which gives a bare boolean attribute the value "" — so the value-matching form
      # never matches, whatever the markup says. (The HTML4 parser normalised it to "selected",
      # which is why the value form looks like it should work.)
      assert_select "form.sort-form select[name=sort] option[value=type][selected]"
      assert_select "form.sort-form select[name=dir] option[value=desc][selected]"
      # And the choice the user did NOT make is not also marked.
      assert_select "form.sort-form select[name=sort] option[selected]", count: 1
    end

    test "the grid sort form carries the folder, so submitting it does not leave the folder" do
      @user.nodes.create!(node_id: "d-4", name: "prints", kind: "dir")
      @user.nodes.create!(node_id: "n-p", name: "p.stl", kind: "file",
                          parent_node_id: "d-4", mtime: 1, size: 1)
      get files_path(folder: "d-4", view: "grid")
      assert_select "form.sort-form input[type=hidden][name=folder][value=d-4]"
    end
  end
end
