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
    # of the scope would take every one of them out of the listing. This assertion is what makes
    # that mutation red, which is why the fixture sits in the FOLDER the marker sits in rather
    # than somewhere the exclusion could never have reached it.
    test "a file merely named .gitignore is still listed beside the hidden marker" do
      get files_path(folder: "dir-firmware")

      assert_equal [ ".gitignore", "main.py" ], listed_names.sort
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
