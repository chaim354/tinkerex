require "test_helper"

module Web
  # The data attributes `filemenu_controller.js` builds its right-click menu from. The controller
  # reads them and NEVER assembles a URL itself, so this is where the menu's contents are actually
  # decided — and where a surface that silently lost an entry would show up.
  #
  # THE SYSTEM TEST (test/system/file_menu_test.rb) PROVES THE MENU RENDERS; THIS PROVES EVERY
  # SURFACE FEEDS IT. They are different failures: the menu working on the list while the grid's
  # cards carry no download-url is invisible to a browser test that only ever visits one of them,
  # and the grid is the surface that needs it most — a card has no row-actions cell, so the menu is
  # its only route to the bytes without opening the file first.
  #
  # BACKEND-NEUTRAL: these are route helpers on `nodes` rows, nothing touches the port.
  class FileMenuWiringTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "menu-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      # One thumbnailable file (takes the .file-cell branch) and one that is not (the plain-link
      # branch) — the two views each have both, and only one of them was wired at first.
      @user.nodes.create!(node_id: "n-stl", name: "widget.stl", kind: "file", mtime: 1, size: 5)
      @user.nodes.create!(node_id: "n-txt", name: "readme.rtf", kind: "file", mtime: 1, size: 5)
    end

    def download_urls
      css_select("[data-download-url]").map { |el| el["data-download-url"] }
    end

    test "the list view offers a download url on both cell shapes" do
      get files_path(view: "list")
      assert_includes download_urls, blob_file_path("n-stl", download: 1)
      assert_includes download_urls, blob_file_path("n-txt", download: 1)
    end

    test "the grid view offers one on both card shapes too" do
      get files_path(view: "grid")
      assert_includes download_urls, blob_file_path("n-stl", download: 1)
      assert_includes download_urls, blob_file_path("n-txt", download: 1)
    end

    test "a project's attachment tiles offer one as well" do
      project = @user.maker_projects.create!(name: "Lamp")
      project.file_attachments.create!(user: @user, node_id: "n-stl", role: "model")

      get project_path(project)
      assert_includes download_urls, blob_file_path("n-stl", download: 1)
    end

    # `?download=1` IS THE WHOLE MECHANISM, and it is the server's rather than the anchor's.
    # FilesController#blob reads it and answers `Content-Disposition: attachment`; the HTML
    # `download` attribute cannot do this job, because on chunk and s3 the endpoint 302s to a
    # presigned CROSS-ORIGIN storage URL and browsers ignore `download` across origins. Dropping the
    # param would leave a "Download" that opens a PDF in a tab on every backend.
    test "the download url forces an attachment rather than trusting the browser" do
      get files_path
      assert download_urls.all? { |u| u.include?("download=1") },
             "a menu url without ?download=1 opens inline instead of downloading"
    end

    # DELETE IS THE MENU'S ONLY DESTRUCTIVE ENTRY AND IT MUST REACH EVERY MENU-BEARING ROW. The
    # list has carried a `button_to "Delete"` in its row-actions cell since it shipped; the GRID has
    # no row-actions cell at all, so before this a card's only route to deleting the file was to
    # open it first. Swept across every row rather than asserted on one, for the reason this file
    # exists: an entry that works on the list and is missing from the grid is invisible to a browser
    # test that only ever visits one of them.
    test "every menu-bearing row carries a delete url" do
      get files_path
      assert_response :success
      rows = css_select("[data-action*='filemenu#open']")
      refute_empty rows, "no menu-bearing rows rendered — the fixture is not reaching the list"
      rows.each do |row|
        assert row["data-delete-url"].present?,
               "a menu-bearing row has no data-delete-url: #{row["data-node-id"] || row.to_s.first(80)}"
      end
    end

    # A FOLDER GOT NEITHER MENU NOR THUMB CELL until 2026-09-10. It gains the MENU and still no
    # cell, which makes files_helper's "not co-extensive" comment MORE true rather than less: a
    # folder has no note popover, no blob to download and no addon origin, so Delete is its whole
    # menu — which is why it is a separate builder and not `file_menu_data` with four nils.
    #
    # BOTH VIEWS, and by the folder branch's own selector rather than by a node id: `folder_menu_data`
    # deliberately writes NO `data-node-id`, because that attribute is the THUMB POLL's key
    # (thumbs_controller reads `dataset.nodeId`) and a folder has nothing to poll for.
    test "a folder row carries a menu holding a delete url and nothing else" do
      @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir")

      # UNCONDITIONAL AGAIN SINCE 2026-09-10. This skipped where the backend refused a directory
      # delete, for the two weeks between the menu shipping and the port learning to cascade. Every
      # backend cascades now, so every backend offers the menu.

      { "list" => "a.dir", "grid" => ".grid-folder" }.each do |view, selector|
        get files_path(view:)
        folder = css_select(selector).first
        refute_nil folder, "the #{view} view rendered no folder row at all"
        assert_includes folder["data-action"].to_s, "filemenu#open",
                        "the #{view} view's folder row has no right-click menu"
        assert_equal file_path("dir-cad"), folder["data-delete-url"],
                     "the #{view} view's folder menu has no delete url"
        assert_nil folder["data-note-url"], "a folder has no notes"
        assert_nil folder["data-download-url"], "a folder has no blob"
        assert_nil folder["data-thumbs-target"], "a folder has nothing to poll a thumbnail for"
      end
    end

    # A DIRECTORY HAS NO BYTES, AND THAT HALF STILL HOLDS — what changed on 2026-09-10 is only the
    # MENU. This test asserted `[data-action], count: 0` on both folder branches until then, which
    # was the right assertion while a folder had nothing to put in a menu; it is REVERSED here
    # deliberately rather than deleted, because the half worth keeping is the one that was always
    # the point: no download url reaches a directory. The obvious way to give a folder a menu is a
    # blanket `file_menu_data` on every cell, and that would hand every folder a dead Download.
    test "a folder is offered a menu but never a download" do
      @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir")

      get files_path(view: "list")
      assert_select "a.dir[data-download-url]", count: 0
      assert_select "a.dir[data-action]", count: 1

      get files_path(view: "grid")
      assert_select ".grid-folder[data-download-url]", count: 0
      assert_select ".grid-folder[data-action]", count: 1
    end

    # The menu is gated on `data-note-url` (`if (!noteUrl) return`), so a cell with a download url
    # and no note url renders no menu at all — the Download would be unreachable. They travel
    # together or the entry is dead.
    test "every cell offering a download also carries the note url the menu is gated on" do
      get files_path
      cells = css_select("[data-download-url]")
      assert_operator cells.size, :>=, 2
      assert cells.all? { |el| el["data-note-url"].present? },
             "a cell with a download url but no note url renders no menu, so the entry is unreachable"
    end
  end
end
