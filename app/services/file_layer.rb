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

  # This backend cannot do this op TO THIS NODE, and no retry or reconfiguration changes that:
  # share-mode delete refuses a directory (it would strand the children's nodes). A CLIENT
  # condition — the user clicked delete on a folder — so Phase 4 maps it to 409/422.
  #
  # Distinct from NotImplementedError, and the axis is not "how unsupported": it is WHO IS
  # WRONG and WHEN YOU CAN KNOW.
  #
  #   NotImplementedError -> the DEPLOYMENT is mis-wired (LIBRARY_BACKEND=chunk got a `write`).
  #                          Knowable from FileLayer.current.class before the call, so it is
  #                          capability-gateable and never user-triggered. Phase 4: 501.
  #   UnsupportedOperation -> the REQUEST is wrong (a user clicked delete on a folder). Knowable
  #                          only per-node at runtime, so Capabilities — which is per-DEPLOYMENT
  #                          — cannot gate it. Phase 4: 409/422.
  #
  # A StandardError on purpose. NotImplementedError is a ScriptError, so a caller's
  # `rescue StandardError` (GeneratePreviewJob's shape) does NOT catch it — right for a wiring
  # bug that should reach a developer, wrong for ordinary user input, which would otherwise
  # propagate uncaught and page on-call because someone deleted a folder.
  #
  # NOT named `Unsupported`, on purpose: Maker::GeneratePreviewJob::Unsupported already exists
  # and means a genuinely different thing — "no preview renderer for .step", which is TERMINAL
  # and correct. This one is a live request a caller could have made differently. Phase 4 has to
  # map them to different answers (this → 409/422; the job's → its terminal status), and two
  # classes named `Unsupported` meaning opposite things is how that mapping gets written wrong.
  # The suffix says which of the two is unsupported: the OPERATION, not the file.
  UnsupportedOperation = Class.new(StandardError)

  # Cap to protect the job host when reading a whole file into memory. Port-wide: it applies
  # to any backend, not just the chunk store.
  MAX_BYTES = 256 * 1024 * 1024

  class << self
    attr_writer :current

    # The adapter for THIS deployment. One backend per deployment (spec decision 1): an
    # instance is the sync product (chunk) or the web-over-your-own-storage product
    # (share/s3), never both.
    def current
      @current ||= build
    end

    def reset!
      @current = nil
    end

    def build
      case ENV.fetch("LIBRARY_BACKEND", "chunk")
      when "chunk" then Chunk.new
      when "share"
        # Validate before constructing: Share.new defaults to ENV.fetch("LIBRARY_PATH"), which
        # raises a bare KeyError naming nothing. The boot guard normally catches this first, but
        # it is skipped in the test env and reads ENV once at boot — so the factory asks too, and
        # the operator gets the same explanation either way.
        LibraryBackendCheck.check!
        Share.new
      when "s3"
        # Validate before constructing, for the same reason as share and a sharper one: S3.from_env
        # fetches five knobs, so a bare KeyError would name exactly ONE of them and the operator
        # would learn the rest one restart at a time. check! names them all at once. It must be
        # asked HERE and not left to the boot guard alone — the guard is skipped in the test env
        # and reads ENV once at boot.
        LibraryBackendCheck.check!
        S3.from_env
      else
        raise ArgumentError, "unknown LIBRARY_BACKEND #{ENV['LIBRARY_BACKEND'].inspect}"
      end
    end
  end
end
