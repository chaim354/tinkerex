require "test_helper"

module Web
  # THE LIBRARY'S ACTIONS ARE IN THE OPEN (UX audit D2 and B5, 2026-11-02). Grid cards had no visible
  # action at all, Details was right-click only, and a folder delete asked "Delete cad?" though it
  # takes the whole subtree. Every list row and grid card now carries Details (a file), Download (a
  # file) and Delete, each named for what it acts on, and every Delete asks FilesHelper#delete_confirm's
  # question — the menu's included, through `data-delete-confirm`.
  #
  # PINNED TO A FRESH SHARE LIBRARY, files_selection_test.rb's reason: the Library's index backfills
  # thumbnails for renderable rows, and on the ambient s3 or chunk_remote leg a bare row would reach a
  # stub bucket or a live sync server. What is asserted is route helpers and labels.
  class FilesRowActionsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    FOLDER_QUESTION = "Delete the folder cad and everything in it?".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "ra-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @dir = @user.nodes.create!(node_id: "d-cad", name: "cad", kind: "dir")
      @stl = @user.nodes.create!(node_id: "n-stl", name: "bracket.stl", kind: "file", mtime: 1, size: 5)
      @rtf = @user.nodes.create!(node_id: "n-rtf", name: "notes.rtf", kind: "file", mtime: 1, size: 5)
    end

    # Every action's accessible name inside `scope`, across the page.
    def action_names(scope) = css_select("#{scope} .row-action").map { |el| el["aria-label"] }

    test "every list row and grid card carries its actions, named for the thing they act on" do
      { "list" => "table.files td.row-actions", "grid" => ".files-grid .grid-actions" }.each do |view, scope|
        get files_path(view:)
        assert_response :success
        named = action_names(scope)
        [ @stl, @rtf ].each do |file|
          %w[Details Download Delete].each do |verb|
            label = verb == "Details" ? "Details for #{file.name}" : "#{verb} #{file.name}"
            assert_includes named, label, "#{view}: #{file.name} has no #{verb}"
          end
        end
        assert_includes named, "Delete cad", "#{view}: the folder has no Delete"
        refute_includes named, "Download cad", "#{view}: a folder has no bytes to download"
        refute_includes named, "Details for cad", "#{view}: a folder is not a Details item"
      end
    end

    test "a grid card's actions sit beside the card, never inside the link" do
      get files_path(view: "grid")
      assert_select "a.grid-card .row-action", 0, "an action inside the card's link is a link in a link"
      assert_select ".files-grid > .grid-item > a.grid-card + .grid-actions", 3
    end

    # A FOLDER DELETE SAYS WHAT IT TAKES, on the row, on the card and in the right-click menu.
    test "every door that deletes a folder asks about everything in it" do
      %w[list grid].each do |view|
        get files_path(view:)
        assert_select "form[action=?][data-turbo-confirm=?]", file_path(@dir.node_id), FOLDER_QUESTION
        assert_select "[data-delete-url=?][data-delete-confirm=?]", file_path(@dir.node_id), FOLDER_QUESTION
        assert_select "form[action=?][data-turbo-confirm=?]", file_path(@stl.node_id), "Delete bracket.stl?"
        assert_select "[data-delete-url=?][data-delete-confirm=?]", file_path(@stl.node_id), "Delete bracket.stl?"
      end
    end

    # THE ROW'S DETAILS ON A PAGED FOLDER CARRIES ITS PAGE: #index honours `selected` only for a file
    # in the rows it renders, so a Details link to page 1 for a file on page 2 would open nothing.
    test "a Details link on page two of a folder stays on page two" do
      shelf = @user.nodes.create!(node_id: "d-shelf", name: "shelf", kind: "dir")
      (FilesController::FOLDER_PAGE + 1).times do |i|
        @user.nodes.create!(node_id: format("n-p%04d", i), name: format("p%04d.stl", i), kind: "file",
                            mtime: 1, size: 1, parent_node_id: shelf.node_id)
      end
      last = format("n-p%04d", FilesController::FOLDER_PAGE)
      get files_path(folder: shelf.node_id, page: 2, view: "list")
      assert_select "a.row-action[data-selection-id=?][href=?]", last,
                    files_path(folder: shelf.node_id, selected: last, page: 2)
    end
  end
end
