# Whether v1 `POST /v1/commit/:id/finalize` performs a storage `exists?` check that the
# chunk bytes actually landed before creating the immutable version + changelog entry
# (closes the hole where a client that crashes/lies between the presigned PUT and finalize
# would create a version + chunk rows for bytes that never arrived — permanent hydration
# 404s, with dedup then reporting the phantom chunk "present").
#
# ON by default: in any real deployment the client PUTs to a presigned URL for the SAME
# store the server then checks (S3/R2, or the `local` backend's blob endpoint), so the
# exists?-check is meaningful and closes the hole. It costs one storage HEAD per
# *first-seen* hash only (already-known chunks are satisfied from the DB), so the write
# hot path pays nothing for dedup hits.
#
# Set SYNC_VERIFY_FINALIZE=0 to disable. The sync-engine test suites do exactly that,
# because they deliberately move chunk bytes through a decoupled transport (`SharedDirIO`,
# a shared-dir stand-in for the cloud) rather than the server's store: it keeps the
# engine-logic tests fast and, crucially, is the seam the fault tests wrap to inject
# offline/corrupt/counting transports (fault_injection.rs has no server at all). The real
# presigned data plane is covered at the right layer instead — two_device_e2e.rs and
# examples/presigned_roundtrip.rs use PresignedIO, and the two-device conformance scripts
# run STORAGE_BACKEND=local. The server's own v1 request tests upload to /dev/blobs and so
# exercise this check end-to-end with it ON.
Rails.application.config.x.verify_finalize = ENV.fetch("SYNC_VERIFY_FINALIZE", "1") == "1"
