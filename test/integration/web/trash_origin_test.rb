require "test_helper"

module Web
  # TRASH SAYS WHAT EACH ROW IS AND WHERE IT CAME FROM, AND A RESTORE SAYS WHERE IT WENT (UX audit D7
  # and B6, 2026-11-02). The Kind column printed the raw `file`/`dir`; two deleted README.md files
  # could not be told apart; Restore was revealed only by hover; and a restore landed on the library
  # root with "Restored X." and no word on where X now was.
  #
  # PINNED TO A FRESH SHARE LIBRARY: the deletes and the restore go through the port for real, so
  # the trash rows are the ones a maker would see, on every backend leg alike.
  class TrashOriginTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "trash-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @projects = create_node!(@user, node_id: "d-projects", name: "Projects", kind: "dir")
      @catan = create_node!(@user, node_id: "d-catan", name: "catan", kind: "dir", parent_node_id: @projects.node_id)
      @lamp = create_node!(@user, node_id: "d-lamp", name: "lamp", kind: "dir", parent_node_id: @projects.node_id)
      @readme_catan = create_node!(@user, node_id: "n-rc", name: "README.md", kind: "file", parent_node_id: @catan.node_id)
      @readme_lamp = create_node!(@user, node_id: "n-rl", name: "README.md", kind: "file", parent_node_id: @lamp.node_id)
      @plate = create_node!(@user, node_id: "n-plate", name: "plate.lbrn2", kind: "file")
    end

    def row_for(node_id)
      css_select("table.files tbody tr").find { |tr| tr.at_css("form[action='#{restore_trash_path(node_id)}']") }
    end

    test "each row says its type in the Library's words and the folder it came from" do
      [ @readme_catan, @readme_lamp, @plate ].each { |n| FileLayer.current.delete(@user, node_id: n.node_id) }

      get trash_index_path
      assert_response :success
      assert_select "table.files th.col-type", text: "Type"
      assert_select "table.files th.col-folder", text: "From"

      catan = row_for(@readme_catan.node_id)
      lamp = row_for(@readme_lamp.node_id)
      assert_equal "MD", catan.at_css("td.col-type").text.strip
      assert_equal "Projects/catan", catan.at_css("td.col-folder a").text
      assert_equal files_path(folder: @catan.node_id), catan.at_css("td.col-folder a")["href"]
      assert_equal "Projects/lamp", lamp.at_css("td.col-folder a").text, "the two READMEs must be told apart"
      assert_equal "Library", row_for(@plate.node_id).at_css("td.col-folder a").text
      assert_select "table.files td.col-type", text: /\A\s*(file|dir)\s*\z/, count: 0
    end

    # A FOLDER IN THE TRASH WITH ITS CONTENTS: the folder's row says "Folder", and a child's row names
    # the folder as in the Trash too — restoring the child is refused until that folder is back.
    test "a deleted folder's contents name the folder, as in the Trash too" do
      FileLayer.current.delete(@user, node_id: @catan.node_id)

      get trash_index_path
      assert_equal "Folder", row_for(@catan.node_id).at_css("td.col-type").text.strip
      assert_equal "Projects", row_for(@catan.node_id).at_css("td.col-folder a").text
      assert_match(/\Acatan \(in Trash too\)\z/, row_for(@readme_catan.node_id).at_css("td.col-folder").text.strip)
    end

    # RESTORE IS NEVER HOVER-ONLY: the cell opts out of the list's fine-pointer fade, and the button is
    # named for the row it restores.
    test "Restore is shown on every row and named for its file" do
      FileLayer.current.delete(@user, node_id: @plate.node_id)
      get trash_index_path
      assert_select "td.row-actions.row-actions--shown button[aria-label=?]", "Restore plate.lbrn2", text: "Restore"
    end

    test "a restore lands back on Trash and names the folder the file is in again" do
      FileLayer.current.delete(@user, node_id: @readme_catan.node_id)

      post restore_trash_path(@readme_catan.node_id)
      assert_redirected_to trash_index_path
      assert_equal "Restored README.md to Projects/catan.", flash[:notice]
      refute @user.nodes.find_by!(node_id: @readme_catan.node_id).deleted?
    end

    # CONSTANT IN N, AND OVER THE EXPENSIVE CASE: rows whose folder is in the Trash too are the ones
    # that need the third query (their folders' names), which page_query_budget_test.rb's bare
    # tombstones never reach — so this deletes folders WITH contents, one and then five.
    test "trash#index does not grow with rows whose folder is in the Trash too" do
      add = lambda do |prefix, count|
        count.times do |i|
          dir = create_node!(@user, node_id: "d-#{prefix}#{i}", name: "box#{prefix}#{i}", kind: "dir")
          create_node!(@user, node_id: "n-#{prefix}#{i}", name: "lid.svg", kind: "file", parent_node_id: dir.node_id)
          FileLayer.current.delete(@user, node_id: dir.node_id)
        end
      end
      add.call("s", 1)
      few = queries_for { get trash_index_path }
      add.call("l", 4)
      many = queries_for { get trash_index_path }
      assert_select "td.col-folder", text: /in Trash too/, count: 5
      assert_equal few, many, "the trash's origins grew with its rows (#{few} against #{many})"
    end

    private

    def queries_for
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
      count
    end
  end
end
