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
    Rake::Task["tinkerex:demo:setup"].reenable
    Rake::Task["tinkerex:demo:reset"].reenable
    ENV["TINKEREX_PASSWORD"] = PASSWORD
    @prior_demo_email = ENV["DEMO_ACCOUNT_EMAIL"]
    ENV.delete("DEMO_ACCOUNT_EMAIL")
  end

  teardown do
    ENV.delete("TINKEREX_PASSWORD")
    @prior_demo_email ? ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo_email : ENV.delete("DEMO_ACCOUNT_EMAIL")
  end

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

  # --- The demo account (tinkerex:demo:*) ----------------------------------------------------------
  #
  # The tasks' job is choosing the account and handing it to Tinkerex::DemoReset; the reset itself is
  # test/lib/demo_reset_test.rb's subject, so here it is a recording stand-in. Swapped in through the
  # house `replacing` helper (new_menu_test.rb carries the same body; Minitest 6 has no Object#stub).
  def replacing(owner, name, replacement)
    mod = owner.singleton_class
    own = mod.instance_methods(false).include?(name)
    original = mod.instance_method(name)
    mod.define_method(name, &replacement)
    yield
  ensure
    own ? mod.define_method(name, original) : mod.remove_method(name)
  end

  FakeReset = Struct.new(:user, :seed_dir, :ran) do
    def call
      self.ran = true
      user
    end
  end

  def recording_resets
    resets = []
    fake_new = lambda do |user:, seed_dir: Tinkerex::DemoReset::DEFAULT_SEED_DIR|
      FakeReset.new(user, seed_dir, false).tap { |r| resets << r }
    end
    replacing(Tinkerex::DemoReset, :new, fake_new) { yield resets }
  end

  test "demo:setup and demo:reset refuse, saying why, while DEMO_ACCOUNT_EMAIL is unset" do
    recording_resets do |resets|
      %w[tinkerex:demo:setup tinkerex:demo:reset].each do |task|
        assert_no_difference -> { User.count } do
          err = assert_raises(SystemExit) { capture_io { invoke!(task) } }
          assert_match(/DEMO_ACCOUNT_EMAIL/, err.message, "#{task} must name the setting it needs")
        end
      end
      assert_empty resets
    end
  end

  test "demo:setup creates the confirmed demo account when it is absent, then resets it once" do
    # Setup asks Tinkerex::DemoReset.refusal before minting, and that question reads the port: pinned
    # to share so the answer is the same on every CI leg.
    @root = use_fresh_share_library!
    ENV["DEMO_ACCOUNT_EMAIL"] = "Demo@Example.com"

    recording_resets do |resets|
      assert_difference -> { User.count }, 1 do
        capture_io { invoke!("tinkerex:demo:setup") }
      end
      demo = User.find_by!(email: "demo@example.com")
      assert demo.confirmed?
      assert_equal "demo", demo.handle
      assert_equal [ demo ], resets.map(&:user)
      assert_equal Tinkerex::DemoReset::DEFAULT_SEED_DIR, resets.first.seed_dir
      assert resets.first.ran
    end
  end

  test "demo:setup on an existing account creates nothing and resets it" do
    demo = User.create!(email: "demo@example.com", handle: "demo", password: PASSWORD, confirmed_at: Time.current)
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"

    recording_resets do |resets|
      assert_no_difference -> { User.count } do
        capture_io { invoke!("tinkerex:demo:setup") }
      end
      assert_equal [ demo ], resets.map(&:user)
      assert resets.first.ran
    end
  end

  test "demo:reset resets the existing account, and refuses, pointing at setup, when there is none" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"

    recording_resets do |resets|
      err = assert_raises(SystemExit) { capture_io { invoke!("tinkerex:demo:reset") } }
      assert_match(/tinkerex:demo:setup/, err.message)
      assert_empty resets

      demo = User.create!(email: "demo@example.com", handle: "demo", password: PASSWORD, confirmed_at: Time.current)
      capture_io { invoke!("tinkerex:demo:reset") }
      assert_equal [ demo ], resets.map(&:user)
      assert resets.first.ran
    end
  end

  # THE REAL REFUSAL, THROUGH BOTH DOORS: on a library another account shares (share, here; s3 is the
  # same fact), setup refuses BEFORE minting the account — minting it is half the harm — and reset
  # refuses before touching the account it names. Each says the sentence and exits non-zero.
  test "on a library another account shares, both tasks refuse in the reset's own words and exit non-zero" do
    @root = use_fresh_share_library!
    User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"

    err = assert_raises(SystemExit) { capture_io { invoke!("tinkerex:demo:setup") } }
    refute err.success?, "a refusal must exit non-zero"
    assert_match(/would wipe a library 1 other account shares/, err.message)
    refute User.exists?(email: "demo@example.com"), "setup minted the demo account before refusing"

    demo = User.create!(email: "demo@example.com", handle: "demo", password: PASSWORD, confirmed_at: Time.current)
    err = assert_raises(SystemExit) { capture_io { invoke!("tinkerex:demo:reset") } }
    refute err.success?
    assert_match(/would wipe a library 1 other account shares/, err.message)
    assert User.exists?(demo.id), "reset replaced the demo account before refusing"
  end
end
