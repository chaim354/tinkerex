require "test_helper"

module Tinkerex
  # The keys the two sign-in doors throttle by (pentest M4b, tinkerex#466). The doors themselves are
  # driven in test/integration/web/auth_throttle_test.rb and test/integration/v1/device_login_test.rb.
  class SignInThrottleTest < ActiveSupport::TestCase
    test "an IPv4 address is its own source" do
      assert_equal "203.0.113.7", SignInThrottle.source("203.0.113.7")
      assert_not_equal SignInThrottle.source("203.0.113.7"), SignInThrottle.source("203.0.113.8")
    end

    test "every IPv6 address in one /64 is ONE source, and the next /64 is another" do
      a = SignInThrottle.source("2001:db8:1:2::1")
      assert_equal a, SignInThrottle.source("2001:db8:1:2:ffff:ffff:ffff:fffe")
      assert_equal "2001:db8:1:2::/64", a
      assert_not_equal a, SignInThrottle.source("2001:db8:1:3::1")
    end

    test "an IPv4-mapped IPv6 address counts as the IPv4 address it carries" do
      assert_equal "203.0.113.7", SignInThrottle.source("::ffff:203.0.113.7")
    end

    test "an unparsable source keeps a budget of its own rather than sharing a blank one" do
      assert_equal "not-an-ip", SignInThrottle.source("not-an-ip")
    end

    test "the account key ignores case and padding, holds no address, and is per source" do
      key = SignInThrottle.account_key("Owner@Example.com ", "203.0.113.7")
      assert_equal key, SignInThrottle.account_key("owner@example.com", "203.0.113.7")
      assert_not_includes key, "example.com"
      assert_not_equal key, SignInThrottle.account_key("owner@example.com", "203.0.113.8")
      assert_not_equal key, SignInThrottle.account_key("other@example.com", "203.0.113.7")
    end

    # The account limit has to bound one source at least as tightly as the source limit does, or
    # one source could spend its whole budget on one account. It also has to be counted over a
    # longer window, or it adds nothing to the source limit.
    test "the account limit is no looser than the source limit and spans a longer window" do
      assert_operator SignInThrottle::PER_ACCOUNT[:to], :<=, SignInThrottle::PER_SOURCE[:to]
      assert_operator SignInThrottle::PER_ACCOUNT[:within], :>, SignInThrottle::PER_SOURCE[:within]
    end
  end
end
