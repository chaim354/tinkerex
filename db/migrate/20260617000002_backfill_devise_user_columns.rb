# Copy the existing has_secure_password bcrypt digest (password_digest) into Devise's
# encrypted_password column. Both are bcrypt with the same internal format, so existing
# confirmed users authenticate against Devise unchanged — no password reset required.
# Rows with a NULL/blank password_digest (OmniAuth-only accounts) keep the "" default,
# which bcrypt will never match — exactly the passwordless behavior we want.
class BackfillDeviseUserColumns < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE users
      SET encrypted_password = password_digest
      WHERE password_digest IS NOT NULL AND password_digest <> ''
    SQL
  end

  def down
    # No-op: encrypted_password is dropped only if the whole feature is rolled back.
  end
end
