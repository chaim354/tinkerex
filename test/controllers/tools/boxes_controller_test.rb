require "test_helper"
require_relative "../../support/fake_boxes"

module Tools
  class BoxesControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "boxes@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      BoxesClient.stub = FakeBoxes.new
      Storage::ChunkStore.reset!
      if ENV["LIBRARY_BACKEND"] == "s3"
        require_relative "../../support/fake_s3"
        @fake = FakeS3.new
        FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                              secret_access_key: "sk", prefix: "library",
                                              client: @fake.client)
      end
    end
    teardown do
      BoxesClient.reset!
      FileLayer.reset!
    end

    test "index tiles show the generator's short name (key), not its descriptive title" do
      get tools_boxes_path
      assert_response :success
      assert_select ".addon-card .addon-title", text: "ABox" # short name on the tile
      assert_select ".addon-card", text: /Simple box/, count: 0 # descriptive title lives on the editor now
    end

    test "index groups generators under their real boxes.py ui_group headings" do
      get tools_boxes_path
      assert_response :success
      assert_select ".box-group-title", text: "Box"
      assert_select ".box-group-title", text: "Tray"
      assert_select ".addon-card[data-boxfilter-target='card']", minimum: 2
      assert_select "input.box-search"
    end

    test "index tiles show the generator's sample photo via the internal proxy (JS fallback on 404)" do
      get tools_boxes_path
      assert_response :success
      assert_select "a.addon-card img.addon-thumb[data-controller='thumbfallback']"
      assert_select "img.addon-thumb[src=?]", "/tools/boxes/thumb/ABox"
      assert_select "img.addon-thumb[src*='githubusercontent']", count: 0 # self-hosted, no external host
    end

    test "thumb proxies a generator's sample photo from the sidecar, 404 when there is none" do
      get thumb_tools_boxes_path("ABox")
      assert_response :success
      assert_equal "image/jpeg", response.media_type
      assert response.body.bytesize.positive?

      get thumb_tools_boxes_path("TypeTray") # FakeBoxes has no sample for this one -> nil -> 404
      assert_response :not_found
    end

    test "the param form groups fields: open sections for basics, collapsed details for advanced" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      # a basic group -> open <fieldset> with a <legend>, fields directly usable
      assert_select "fieldset.param-group > legend", text: "ABox Settings"
      assert_select "fieldset.param-group input[name=?]", "params[x]"
      # an advanced group -> collapsed <details>; its fields are still in the DOM (so still submitted)
      assert_select "details.param-group-adv > summary", text: "Settings for Finger Joints"
      assert_select "details.param-group-adv select[name=?]", "params[FingerJoint_style]"
    end

    test "new headings the generator's short name (key) with its title as a description" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".page-head h1", text: "ABox"          # the short name is the heading
      assert_select ".page-subtitle", text: "Simple box"    # the descriptive title moved here
    end

    test "new renders a dynamic form from the generator's params" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select "input[name=?]", "params[x]"
      assert_select "input[name=?]", "params[y]"
    end

    test "new renders the two-column editor with a params grid and a preview column" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".box-editor > form .box-params input[name=?]", "params[x]"
      assert_select ".box-editor > aside.box-side .box-preview img[data-boxpreview-target='image']"
    end

    test "preview returns a rasterized PNG of the generated SVG" do
      post preview_tools_boxes_path, params: { generator: "ABox", params: { x: 120, y: 60 } }
      assert_response :success
      assert_equal "image/png", response.media_type if Maker::Previews::SvgRasterizer.available?
    end

    test "create saves the state + a tied bundle (svg output + params file)" do
      assert_difference("Maker::AddonState.count", 1) do
        post tools_boxes_path, params: { name: "My Box", generator: "ABox", params: { x: 120, y: 60 } }
      end
      state = @user.maker_addon_states.for_addon("boxes").order(:id).last
      assert_equal %w[output parameters], state.files.map(&:role)
      state.files.each { |af| assert @user.nodes.exists?(node_id: af.node_id) }
      assert_redirected_to tools_box_path(state)
    end

    test "new offers a folder picker: the library root plus existing folders" do
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "Projects", kind: "dir")
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select "select[name='parent_node_id'] option[value='']" # root, the default
      assert_select "select[name='parent_node_id'] option", text: %r{/Projects}
    end

    # Spy on LibraryOutput.write (define_singleton_method — the repo's mocking idiom, e.g.
    # chunk_test.rb) so these assert the CONTROLLER's parent-selection wiring without depending on
    # any one backend's write mechanics -> they pass identically on chunk/share/s3.
    test "create saves the bundle into the chosen folder" do
      folder = @user.nodes.create!(node_id: SecureRandom.uuid, name: "CNC", kind: "dir")
      captured = :unset
      original = Maker::Addons::LibraryOutput.method(:write)
      Maker::Addons::LibraryOutput.define_singleton_method(:write) do |user:, state:, parent_node_id:, files:|
        captured = parent_node_id
        []
      end
      begin
        post tools_boxes_path,
             params: { name: "Boxed", generator: "ABox", params: { x: 1, y: 2 }, parent_node_id: folder.node_id }
      ensure
        Maker::Addons::LibraryOutput.define_singleton_method(:write, original)
      end
      assert_equal folder.node_id, captured
    end

    test "create ignores a parent_node_id that is not the user's own live folder (falls back to root)" do
      other = User.create!(email: "other-boxes@example.com", password: PASSWORD, confirmed_at: Time.current)
      foreign = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs", kind: "dir")
      captured = :unset
      original = Maker::Addons::LibraryOutput.method(:write)
      Maker::Addons::LibraryOutput.define_singleton_method(:write) do |user:, state:, parent_node_id:, files:|
        captured = parent_node_id
        []
      end
      begin
        post tools_boxes_path,
             params: { name: "Boxed", generator: "ABox", params: { x: 1, y: 2 }, parent_node_id: foreign.node_id }
      ensure
        Maker::Addons::LibraryOutput.define_singleton_method(:write, original)
      end
      assert_nil captured
    end

    test "show reopens a saved box with its params" do
      post tools_boxes_path, params: { name: "Reopen Me", generator: "ABox", params: { x: 77, y: 33 } }
      state = @user.maker_addon_states.for_addon("boxes").order(:id).last
      get tools_box_path(state)
      assert_response :success
      assert_select "*", text: /Reopen Me/
    end

    test "new lists prior boxes for this generator only, newest first" do
      post tools_boxes_path, params: { name: "Older ABox", generator: "ABox", params: { x: 1, y: 2 } }
      post tools_boxes_path, params: { name: "Newer ABox", generator: "ABox", params: { x: 3, y: 4 } }
      post tools_boxes_path, params: { name: "A Tray",     generator: "TypeTray", params: { x: 5 } }

      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".box-prior", text: /Newer ABox/
      assert_select ".box-prior", text: /Older ABox/
      assert_select ".box-prior", text: /A Tray/, count: 0
      assert response.body.index("Newer ABox") < response.body.index("Older ABox"),
             "newer box should render before older"
      # the rail wires each prior box to the shared thumbnails poller (reuse, not a new endpoint)
      assert_select ".box-prior[data-controller='thumbs']"
      assert_select ".box-prior-item[data-thumbs-target='cell'][data-node-id]", minimum: 2
    end

    test "new omits the history rail when this generator has no saved boxes" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".box-prior", count: 0
      assert_select ".box-prior-hint", text: /No saved boxes/
    end

    test "a prior box's Load link nests params under params[] so the editor actually prefills" do
      post tools_boxes_path, params: { name: "Loadable", generator: "ABox", params: { x: 999, y: 7 } }

      get new_tools_box_path(generator: "ABox")
      assert_response :success
      href = css_select(".box-prior a").find { |a| a.text.strip == "Load" }&.[]("href")
      assert href, "expected a Load link in the rail"
      # WIRE FORMAT, asserted deliberately: params must be NESTED (params[x]=999), not flattened
      # (x=999). `:params` is a reserved url_for option that appends its hash to the query string, so
      # the flattened form is silently ignored by `new` (which reads params[:params]) -> no prefill.
      # Comparing against new_tools_box_path(params:) would reproduce the SAME bug on both sides and
      # pass vacuously (that was the original test's flaw).
      assert_includes href, "params%5Bx%5D=999"
      assert_includes href, "params%5By%5D=7"

      # END-TO-END: following the Load link actually prefills the form (the behavior that broke).
      get href
      assert_response :success
      assert_select "input[name='params[x]'][value=?]", "999"
    end

    test "the param form renders a boxes.py manual link as a compact link, not raw markdown" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      # y's help carries a `[🛈](…usermanual.html#y)` manual link; it must become a compact
      # <a class="box-help">, and the raw glyph / URL must NOT appear as inline label text.
      assert_select "a.box-help[href=?]", "https://florianfesti.github.io/boxes/html/usermanual.html#y"
      assert_select ".box-field-label", text: /🛈/, count: 0
      assert_select ".box-field-label", text: /usermanual\.html/, count: 0
    end

    test "new pre-selects the current project's folder in the save picker" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select "select[name='parent_node_id'] option[selected='selected'][value=?]", folder.node_id
    end

    test "create attaches both output files to the current project" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }
      assert_difference "project.file_attachments.count", 2 do
        post tools_boxes_path, params: { name: "Cur Box", generator: "ABox", params: { x: 1, y: 2 },
                                         parent_node_id: folder.node_id }
      end
      # both attached nodes live under the project folder
      project.file_attachments.each do |att|
        assert_equal folder.node_id, @user.nodes.find_by(node_id: att.node_id).parent_node_id
      end
    end

    test "create attaches nothing when no project is current" do
      @user.maker_projects.create!(name: "Desk Lamp") # exists but not current
      assert_no_difference "Maker::FileAttachment.count" do
        post tools_boxes_path, params: { name: "Loose Box", generator: "ABox", params: { x: 1, y: 2 } }
      end
    end
  end
end
