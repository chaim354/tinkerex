require "test_helper"
require_relative "../../support/fake_openscad"

module Tools
  class OpenscadControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "oscad@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      # The gallery GREYS OUT an addon whose sidecar isn't configured, so a test that asserts the
      # LINK renders has to look like a deployment that has one. The stub still answers every call:
      # OpenscadClient.current prefers @stub over the URL, so nothing here reaches the network.
      @prior_sidecar_url = ENV["OPENSCAD_SIDECAR_URL"]
      ENV["OPENSCAD_SIDECAR_URL"] = "http://openscad.invalid"
      OpenscadClient.stub = FakeOpenscad.new
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
      ENV["OPENSCAD_SIDECAR_URL"] = @prior_sidecar_url
      OpenscadClient.reset!
      FileLayer.reset!
    end

    test "the /tools gallery links the addon without raising on the helper" do
      # REGRESSION GUARD: `resources :openscad` would make tools_openscad_path the SHOW helper, which
      # needs an id — and the gallery calls send("tools_#{key}_path") with no args, so /tools itself
      # would 500 for every user the moment this addon is registered.
      get tools_path
      assert_response :success
      assert_select "a.addon-card[href=?]", "/tools/openscad"
    end

    test "index lists the bundled catalog" do
      get tools_openscad_path
      assert_response :success
      assert_select ".addon-card .addon-title", text: "hex_plate"
    end
  end
end
