require "test_helper"

module Tools
  class GeneratorsControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "gen@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      Storage::ChunkStore.reset!
      if ENV["LIBRARY_BACKEND"] == "s3"
        require_relative "../../support/fake_s3"
        @fake = FakeS3.new
        FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                              secret_access_key: "sk", prefix: "library",
                                              client: @fake.client)
      end
    end
    teardown { FileLayer.reset! }

    test "the tools gallery lists Generators as an always-available addon" do
      get tools_path
      assert_response :success
      assert_select "a.addon-card[href=?]", tools_generators_path do
        assert_select ".addon-title", text: "Generators"
      end
    end

    test "index mounts the harness and offers a save form with a folder picker" do
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "Projects", kind: "dir")
      get tools_generators_path
      assert_response :success
      # the harness mount (Stimulus builds picker/form/preview inside it)
      assert_select "[data-controller='generator']"
      assert_select "[data-generator-target='picker']"
      assert_select "[data-generator-target='preview']"
      # the save form posts to create, with name + folder picker (root default + existing folder)
      assert_select "form[action=?][method='post']", tools_generators_path
      assert_select "form input[name='name']"
      assert_select "form select[name='parent_node_id'] option[value='']"
      assert_select "form select[name='parent_node_id'] option", text: %r{/Projects}
      # hidden fields the harness fills before submit
      assert_select "form input[type='hidden'][name='generator']"
      assert_select "form input[type='hidden'][name='svg']"
    end

    test "index lists this user's saved grids, newest first" do
      @user.maker_addon_states.create!(addon_key: "generators", name: "Older Grid",
                                       data: { "generator" => "material-test-grid", "params" => {} })
      @user.maker_addon_states.create!(addon_key: "generators", name: "Newer Grid",
                                       data: { "generator" => "material-test-grid", "params" => {} })
      get tools_generators_path
      assert_response :success
      assert_select ".generator-saved", text: /Newer Grid/
      assert_select ".generator-saved", text: /Older Grid/
      assert response.body.index("Newer Grid") < response.body.index("Older Grid"),
             "newer grid should render before older"
    end

    test "index does not list another user's saved grids" do
      other = User.create!(email: "gen-other@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.maker_addon_states.create!(addon_key: "generators", name: "Secret Grid",
                                       data: { "generator" => "material-test-grid", "params" => {} })
      get tools_generators_path
      assert_response :success
      assert_select "*", text: /Secret Grid/, count: 0
    end

    SVG_FIXTURE = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>).freeze

    test "create saves the state + a tied bundle (svg output + params file) and redirects to show" do
      assert_difference("Maker::AddonState.count", 1) do
        post tools_generators_path, params: {
          name: "My Grid", generator: "material-test-grid",
          params: { cols: 3, rows: 3, cell: 10 }, svg: SVG_FIXTURE
        }
      end
      state = @user.maker_addon_states.for_addon("generators").order(:id).last
      assert_equal "material-test-grid", state.data["generator"]
      assert_equal({ "cols" => "3", "rows" => "3", "cell" => "10" }, state.data["params"])
      assert_equal %w[output parameters], state.files.map(&:role)
      state.files.each { |af| assert @user.nodes.exists?(node_id: af.node_id) }
      assert_redirected_to tools_generator_path(state)
    end

    test "create writes an svg output node and a json parameters node into the library" do
      post tools_generators_path, params: {
        name: "Bundle", generator: "material-test-grid", params: { cols: 2 }, svg: SVG_FIXTURE
      }
      state = @user.maker_addon_states.for_addon("generators").order(:id).last
      out = state.files.find { |f| f.role == "output" }
      par = state.files.find { |f| f.role == "parameters" }
      assert_equal "image/svg+xml", out.content_type
      assert_equal "application/json", par.content_type
    end

    test "create enqueues a preview for each written node" do
      assert_enqueued_jobs 2, only: Maker::GeneratePreviewJob do
        post tools_generators_path, params: {
          name: "Preview Me", generator: "material-test-grid", params: { cols: 2 }, svg: SVG_FIXTURE
        }
      end
    end

    test "create saves into the chosen folder (asserts the controller's parent wiring, backend-agnostic)" do
      folder = @user.nodes.create!(node_id: SecureRandom.uuid, name: "CNC", kind: "dir")
      captured = :unset
      original = Maker::Addons::LibraryOutput.method(:write)
      Maker::Addons::LibraryOutput.define_singleton_method(:write) do |user:, state:, parent_node_id:, files:|
        captured = parent_node_id
        []
      end
      begin
        post tools_generators_path, params: {
          name: "Foldered", generator: "material-test-grid", params: { cols: 2 },
          svg: SVG_FIXTURE, parent_node_id: folder.node_id
        }
      ensure
        Maker::Addons::LibraryOutput.define_singleton_method(:write, original)
      end
      assert_equal folder.node_id, captured
    end

    test "create ignores a foreign parent_node_id (falls back to root)" do
      other = User.create!(email: "gen-foreign@example.com", password: PASSWORD, confirmed_at: Time.current)
      foreign = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs", kind: "dir")
      captured = :unset
      original = Maker::Addons::LibraryOutput.method(:write)
      Maker::Addons::LibraryOutput.define_singleton_method(:write) do |user:, state:, parent_node_id:, files:|
        captured = parent_node_id
        []
      end
      begin
        post tools_generators_path, params: {
          name: "Foreign", generator: "material-test-grid", params: { cols: 2 },
          svg: SVG_FIXTURE, parent_node_id: foreign.node_id
        }
      ensure
        Maker::Addons::LibraryOutput.define_singleton_method(:write, original)
      end
      assert_nil captured
    end

    test "create rejects a missing svg with 422" do
      post tools_generators_path, params: { name: "No SVG", generator: "material-test-grid", params: { cols: 2 } }
      assert_response :unprocessable_entity
    end

    test "create rejects an over-cap svg with 422" do
      post tools_generators_path, params: {
        name: "Huge", generator: "material-test-grid", params: { cols: 2 }, svg: "x" * 2_000_001
      }
      assert_response :unprocessable_entity
    end

    test "show reopens a saved grid: its name and a rehydration payload for the harness" do
      post tools_generators_path, params: {
        name: "Reopen Me", generator: "material-test-grid",
        params: { cols: 4, rows: 2 }, svg: SVG_FIXTURE
      }
      state = @user.maker_addon_states.for_addon("generators").order(:id).last
      get tools_generator_path(state)
      assert_response :success
      assert_select "*", text: /Reopen Me/
      # the harness reads data-generator-reopen-value to prefill generator + params
      assert_select "[data-controller='generator'][data-generator-reopen-value*='material-test-grid']"
      assert_select "[data-generator-reopen-value*='cols']"
    end

    test "show does not expose another user's grid (scoped find → 404)" do
      other = User.create!(email: "gen-show-other@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: "generators", name: "Theirs",
                                                data: { "generator" => "material-test-grid", "params" => {} })
      get tools_generator_path(theirs)
      assert_response :not_found
    end
  end
end
