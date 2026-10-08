require "test_helper"

module Web
  class NewMenuTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      # A REAL SHARE LIBRARY AND A FOLDER THAT EXISTS ON DISK. Four tests below reach the port's
      # mkdir, and a bare `nodes.create!` leaves a NULL storage_path, which cannot exist on share or
      # s3 (§14a): the mkdir has no parent to place under and every create answers 422. Same idiom
      # as library_browse_test.rb; test_helper removes the directory afterwards.
      @root = use_fresh_share_library!
      @user = User.create!(email: "new-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @dir = create_node!(@user, node_id: "dir-laser", name: "laser", kind: "dir")
    end

    test "the top bar's New menu offers a folder, a text file, a project and an inventory item" do
      get projects_path
      assert_select "header.topbar details.menu.topbar-new" do
        assert_select "form[action=?] input[name='name']", library_folders_path
        assert_select "a.menu-item[href=?]", new_files_text_file_path, text: "Text file"
        assert_select "a.menu-item[href=?]", new_project_path, text: "Project"
        assert_select "a.menu-item[href=?]", new_inventory_item_path, text: "Inventory item"
      end
    end

    test "on a folder's page, New creates in that folder" do
      get files_path(folder: @dir.node_id)
      assert_select "header.topbar form[action=?] input[name='parent_node_id'][value=?]",
                    library_folders_path, @dir.node_id
      assert_select "header.topbar a.menu-item[href=?]",
                    new_files_text_file_path(parent_node_id: @dir.node_id)
    end

    # ONE ENTRY PER AVAILABLE TOOL, AND AN UNAVAILABLE ONE IS LEFT OUT rather than listed as a link
    # that opens an apology. The fixture source declares `boxes` (service `boxes`) and `fixture`
    # (service `fixture-svc`); only the first has a sidecar URL here, so it is the positive and the
    # other the negative case on the same page.
    test "the New menu lists the tools this deployment can run, and only those" do
      prior = ENV.to_h.slice("ADDON_SOURCE_PATH", "BOXES_SIDECAR_URL", "FIXTURE_SVC_SIDECAR_URL")
      ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
      ENV["BOXES_SIDECAR_URL"] = "http://boxes.invalid"
      ENV.delete("FIXTURE_SVC_SIDECAR_URL")

      get projects_path
      assert_select "header.topbar .topbar-new a.menu-item[href=?]", tools_addon_path("boxes"),
                    text: "Box Generator…"
      assert_select "header.topbar .topbar-new a.menu-item[href=?]", tools_addon_path("fixture"),
                    count: 0
    ensure
      %w[ADDON_SOURCE_PATH BOXES_SIDECAR_URL FIXTURE_SVC_SIDECAR_URL].each do |key|
        prior&.key?(key) ? ENV[key] = prior[key] : ENV.delete(key)
      end
    end

    test "New ▸ Folder from the browser lands in the new folder" do
      post library_folders_path, params: { name: "jigs", parent_node_id: @dir.node_id },
                                 headers: { "Accept" => "text/html" }
      created = @user.nodes.present.find_by!(name: "jigs", parent_node_id: @dir.node_id)
      assert_redirected_to files_path(folder: created.node_id)
    end

    test "a refused folder name comes back as a flash, not JSON" do
      post library_folders_path, params: { name: "", parent_node_id: @dir.node_id },
                                 headers: { "Accept" => "text/html", "HTTP_REFERER" => files_url(folder: @dir.node_id) }
      assert_redirected_to files_url(folder: @dir.node_id)
      assert_equal "Folder name can't be blank.", flash[:alert]
    end

    test "the file chooser's JSON door is unchanged" do
      post library_folders_path, params: { name: "fixtures", parent_node_id: @dir.node_id }, as: :json
      assert_response :created
      assert_equal "fixtures", response.parsed_body["name"]
    end

    # AN AMBIGUOUS Accept KEEPS GETTING JSON — a caller that never said what it wants is an older
    # caller, and it was getting JSON before the HTML door existed. This is what pins the respond_to
    # ORDER; the explicit-JSON test above cannot see it.
    test "an ambiguous Accept still gets JSON" do
      post library_folders_path, params: { name: "anything", parent_node_id: @dir.node_id },
                                 headers: { "Accept" => "*/*" }
      assert_response :created
      assert_equal "application/json", response.media_type
    end
  end
end
