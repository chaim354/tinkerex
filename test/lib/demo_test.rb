require "test_helper"

# DEMO_ACCOUNT_EMAIL names the shared demo account, and nothing of the demo exists without it;
# DEMO_MAX_UPLOAD_BYTES caps one file. Both are read on every call, so a test that flips ENV sees the
# flip on the very next call -- the property the whole web suite relies on to switch demo mode.
class DemoTest < ActiveSupport::TestCase
  PASSWORD = "correct horse battery staple".freeze

  setup do
    @prior = ENV.to_h.slice("DEMO_ACCOUNT_EMAIL", "DEMO_MAX_UPLOAD_BYTES")
    ENV.delete("DEMO_ACCOUNT_EMAIL")
    ENV.delete("DEMO_MAX_UPLOAD_BYTES")
    @demo = User.create!(email: "demo@example.com", password: PASSWORD, confirmed_at: Time.current)
    @other = User.create!(email: "maker@example.com", password: PASSWORD, confirmed_at: Time.current)
  end

  teardown do
    %w[DEMO_ACCOUNT_EMAIL DEMO_MAX_UPLOAD_BYTES].each { |k| @prior.key?(k) ? ENV[k] = @prior[k] : ENV.delete(k) }
  end

  test "unset, there is no demo: not enabled, no email, no account, nobody is the demo" do
    assert_not Tinkerex::Demo.enabled?
    assert_nil Tinkerex::Demo.email
    assert_nil Tinkerex::Demo.account, "an account that happens to be named like a demo is not one"
    assert_not Tinkerex::Demo.demo?(@demo)
    assert_not Tinkerex::Demo.demo_email?("demo@example.com")
  end

  test "a blank or whitespace setting is the same as unset" do
    [ "", "   " ].each do |blank|
      ENV["DEMO_ACCOUNT_EMAIL"] = blank
      assert_not Tinkerex::Demo.enabled?, "#{blank.inspect} must not switch demo mode on"
      assert_nil Tinkerex::Demo.account
      assert_not Tinkerex::Demo.demo?(@demo)
    end
  end

  test "set to an address with no account, demo mode is on and the account is nil" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "nobody@example.com"
    assert Tinkerex::Demo.enabled?
    assert_equal "nobody@example.com", Tinkerex::Demo.email
    assert_nil Tinkerex::Demo.account
    assert_not Tinkerex::Demo.demo?(@demo)
  end

  test "set to an existing account, that user is the demo and nobody else is" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    assert_equal @demo, Tinkerex::Demo.account
    assert Tinkerex::Demo.demo?(@demo)
    assert_not Tinkerex::Demo.demo?(@other)
    assert_not Tinkerex::Demo.demo?(nil), "a signed-out request is never the demo"
  end

  # Devise stores the address the way config/initializers/devise.rb's case_insensitive_keys and
  # strip_whitespace_keys say (downcased, stripped), so the setting and a submitted address are both
  # compared that way -- or `Demo@Example.com` in a deploy file names no account at all.
  test "addresses compare case-insensitively and ignore surrounding whitespace" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "  Demo@Example.COM "
    assert_equal "demo@example.com", Tinkerex::Demo.email
    assert_equal @demo, Tinkerex::Demo.account
    assert Tinkerex::Demo.demo?(@demo)
    assert Tinkerex::Demo.demo_email?("DEMO@example.com ")
    assert_not Tinkerex::Demo.demo_email?("demo@example.co")
    assert_not Tinkerex::Demo.demo_email?(nil)
  end

  test "the setting is read on every call, never remembered" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    assert Tinkerex::Demo.demo?(@demo)
    ENV["DEMO_ACCOUNT_EMAIL"] = "maker@example.com"
    assert_not Tinkerex::Demo.demo?(@demo)
    assert Tinkerex::Demo.demo?(@other)
    ENV.delete("DEMO_ACCOUNT_EMAIL")
    assert_not Tinkerex::Demo.enabled?
  end

  test "the per-file cap defaults to 25 MB and reads DEMO_MAX_UPLOAD_BYTES" do
    assert_equal 26_214_400, Tinkerex::Demo.max_upload_bytes
    ENV["DEMO_MAX_UPLOAD_BYTES"] = "1024"
    assert_equal 1024, Tinkerex::Demo.max_upload_bytes
    ENV["DEMO_MAX_UPLOAD_BYTES"] = " "
    assert_equal 26_214_400, Tinkerex::Demo.max_upload_bytes, "blank is unset"
  end

  # `"25MB".to_i` is 25, so a lenient read would cap the demo at 25 BYTES and refuse every upload with
  # a sentence nobody could explain. A cap that is not a whole number of bytes raises instead, and
  # validate! -- what config/initializers/demo.rb runs at boot -- raises it before any visitor can.
  test "a cap that is not a whole number of bytes is refused, at boot while demo mode is on" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    %w[25MB 0 -5 1.5 1e6].each do |junk|
      ENV["DEMO_MAX_UPLOAD_BYTES"] = junk
      e = assert_raises(Tinkerex::Demo::Error, "#{junk.inspect} must be refused") { Tinkerex::Demo.validate! }
      assert_match(/DEMO_MAX_UPLOAD_BYTES/, e.message)
    end
    ENV["DEMO_MAX_UPLOAD_BYTES"] = "1048576"
    assert_nil Tinkerex::Demo.validate!
  end

  test "validate! is silent while demo mode is off, whatever the cap says" do
    ENV["DEMO_MAX_UPLOAD_BYTES"] = "25MB"
    assert_nil Tinkerex::Demo.validate!, "nothing of the demo exists without DEMO_ACCOUNT_EMAIL"
  end

  test "an upload refusal names the file and the limit, for the demo alone and only over the cap" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    ENV["DEMO_MAX_UPLOAD_BYTES"] = "1024"
    assert_equal "big.stl is larger than 1 KB, the most the shared demo takes in one file.",
                 Tinkerex::Demo.upload_refusal(@demo, name: "big.stl", size: 1025)
    assert_nil Tinkerex::Demo.upload_refusal(@demo, name: "edge.stl", size: 1024), "the cap itself is allowed"
    assert_nil Tinkerex::Demo.upload_refusal(@other, name: "big.stl", size: 1025), "any other account is uncapped"
    ENV.delete("DEMO_ACCOUNT_EMAIL")
    assert_nil Tinkerex::Demo.upload_refusal(@demo, name: "big.stl", size: 1025), "demo mode off caps nobody"
  end
end
