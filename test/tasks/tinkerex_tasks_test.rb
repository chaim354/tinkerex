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
  include ActiveJob::TestHelper
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

  # The FIRST account on a fresh server enqueues the first library scan (J, 2026-10-15), a later one
  # does not. Enqueued, never performed. A FRESH install has no `library.root` row, and on share the
  # console door writes the whole mount before it asks (K §3): an operator who mounted a folder chose
  # it, and the console path must scan with no browser. Without that write the share branch below is
  # red -- the scan would wait for a confirmation nobody at a console can give. s3 and chunk_remote
  # have no folder to confirm and write nothing.
  test "owner on a fresh server confirms a share mount and enqueues the first scan; a second account does neither" do
    User.delete_all
    Setting.forget(Tinkerex::LibraryRoot::KEY)
    share = FileLayer.current.is_a?(FileLayer::Share)
    if FileLayer.current.capabilities.scannable?
      assert_enqueued_with(job: Library::ScanJob) { invoke!("tinkerex:owner", "first@example.com") }
    else
      assert_no_enqueued_jobs(only: Library::ScanJob) { invoke!("tinkerex:owner", "first@example.com") }
    end
    if share
      assert_equal "", Setting.get(Tinkerex::LibraryRoot::KEY), "the console door confirms the whole mount"
    else
      assert_nil Setting.get(Tinkerex::LibraryRoot::KEY), "only a share library has a folder to confirm"
    end
    assert_no_enqueued_jobs(only: Library::ScanJob) { invoke!("tinkerex:owner", "second@example.com") }
    assert_equal 2, User.count
  end

  # ONLY THE FIRST ACCOUNT CONFIRMS. An owner who signed up in the browser and has not yet answered
  # /settings/library is still deciding; a console account added meanwhile must not answer for them
  # (and start the 15-minute scans of the whole mount). Found in review: the test above cannot see
  # this, because after its first console account the row is already "" and a second write is
  # invisible. Mutation-checked: `clear! if pending?` without `first &&` turns this red on share.
  test "a console account added while the web owner is still choosing confirms nothing" do
    User.delete_all
    Setting.forget(Tinkerex::LibraryRoot::KEY)
    User.create!(email: "web-owner@example.com", password: PASSWORD, confirmed_at: Time.current)

    assert_no_enqueued_jobs(only: Library::ScanJob) { invoke!("tinkerex:owner", "second@example.com") }

    assert_nil Setting.get(Tinkerex::LibraryRoot::KEY), "the folder is still the web owner's to choose"
    assert_equal 2, User.count
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
