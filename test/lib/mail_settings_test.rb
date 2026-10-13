require "test_helper"

# Mail is configured by ENVIRONMENT, never by editing production.rb: SMTP_ADDRESS turns SMTP on and
# the other knobs refine it. The function is pure so this test needs no mailer and no boot.
class MailSettingsTest < ActiveSupport::TestCase
  test "unconfigured when SMTP_ADDRESS is unset" do
    assert_nil Tinkerex::MailSettings.from_env({})
    assert_not Tinkerex::MailSettings.configured?({ "SMTP_ADDRESS" => "" })
  end

  test "a bare address gets the defaults: 587, STARTTLS, the mail-link host as HELO domain, no auth" do
    s = Tinkerex::MailSettings.from_env({ "SMTP_ADDRESS" => "smtp.example.net", "APP_HOST" => "maker.example" })
    assert_equal({ address: "smtp.example.net", port: 587, domain: "maker.example", enable_starttls_auto: true }, s)
  end

  test "credentials add plain authentication, and every knob can be overridden" do
    s = Tinkerex::MailSettings.from_env({
      "SMTP_ADDRESS" => "smtp.example.net", "SMTP_PORT" => "2525", "SMTP_DOMAIN" => "mail.example",
      "SMTP_USER_NAME" => "u", "SMTP_PASSWORD" => "p", "SMTP_AUTHENTICATION" => "login", "SMTP_STARTTLS" => "false"
    })
    assert_equal({ address: "smtp.example.net", port: 2525, domain: "mail.example", user_name: "u",
                   password: "p", authentication: :login, enable_starttls_auto: false }, s)
  end

  test "the sender is MAIL_FROM, else no-reply at the mail-link host, else the historical literal" do
    assert_equal "hi@x.example", Tinkerex::MailSettings.sender({ "MAIL_FROM" => "hi@x.example", "APP_HOST" => "y" })
    assert_equal "no-reply@maker.example", Tinkerex::MailSettings.sender({ "APP_HOST" => "maker.example" })
    assert_equal "no-reply@tinkerex.app", Tinkerex::MailSettings.sender({})
  end
end
