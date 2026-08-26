require "test_helper"

module Web
  # The `.git` marker is INDEXED ON PURPOSE and DISPLAYED NEVER — Node.outside_repo_metadata, in
  # both of FilesController#index's listing scopes.
  #
  # BOTH SCOPES IN ONE FILE, BECAUSE ONE RULE WITH TWO HOMES IS THE SHAPE §14a FORBIDS. #index has
  # two independent scopes over the same catalog — the flat by-extension one and the folder one —
  # and a fix applied to only one is one condition with two answers. Splitting these two tests
  # across files_type_filter_test.rb and folder_nav_test.rb would put the rule where a reader can
  # delete half of it without meeting the other half.
  #
  # DELIBERATELY NOT PINNED TO A BACKEND, for the reason folder_nav_test.rb and
  # files_type_filter_test.rb give: everything here reads `nodes.name`/`parent_node_id`, and
  # stat_all answers from `nodes` alone on all three adapters, so bare seeded rows on the ambient
  # LIBRARY_BACKEND are what prove the rule is backend-neutral. Must stay green on
  # `bin/rails test`, `LIBRARY_BACKEND=share` and `LIBRARY_BACKEND=s3`.
  class FilesGitMarkerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "git-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }

      #   /firmware/                 (dir-firmware)
      #   /firmware/.git             <- THE MARKER: a directory, what Library::Scanner indexes
      #   /firmware/.gitignore       <- an ORDINARY file whose name merely starts with ".git"
      #   /firmware/main.py          <- an ordinary file, so the folder page is not empty
      #   /.git                      <- a `gitdir:` POINTER FILE (submodule / linked worktree),
      #                                 which Library::RepoMetadata's header records as indexed
      #                                 like any other file — and the only way a row named `.git`
      #                                 can reach the flat view, which filters kind: "file"
      #   /firmware.git              <- a bare-repo archive: an ordinary file ENDING in ".git"
      @user.nodes.create!(node_id: "dir-firmware", name: "firmware", kind: "dir")
      @marker = dir(".git", "dir-firmware")
      file(".gitignore", "dir-firmware")
      file("main.py", "dir-firmware")
      @pointer = file(".git", nil, id: "n-pointer")
      file("firmware.git", nil)
    end

    def dir(name, parent, id: "d-#{SecureRandom.hex(4)}")
      @user.nodes.create!(node_id: id, name:, kind: "dir", parent_node_id: parent)
    end

    def file(name, parent, id: "n-#{SecureRandom.hex(4)}")
      @user.nodes.create!(node_id: id, name:, kind: "file", parent_node_id: parent,
                          mtime: 1_000_000_000, size: 5)
    end

    # Same reader as files_sort_test.rb and files_type_filter_test.rb — a thumbnailable file's
    # link contains the thumbnail cell as well as the name, so read the .file-name span when there
    # is one, and strip the folder glyph a directory row carries.
    def listed_names
      css_select("table.files tbody tr td:first-child").map do |cell|
        (cell.at_css(".file-name") || cell.at_css("a")).text.strip.delete_prefix("📁 ")
      end
    end

    # THE FOLDER SCOPE (FilesController#index's `else` branch).
    test "a folder listing hides the .git marker and keeps it in the catalog" do
      get files_path(folder: "dir-firmware")

      assert_response :success
      assert_not_includes listed_names, ".git"
      assert Node.exists?(@marker.id), "hidden from the UI, still in the catalog"
    end

    # THE `.git` PREFIX IS NOT THE RULE — the rule is the exact name. `.gitignore` and
    # `.gitattributes` are ordinary files a repo's root is full of, and a `LIKE '.git%'` spelling
    # of the marker scope would take every one of them out of the listing PERMANENTLY, with no
    # toggle able to bring them back. This assertion is what makes that mutation red, which is why
    # the fixture sits in the FOLDER the marker sits in rather than somewhere the exclusion could
    # never have reached it.
    #
    # ASKED WITH `hidden=1` SINCE 2026-08-26, and the change is a widening rather than a
    # concession: `.gitignore` is now hidden BY DEFAULT as ordinary dot-file clutter, so asserting
    # it against the default listing would only re-state that new rule. Asking with hidden files
    # SHOWN is what still isolates the original claim — the two rules are separate, and only the
    # marker one is absolute.
    test "a file merely named .gitignore is reachable, while the marker never is" do
      get files_path(folder: "dir-firmware", hidden: "1")

      assert_equal [ ".gitignore", "main.py" ], listed_names.sort
      assert_not_includes listed_names, ".git",
                          "the marker stays hidden even with hidden files shown — a different rule"
    end

    # THE DEFAULT, stated separately so the two rules cannot be conflated by a reader or collapsed
    # by an editor. Dot-files are hidden unless asked for; the marker is hidden either way.
    test "dot-files are hidden by default and the toggle brings them back" do
      get files_path(folder: "dir-firmware")
      assert_equal [ "main.py" ], listed_names.sort

      get files_path(folder: "dir-firmware", hidden: "1")
      assert_includes listed_names, ".gitignore"
    end

    # THE CONTROL ITSELF MUST RENDER, which every other test in this file is blind to: they drive
    # `?hidden=` directly, so a typo'd or deleted link in index.html.erb leaves them all green while
    # the user has no way to reach the behaviour. That is §14d's inert-control shape — a request
    # test proves the endpoint works and nothing about whether anything CALLS it.
    #
    # THE HREF IS ASSERTED, NOT JUST THE TEXT, and the label must FLIP: a control that always says
    # "Show" and always sends `hidden=1` is a one-way switch, which is the exact defect the
    # two-way test below covers from the behaviour side.
    test "the hidden-files toggle renders and flips with the current state" do
      # A PLAIN STRING, NEVER A REGEXP — §14e. `assert_select "[href*=?]", /hidden=1/` interpolates
      # the Regexp into the selector and compiles `[href*="(?-mix:hidden=1)"]`, which matches an
      # attribute whose literal text is that and so can NEVER pass. Walked into while writing this
      # test; it failed as an un-greenable test rather than a false green, which is the better
      # direction but only once you know why.
      get files_path(folder: "dir-firmware")
      assert_select "a[href*=?]", "hidden=1", { count: 1 }, "the default page must offer SHOW"

      get files_path(folder: "dir-firmware", hidden: "1")
      assert_select "a[href*=?]", "hidden=0", { count: 1 }, "with hidden shown it must offer HIDE"
    end

    # THE TOGGLE MUST GO BOTH WAYS, AND THIS IS THE HALF A `present?` SPELLING BREAKS. The "Hide"
    # link emits `?hidden=0`, which IS present — so `@show_hidden = params[:hidden].present?` reads
    # it as SHOW and the control turns dot-files on and can never turn them off. That was the first
    # draft of `resolve_hidden`. It also pins the cookie: `?hidden=1` has to persist across a
    # request with no parameter at all, or the choice dies the moment the user clicks into a folder,
    # since folder links carry only `folder:`.
    test "hidden=0 hides again, and the choice persists across a bare request" do
      get files_path(folder: "dir-firmware", hidden: "1")
      assert_includes listed_names, ".gitignore"

      # No parameter: the cookie is the only thing that can still be answering.
      get files_path(folder: "dir-firmware")
      assert_includes listed_names, ".gitignore", "the choice must survive folder navigation"

      get files_path(folder: "dir-firmware", hidden: "0")
      assert_equal [ "main.py" ], listed_names.sort

      get files_path(folder: "dir-firmware")
      assert_equal [ "main.py" ], listed_names.sort, "hiding must persist too, not just showing"
    end

    # WHERE THE EXCLUSION SITS IN THE CHAIN IS A SEPARATE CLAIM FROM WHETHER IT IS THERE, AND
    # EVERY TEST ABOVE IS GREEN WITHOUT IT. `.outside_repo_metadata` is applied to the `scope =`
    # assignment rather than to the `.order` chain below it, so `@child_count` — which is what
    # `@pages` is computed from — counts the rows the page actually renders. Moved one line down,
    # the marker is still hidden from every listing and the whole suite stays green while the
    # folder gains a PHANTOM SECOND PAGE that renders nothing: 251 rows counted, 250 shown, page 2
    # empty. Measured: the mutation leaves 2412 runs / 0 failures without this test.
    #
    # FOLDER_PAGE is 250, so the fixture sits exactly ON the boundary — that is the only size at
    # which one extra counted row changes `@pages`, and it is why this seeds 250 rather than a
    # round handful. `insert_all` because 250 `create!`s is 250 round trips for fixture setup.
    # Paging is name-sorted only (`paged_folder?`), which is the default sort, so no sort param.
    test "the hidden marker does not inflate the folder's page count" do
      now = Time.current
      @user.nodes.create!(node_id: "dir-big", name: "repo", kind: "dir")
      dir(".git", "dir-big")
      Node.insert_all(250.times.map do |i|
        { node_id: "big-#{i}", name: format("f%03d.stl", i), kind: "file", user_id: @user.id,
          parent_node_id: "dir-big", size: 5, mtime: 1_000_000_000, deleted: false,
          created_at: now, updated_at: now }
      end)

      get files_path(folder: "dir-big")

      assert_response :success
      assert_equal 250, listed_names.size
      assert_not_includes listed_names, ".git"
      # The claim, stated as the user-visible consequence: 250 renderable rows is ONE page, so no
      # pager is offered at all. Under the mutation @child_count is 251 and this nav appears.
      assert_select "nav.pager", count: 0

      # And there is no second page to fall off. resolve_page clamps to @pages, so ?page=2 serves
      # page 1 again; under the mutation @pages is 2, the clamp lets it through, and the offset
      # runs off the end of a 250-row set to render an empty table.
      get files_path(folder: "dir-big", page: 2)

      assert_response :success
      assert_equal 250, listed_names.size, "a page the folder does not have must not render empty"
    end

    # THE FLAT SCOPE (FilesController#index's `if @flat` branch), which is a different query over
    # the same catalog and so has to answer the same way. It filters kind: "file", so the row that
    # reaches it is the `gitdir:` pointer, not the marker directory.
    test "the flat by-extension listing hides a .git row too, and lists a real .git file" do
      get files_path(ext: "git")

      assert_response :success
      # The control is doing real work: it proves the ext filter selected rows at all, and it
      # fails any spelling of the scope that matches a `.git` SUFFIX instead of the whole name.
      assert_equal [ "firmware.git" ], listed_names
      assert Node.exists?(@pointer.id), "hidden from the UI, still in the catalog"
    end
  end
end
