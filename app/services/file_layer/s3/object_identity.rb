module FileLayer
  class S3
    # What `content_hash` / `content_token` MEAN for an S3 object.
    #
    # An S3 object has no content hash you can get for free, and the port asks two different
    # questions of one value:
    #
    #   content_token -- a content-STATE token (spec 3.1). Previews key on it; it must change
    #                    iff the bytes change. Explicitly opaque; it need not be a hash.
    #   content_hash  -- the move-pairing key. Library::Reconciler pairs a vanished path with a
    #                    new one by (content_hash, size), which is what makes a rename keep its
    #                    node_id and every attachment on it survive. This one must be content-
    #                    DETERMINED: the same bytes at a new key must produce the same value.
    #
    # An ETag answers the first perfectly and the second only sometimes, so one namespaced value
    # serves both by a strength ladder. The namespacing is load-bearing, not decoration: "abc-5"
    # sitting in a column called content_hash is a lie unless it says what it is. A reader must
    # not compare an md5: against a sha256: and conclude the bytes differ, nor mistake an etag:
    # for a content hash.
    #
    #   sha256:<b64>  rung 1  a FULL_OBJECT checksum. Content-determined. Costs a HEAD.
    #   md5:<hex>     rung 2  a single-part ETag IS the md5. Content-determined. Free.
    #   etag:<raw>    rung 3  anything else. NOT content-determined; moves degrade to
    #                         delete+create -- a missed rename, never a wrong pairing.
    #
    # THE LADDER IS TOTAL BY CONSTRUCTION -- it never returns nil, and that is a data-loss
    # guard, not tidiness. Reconciler#plan_moves does
    #
    #     candidates = unmatched.filter_map { |o| (h = hash_for(o)) && [ o, h ] }
    #
    # so a nil-hash observation is DROPPED from candidates -- and candidates is what becomes the
    # leftovers that get indexed. A nil hash means the object is never indexed at all: no error,
    # no log, no node. Its comment reasons "the next pass indexes it properly", which is true for
    # a share (a nil hash there is an EACCES blip) and PERMANENTLY false for S3, where an object
    # with no derivable checksum has none next pass either. Nothing from this ladder may reach
    # that branch, so the ladder answers for every object it is ever shown.
    #
    # Why the failure direction is acceptable where the ladder is weak: an ETag collision
    # requires an MD5 collision, and pairing additionally requires equal size, so the errors are
    # false NEGATIVES (a missed move) and never false POSITIVES (two unrelated files fused into
    # one identity, taking each other's attachments). The safe direction.
    class ObjectIdentity
      # A real single-part ETag is the MD5: exactly 32 hex digits. Case-insensitive here only so
      # `for` can canonicalize -- see the downcase in the md5 rung.
      MD5_ETAG = /\A\h{32}\z/

      CONTENT_DETERMINED_PREFIXES = %w[ md5: sha256: ].freeze

      class << self
        # -> String, always. Never nil (see the class header).
        def for(etag:, checksum_sha256: nil, checksum_type: nil)
          tag = normalize_etag(etag)

          # Rung 1. FULL_OBJECT is the whole reason this rung is trustworthy, so the TYPE is
          # required, not the checksum alone. A COMPOSITE sha256 is a checksum-of-checksums --
          # the same shape problem as a multipart ETag wearing a more trustworthy name -- and
          # using it as an identity would reintroduce exactly the bug the multipart demotion
          # below exists to prevent. Absent the type we cannot tell the two apart, and guessing
          # is that bug. Fall through instead.
          if checksum_type == "FULL_OBJECT" && checksum_sha256.present?
            return "sha256:#{checksum_sha256}"
          end

          # Rung 2. A single-part ETag IS the md5 of the bytes.
          #
          # "Single-part" is 32 hex, NOT merely "has no -N suffix". The dash-free test would
          # label any dash-free string an md5, and this backend is aimed at S3-COMPATIBLE stores
          # (SeaweedFS/MinIO/Ceph) that are free to emit an ETag in any shape they like. Calling
          # an unknown string `md5:` is the same class of lie the namespacing exists to prevent:
          # it promises the reader, and any code trusting the prefix, that this value is the MD5
          # of the bytes. A multipart ETag fails this test anyway -- `-` is not a hex digit -- so
          # 32-hex subsumes the dash rule rather than competing with it.
          #
          # Downcased because we compare these against md5s WE compute (Digest::MD5.hexdigest is
          # lowercase). A store answering in uppercase would otherwise give the same bytes two
          # identities, which is Landmine 2 wearing a different hat.
          return "md5:#{tag.downcase}" if MD5_ETAG.match?(tag)

          # Rung 3. Sound state token, unsound identity. Stored verbatim: it is opaque, so
          # mangling it (case, punctuation) could only ever lose information.
          "etag:#{tag}"
        end

        # Can `identity` pair a move? Asked by Library::S3Observer, once per scan, to count the
        # objects on rung 3 and WARN — so an operator is told "moves are not detectable for N
        # objects in this bucket" rather than left to discover it when a rename orphans their
        # attachments. That is the method's only production caller, and the only one it needs:
        # the answer is advisory, and nothing branches on it.
        #
        # Unknown shapes answer false, deliberately. nodes.content_hash is SHARED with share
        # mode, which stores a bare Digest::SHA256 hexdigest with no prefix at all -- so this
        # method will be handed values it has no business judging. False is the conservative
        # direction: it under-promises ("we may not detect moves"), where the reverse would
        # promise pairing we cannot deliver.
        def content_determined?(identity)
          identity.to_s.start_with?(*CONTENT_DETERMINED_PREFIXES)
        end

        private

        # The ONE place the quotes come off. S3 wraps every ETag in literal double quotes, in
        # list, head AND put responses. Every caller normalizes through here or the quoted and
        # unquoted forms of one object's ETag coexist and never compare equal: every object looks
        # changed on every scan, move-pairing never pairs, and every rename becomes delete+create
        # -- breaking every attachment, on every pass. A pair of quotes; the headline promise
        # silently inverted.
        def normalize_etag(etag)
          tag = etag.to_s.strip
          tag = tag.delete_prefix('"').delete_suffix('"')

          # S3 always sends an ETag, so a blank one means a store is doing something we do not
          # model. Returning nil here would silently un-index the object (see the class header);
          # a bug we can see beats a file that quietly is not there.
          if tag.empty?
            raise ArgumentError, "etag is required to derive an object identity (got #{etag.inspect})"
          end

          tag
        end
      end
    end
  end
end
