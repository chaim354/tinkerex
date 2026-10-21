require "test_helper"

# WHO MAY MANAGE ACCOUNTS. `admin` is the stored flag; `can_manage_accounts?` is the answer every
# caller asks, and the shared demo account never gets a yes whatever its row says.
class UserAdminTest < ActiveSupport::TestCase
  setup do
    @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
    ENV.delete("DEMO_ACCOUNT_EMAIL")
  end

  teardown { @prior_demo ? ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo : ENV.delete("DEMO_ACCOUNT_EMAIL") }

  def account!(email, admin: false)
    User.create!(email:, admin:, confirmed_at: Time.current, omniauth_signup: true)
  end

  test "a new account is not an admin unless a door says so" do
    assert_not account!("plain@example.com").admin?
  end

  test "an admin manages accounts and a plain account does not" do
    assert account!("a@example.com", admin: true).can_manage_accounts?
    assert_not account!("b@example.com").can_manage_accounts?
  end

  test "the demo account never manages accounts, whatever its row says" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    demo = account!("demo@example.com", admin: true)

    assert demo.admin?, "the stored flag is set"
    assert_not demo.can_manage_accounts?
    assert_not_includes User.account_managers, demo
  end

  test "the last account manager is the only admin left, the demo not counting" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    admin = account!("admin@example.com", admin: true)
    account!("demo@example.com", admin: true)
    account!("plain@example.com")

    assert admin.last_account_manager?

    second = account!("second@example.com", admin: true)
    assert_not admin.last_account_manager?
    assert_not second.last_account_manager?
  end

  test "a plain account is never the last account manager" do
    assert_not account!("plain@example.com").last_account_manager?
  end
end
