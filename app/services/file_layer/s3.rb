module FileLayer
  # The user's own S3-compatible bucket as a library: no chunks and no versions -- the object
  # IS the truth (spec decision 3, the same trade as Share). Phase 3.
  #
  # THIS FILE IS THE NAMESPACE, and it has to exist for that reason alone before it has any
  # behavior. Zeitwerk builds an implicit namespace from a DIRECTORY as a *module*, so with
  # `app/services/file_layer/s3/` present and no `s3.rb`, `FileLayer::S3` resolves to a module
  # and every `class S3` reopening it -- in object_identity.rb and in the tests -- dies with
  # "S3 is not a class (TypeError)". Verified, not reasoned: that is the exact error.
  #
  # So the ladder's namespace cannot be declared by the ladder's own file. This file must remain
  # `class S3`, not `module S3`, for that reason — see the ladder in s3/object_identity.rb.
  class S3
    # Mirrors Storage::S3ChunkStore.from_env's SHAPE, deliberately without touching or subclassing
    # it: that class is the SYNC engine's chunk store, keyed by CHUNK_*, and a library pointed at
    # the user's own bucket is a different deployment concern that must be configurable
    # independently. Same shape so an operator who has configured one can configure the other.
    #
    # The knobs are validated by LibraryBackendCheck.check! BEFORE this runs (FileLayer.build calls
    # it), which is what makes these fetches' bare KeyError unreachable in practice — the guard
    # names every missing knob at once instead of one per restart.
    def self.from_env(env = ENV)
      new(
        bucket:            env.fetch("LIBRARY_S3_BUCKET"),
        region:            env.fetch("LIBRARY_S3_REGION", "auto"),
        access_key_id:     env.fetch("LIBRARY_S3_ACCESS_KEY_ID"),
        secret_access_key: env.fetch("LIBRARY_S3_SECRET_ACCESS_KEY"),
        endpoint:          env["LIBRARY_S3_ENDPOINT"],
        prefix:            env["LIBRARY_S3_PREFIX"]
      )
    end

    attr_reader :bucket, :prefix, :client

    # `client:` is the TEST SEAM: injecting a stubbed Aws::S3::Client is what lets the adapter's
    # suite run hermetically, with no network and no credentials. Defaulted from the other args so
    # production never passes it.
    #
    # NOTHING HERE MAY TOUCH THE NETWORK. The factory runs this at boot, so a construct-time
    # round-trip would put a third party's uptime in our boot path — the same rule the boot guard
    # keeps, and it would be pointless to hold there and break here. Verified against the real
    # SDK: Aws::S3::Client.new with a closed-port endpoint constructs without connecting (it is
    # lazy), and presigning is local HMAC.
    def initialize(bucket:, region:, access_key_id:, secret_access_key:, endpoint: nil,
                   prefix: nil, client: nil)
      @bucket = bucket
      # Normalized HERE, once, because it is a CONFIG concern: "models/" and "models" are the same
      # intent typed two ways, and letting both through means every key-composing caller (Task 4
      # onward) either strips it again or silently addresses a different prefix than its neighbour.
      # Blank ("" or unset) means the whole bucket, which is a legitimate choice, not a mistake.
      @prefix = prefix.presence&.sub(%r{/+\z}, "").presence
      @client = client || build_client(region:, access_key_id:, secret_access_key:, endpoint:)
    end

    # THE ONE BACKEND WHERE presignable IS TRUE AND versioned IS FALSE — and that combination is
    # the point of this adapter, not an oversight.
    #
    # Every other backend has the two agreeing (chunk: true/true; share: false/false), so a reader
    # could reasonably infer they co-vary and collapse one into the other. S3 is the counterexample
    # that forbids it. They answer unrelated questions:
    #
    #   versioned?   -> can we hand back OLD bytes? NO. The object IS the truth; the user's own
    #                   overwrite in the AWS console destroys what was there (spec decision 3), so
    #                   CLAUDE.md §5's "keep versions so restore always works" does NOT survive
    #                   here. Restore stays a chunk-mode feature.
    #   presignable? -> can we hand back a URL instead of proxying the bytes through Rails? YES.
    #                   A bucket has a URL signer, which is exactly what a mounted directory lacks
    #                   (hence Share's false). So §15's "keep bytes out of Rails" DOES survive
    #                   here — and it survives precisely where it was aimed, at managed/WAN egress.
    #                   Phase 4's Redirect is built on this being true.
    #
    # syncable? is false: this is the web-over-your-own-storage product, with no sync engine, no
    # changelog and no devices (§10 tripwire).
    def capabilities
      Capabilities.new(versioned: false, syncable: false, presignable: true)
    end

    private

    def build_client(region:, access_key_id:, secret_access_key:, endpoint:)
      # Required lazily, matching Storage::S3ChunkStore: the gem is `require: false` in the
      # Gemfile, so a chunk- or share-mode deployment never loads it. An injected `client:` skips
      # this entirely, which is what keeps the adapter's tests free of the dependency too.
      require "aws-sdk-s3"
      opts = { region:, access_key_id:, secret_access_key:, force_path_style: true }
      # force_path_style: matches S3ChunkStore. SeaweedFS/MinIO need it, and R2 accepts it.
      opts[:endpoint] = endpoint if endpoint.present?
      Aws::S3::Client.new(**opts)
    end
  end
end
