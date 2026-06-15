require "test_helper"

class UserMailerTest < ActionMailer::TestCase
  test "confirmation email targets the user and embeds the confirm link" do
    user = User.create!(email: "m@example.com", password: "a strong password here")
    mail = UserMailer.confirmation(user, "tok-123")
    assert_equal [ "m@example.com" ], mail.to
    assert_match "Confirm", mail.subject
    assert_match "tok-123", mail.body.encoded
  end

  test "password reset email targets the user and embeds the reset link" do
    user = User.create!(email: "n@example.com", password: "a strong password here")
    mail = UserMailer.password_reset(user, "rst-456")
    assert_equal [ "n@example.com" ], mail.to
    assert_match "rst-456", mail.body.encoded
  end
end
