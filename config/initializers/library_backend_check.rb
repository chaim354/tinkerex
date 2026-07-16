# Boot-time library-backend configuration check (phase 2a).
#
# Refuses to boot a LIBRARY_BACKEND=share deployment whose LIBRARY_PATH is unset, missing, not a
# directory, or unreadable — following the postgres_pooler_check precedent, because a
# misconfiguration that only appears on the first request is worse than one that stops the boot.
# See lib/library_backend_check.rb. No-op for chunk mode.
require "library_backend_check"

# Skip in the test env: the suite constructs adapters with explicit tmpdir roots and must not
# depend on a process-wide LIBRARY_PATH. FileLayer.build calls check! itself, so the share path is
# still guarded in tests — this only skips the *boot-time* assertion.
LibraryBackendCheck.check! unless Rails.env.test?
