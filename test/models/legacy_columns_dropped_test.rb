require "test_helper"

class LegacyColumnsDroppedTest < ActiveSupport::TestCase
  test "legacy hand-rolled auth columns are gone" do
    cols = User.column_names
    %w[password_digest confirmation_token_digest reset_token_digest reset_sent_at].each do |c|
      assert_not_includes cols, c, "#{c} should be dropped (Devise replaces it)"
    end
  end

  test "device_pairings table is dropped" do
    assert_not ActiveRecord::Base.connection.table_exists?(:device_pairings)
  end

  test "the custom sessions table is dropped (Devise/Warden cookie sessions now)" do
    assert_not ActiveRecord::Base.connection.table_exists?(:sessions)
  end

  test "Devise columns remain" do
    assert_includes User.column_names, "encrypted_password"
    assert_includes User.column_names, "confirmed_at"
    assert_includes User.column_names, "confirmation_sent_at"
  end
end
