require "test_helper"

module Web
  class NewMenuTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # The house stub helper (text_file_creation_test.rb carries the same body; Minitest 6 has no
    # Object#stub). Replaces a SINGLETON method for the block, removing an inherited one after.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

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

    # NOT ONLY THE FILES INDEX (redesign slice 4): New reads FolderDestination, so every page that
    # renders a folder — here a file's workspace — creates beside what it shows. Until slice 4 the
    # menu read `params[:folder]` on files#index alone and created at the root everywhere else.
    test "on a file's page, New creates in the file's folder" do
      file = create_node!(@user, node_id: "n-sheet", name: "sheet.svg", kind: "file", parent_node_id: @dir.node_id)
      get file_path(file.node_id)
      assert_response :success
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

      # A page with no folder: `in: nil` is dropped by url_for, so this is the plain path.
      get projects_path
      assert_select "header.topbar .topbar-new turbo-frame#new-menu-tools[src=?][loading='lazy'][target='_top']",
                    tools_new_menu_path(in: nil)

      # A folder's page: the frame carries the folder, and each tool link it serves echoes it as
      # `in=`, so New ▸ <tool> starts its save where the maker is standing (Tools::HomeController).
      get files_path(folder: @dir.node_id)
      assert_select "header.topbar .topbar-new turbo-frame#new-menu-tools[src=?]",
                    tools_new_menu_path(in: @dir.node_id)

      get tools_new_menu_path
      assert_response :success
      assert_select "turbo-frame#new-menu-tools a.menu-item[href=?]", tools_addon_path("boxes"),
                    text: "Box Generator…"
      assert_select "turbo-frame#new-menu-tools a.menu-item[href=?]", tools_addon_path("fixture"),
                    count: 0
    ensure
      %w[ADDON_SOURCE_PATH BOXES_SIDECAR_URL FIXTURE_SVC_SIDECAR_URL].each do |key|
        prior&.key?(key) ? ENV[key] = prior[key] : ENV.delete(key)
      end
    end

    # THE LAYOUT NEVER READS THE ADDON REGISTRY (docs/invariants/addons.md; found in review). With a
    # source CONFIGURED — production's shape, and the case a stubbed source with no ADDON_SOURCE_*
    # set cannot reach — a page render fetches no manifests; only the menu's frame does, when someone
    # opens New. Asserted both ways, so the zero means "not called" rather than "not counting".
    test "no page render reads the addon registry; only the menu's frame does" do
      prior = ENV["ADDON_SOURCE_PATH"]
      ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
      calls = 0
      real = Maker::Addons::Registry.method(:manifests)
      replacing(Maker::Addons::Registry, :manifests, -> { calls += 1; real.call }) do
        get files_path
        get projects_path
        assert_equal 0, calls, "a page render read the addon registry #{calls} time(s)"

        get tools_new_menu_path
        assert_operator calls, :>=, 1, "the menu's frame did not read the registry at all"
      end
    ensure
      prior ? ENV["ADDON_SOURCE_PATH"] = prior : ENV.delete("ADDON_SOURCE_PATH")
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
