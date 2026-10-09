require "test_helper"

module Web
  # The Files page's controls (spec §8, PR 2): Upload is the page's primary action and has lived in
  # the top bar since redesign slice 4 (topbar_upload_test.rb owns it), rescan and the folder's own
  # actions live in an overflow menu, and everything else —
  # the type filter, the dot-file switch, the count, the view toggle and the sort — sits on ONE
  # toolbar row in both views. Nodes are created directly, as files_type_filter_test.rb does.
  class FilesToolbarTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "tb-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir")
      file("root.stl", nil)
      file("plate.dxf", nil)
      file("firmware.bin", nil)   # no preview renderer: the generic card
      file("notes.pdf", "dir-cad")
    end

    # The two tests that select a backend assign FileLayer.current directly, which sets no pin for
    # test_helper's own teardown to unwind (see pin_file_layer_backend's comment) -- so the reset is
    # this file's, or an adapter leaks into the next test in this forked worker.
    teardown { FileLayer.reset! }

    # BOTH content columns, and both are load-bearing: the tile prints a size only when stat_all
    # reports a content token, and that token is `content_hash` on share/s3 but `current_version_id`
    # on chunk_remote. Setting one would render the size on two legs and not the third.
    def file(name, parent)
      @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file",
                          parent_node_id: parent, mtime: 1_000_000_000, size: 2_400,
                          content_hash: "h-#{name}", current_version_id: "v-#{name}")
    end

    # THE PAGE HEAD NO LONGER HOLDS AN UPLOADER. It moved to the top bar (redesign slice 4), which
    # uploads into the folder this page shows; topbar_upload_test.rb owns its markup, flows and
    # destination. `.uploader` is the class BOTH flows carry (the multipart form and the chunk
    # section), so these counts hold on every backend leg without a `port_writable?` branch.
    test "the Files page head no longer holds an uploader; Upload is the top bar's" do
      get files_path
      assert_response :success
      assert_select "main .uploader", count: 0
      assert_select "header.topbar .topbar-upload .uploader", count: 1
      assert_select ".page-head .page-actions a.btn[href=?]", new_files_text_file_path, text: "New text file"
    end

    test "rescan lives in the overflow menu on a scannable backend" do
      get files_path
      if FileLayer.current.capabilities.scannable?
        assert_select ".page-actions details.menu[data-controller='menu'] summary.btn"
        assert_select ".page-actions details.menu form[action=?] button.menu-item", rescan_files_path, text: /rescan/i
      else
        assert_select "form[action=?]", rescan_files_path, count: 0
      end
    end

    test "the toolbar carries the search box, the filter, the dot-file switch, the count, the view toggle and the sort, in both views" do
      %w[list grid].each do |view|
        get files_path(view:)
        assert_select ".toolbar.files-toolbar", count: 1
        assert_select ".files-toolbar form.files-search input[type='search'][name='q']"
        assert_select ".files-toolbar .ext-picker select#ext-add"
        assert_select ".files-toolbar p.hidden-toggle a.chip[href*=?]", "hidden=1", text: "Show dot-files"
        assert_select ".files-toolbar .toolbar-count", text: "4 items"
        assert_select ".files-toolbar .view-toggle a.toggle.active", text: view.capitalize
        assert_select ".files-toolbar form.sort-form select[name='sort']"
        assert_select ".files-toolbar form.sort-form select[name='dir']"
      end
    end

    test "the count says matches when the view is flat, and keeps the truncation sentence" do
      get files_path(ext: "stl")
      assert_select ".files-toolbar .toolbar-count", text: "1 match"
      get files_path(q: "e")
      assert_select ".files-toolbar .toolbar-count", text: "3 matches"
    end

    # The scannable arm is asserted too, so this run is not a test that reports success having
    # asserted nothing on the backend it happens to be running against (§15).
    test "no menu renders when it would be empty" do
      get files_path
      if FileLayer.current.capabilities.scannable?
        assert_select ".page-actions details.menu", count: 1
      else
        assert_select ".page-actions details.menu", count: 0
      end
    end

    test "grid tiles carry a size-and-type line" do
      get files_path(view: "grid")
      assert_select ".files-grid .grid-card.file-cell .grid-sub", text: "2.34 KB · STL"
      assert_select ".files-grid .grid-card:not(.file-cell):not(.grid-folder) .grid-sub", text: "2.34 KB · BIN"
      assert_select ".files-grid .grid-folder .grid-sub", count: 0
    end

    # STORY 1.3 / 4.7 — the one door onto adoption. It renders on the FOLDER view only: the flat
    # view and the root are questions about the library, and there is no folder there to adopt.
    test "a folder view offers 'Make this folder a project', and the root does not" do
      get files_path(folder: "dir-cad")
      assert_select ".page-actions details.menu form[action=?] button.menu-item",
                    adopt_projects_path, text: /make this folder a project/i
      assert_select ".page-actions details.menu form[action=?] input[name=?][value=?]",
                    adopt_projects_path, "node_id", "dir-cad"

      get files_path
      assert_select "form[action=?]", adopt_projects_path, count: 0
    end

    # THE MENU MUST NOT OFFER WHAT THE DOOR WOULD REFUSE for a reason the page can see for free.
    # The expensive refusals (an ancestor's claim, a working tree) stay in the controller; these
    # two are a string test and a nil test on a row the page already holds.
    test "the adopt item is absent for a dot-folder and for the Projects root" do
      projects = @user.nodes.create!(node_id: "dir-projects", name: Maker::ProjectFolders::ROOT,
                                     kind: "dir")
      dot = @user.nodes.create!(node_id: "dir-dot", name: ".hidden", kind: "dir")

      # `?hidden=` is not needed: it filters which CHILDREN are listed, and FilesController
      # #current_folder resolves params[:folder] by node_id regardless of the dot rule.
      [ projects, dot ].each do |folder|
        get files_path(folder: folder.node_id)
        # BRACES ON THE EQUALITY HASH. `assert_select sel, arg, count: 0, "msg"` is a Ruby SYNTAX
        # ERROR — a positional argument cannot follow a braceless hash — and rails-dom-testing's
        # signature is (selector, *substitutions, equality, message). Every other assertion in this
        # plan puts the hash last and needs no braces; this one carries a message.
        assert_select "form[action=?]", adopt_projects_path, { count: 0 }, "for #{folder.name}"
      end
    end

    # A CLAIMED FOLDER OFFERS THE PROJECT, NOT THE VERB. Unscoped on status, like every other
    # reader of this claim: an archived project still owns its folder, and the page saying nothing
    # about it is how a maker ends up with two projects for one folder.
    test "a folder a project already claims links to that project instead" do
      project = @user.maker_projects.create!(name: "Cad Build")
      project.update_column(:folder_node_id, "dir-cad")

      get files_path(folder: "dir-cad")

      assert_select ".page-actions details.menu a.menu-item[href=?]", project_path(project),
                    text: /Cad Build/
      assert_select "form[action=?]", adopt_projects_path, count: 0
    end

    # The menu itself must appear on a folder view even where it would otherwise be empty —
    # chunk_remote is not scannable, so before this slice the `details.menu` did not render at all
    # and the item would have had nowhere to go.
    test "the overflow menu renders on a folder view on every backend" do
      get files_path(folder: "dir-cad")
      assert_select ".page-actions details.menu[data-controller='menu'] summary.btn", count: 1
    end

    # AND IT STILL MUST NOT RENDER EMPTY — the rule two tests up, asked on the folder view, where a
    # gate reading "is there a folder at all" once escaped it. Since slice 2 of the 2026-10-08
    # redesign every folder view holds "Pin to sidebar", so a folder view always has a menu, and
    # what this pins is that the folder arm adds exactly what it offers beside the pin. chunk_remote
    # EXPLICITLY (the idiom rescan_test.rb records: constructing the adapter needs no sync server,
    # and its reads answer from the local mirror), so the folder arms are the only possible items:
    # a dot-folder and the Projects root offer the pin alone, an ordinary folder the pin and the
    # adopt button.
    test "on a non-scannable backend the folder menu holds the pin and only what the folder offers" do
      FileLayer.current = FileLayer::ChunkRemote.new
      @user.nodes.create!(node_id: "dir-dot2", name: ".config", kind: "dir")
      @user.nodes.create!(node_id: "dir-projects2", name: Maker::ProjectFolders::ROOT, kind: "dir")

      %w[dir-dot2 dir-projects2].each do |folder|
        get files_path(folder:)
        assert_response :success
        assert_select ".page-actions details.menu .menu-item", { count: 1 }, "for #{folder}"
        assert_select ".page-actions details.menu form[action=?] button.menu-item", pins_path,
                      { text: "Pin to sidebar" }, "for #{folder}"
      end

      get files_path(folder: "dir-cad")
      assert_select ".page-actions details.menu", count: 1
      assert_select ".page-actions details.menu .menu-item", count: 2
      assert_select ".page-actions details.menu form[action=?] button.menu-item", pins_path,
                    text: "Pin to sidebar"
      assert_select ".page-actions details.menu form[action=?] button.menu-item",
                    adopt_projects_path, text: /make this folder a project/i

      # AND THE ROOT, ON THIS SAME ADAPTER, STILL RENDERS NO MENU: no folder means no pin, and
      # nothing else here has an item. The folder views above can no longer be empty, so this is
      # the one place left where this file pins "never an empty ⋯" on every backend leg.
      get files_path
      assert_select ".page-actions details.menu", { count: 0 }, "at the root"
    end

    # THE OTHER HALF OF THE SAME GATE, and Task E's phone sweep depends on it: a folder a project
    # claims offers "Open project" on every backend, so the folder arm must contribute for a
    # CLAIMED folder as well as an adoptable one.
    test "a claimed folder still renders the menu on a non-scannable backend" do
      FileLayer.current = FileLayer::ChunkRemote.new
      project = @user.maker_projects.create!(name: "Cad Build")
      project.update_column(:folder_node_id, "dir-cad")

      get files_path(folder: "dir-cad")

      assert_select ".page-actions details.menu", count: 1
      assert_select ".page-actions details.menu a.menu-item[href=?]", project_path(project),
                    text: /Cad Build/
    end
  end
end
