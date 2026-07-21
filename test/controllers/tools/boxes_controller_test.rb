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

    test "index lists generators and saved boxes" do
      get tools_boxes_path
      assert_response :success
      assert_select "*", text: /Simple box/
    end

    test "index groups generators under their group headings" do
      get tools_boxes_path
      assert_response :success
      assert_select ".box-group-title", text: "Boxes"
      assert_select ".box-group-title", text: "Trays"
      assert_select ".addon-card[data-boxfilter-target='card']", minimum: 2
      assert_select "input.box-search"
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

    test "show reopens a saved box with its params" do
      post tools_boxes_path, params: { name: "Reopen Me", generator: "ABox", params: { x: 77, y: 33 } }
      state = @user.maker_addon_states.for_addon("boxes").order(:id).last
      get tools_box_path(state)
      assert_response :success
      assert_select "*", text: /Reopen Me/
    end
  end
end
