require "test_helper"

module Tools
  class HomeControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "tools@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "requires login" do
      reset!
      get tools_path
      assert_redirected_to new_user_session_path
    end

    test "lists registered addons" do
      get tools_path
      assert_response :success
      assert_select ".addon-card", text: /Box Generator/
    end
  end
end
