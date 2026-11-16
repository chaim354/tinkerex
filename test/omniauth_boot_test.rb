require "test_helper"
require "open3"

# SINGLE SIGN-ON IS A SWITCH WITH TWO DOCUMENTED POSITIONS (docs/INSTALL.md, `OMNIAUTH_ENABLED`),
# AND THE APP COULD ONLY START IN ONE OF THEM. The strategy's gem is `require: false` and nothing
# required it, so with the switch on Devise looked for a class that had never been loaded and the
# boot died with `Devise::OmniAuth::StrategyNotFound`.
#
# ONLY A BOOT CAN SEE THIS, WHICH IS WHY IT IS ONE. The failure is in a railtie initializer, and
# this process booted with the switch off. The callback tests put their mock result straight into
# the request environment and never go through the middleware that needed the class
# (omniauth_callback_test.rb), so the suite was green over an application that could not start.
#
# The child boots the share backend on a scratch folder whichever leg runs this, so the switch is
# the only thing that differs from an ordinary boot. Nothing here reaches a provider: discovery
# happens on a sign-in request, not at boot.
class OmniauthBootTest < ActiveSupport::TestCase
  SWITCHED_ON = {
    "OMNIAUTH_ENABLED" => "1",
    "OIDC_ISSUER" => "https://idp.example.test",
    "OIDC_CLIENT_ID" => "tinkerex",
    "OIDC_CLIENT_SECRET" => "not-a-secret",
    "OIDC_REDIRECT_URI" => "https://tinkerex.example.test/users/auth/openid_connect/callback"
  }.freeze

  test "the app boots with single sign-on switched on, with the strategy in its middleware" do
    Dir.mktmpdir("sso-boot") do |library|
      env = SWITCHED_ON.merge("LIBRARY_BACKEND" => "share", "LIBRARY_PATH" => library)
      out, status = Open3.capture2e(env, "bin/rails", "runner",
                                    "puts Rails.application.middleware.map(&:name).grep(/OmniAuth/).inspect",
                                    chdir: Rails.root.to_s)

      assert status.success?, "the boot failed:\n#{out.lines.first(6).join}"
      assert_includes out, "OmniAuth::Strategies::OpenIDConnect"
    end
  end
end
