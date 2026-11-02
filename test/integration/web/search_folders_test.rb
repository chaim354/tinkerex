require "test_helper"

module Web
  # A SEARCH RESULT SAYS WHERE IT IS (UX audit D11, 2026-11-02): file rows showed a name and an
  # extension, so three "tetra.stl" rows were three identical lines, and the models group was
  # "Models" where the rail says "3D models". Rows now carry their folder under the name, as a link
  # into it; a row whose folder is unknown names none rather than claim the library root.
  #
  # NO PORT IS TOUCHED — the search reads `nodes` and the folder walk is Maker::LibraryTree's pluck —
  # so bare catalog rows behave the same on every backend leg.
  class SearchFoldersTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "srf-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @projects = @user.nodes.create!(node_id: "d-projects", name: "Projects", kind: "dir")
      @catan = @user.nodes.create!(node_id: "d-catan", name: "catan", kind: "dir", parent_node_id: "d-projects")
      @lamp = @user.nodes.create!(node_id: "d-lamp", name: "lamp", kind: "dir", parent_node_id: "d-projects")
    end

    def path_under(group, href)
      row = css_select(".result-group--#{group} .result-row").find { |li| li.at_css("a[href='#{href}']") }
      refute_nil row, "no #{group} row links #{href}"
      row.at_css(".result-path")
    end

    test "file rows that share a name are told apart by their folders" do
      a = @user.nodes.create!(node_id: "n-a", name: "tetra.stl", kind: "file", parent_node_id: "d-catan")
      b = @user.nodes.create!(node_id: "n-b", name: "tetra.stl", kind: "file", parent_node_id: "d-lamp")
      c = @user.nodes.create!(node_id: "n-c", name: "tetra.stl", kind: "file")

      get search_path(q: "tetra")
      assert_response :success
      assert_equal "Projects/catan", path_under(:file, file_path(a.node_id)).text
      assert_equal files_path(folder: "d-catan"), path_under(:file, file_path(a.node_id))["href"]
      assert_equal "Projects/lamp", path_under(:file, file_path(b.node_id)).text
      assert_equal "Library", path_under(:file, file_path(c.node_id)).text
    end

    test "a folder row names the folder it sits in" do
      @user.nodes.create!(node_id: "d-laser-c", name: "laser", kind: "dir", parent_node_id: "d-catan")
      @user.nodes.create!(node_id: "d-laser-l", name: "laser", kind: "dir", parent_node_id: "d-lamp")
      get search_path(q: "laser")
      assert_equal "Projects/catan", path_under(:folder, files_path(folder: "d-laser-c")).text
      assert_equal "Projects/lamp", path_under(:folder, files_path(folder: "d-laser-l")).text
    end

    # "3D models", AND A MODEL'S FOLDER WHERE IT HAS ONE; one imported with none names nothing.
    test "the models group is 3D models and its rows name their folders" do
      foldered = @user.maker_models.create!(title: "tetra", folder_node_id: "d-catan")
      loose = @user.maker_models.create!(title: "tetra twin")
      get search_path(q: "tetra")
      assert_select ".result-group--model h2", text: /\A3D models/
      assert_equal "Projects/catan", path_under(:model, model_path(foldered)).text
      assert_nil path_under(:model, model_path(loose)), "a model with no folder must not claim the root"
    end

    # A BROKEN CHAIN NAMES NOTHING: Maker::LibraryTree#path_for answers nil for a row whose folder is
    # gone, and saying "Library" there would put the file at the root.
    test "a file whose folder is gone names no folder" do
      @catan.update!(deleted: true)
      orphan = @user.nodes.create!(node_id: "n-o", name: "tetra.stl", kind: "file", parent_node_id: "d-catan")
      get search_path(q: "tetra")
      assert_nil path_under(:file, file_path(orphan.node_id))
    end
  end
end
