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
  # THE SECOND INSTANCE IS A CLOBBER — write/move/undelete onto a name that is already taken —
  # and it is here rather than in a class of its own BECAUSE OF THE AXIS BELOW, which is the only
  # reason the taxonomy is worth having. "Unsupported" reads oddly for it at first glance (share
  # and s3 support writing perfectly well; they refuse THIS one), and that reading is the "how
  # unsupported" axis this comment rejects. On the real axis a clobber and a directory delete are
  # the SAME shape: the client is wrong, it is knowable only per-path at runtime, no per-deployment
  # capability can gate it, and the caller could have made the request differently (pick another
  # name). The suffix already says which of the two is unsupported — the OPERATION, not the file.
  #
  # These raised NotFound until the Phase 4 follow-up, so a duplicate-name upload told the user
  # "File not found." about a file that was demonstrably there — the one thing NotFound must never
  # say. FetchError would have been worse, not better: it is the RETRYABLE answer, and retrying a
  # clobber fails identically forever.
  #
  # THE THIRD INSTANCE (Task 8) IS A MALFORMED UPLOAD MANIFEST — `Chunk#begin_upload` re-raises
  # `Sync::Commit::InvalidManifest` (a chunk hash that isn't 64-hex, or a manifest over
  # MAX_MANIFEST_CHUNKS) as this class rather than minting a fourth one. It fits the same axis as
  # the first two: the CLIENT sent something wrong, knowable only by reading THIS request, no
  # `Capabilities` flag could have gated it in advance, and a different request (a valid manifest)
  # would succeed. It costs nothing new, either — FilesController's existing
  # `rescue_from FileLayer::UnsupportedOperation` already renders `{ error: e.message }` at 422,
  # byte-identical to what a per-action `rescue Sync::Commit::InvalidManifest` used to render, so
  # closing that seam needed no new rescue at all, only deleting the redundant old one.
  #
  # If a caller ever needs to tell a clobber FROM a directory delete FROM a bad manifest — say, to
  # offer "rename and retry" for one and not the others — the answer is a SUBCLASS of this, not a
  # sibling: every existing rescue keeps working and the 422 mapping is unchanged. Nothing branches
  # on which instance it is today, and the message already distinguishes them for the human who
  # reads it.
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

  # A `write(replace: true, expect_token:)` found the STORE holding content the caller did not name
  # — someone changed the file between the editor rendering it and Save. Refused with nothing
  # written, which is the same answer a clobber gets and for the same reason: on a current-state-only
  # backend the overwritten bytes are gone for good.
  #
  # A SUBCLASS RATHER THAN A SIBLING, which is §14a's rule for exactly this shape ("if a caller must
  # branch, the answer is a subclass"). A caller that does not branch — every door that passes no
  # `expect_token`, plus any future one that forgets — still gets the port's ordinary
  # UnsupportedOperation mapping (422, "the request is wrong for this node"), so a missed rescue
  # degrades to a refusal rather than to a 500. Maker::TextSave is the caller that MUST branch: it
  # has a stale answer of its own (409 + "reload to see the current version"), and rescuing the
  # PARENT there would swallow the create-path clobber refusal that means something else.
  #
  # NOT FetchError, though both leave the store untouched: FetchError is the RETRYABLE answer and
  # this never succeeds on retry — the caller has to re-read the file first.
  StaleContent = Class.new(UnsupportedOperation)

  # A `#finalize_upload` was asked to seal a commit whose manifest names chunks storage never
  # received — the browser's presigned PUTs didn't all land (or, for a server-side caller, a bug
  # skipped one) before finalize was called. Task 8: `Chunk#finalize_upload` re-raises
  # `Sync::Commit::ChunksMissing` as this, carrying the same `hashes`, rather than reusing
  # UnsupportedOperation above — unlike a bad manifest (Chunk#begin_upload; see UnsupportedOperation's
  # own comment), this needs to carry STRUCTURED DATA back to the caller (both existing callers of
  # the old Sync::Commit::ChunksMissing read `.hashes` to tell the browser exactly which chunks to
  # retry), and no existing member of this vocabulary carries anything beyond a message. Minting a
  # new class here is the same call TrashEntry made against FileInfo: reuse would mean silently
  # dropping data a real caller needs, not a saving of vocabulary.
  #
  # RETRYABLE, but deliberately not FetchError: FetchError means "the file's bytes may exist, we
  # just could not reach them right now" — this means the bytes were never confirmed to exist at
  # all, which is a different fact the caller (and the human reading the error) should be told
  # plainly rather than as a generic fetch hiccup.
  ChunksMissing = Class.new(StandardError) do
    attr_reader :hashes

    def initialize(hashes)
      super("chunks missing")
      @hashes = hashes
    end
  end

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
      # THE DEFAULT IS `share`, AND IT USED TO BE `chunk`. Embedded chunk was retired in Arc D
      # Part 2, so the old default named a backend that no longer exists — every context that did
      # not set LIBRARY_BACKEND explicitly got `NameError: uninitialized constant FileLayer::Chunk`
      # from inside this method, several call frames from anything that mentioned a backend.
      #
      # `share` rather than `chunk_remote`, deliberately, even though chunk_remote is now the
      # primary: it is the only HERMETIC backend left. chunk_remote resolves every read and write
      # against a standalone sync server, so defaulting to it would mean a developer who has not
      # set anything gets a WAN/localhost dependency and a connection error instead of a working
      # library. Nothing in production relies on this default either way — all four Kamal
      # destinations set LIBRARY_BACKEND explicitly, and LibraryBackendCheck refuses to boot on a
      # value it does not recognise — so this governs dev and test only, where hermetic wins.
      #
      # THE RESOLVED VALUE IS PASSED TO THE GUARD, NEVER LEFT FOR IT TO RE-DERIVE — and it was,
      # until 2026-08-26. `LibraryBackendCheck.check!` takes `backend:` defaulted to
      # `env.fetch("LIBRARY_BACKEND", "chunk")`, and calling it with NO ARGUMENTS made it re-read
      # ENV with a default of its own that had drifted from this one: Arc D Part 2 changed the
      # line above from `chunk` to `share` and left the guard's behind on a value this method now
      # REFUSES. With LIBRARY_BACKEND unset the two disagreed — this method built a Share, the
      # guard matched no `when` arm and returned having checked nothing, and `Share.new`'s
      # `ENV.fetch("LIBRARY_PATH")` raised a bare KeyError naming no setting. So THE ONE BACKEND
      # REACHABLE WITHOUT SETTING LIBRARY_BACKEND WAS THE ONE THE GUARD NEVER CHECKED, which is
      # the configuration a fresh clone has: it broke `bin/ci setup`, several frames away, inside
      # the PurgeRepoMetadataNodes migration asking FileLayer.current for a capability.
      #
      # FIXED HERE RATHER THAN IN THE GUARD'S OWN DEFAULT, and that is not a stylistic pick —
      # `check!` is ALSO called with no arguments by config/initializers/library_backend_check.rb,
      # where the no-arg default governs whether an unconfigured dev box BOOTS. Measured both
      # ways: making that default `share` refuses the boot of any dev box with nothing set, so
      # `bin/setup` fails one step EARLIER instead of being fixed. The factory knows which backend
      # it resolved; the initializer is asking a genuinely different question. Telling beats
      # re-deriving — see also Library::ScanJob.scan_all!, which asks this factory rather than
      # keeping a third copy of the same ENV read.
      backend = ENV.fetch("LIBRARY_BACKEND", "share")
      case backend
      when "share"
        # Validate before constructing: Share.new defaults to ENV.fetch("LIBRARY_PATH"), which
        # raises a bare KeyError naming nothing. The boot guard normally catches this first, but
        # it is skipped in the test env and reads ENV once at boot — so the factory asks too, and
        # the operator gets the same explanation either way.
        LibraryBackendCheck.check!(backend:)
        Share.new
      when "s3"
        # Validate before constructing, for the same reason as share and a sharper one: S3.from_env
        # fetches five knobs, so a bare KeyError would name exactly ONE of them and the operator
        # would learn the rest one restart at a time. check! names them all at once. It must be
        # asked HERE and not left to the boot guard alone — the guard is skipped in the test env
        # and reads ENV once at boot.
        LibraryBackendCheck.check!(backend:)
        S3.from_env
      # THE LAST STEP OF STAGE 4, AND IT IS DELIBERATELY THE LAST. ChunkRemote landed over six PRs
      # with no arm here, so a half-built adapter was never reachable by any deployment -- an
      # unknown LIBRARY_BACKEND raises, which is the honest answer for a backend that does not work
      # yet. The arm is what turns twelve implemented verbs into something an operator can select.
      #
      # `check!` for the same reason S3 asks: ChunkRemote's transport fetches CHUNK_REMOTE_URL
      # lazily, and FileLayer::ChunkRemote::Provisioning fetches SYNC_ADMIN_TOKEN just as lazily to
      # auto-provision a library on a user's first write -- so without this call, either missing
      # knob would surface as a KeyError/FetchError on somebody's first request rather than at boot,
      # and name only one of the two. (Not CHUNK_REMOTE_TOKEN: Arc C moved ordinary per-user traffic
      # off that single process-wide credential entirely -- lib/library_backend_check.rb's
      # CHUNK_REMOTE_REQUIRED has the full history.)
      when "chunk_remote"
        LibraryBackendCheck.check!(backend:)
        ChunkRemote.new
      else
        raise ArgumentError, "unknown LIBRARY_BACKEND #{ENV['LIBRARY_BACKEND'].inspect}"
      end
    end
  end
end
