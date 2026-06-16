require "test_helper"

# Verifies the Devise columns exist on `users` after the additive migration. At this point
# `User` does NOT yet call `devise` (Task 4), so we only check the schema.
class DeviseColumnsTest < ActiveSupport::TestCase
  COLUMNS = %w[
    encrypted_password reset_password_token reset_password_sent_at remember_created_at
    confirmation_token unconfirmed_email failed_attempts unlock_token locked_at
    sign_in_count current_sign_in_at last_sign_in_at current_sign_in_ip last_sign_in_ip
  ].freeze

  test "users has all Devise columns" do
    cols = User.column_names
    COLUMNS.each { |c| assert_includes cols, c, "users should have #{c}" }
  end

  test "confirmed_at is retained" do
    assert_includes User.column_names, "confirmed_at"
  end
end
