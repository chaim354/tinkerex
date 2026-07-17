# Boot-time library-backend configuration check (phase 2a; s3 added in phase 3).
#
# Refuses to boot a misconfigured scanned deployment — following the postgres_pooler_check
# precedent, because a misconfiguration that only appears on the first request is worse than one
# that stops the boot. `share`: LIBRARY_PATH unset, missing, not a directory, unreadable or not
# writable. `s3`: the required LIBRARY_S3_* knobs unset — presence only, NEVER the network, so a
# boot cannot depend on a third party being up. See lib/library_backend_check.rb, whose header
# gives the asymmetry in full. No-op for chunk mode.
require "library_backend_check"

# Skip in the test env: the suite constructs adapters with explicit tmpdir roots and must not
# depend on a process-wide LIBRARY_PATH. FileLayer.build calls check! itself, so the share path is
# still guarded in tests — this only skips the *boot-time* assertion.
# after_initialize, NOT at initializer top level: the check names Library::Scanner::TEMP_PREFIX
# (see LibraryBackendCheck.writable!), and app/ constants are not autoloadable while initializers
# run — a top-level call raises `uninitialized constant Library` and takes the boot down for the
# wrong reason. This still refuses to boot: after_initialize runs inside `initialize!`, so the
# raise aborts before Puma binds a port. Verified both ways (a NameError before, a clean refusal
# after); no test can catch it, because the test env skips this file.
Rails.application.config.after_initialize do
  LibraryBackendCheck.check! unless Rails.env.test?
end
