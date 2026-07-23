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
  end
end
