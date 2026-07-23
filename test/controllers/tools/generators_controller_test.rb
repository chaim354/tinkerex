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
  end
end
