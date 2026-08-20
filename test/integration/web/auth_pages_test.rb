require "test_helper"

module Web
  # The auth and new-record GETs that no test drove.
  #
  # Measured with a process_action.action_controller subscriber over the whole suite: 72 of 85
  # non-v1 actions were exercised, and these were among the thirteen that were not. Reading the
  # controllers would not have produced that list.
  #
  # Smoke-level deliberately. For a form page, "it renders for the right visitor and turns the
  # wrong one away" is the contract; the POST behind each one is covered in devise_auth_flow_test,
  # account_settings_test, account_enumeration_test and models_flow_test.
  class AuthPagesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Sync::Storage::ChunkStore.reset!
    end

    test "the sign-up page renders" do
      get new_user_registration_path
      assert_response :success
      assert_select "form[action=?]", user_registration_path
    end

    test "the sign-up page states the password length requirement" do
      # set_minimum_password_length is what puts it there, and it reads from
      # Devise.password_length — so this fails if the floor is raised without the form following.
      get new_user_registration_path
      assert_select "form", /#{Devise.password_length.min} characters minimum/
    end

    test "the password-reset request page renders" do
      get new_user_password_path
      assert_response :success
      assert_select "form[action=?]", user_password_path
    end

    test "the confirmation-resend page renders" do
      get new_user_confirmation_path
      assert_response :success
      assert_select "form[action=?]", user_confirmation_path
    end

    test "the password-reset form renders for a valid token" do
      user = User.create!(email: "reset@example.com", password: PASSWORD,
                          confirmed_at: Time.current)
      raw = user.send_reset_password_instructions
      get edit_user_password_path(reset_password_token: raw)
      assert_response :success
      assert_select "form[action=?]", user_password_path
    end

    test "the omniauth authorize endpoint 404s with no IdP configured, and does not error" do
      # `passthru` is Devise's stub for the OmniAuth request phase: when no provider strategy
      # claims the path — which is the case here and on every deployment that has not configured
      # OIDC — it raises and Rails renders 404. That is the designed answer, and the property
      # worth pinning is that an UNCONFIGURED OIDC deployment answers 404 rather than 500.
      #
      # Checked both verbs rather than assuming the route table: the route is declared POST-only,
      # but OmniAuth's MIDDLEWARE sits in front of Rails routing, so what the route says and what
      # the request gets are two different questions. Both answer 404 here.
      get "/users/auth/openid_connect"
      assert_response :not_found

      post "/users/auth/openid_connect"
      assert_response :not_found
    end

    test "the new-model page renders for a signed-in user" do
      email = "modeler@example.com"
      User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }

      get new_model_path
      assert_response :success
      assert_select "form"
    end

    test "the new-model page requires a session" do
      get new_model_path
      assert_redirected_to new_user_session_path
    end
  end
end
