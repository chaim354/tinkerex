# Whether v1 `POST /v1/commit/:id/finalize` performs a storage `exists?` check that the
# chunk bytes actually landed before creating the immutable version + changelog entry
# (closes the hole where a client that crashes/lies between the presigned PUT and finalize
# would create a version + chunk rows for bytes that never arrived — permanent hydration
# 404s, with dedup then reporting the phantom chunk "present").
#
# OFF by default, because the check (a) costs one storage HEAD per first-seen chunk on the
# write hot path, and (b) only makes sense when the client uploads to the SAME store the
# server verifies. In production (STORAGE_BACKEND=s3) presigned uploads land in the bucket
# the server checks, so operators should enable it with SYNC_VERIFY_FINALIZE=1. The
# sync-engine integration harness deliberately moves bytes through a decoupled data plane
# (SharedDirIO), so it leaves this off and trusts the client, as the v1 path did originally.
Rails.application.config.x.verify_finalize = ENV.fetch("SYNC_VERIFY_FINALIZE", "0") == "1"
