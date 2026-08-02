require "test_helper"

module Maker
  class AddonsTest < ActiveSupport::TestCase
    test "SDK_VERSION parses as a semantic version" do
      assert_nothing_raised { Gem::Version.new(Maker::Addons::SDK_VERSION) }
    end

    test "require_sdk! returns true for a requirement the host satisfies" do
      assert Maker::Addons.require_sdk!("~> #{Maker::Addons::SDK_VERSION}")
    end

    test "require_sdk! raises when the host is older than the addon needs" do
      next_major = Gem::Version.new(Maker::Addons::SDK_VERSION).segments.first + 1
      error = assert_raises(Maker::Addons::IncompatibleSDK) do
        Maker::Addons.require_sdk!("~> #{next_major}.0")
      end
      assert_match(/host provides #{Regexp.escape(Maker::Addons::SDK_VERSION)}/, error.message)
    end
  end
end
