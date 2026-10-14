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

    # THE EMAIL-UNLOCK SURFACE IS ABSENT ON PURPOSE, AND THESE TWO TESTS ARE WHAT KEEP IT ABSENT.
    #
    # `config.unlock_strategy = :time` (config/initializers/devise.rb, with the argument for :time
    # over :email beside it) means `devise_for` draws NO unlock routes at all — measured, zero. The
    # generated `users/unlocks/new.html.erb` and the `_links` branch offering "Didn't receive unlock
    # instructions?" were therefore reachable by nothing and were deleted. The view was in fact dead
    # TWICE over: `Devise.scoped_views` is false, so `Devise::UnlocksController`'s prefixes are
    # ["devise/unlocks", "devise", "application"] and even a drawn route would have rendered the
    # GEM's template, not ours. Flipping the strategy back to :email/:both would need
    # `scoped_views = true` as well before any app-owned unlock view rendered — so do not read a
    # red here as "restore the deleted files".
    #
    # TWO METHODS, NOT ONE: minitest abandons a method at its first failure, so a mutation that
    # revives BOTH halves of the surface can only report both if the guards live apart.
    test "no unlock route is drawn under unlock_strategy = :time" do
      # THE CONTROL IS NOT DECORATION. An assertion that a path 404s passes just as well when the
      # whole auth stack is down or the path string is a typo, which is the vacuous shape §14e
      # warns about. This proves the spelling and the stack before the 404 is allowed to mean
      # anything, using the nearest live neighbour: another Devise "resend me the mail" page,
      # drawn by the same `devise_for` call, differing only in which module enables it.
      get "/users/confirmation/new"
      assert_response :success

      get "/users/unlock/new"
      assert_response :not_found
    end

    test "the sign-in page offers no unlock link" do
      get new_user_session_path
      assert_response :success
      # BOTH NEEDLES SURVIVE HTML ESCAPING; THE OBVIOUS ONE DOES NOT. The link's own text is
      # "Didn't receive unlock instructions?" and `link_to` escapes the apostrophe to `&#39;`, so a
      # needle carrying a literal `'` matches nothing — an ABSENT guard, not a lenient one, the same
      # shape template_hygiene_test's LEAKED_PROSE list exists to refuse. This is measured, not
      # foreseen: the first draft of this test stayed GREEN under the mutation below.
      assert_not_includes response.body, "receive unlock instructions"
      assert_not_includes response.body, "/users/unlock"
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

    # --- the auth card (spec §8): a restyled form that renamed a field would look finished and
    # never sign anyone in, so these pin the card's markup AND Devise's field names together. ---

    test "sign in renders the card with Devise's fields" do
      get new_user_session_path
      assert_response :success
      # The sign-in page is the landing (2026-10-14): its masthead carries the brand, not the card.
      assert_select ".landing-brand .brand-name", text: "Tinkerex"
      assert_select ".auth-card form[action=?] input[name='user[email]'][type='email']", user_session_path
      assert_select ".auth-card form input[name='user[password]'][type='password']"
      assert_select ".auth-card form input[name='user[remember_me]'][type='checkbox']"
      assert_select ".auth-card form input[type='submit'][value='Log in'].primary"
      assert_select ".auth-card ul.auth-links a[href=?]", new_user_registration_path
      assert_select ".auth-card ul.auth-links a[href=?]", new_user_password_path
    end

    test "sign up, reset and resend render the card with their fields" do
      get new_user_registration_path
      assert_select ".auth-card form input[name='user[email]']"
      assert_select ".auth-card form input[name='user[password]']"
      assert_select ".auth-card form input[name='user[password_confirmation]']"
      assert_select ".auth-card form input[type='submit'][value='Sign up'].primary"

      get new_user_password_path
      assert_select ".auth-card form input[name='user[email]']"
      assert_select ".auth-card form input[type='submit'].primary"

      get new_user_confirmation_path
      assert_select ".auth-card form input[name='user[email]']"
    end

    test "a failed sign-in shows the alert as a toast, not inside the card" do
      post user_session_path, params: { user: { email: "nobody@example.com", password: "wrong" } }
      assert_response :unprocessable_entity
      assert_select ".flash-stack .flash-alert"
    end
  end
end
