# frozen_string_literal: true

# ARC C TASK 4: ONE DEVICE TOKEN PER MAKER USER, replacing the single process-wide
# CHUNK_REMOTE_TOKEN every user's request used to authenticate with (FileLayer::ChunkRemote's own
# header, and CLAUDE.md §14a). Nullable and defaultless on purpose: a user who has never touched
# their library under LIBRARY_BACKEND=chunk_remote has no remote device yet -- Task 5's lazy
# provisioning is what fills this in, on first use, not this migration.
#
# `t.string`, MATCHING `encrypted_password` TWO LINES UP IN THE SAME TABLE. Rails encryption
# stores its ciphertext (nonce + AEAD tag + payload, base64) as text, which is longer than the
# plaintext device token -- `t.string` is still correct because neither adapter this app ships
# (SQLite, Postgres) enforces a VARCHAR length limit unless one is given, matching how
# `encrypted_password` already stores a bcrypt digest in the same column type.
#
# ENCRYPTED, NOT PLAIN -- see app/models/user.rb's `encrypts :sync_device_token`. This migration
# only adds the column; config/initializers/active_record_encryption.rb (already configured on
# this branch, `support_unencrypted_data: false`) is what makes a value written here anything
# other than an accident.
class AddSyncDeviceTokenToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :sync_device_token, :string
  end
end
