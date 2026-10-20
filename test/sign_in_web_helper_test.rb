require "test_helper"

# THE ONE VERIFYING WEB SIGN-IN. A FAILED sign-in also redirects — Devise's FailureApp (a wrong
# password, an unconfirmed or locked account) and Users::SessionsController's per-IP throttle both
# `redirect_to` — so a bare `post user_session_path` cannot tell success from failure, and a test that
# only posts runs every later request anonymously while believing it holds a session. Three tests in
# this tree passed exactly that way, on negative assertions alone (attach_from_files_test.rb's
# `count: 0` and `assert_difference 0`, public_project_test.rb's owner-sees-404). `sign_in_web!` fails
# AT THE HELPER instead, naming the email, so the failure lands in the test that signed in rather than
# three assertions later as a 404 that looks right. This file pins both directions of the helper.
class SignInWebHelperTest < ActionDispatch::IntegrationTest
  def confirmed_user
    User.create!(email: "web-#{SecureRandom.hex(4)}@example.com", password: WEB_PASSWORD,
                 confirmed_at: Time.current)
  end

  test "a confirmed user is signed in: the helper returns the user and the next request is theirs" do
    user = confirmed_user

    assert_same user, sign_in_web!(user)
    get projects_path
    assert_response :success
  end

  test "an unconfirmed user is refused at the helper, and the message names the email" do
    user = User.create!(email: "unconfirmed-#{SecureRandom.hex(4)}@example.com", password: WEB_PASSWORD)

    err = assert_raises(Minitest::Assertion) { sign_in_web!(user) }
    assert_includes err.message, user.email
  end

  test "a wrong password is refused at the helper" do
    user = confirmed_user

    err = assert_raises(Minitest::Assertion) { sign_in_web!(user, password: "not it") }
    assert_includes err.message, user.email
  end
end
