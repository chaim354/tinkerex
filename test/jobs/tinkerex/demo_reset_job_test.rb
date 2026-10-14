require "test_helper"

# The recurring job's one decision: WHICH account to reset, or none. The reset itself is
# test/lib/demo_reset_test.rb's subject, so here it is a recording stand-in — which is also what lets
# "no port call" be an observation: with the reset never built, nothing can reach the port.
module Tinkerex
  class DemoResetJobTest < ActiveSupport::TestCase
    # The house stub helper (new_menu_test.rb carries the same body; Minitest 6 has no Object#stub).
    # Replaces a SINGLETON method for the block, removing an inherited one after.
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

    setup do
      @prior_email = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV.delete("DEMO_ACCOUNT_EMAIL")
      @resets = []
    end

    teardown do
      @prior_email ? ENV["DEMO_ACCOUNT_EMAIL"] = @prior_email : ENV.delete("DEMO_ACCOUNT_EMAIL")
    end

    def recording_resets(&)
      resets = @resets
      fake_new = lambda do |user:, seed_dir: Tinkerex::DemoReset::DEFAULT_SEED_DIR|
        FakeReset.new(user, seed_dir, false).tap { |r| resets << r }
      end
      replacing(Tinkerex::DemoReset, :new, fake_new, &)
    end

    def capture_log
      io = StringIO.new
      prior = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
      io.string
    ensure
      Rails.logger = prior
    end

    def demo_user!(email = "demo-#{SecureRandom.hex(4)}@example.com")
      User.create!(email:, handle: "demo", password: SecureRandom.base58(24), confirmed_at: Time.current)
    end

    test "with demo mode off it does nothing at all" do
      user = demo_user!

      recording_resets { Tinkerex::DemoResetJob.perform_now }

      assert_empty @resets, "a reset was built with DEMO_ACCOUNT_EMAIL unset"
      assert User.exists?(user.id)
    end

    test "an address that names no account is logged and left alone" do
      demo_user!
      ENV["DEMO_ACCOUNT_EMAIL"] = "nobody@example.com"

      log = capture_log { recording_resets { Tinkerex::DemoResetJob.perform_now } }

      assert_empty @resets
      assert_match(/nobody@example\.com/, log)
      assert_match(/tinkerex:demo:setup/, log, "the warning must name the command that fixes it")
    end

    test "it resets the account DEMO_ACCOUNT_EMAIL names, whatever its case and spacing" do
      user = demo_user!("demo-case@example.com")
      # A second account, which must not be the one picked.
      User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current)
      ENV["DEMO_ACCOUNT_EMAIL"] = "  Demo-Case@Example.COM "

      recording_resets { Tinkerex::DemoResetJob.perform_now }

      assert_equal 1, @resets.size
      assert_equal user, @resets.first.user
      assert_equal Tinkerex::DemoReset::DEFAULT_SEED_DIR, @resets.first.seed_dir
      assert @resets.first.ran, "the reset was built but never called"
    end

    # THE REAL RESET, NOT THE STAND-IN: on a library another account shares it refuses, and the job
    # logs the sentence and returns rather than failing. Pinned to a fresh share library so the
    # refusal is the shared-library one on every CI leg.
    test "a refusal is logged with its sentence and the job returns, changing nothing" do
      @root = use_fresh_share_library!
      user = demo_user!
      User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current)
      ENV["DEMO_ACCOUNT_EMAIL"] = user.email

      log = capture_log { Tinkerex::DemoResetJob.perform_now }

      assert_match(/refused and changed nothing: the demo would wipe a library 1 other account shares/, log)
      assert User.exists?(user.id), "the demo account was replaced despite the refusal"
    end
  end
end
