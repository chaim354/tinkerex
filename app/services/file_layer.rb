# The file-layer port: the seam between the maker layer (projects/inventory/BOM/previews)
# and whatever actually holds the bytes. Adapters: Chunk (the sync engine's content-addressed
# chunk store), and — in later phases — Share (a mounted directory) and S3 (the user's bucket).
#
# Selected per deployment via LIBRARY_BACKEND, mirroring Storage::ChunkStore.current.
# See docs/superpowers/specs/2026-07-14-maker-file-layer-split-design.md.
module FileLayer
  # The file/version genuinely isn't there. TERMINAL: retrying won't help, so a preview job
  # marks the preview "failed".
  NotFound = Class.new(StandardError)

  # A TRANSIENT failure reaching the bytes: a 403 (auth/creds blip), a 5xx, a network error,
  # or (later) an unmounted share. Distinct from NotFound on purpose — the bytes may well
  # exist; we just couldn't read them right now, so the caller should RETRY rather than mark
  # the file permanently broken. This distinction was written for a real production incident
  # where a 403 during a chunk-store creds outage was swallowed as "missing chunk".
  FetchError = Class.new(StandardError)

  # Cap to protect the job host when reading a whole file into memory. Port-wide: it applies
  # to any backend, not just the chunk store.
  MAX_BYTES = 256 * 1024 * 1024
end
