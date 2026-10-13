require "test_helper"
require "rake"

# The console doors for an owner whose server has no mail: create a confirmed account, reset a
# password. The password comes from TINKEREX_PASSWORD, never argv (argv is in `ps` and shell
# history), and the tasks refuse the cases a human gets wrong at 2 a.m.
#
# Loading and invoking follow test/tasks/projects_sweep_pointers_test.rb: the task definitions are
# loaded once per process (a second `load_tasks` would append a SECOND action to every task), and a
# task is re-enabled after EVERY invoke, success or SystemExit — `Rake::Task#invoke` runs an action
# only the first time per process, so without that the next invoke in this file would silently do
# nothing and fail for the wrong reason.
class TinkerexTasksTest < ActiveSupport::TestCase
  PASSWORD = "correct horse battery staple".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("tinkerex:owner")
    Rake::Task["tinkerex:owner"].reenable
    Rake::Task["tinkerex:password"].reenable
    ENV["TINKEREX_PASSWORD"] = PASSWORD
  end

  teardown { ENV.delete("TINKEREX_PASSWORD") }

  def invoke!(name, *args)
    Rake::Task[name].invoke(*args)
  ensure
    Rake::Task[name].reenable
  end

  test "owner creates a confirmed account that can sign in" do
    assert_difference -> { User.count }, 1 do
      invoke!("tinkerex:owner", "maker@example.com")
    end
    u = User.find_by!(email: "maker@example.com")
    assert u.confirmed?
    assert u.valid_password?(PASSWORD)
  end

  test "owner refuses an existing address and a short password" do
    User.create!(email: "taken@example.com", password: PASSWORD, confirmed_at: Time.current)
    assert_raises(SystemExit) { invoke!("tinkerex:owner", "taken@example.com") }
    ENV["TINKEREX_PASSWORD"] = "short"
    assert_no_difference -> { User.count } do
      assert_raises(SystemExit) { invoke!("tinkerex:owner", "new@example.com") }
    end
  end

  test "password resets and confirms an existing account" do
    u = User.create!(email: "lost@example.com", password: "old password here!!")
    invoke!("tinkerex:password", "lost@example.com")
    u.reload
    assert u.confirmed?
    assert u.valid_password?(PASSWORD)
  end
end
