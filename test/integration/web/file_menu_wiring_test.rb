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
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
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

    # A DIRECTORY HAS NO BYTES. Folders take a different branch in both views and carry no
    # contextmenu action at all, which is what keeps a "Download" off them — asserted rather than
    # assumed, because the obvious way to add this feature is a blanket attribute on every cell.
    test "folders are offered neither a menu nor a download" do
      @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir")

      get files_path(view: "list")
      assert_select "a.dir[data-download-url]", count: 0
      assert_select "a.dir[data-action]", count: 0

      get files_path(view: "grid")
      assert_select ".grid-folder[data-download-url]", count: 0
      assert_select ".grid-folder[data-action]", count: 0
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
