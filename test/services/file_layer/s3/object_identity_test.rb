require "test_helper"

module FileLayer
  class S3
    # The identity ladder: what content_hash/content_token MEAN for an S3 object.
    #
    # Pure logic, no client, no network -- which is the point. This is where both of the
    # phase's silent-data-loss shapes live, so it is tested exhaustively and in isolation.
    class ObjectIdentityTest < ActiveSupport::TestCase
      # S3 wraps every ETag in LITERAL double quotes, in list, head, AND put responses.
      # Store the quoted form once and the unquoted form somewhere else and they never
      # compare equal: every object looks changed on every scan, move-pairing never pairs,
      # and every rename becomes delete+create -- breaking every attachment, every pass.
      # A pair of quotes; the phase's headline promise, silently inverted.
      test "a single-part ETag IS the md5, and the quotes S3 wraps it in are stripped" do
        id = ObjectIdentity.for(etag: %q("d41d8cd98f00b204e9800998ecf8427e"))
        assert_equal "md5:d41d8cd98f00b204e9800998ecf8427e", id
        assert_not_includes id, '"', "the quotes must never reach the database"
      end

      test "an unquoted ETag is accepted too - normalization is not quote-dependent" do
        assert_equal "md5:d41d8cd98f00b204e9800998ecf8427e",
                     ObjectIdentity.for(etag: "d41d8cd98f00b204e9800998ecf8427e")
      end

      # A multipart ETag is md5-of-part-md5s + "-N". It is NOT content-determined: the same
      # bytes with a different part size give a different ETag. So it is demoted to the
      # etag: rung, which is a sound content-STATE token (it changes iff the bytes change)
      # but an unsound content IDENTITY (moves degrade to delete+create).
      test "a multipart ETag is demoted to the etag rung, not passed off as an md5" do
        id = ObjectIdentity.for(etag: %q("9bb58f26192e4ba00f01e2e7b136bbd8-5"))
        assert_equal "etag:9bb58f26192e4ba00f01e2e7b136bbd8-5", id
        assert_not id.start_with?("md5:"), "a part-checksum must never be labelled a content hash"
      end

      # Rung 2: a FULL_OBJECT sha256 IS content-determined, so it outranks the ETag.
      test "a FULL_OBJECT sha256 checksum outranks the ETag" do
        id = ObjectIdentity.for(etag: %q("9bb58f26192e4ba00f01e2e7b136bbd8-5"),
                                checksum_sha256: "n4bQgYhMfWWaL+qgxVrQFaO/TxsrC4Is0V1sFbDwCgg=",
                                checksum_type: "FULL_OBJECT")
        assert_equal "sha256:n4bQgYhMfWWaL+qgxVrQFaO/TxsrC4Is0V1sFbDwCgg=", id
      end

      # A COMPOSITE sha256 is a checksum-of-checksums -- the SAME shape problem as a
      # multipart ETag, wearing a more trustworthy name. Using it as an identity would
      # reintroduce the exact bug the multipart demotion above exists to prevent.
      test "a COMPOSITE sha256 is NOT an identity and must not be used as one" do
        id = ObjectIdentity.for(etag: %q("9bb58f26192e4ba00f01e2e7b136bbd8-5"),
                                checksum_sha256: "abc123=",
                                checksum_type: "COMPOSITE")
        assert_equal "etag:9bb58f26192e4ba00f01e2e7b136bbd8-5", id
        assert_not id.start_with?("sha256:")
      end

      # A single-part object's md5 ETag is content-determined and free; a FULL_OBJECT
      # sha256 is content-determined and costs a HEAD. Both are valid identities, so
      # rung order between them is arbitrary EXCEPT that it must be deterministic --
      # two scans disagreeing about one object's identity would unpair every move.
      test "the ladder is deterministic when several rungs apply" do
        args = { etag: %q("d41d8cd98f00b204e9800998ecf8427e"),
                 checksum_sha256: "n4bQ=", checksum_type: "FULL_OBJECT" }
        assert_equal ObjectIdentity.for(**args), ObjectIdentity.for(**args)
      end

      # LANDMINE 1, at its source. The Reconciler DROPS a nil-hash observation entirely --
      # verified by probe: it is never indexed, no error, no log. That is survivable on a
      # share (a nil hash is an EACCES blip; the next pass succeeds) and permanent for S3.
      # So the ladder must be TOTAL: every object gets an identity, or it does not exist.
      test "the ladder is TOTAL - an object with only an ETag still gets an identity" do
        assert ObjectIdentity.for(etag: %q("abc-99")).present?
        assert ObjectIdentity.for(etag: "abc").present?
      end

      # An object with NO etag at all should not happen (S3 always sends one), but if a
      # store omits it, returning nil would silently un-index the object. Refuse loudly:
      # a bug we can see beats a file that quietly is not there.
      test "an object with no ETag raises rather than returning nil" do
        err = assert_raises(ArgumentError) { ObjectIdentity.for(etag: nil) }
        assert_match(/etag/i, err.message)
        assert_raises(ArgumentError) { ObjectIdentity.for(etag: "") }
      end

      test "content-determined identities are distinguishable from weak ones" do
        assert ObjectIdentity.content_determined?("md5:d41d8cd98f00b204e9800998ecf8427e")
        assert ObjectIdentity.content_determined?("sha256:n4bQ=")
        assert_not ObjectIdentity.content_determined?("etag:abc-5")
      end

      # ---------------------------------------------------------------------------------
      # Below this line: decisions the plan left open. Each is argued in the implementation.
      # ---------------------------------------------------------------------------------

      # The plan defines "single-part" as "no dash" and stops there. But "no dash" is not
      # "is an md5": a real single-part ETag is 32 lowercase hex. S3-COMPATIBLE stores are
      # what this backend is aimed at (SeaweedFS/MinIO/Ceph), and they are free to emit an
      # ETag in any shape they like -- the plan's own totality test hands us "abc". Labelling
      # that `md5:` is exactly the class of lie the namespacing exists to prevent: it claims
      # to a future reader, and to any code that trusts the prefix, that this value is the
      # MD5 of the bytes. It is not; we have no idea what it is. Demote it to `etag:`, which
      # is the honest answer -- a sound state token, an unsound identity.
      test "an ETag that is not 32 hex is NOT labelled md5, however dash-free it is" do
        assert_equal "etag:abc", ObjectIdentity.for(etag: "abc")
        assert_equal "etag:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
                     ObjectIdentity.for(etag: %q("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")),
                     "32 chars is not 32 HEX chars"
        assert_equal "etag:d41d8cd98f00b204e9800998ecf8427",
                     ObjectIdentity.for(etag: "d41d8cd98f00b204e9800998ecf8427"),
                     "31 hex is not an md5"
      end

      # Uppercase hex is still an md5, but it must normalize -- storing D41D... once and
      # d41d... elsewhere is Landmine 2 wearing a different hat: the same bytes, two
      # identities, move-pairing broken.
      test "an uppercase ETag normalizes to one canonical md5 identity" do
        assert_equal ObjectIdentity.for(etag: "d41d8cd98f00b204e9800998ecf8427e"),
                     ObjectIdentity.for(etag: %q("D41D8CD98F00B204E9800998ECF8427E"))
      end

      # A sha256 with no checksum_type at all is NOT usable: the whole point of rung 2 is
      # that FULL_OBJECT is what makes it content-determined. Absent the type we cannot tell
      # a full-object checksum from a composite one, and guessing wrong is the multipart bug.
      test "a sha256 with no checksum_type is not trusted as an identity" do
        id = ObjectIdentity.for(etag: %q("9bb58f26192e4ba00f01e2e7b136bbd8-5"),
                                checksum_sha256: "n4bQ=")
        assert_equal "etag:9bb58f26192e4ba00f01e2e7b136bbd8-5", id
      end

      test "a blank sha256 falls through to the ETag rungs rather than yielding sha256:" do
        assert_equal "md5:d41d8cd98f00b204e9800998ecf8427e",
                     ObjectIdentity.for(etag: %q("d41d8cd98f00b204e9800998ecf8427e"),
                                        checksum_sha256: "", checksum_type: "FULL_OBJECT")
      end

      # content_determined? is asked about values read back from nodes.content_hash -- a
      # column SHARED with share mode, which stores a BARE Digest::SHA256 hexdigest with no
      # prefix. Unknown shape => false. That is the conservative direction: it under-promises
      # ("moves may not be detectable"), where the reverse would promise pairing we cannot do.
      test "an unrecognized or blank identity is not claimed as content-determined" do
        assert_not ObjectIdentity.content_determined?(nil)
        assert_not ObjectIdentity.content_determined?("")
        assert_not ObjectIdentity.content_determined?(
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        ), "a bare share-mode hexdigest is not an S3 identity; do not answer for it"
      end
    end
  end
end
