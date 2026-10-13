# ACTIVE RECORD ENCRYPTION -- keys live in config/credentials.yml.enc under
# `active_record_encryption:` (primary_key / deterministic_key / key_derivation_salt, each
# generated once by `bin/rails db:encryption:init` and never meant to be regenerated --
# regenerating replaces all three and makes every already-encrypted column permanently
# undecryptable; see docs/DEPLOY.md for the rotation story). They reach the app exactly the way
# secret_key_base always has: RAILS_MASTER_KEY decrypts config/credentials.yml.enc at boot
# (config/master.key locally, an env var in every deployment). No new deploy plumbing follows
# from that -- RAILS_MASTER_KEY is already resolved for all four destinations
# (.kamal/secrets-common; verified with `bin/secrets-preflight --all`, all four "ok").
#
# `config.active_record.encryption.*` has to be set at initializer time (here, or
# config/application.rb / config/environments/*.rb) rather than later -- ActiveRecord::Railtie's
# own "active_record_encryption.configuration" initializer reads
# `Rails.application.config.active_record.encryption` and hands it to
# `ActiveRecord::Encryption.configure`. Its `on_load(:active_record_encryption)` hook has already
# FIRED once by then (at `require "active_record/encryption"` time, inside `Bundler.require` in
# config/application.rb, well before any config/initializers/*.rb runs), and a late `on_load`
# registration for an already-fired hook runs its block immediately -- so whatever this
# OrderedOptions holds by the time config/initializers/*.rb finishes is what
# ActiveRecord::Encryption.config ends up with. Verified by probe, not assumed: a throwaway
# initializer flipping this to `true` and reading `ActiveRecord::Encryption.config
# .support_unencrypted_data` back in a fresh `bin/rails runner` showed the override took.

# KEYS FROM THE ENVIRONMENT, FOR A BOX WITH NO MASTER KEY (C, 2026-10-13; lib/tinkerex/encryption_keys.rb
# says why only-when-present matters). The author's deployments set none of these and keep reading
# credentials. A stranger's chunk_remote deployment sets all three (any 32+ character strings) and
# never RAILS_MASTER_KEY — a wrong key crashes the boot, an absent one reads empty credentials.
require "tinkerex/encryption_keys"
Tinkerex::EncryptionKeys.from_env.each do |name, value|
  Rails.application.config.active_record.encryption.public_send("#{name}=", value)
end

# SUPPORT_UNENCRYPTED_DATA: FALSE -- SET EXPLICITLY RATHER THAN LEFT ON THE FRAMEWORK DEFAULT
# (which is also false today; see activerecord's encryption/config.rb#set_defaults). Explicit
# because relying on a default that happens to already match is exactly the kind of thing a later
# Rails upgrade silently flips (CLAUDE.md's own §14e is full of defaults that changed under a
# `load_defaults` bump). The column this exists for -- Task 4's per-user sync-server device token
# on `users` -- is new and starts empty on every deployment: there is no legacy plaintext value
# anywhere that strict mode would need to tolerate. That is true only once, on the day the column
# is introduced -- turning this off later, after real unencrypted data exists under a `true`
# regime, means auditing every row to tell "legitimately never encrypted" from "encryption
# silently failed" apart, which is exactly the ambiguity `false` refuses to allow in the first
# place. So the strict setting is free today and only gets harder to adopt later; it is set now
# rather than deferred.
#
# Concretely: with this `false`, reading an `encrypts`-declared attribute whose stored column
# value is not a valid encrypted message raises `ActiveRecord::Encryption::Errors::Decryption`
# instead of silently handing back the raw column bytes as if they were the plaintext. A device
# token that somehow reached the column unencrypted -- a hand-written fixture, a direct SQL
# write, a future migration bug -- fails loudly on read rather than being trusted as a real token.
Rails.application.config.active_record.encryption.support_unencrypted_data = false

# encrypt_fixtures is deliberately NOT decided here -- it is a test-only concern with its own
# argument; see config/environments/test.rb.
