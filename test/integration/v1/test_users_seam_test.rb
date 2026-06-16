require "test_helper"

module V1
  # The test/dev-only signup seam (POST /v1/test/users) used by the Rust integration tests.
  # Creates a confirmed account when ENABLE_TEST_SIGNUP is set; 404 otherwise.
  class TestUsersSeamTest < ActionDispatch::IntegrationTest
    test "creates a confirmed account when ENABLE_TEST_SIGNUP is set" do
      ENV["ENABLE_TEST_SIGNUP"] = "1"
      assert_difference -> { User.count }, 1 do
        post "/v1/test/users", params: { email: "rust@example.com", password: "correct horse battery staple" }, as: :json
      end
      assert_response :created
      user = User.find_by(email: "rust@example.com")
      assert user.confirmed?
      assert user.valid_password?("correct horse battery staple")
    ensure
      ENV.delete("ENABLE_TEST_SIGNUP")
    end

    test "is a 404 when ENABLE_TEST_SIGNUP is not set" do
      ENV.delete("ENABLE_TEST_SIGNUP")
      assert_no_difference -> { User.count } do
        post "/v1/test/users", params: { email: "nope@example.com", password: "correct horse battery staple" }, as: :json
      end
      assert_response :not_found
    end
  end
end
