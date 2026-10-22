module Library
  # Lists an S3-backed library's bucket and hands what it saw to the Reconciler.
  #
  # THE SIBLING OF Library::Scanner, NOT A SUBCLASS OF IT. This OBSERVES; Library::Reconciler
  # DECIDES — the same split, and the same decider. That reuse is the whole design, and it is worth
  # saying why rather than leaving it to look like laziness: every one of Phase 2a's bugs lived in
  # the code a second copy would have duplicated (the mass-deletion guard, the move-pairing,
  # revive-by-path). A second reconciler would be a second place for all of them.
  #
  # And the Scanner itself is NOT reusable, which is the other half of the same conclusion:
  # `Dir.children`, `lstat`, the symlink dispatch, `Pathname` — every line of it is a filesystem.
  # The spec (§9.3) says Phase 3 "reuses the scanner"; it cannot, and the Reconciler is the half it
  # actually meant. There is nothing to share between this class and the Scanner but the
  # vocabulary, which is Library::Observation, and the two skip-list constants, which are read from
  # the Scanner rather than re-typed.
  #
  # WHAT IS GENUINELY DIFFERENT HERE, in the order it bites:
  #
  #   1. A LISTING IS NOT A SNAPSHOT (see #paginate). It arrives in pages, and a failure on page 7
  #      of 40 is a well-formed lie that reads as a mass deletion. Hence complete-or-abort.
  #   2. S3 HAS NO DIRECTORIES (see #observe, #dir_chain). The tree is synthesized from key
  #      prefixes, and the shapes people use for "folder" have to be recognized as such.
  #   3. IDENTITY IS FREE (see #file_observation). The ETag is in the listing, so the Reconciler's
  #      lazy hashing — right for a share, where identity costs a read — would mean downloading the
  #      bucket. Every observation carries its own content_hash and the reader is never called.
  class S3Observer
    # The Reconciler REQUIRES a `root:` or a `reader:` — "a root: or a reader: is required" — and
    # this observer legitimately needs neither: FileLayer::S3::ObjectIdentity is TOTAL, so every
    # observation carries its own content_hash and Reconciler#hash_for returns it verbatim without
    # ever consulting the reader.
    #
    # Two ways out of that, and the choice is not a coin flip. RELAXING the Reconciler's check to
    # "…or every observation carries a hash" would weaken a guard that exists precisely because a
    # caller who forgets gets silent data loss; it would cost an O(n) pass over what may be 2M
    # observations to answer a question only the constructor asks; and it would make an
    # unconditional invariant conditional for every observer that comes after.
    #
    # So: a reader that RAISES. It is not a placeholder and not a lie — it is a live assertion, in
    # production, that the full-egress bug has not reappeared. The ONLY path that can reach it is
    # an observation arriving with a nil content_hash, which for S3 means the ladder returned nil,
    # which is the one thing the ladder is built to never do (its class header explains that a nil
    # there makes an object PERMANENTLY invisible, not merely unpaired). If it ever does, the
    # alternative to this raise is Reconciler#hash_for quietly falling through to the reader and
    # DOWNLOADING the object to hash it — a full egress of the user's bucket, billed, to recompute
    # a value the listing already handed us. A loud raise beats a silent bill.
    #
    # test/services/file_layer/s3_test.rb's stand-in `scan!` uses exactly this lambda for exactly
    # this reason. The two being identical is the point: that helper stands in for this class.
    NEVER_READ = lambda do |rel|
      raise "Library::S3Observer supplies every content_hash from the listing, so the Reconciler " \
            "must never read an object to hash it (asked for #{rel.inspect}). Reaching this means " \
            "an observation carried a nil identity — FileLayer::S3::ObjectIdentity is total and " \
            "must never return one."
    end

    # Mirrors Scanner.call, including its reason for returning the observer rather than the
    # reconcile's result: a caller (Library::ScanJob) wants to ask #unreadable_dirs afterwards.
    # Matching the shape is deliberate — a second idiom for the same operation is how the two
    # observers start drifting.
    def self.call(user, adapter:, max_delete_pct: nil)
      new(user, adapter:, max_delete_pct:).tap(&:call)
    end

    # `adapter` is a configured FileLayer::S3 — it owns the client, the bucket and the prefix, and
    # asking it is what keeps the observer and the adapter addressing the SAME keyspace. Building a
    # second client from ENV here would be a second copy of the config, i.e. the drift itself.
    #
    # `max_delete_pct` is forwarded for Scanner's reason: it is the only thing that constructs a
    # Reconciler for an S3 library, so a knob it cannot reach is a knob only ENV-mutating tests can
    # use.
    def initialize(user, adapter:, max_delete_pct: nil)
      @user = user
      @adapter = adapter
      @max_delete_pct = max_delete_pct
    end

    # ALWAYS EMPTY, and that is an honest claim rather than a shrug — the Reconciler's own comment
    # demands the claim be made out loud, so here is the argument.
    #
    # `unreadable_dirs` means "here is where I could not look", and it works for the Scanner
    # because a failure there is SUBTREE-SCOPED: `Dir.children(secret)` raised, so everything under
    # `secret/` is unobserved and the Reconciler excludes exactly that subtree from `vanished_paths`
    # and from both sides of the guard's fraction.
    #
    # A listing has no such structure. A page boundary is an ARBITRARY KEY RANGE, not a subtree —
    # there is nothing to scope, and nothing to name. So this observer does not have a partial
    # state to report: #paginate either runs to completion (nothing is unobserved, and [] is
    # literally true) or raises (nothing is reconciled at all, and this is never read). The one
    # thing that must NOT happen is reporting the gap as `["."]`, which looks like the honest
    # answer and is the worst one available: `unobserved?` treats "." as "the root could not be
    # listed", `observable_live_paths` then rejects every path, and `guard_mass_deletion!` returns
    # early on `observable_count.zero?` — silently no-opping the entire reconcile. Refusing is
    # louder than pretending to look.
    #
    # Kept as a method rather than a constant so ScanJob can ask this observer the same question it
    # asks the Scanner, without knowing which one it holds.
    def unreadable_dirs = []

    def call
      # `observe` before `unreadable_dirs` is read, mirroring Scanner#call — here it is cosmetic
      # (the answer is a literal []), but the two classes reading the same way is worth more than
      # the line it saves.
      observations = observe
      Library::Reconciler.new(@user, observations:, unreadable_dirs:, max_delete_pct: @max_delete_pct,
                                     reader: NEVER_READ).call
    end

    # The whole of this class's own behavior, and public for the Scanner's reason: it is testable
    # against a stubbed client with no database at all.
    #
    # Returns dirs first, then files. The Reconciler partitions by `dir` and `ensure_dirs` sorts
    # shallowest-first regardless, so nothing DEPENDS on this order — which is exactly why it is
    # worth stating rather than leaving to be inferred: it is belt and braces, and a future reader
    # must not "discover" that the Reconciler relies on it and then preserve it somewhere else.
    def observe
      files = []
      dirs  = Set.new
      unpairable = 0

      each_object do |rel, obj, dir_marker|
        # A REPO IS ONE DIR NODE AND NO FILES, and here the dir node has to be INVENTED. The
        # Scanner has it easy: it meets a real `.git` directory, observes it, and simply declines
        # the descent. S3 has no directories at all — the tree in `nodes` is synthesized from key
        # prefixes — so the marker exists only as a prefix of the very keys we are dropping. Drop
        # them without recording it and `.git` would not exist on this backend, so the
        # working-tree question would have two answers across backends (§14a) and
        # Maker::AttachToProject's :in_working_tree would silently stop firing on an s3 deployment.
        # Library::RepoMetadata carries the argument for keeping the marker, and owns the
        # STRICTLY-BENEATH question this asks — the marker path itself must fall through, because
        # an object AT it is a `gitdir:` pointer file rather than a repo's metadata.
        #
        # SKIPPED HERE, SO IT CAN NEVER BE TOMBSTONED — the same property #indexable?'s skips have
        # and for the same reason: a key that never becomes an observation never becomes a
        # `vanished_path`, so the reconciler cannot read "we declined to index this" as "the user
        # deleted it". What makes this one safe to write anywhere is that the ancestor prefix IS
        # recorded, so the marker node it hangs off is observed on every pass.
        #
        # NOT IN #indexable?, where the other path-shape skips live: that predicate's rejects are
        # dropped outright and nothing downstream sees the key, but this skip has to RECORD
        # something before dropping. The prefix is the only evidence the repo exists.
        #
        # FIRST, BEFORE THE DIRECTORY-MARKER BRANCH, and that order is load-bearing rather than
        # tidy. A zero-byte folder object INSIDE the repo — `firmware/.git/objects/`, which any
        # console or sync tool may leave behind — reaches here as a directory marker, and that
        # branch would merge its whole ancestor chain: a dir node BENEATH `.git`, which is
        # precisely the content this skip exists to drop. Checked below it, this branch would
        # never see that key. (A `firmware/.git/` folder marker is not beneath anything, so it
        # falls through to that branch and synthesizes the same dir node either way.)
        if Library::RepoMetadata.internal?(rel)
          dirs.merge(dir_chain(Library::RepoMetadata.marker_prefix(rel)))
          next
        end

        if dir_marker
          # A directory-marker object IS positive evidence of a directory — including one with no
          # children at all, which nothing else in the listing would reveal. So it becomes a dir
          # observation rather than merely "not a file": the user made a folder in the console and
          # it should appear as one.
          dirs.merge(dir_chain(rel))
          next
        end

        o = file_observation(rel, obj)
        unpairable += 1 unless FileLayer::S3::ObjectIdentity.content_determined?(o.content_hash)
        files << o

        parent = File.dirname(rel)
        dirs.merge(dir_chain(parent)) unless parent == "."
      end

      warn_unpairable(unpairable)
      # LANDMINE 7 — ONE `rel_path`, TWO CONTRADICTORY OBSERVATIONS. `files` and `dirs` are built
      # as two independent collections with no shared key, but `rel_path` IS the Reconciler's key,
      # so a bucket holding both `<prefix>/cad` and `<prefix>/cad/x.stl` used to emit
      # Observation("cad", dir: false) AND Observation("cad", dir: true). A flat keyspace permits
      # that and an existing bucket is exactly this backend's stated on-ramp, so it is ordinary,
      # not pathological — and it must be resolved HERE, because the Reconciler is handed a list
      # and cannot tell a contradiction from two legitimate entries.
      #
      # Measured before this filter, on `cad` + `cad/x.stl`, steady across three passes: FOUR
      # UPDATEs per pass, forever (ensure_dirs tombstones the file and revives the dir;
      # match_live_paths tombstones the dir; create_or_revive! revives the file), net state
      # unchanged. A control library with no collision writes NOTHING. Worse than the churn:
      # `cad/x.stl` stays LIVE with `parent_node_id` pointing at the tombstoned dir node —
      # unreachable from the tree, and never repaired, because it is `unchanged?` and skipped.
      # None of it reaches the mass-deletion guard: both paths ARE observed, so `vanished_paths`
      # is empty and the tombstones come from kind-collision branches the guard does not count.
      # (An earlier account of this also claimed a redundant thumbnail enqueue every 15 minutes.
      # It does not happen — probed at ZERO jobs per steady-state pass, with a renderable
      # colliding name. The four writes are the whole cost; do not repeat the larger claim.)
      #
      # THE DIRECTION IS FORCED, NOT PREFERRED. Dropping the DIR instead breaks ancestor-closure
      # of `dirs`: `parent_id_for("cad")` then resolves to the FILE node and every descendant is
      # parented to a file. So the file observation is what goes.
      #
      # STATED CONSEQUENCE, because it is a real decision and not a tidy-up: the OBJECT at `cad`
      # is then not indexed at all — it has no node, and only this log line says so. That also
      # FLIPS the marker-only sub-case (an empty `cad/` marker beside a real `cad` object), where
      # today the FILE is what survives; after this the directory does. Accepted: a prefix with
      # children is positive evidence of a tree the whole catalog hangs off, and the alternative
      # loses that tree rather than one object. It is the standing objection at
      # object_identity.rb's ladder — an object silently never indexed — which is why it warns.
      shadowed, files = files.partition { |o| dirs.include?(o.rel_path) }
      warn_shadowed_by_dir(shadowed)
      dir_observations(dirs) + files
    end

    private

    # ONCE PER SCAN, WITH A COUNT AND A FEW KEYS — the `warn_unpairable` precedent below, for the
    # same reason: a bucket this backend targets can hold millions, and a line per object is how a
    # log stops being read. warn, not info: an object the user can see in their bucket has no node
    # in their library, and nothing else in this system would ever mention it.
    def warn_shadowed_by_dir(shadowed)
      return if shadowed.empty?

      sample = shadowed.first(3).map { |o| o.rel_path.inspect }.join(", ")
      Rails.logger.warn(
        "library s3 scan: #{shadowed.size} object(s) share a key with a directory prefix in this " \
        "bucket (#{sample}#{'...' if shadowed.size > 3}) — S3's keyspace is flat, so `cad` and " \
        "`cad/x.stl` can both exist, but a library path is one or the other. The directory wins " \
        "(its children need it as their parent) and these objects are NOT indexed: they will not " \
        "appear in the library until they are renamed or the colliding prefix is emptied."
      )
    end

    # THE ONE THING THE LADDER'S RUNG 3 CANNOT SAY FOR ITSELF. An `etag:` identity is not
    # content-determined, so a move of that object does not pair: the Reconciler sees the old path
    # vanish and a new one appear, tombstones one and mints the other, and every attachment on it
    # re-points to a new node_id. That is the SAFE direction (a missed rename, never a wrong
    # pairing — see the ladder's header), and it is silent, which is the problem: on such a bucket
    # the phase's headline promise — your attachments survive a reorganization — simply does not
    # hold, and nothing else in this system would ever mention it.
    #
    # THE SHAPE THAT MAKES THIS MORE THAN A MULTIPART FOOTNOTE: an SSE-KMS-encrypted object has a
    # 32-hex ETag that is NOT the content MD5. It takes rung 2 and gets stamped `md5:`, so this
    # count reads ZERO on a fully-KMS bucket while no move pairs at all — a re-encrypt on copy
    # changes the ETag. So a zero here is "nothing we can SEE", not "moves are fine". The warning
    # is correct where it fires and silent where it cannot; do not read it as a guarantee.
    #
    # ADVISORY: it does not raise and does not skip. An unpairable object is indexed, read, written
    # and deleted like any other — only its moves are invisible, and refusing the scan over that
    # would deny the user a library to punish their storage class.
    #
    # ONCE PER SCAN, WITH A COUNT, NEVER PER OBJECT: a bucket this backend targets can hold
    # millions, and a log line per object is how a log stops being read at all (the Scanner's own
    # argument for not logging its routine skips). warn, not info: it is a promise the operator was
    # made and is not getting.
    def warn_unpairable(count)
      return if count.zero?

      Rails.logger.warn(
        "library s3 scan: #{count} object(s) in this bucket have no content-determined identity " \
        "(a multipart ETag, or an ETag this store computes some other way) — moving or renaming " \
        "them will not be paired, so each one becomes a delete plus a create and any project " \
        "attachment, BOM link or tag on it re-points to the new file. Every other operation is " \
        "unaffected."
      )
    end

    # LANDMINE 4 — THE MOST IMPORTANT METHOD IN THIS FILE, and the one most likely to be
    # "simplified" into a data-loss bug.
    #
    # A multi-page listing IS NOT A SNAPSHOT. `list_objects_v2` pages (at 1000 keys on a real
    # store), and a failure on page 7 of 40 does not produce an error — it produces a listing. A
    # perfectly well-formed one, that is a LIE: it looks exactly like the user having deleted 82%
    # of their library. The Reconciler's mass-deletion guard cannot save us from it, because the
    # guard trusts its input completely BY DESIGN — `vanished_paths` is computed from the
    # observations it is handed, so an incomplete observation IS an absence to it.
    #
    # This is Phase 2a's `Pathname#find`/`EACCES` bug with a different spelling: an incomplete
    # observation rendering as absence. That one shipped through two reviews.
    #
    # So the rule is COMPLETE OR ABORT, and there is no third option — see #unreadable_dirs for why
    # the share's subtree-scoped mechanism has nothing to bite on here. Note that the guard is NOT
    # a backstop for this even when the numbers happen to trip it: a listing that dies on the LAST
    # page of a long one loses a small share of the library, lands UNDER the threshold, and gets
    # tombstoned silently. That is the realistic shape, and it is the one this method exists for.
    #
    # Scanner::UnsafeScan by name, reusing the class rather than minting a sibling: to an operator
    # these are one event ("the scan refused") and to a caller one decision (retry later; do not
    # treat this as the truth). Its own header says exactly that. ScanJob deliberately has no
    # retry_on for it, so this surfaces as one failed execution per scheduled run — visible, and
    # not a backoff loop.
    def paginate
      token = nil
      loop do
        resp = list_page(token)
        resp.contents.each { |obj| yield obj }

        break unless resp.is_truncated

        token = resp.next_continuation_token
        # Truncated but no token: the store has told us there is more and given us no way to ask
        # for it. That is an incomplete listing, so it takes the same exit as a failed page. Real
        # S3 cannot do this; an S3-COMPATIBLE store is not bound by that, and this backend points
        # at whatever the user runs (SeaweedFS/MinIO/Ceph). Cheaper to refuse than to discover it
        # as a mass deletion.
        if token.blank?
          raise Scanner::UnsafeScan,
                "the S3 listing reports more results but returned no continuation token — the " \
                "listing is incomplete and reconciling it would read as a mass deletion. Refusing."
        end
      end
    end

    def list_page(token)
      @adapter.client.list_objects_v2(
        bucket: @adapter.bucket, prefix: @adapter.listing_prefix, continuation_token: token
      )
    rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError => e
      # EVERY listing failure aborts, with no whitelist and no partial credit — the same fail-safe
      # direction FileLayer::S3#read argues at length, for the same reason: an S3-compatible store
      # may emit codes AWS never will, so the DEFAULT must be the safe answer. Here "safe" is
      # "reconcile nothing".
      #
      # e.class is in the message because a stubbed or real SDK error's `message` does not name the
      # code — the CLASS is the only place an operator learns WHICH failure this was.
      raise Scanner::UnsafeScan,
            "the S3 listing failed partway through (#{e.class}: #{e.message}) — a partial listing " \
            "is indistinguishable from a mass deletion, so nothing was reconciled. Refusing."
    rescue ArgumentError, EncodingError => e
      # A NON-UTF-8 KEY, ARRIVING AS A CRASH RATHER THAN AS DATA — verified against aws-sdk-s3
      # 1.226.0, not reasoned. `Aws::S3::Plugins::Http200Errors#check_for_error` force_encodes the
      # whole response body to UTF-8 and `match?`es it for "<Error>", so ONE key with an invalid
      # byte raises `ArgumentError: invalid byte sequence in UTF-8` out of `list_objects_v2` — the
      # page is lost before the parser runs and before #utf8_key's own skip can ever see it. The
      # force_encoding is unconditional for an ASCII-8BIT body (`ENCODINGS_TO_FIX`), and an
      # ASCII-8BIT body is what a real wire response is, so this is the PRODUCTION path and not a
      # stub artifact.
      #
      # EncodingError is the same event reached by the other door: the stubbed client serializes a
      # Ruby object graph into the response body and raises Encoding::UndefinedConversionError
      # instead. That door is hermetic-test-only, but both mean "this page could not be decoded",
      # both cost us the whole page, and enumerating which gem raises which class on which day is
      # exactly the fail-open whitelist FileLayer::S3#read argues against.
      #
      # Scoped to the CLIENT CALL alone, never around the processing loop, so this cannot swallow
      # an ArgumentError from our own code and mislabel a bug as a refusal.
      #
      # This is 2a's non-UTF-8 trap reborn one layer lower, and the honest answer is the same as
      # for any lost page: refuse. Not a skip — we do not have the key to skip, we have no page at
      # all. Naming the cause is the whole value of catching it: the bare ArgumentError, thrown
      # from inside a gem, names nothing an operator could act on.
      raise Scanner::UnsafeScan,
            "the S3 listing could not be decoded (#{e.class}: #{e.message}) — one or more keys in " \
            "this bucket are not valid UTF-8, which aws-sdk-s3 raises on before the listing can be " \
            "read. Nothing was reconciled. Refusing."
    end

    # Yields [rel_path, object, dir_marker?] for every key this library indexes — every skip lives
    # here, and that placement is load-bearing rather than tidy. A key skipped HERE can never reach
    # `vanished_paths`, so it can never be tombstoned. This is the Scanner's own argument for
    # skipping in the observer, and it transfers verbatim.
    def each_object
      paginate do |obj|
        rel = relative_key(obj.key)
        next if rel.nil?

        # LANDMINE 6 — the directory-marker object. The S3 console (and most tools) create a
        # "folder" as a ZERO-BYTE object with a TRAILING SLASH: `cad/`. Emit it as a file and you
        # index a phantom, because `File.basename("cad/")` is `"cad"`: a file node named `cad` at
        # storage_path "cad/", living beside the real dir node `cad`. Two live nodes with distinct
        # storage_path strings, so the partial unique index permits both — a phantom file in every
        # browse view, forever, that no delete resolves.
        # `dir_marker`, not `marker`: this file now also discusses the REPO marker (`.git`), and
        # one word for two unrelated things in one block is how a reader mixes them up.
        dir_marker = rel.end_with?("/")
        rel = rel.delete_suffix("/") if dir_marker
        next unless indexable?(rel)

        yield rel, obj, dir_marker
      end
    end

    # The inverse of FileLayer::S3#key_for_rel: a key is absolute in the bucket, a storage_path is
    # relative to the library. `listing_prefix` (with its trailing slash) is the adapter's, not a
    # second copy — "cad" must not match the sibling "cadence/…" keyspace, and that fact should
    # live in one place.
    #
    # The prefix filter is belt and braces given we LIST by that prefix, and it stays because it
    # costs nothing and the alternative — trusting a store's prefix filter to make storage_paths
    # relative to the right root — is trusting a third party with the shape of our own keys.
    def relative_key(key)
      key = utf8_key(key)
      return nil if key.nil?

      return key if listing_prefix.nil?
      return nil unless key.start_with?(listing_prefix)
      key.delete_prefix(listing_prefix)
    end

    # LANDMINE 6 — a key whose bytes are not UTF-8. Returns the key as a UTF-8 String, or nil to
    # skip it.
    #
    # This is 2a's exact trap: a non-UTF-8 name raises ArgumentError the moment anything touches it
    # (String#split, an AR bind), ArgumentError is not a SystemCallError so no rescue downstream
    # catches it, and because a pass is deliberately un-transactioned ONE such key leaves the
    # library half-indexed and kills every subsequent pass at the same entry. In 2a it was caught
    # only by the final whole-branch review, because macOS cannot create the fixture. An S3 key is
    # far easier to write than a non-UTF-8 filename, so this is MORE likely here, not less.
    #
    # `valid_encoding?` ALONE IS THE BUG, and the Scanner's line does not transfer verbatim the way
    # it looks like it should. It asks "are these bytes valid in the encoding this String is TAGGED
    # with", and an ASCII-8BIT string is ALWAYS valid — every byte sequence is legal binary. The
    # Scanner is safe because `Dir.children` tags names with the filesystem encoding (UTF-8), so a
    # bad name is UTF-8-tagged-invalid and the check fires. A client is under no such obligation:
    # hand this method a binary-tagged key and the naive check waves \xFF straight through into
    # storage_path. Caught by the plan's own `.b` fixture, which is why it is kept.
    #
    # So the question is asked of the BYTES, not the tag, and the survivors are re-tagged UTF-8 so
    # nothing downstream inherits a binary String in a text column.
    #
    # Skip rather than scrub: a scrubbed key no longer addresses the real object, so we would index
    # a file whose every read 404s. Skipping HERE — in the observer — is also what keeps it out of
    # `vanished_paths`, so an unindexable key can never be tombstoned.
    #
    # HONEST SCOPE: through aws-sdk-s3 this is unreachable, because the SDK raises on the whole
    # page before we are handed any key (see #list_page — verified). It stays because `client:` is
    # an injection seam another client can come through, because AWS S3 specifies keys as Unicode
    # while the S3-COMPATIBLE stores this backend targets are not bound by that, and because if a
    # future SDK stops raising this is what catches the key instead of the database.
    def utf8_key(key)
      key = key.to_s
      key = key.dup.force_encoding(Encoding::UTF_8) unless key.encoding == Encoding::UTF_8
      return key if key.valid_encoding?

      Rails.logger.warn("library s3 scan: skipping #{key.scrub.inspect} — the key is not valid UTF-8")
      nil
    end

    # Can this relative key be a path in the tree at all?
    def indexable?(rel)
      # The prefix itself as a marker object ("library/") — the library root, not an entry in it.
      return false if rel.empty?

      # `-1` keeps trailing empties, so "a/" splits to ["a", ""] rather than ["a"]. The default
      # would silently drop exactly the segment we are looking for.
      segs = rel.split("/", -1)

      # A key that is not a tree path. THIS IS LANDMINE 6's PHANTOM ARRIVING BY A SECOND ROUTE, not
      # a hypothetical: S3 is a flat keyspace and permits "cad//x.stl", which is a perfectly good
      # key and not a path. Index it and `File.dirname` gives "cad/", so its ancestor chain yields a
      # dir node at storage_path "cad/" sitting beside the real `cad` — the identical phantom the
      # trailing-slash rule above exists to prevent, wearing different punctuation.
      #
      # "." and ".." are here for a second reason on top of that one: FileLayer::S3#key_for_rel
      # REFUSES a ".." segment as a prefix escape, so indexing such a key would mint a node whose
      # every read raises NotFound — a file in the library that can never be opened.
      #
      # Skipped in the observer, like every other skip of a KEY SHAPE here, so it can never be
      # tombstoned. #observe adds one more skip, for a repo's metadata, and it preserves this
      # same property for this same reason — it is there rather than here because it has to
      # RECORD the marker prefix before dropping the key, which a predicate cannot do.
      if segs.any? { |s| s.empty? || s == "." || s == ".." }
        Rails.logger.warn("library s3 scan: skipping #{rel.inspect} — the key is not addressable " \
                          "as a path (an empty, \".\" or \"..\" segment)")
        return false
      end

      # Never index the trash: doing so re-indexes deleted files as new ones and resurrects them.
      # Root-anchored, so a nested `cad/.trash` is the user's own folder and none of our business.
      #
      # Scanner::TRASH_PREFIX rather than a second ".trash" literal — this skip, FileLayer::S3's
      # `observable!` guard and its `entry_key` are ONE FACT, and two copies of it is exactly how
      # the trash quietly starts getting indexed. No log line: a trashed file is skipped on every
      # scan forever, and logging routine correctness is how a log stops being read.
      #
      # Scanner::TEMP_PREFIX is deliberately NOT mirrored. It is a Share concept — that adapter
      # writes to a temp name and renames, and a scan landing in the window would index a torn
      # file. FileLayer::S3#write has no such window (put_object is atomic), writes no temp key,
      # and says so; skipping the prefix here would make an object a user legitimately named
      # `.maker-tmp-x` invisible, which is the ghost-making shape rather than a guard against it.
      return false if segs.first == Library::Scanner::TRASH_PREFIX

      # OS-generated clutter (.DS_Store, ._*, __MACOSX/, macOS volume metadata) — the SAME
      # Library::OsClutter predicate FileLayer::S3#observable! rejects on, so the skip and the
      # write refusal are one fact and cannot drift. Skipping HERE keeps it out of vanished_paths,
      # so an ignored key is never tombstoned. Any depth (unlike TRASH_PREFIX, which is
      # root-anchored): a `__MACOSX/` or `.DS_Store` anywhere in the bucket is clutter. No log
      # line: routine noise on every scan of every bucket, and a log nobody reads by the time a
      # real warning arrives is worse than none.
      return false if Library::OsClutter.ignore?(rel)

      true
    end

    def file_observation(rel, obj)
      Library::Observation.new(
        rel_path: rel, size: obj.size, dir: false, mtime: nanos(obj.last_modified),
        # THE ETAG ONLY, AND NO HEAD — this is the line the whole "point it at my existing storage"
        # on-ramp rests on. The identity is FREE in the listing, so a scan of a 2M-object bucket
        # costs 2000 listings and nothing else. A HEAD here would cost 2M billed requests EVERY
        # scan (every 15 minutes, forever); a GET would cost a full egress of the bucket.
        #
        # WHICH RUNGS THIS CAN REACH, stated because the ladder has three and this reaches two.
        # `list_objects_v2` returns `checksum_algorithm` and `checksum_type` but NEVER the checksum
        # VALUE, so rung 1 (sha256:, a FULL_OBJECT checksum) is unreachable from a listing by
        # construction — it needs a HEAD per object. Passing `checksum_type:` through would
        # therefore change nothing (rung 1 requires the VALUE to be present) while implying we had
        # asked the question, so it is left out. What remains is rung 2 (md5:, a single-part ETag,
        # content-determined and free) and rung 3 (etag:, whose moves degrade to delete+create — a
        # missed rename, never a wrong pairing).
        #
        # `LIBRARY_S3_HEAD_FOR_CHECKSUM` is NOT implemented, and see the report: the plan prices it
        # at "one HEAD per object on every FIRST SIGHT", which this layer cannot deliver. An
        # observer does not know which objects are new — the Reconciler does — so a HEAD here is
        # per-object-per-SCAN, not per-first-sight. Costing the operator 2M requests a quarter hour
        # under a flag advertised as costing 2M once is worse than not offering it.
        content_hash: FileLayer::S3::ObjectIdentity.for(etag: obj.etag)
      )
    end

    # A synthesized directory carries NO size and NO mtime, and both nils are deliberate.
    #
    # `size: nil` matches the Scanner exactly, for its stated reason: a directory's st_size is an
    # allocation detail (96, 4096) and storing it in a column meaning "how big is this file" is
    # meaningless bytes.
    #
    # `mtime: nil` is where this must DIVERGE from the Scanner, which stamps a real stat mtime. S3
    # has no directories, therefore no directory mtime — there is nothing to convert, and every
    # available invention is worse than nil: 0 is a lie that renders as 1970, and the newest child's
    # mtime is a value the store never had (and would rewrite the dir row on every child's edit).
    # nil is the truthful answer to "when was this prefix modified", which is "S3 does not have
    # that". Verified rather than assumed, on both ends: `nodes.mtime` is a NULLABLE bigint, and
    # Reconciler#ensure_dirs passes `mtime: o.mtime` straight into `update!` with no coercion; the
    # file browser and detail views already render `node.mtime ? … : "—"`.
    #
    # Shallowest-first, matching the order Scanner#observe emits (parent before child) — belt and
    # braces over ensure_dirs' own sort, per #observe.
    def dir_observations(dirs)
      dirs.sort_by { |rel| rel.count("/") }
          .map { |rel| Library::Observation.new(rel_path: rel, size: nil, mtime: nil, dir: true) }
    end

    # Every ancestor prefix of a directory path, shallowest first: "cad/brackets" ->
    # ["cad", "cad/brackets"]. S3 HAS NO DIRECTORIES — the keyspace is flat — so `nodes`' tree is
    # synthesized entirely from this. Without it `parent_node_id` resolves to nothing and browse,
    # search and tags stop working for every file below the top level.
    #
    # Note there is no "does this prefix exist" question to ask: in a flat keyspace a prefix exists
    # exactly when a key has it, which is what makes deriving the chain from the key correct rather
    # than a guess.
    def dir_chain(dir_rel)
      parts = dir_rel.split("/")
      parts.each_index.map { |i| parts[0..i].join("/") }
    end

    def listing_prefix = @adapter.listing_prefix

    # S3's last_modified is a SECOND-granularity Time; nodes.mtime is a bigint of unix NANOSECONDS.
    # FileInfo's contract is that adapters CONVERT rather than pass a Time through — feeding
    # seconds in is the nanos bug that shipped for real, twice, in the WebDAV and WinFsp adapters.
    #
    # The formula is character-for-character FileLayer::S3#nanos, and that is not accidental
    # duplication to be factored out on sight: the two must agree or every file the adapter WRITES
    # looks changed on the next scan. Its comment says so from the other side. (Scanner#nanos is a
    # third copy, over a stat; the convention in this codebase is a local, commented conversion per
    # adapter rather than a shared helper.)
    def nanos(time) = time.to_i * 1_000_000_000 + time.nsec
  end
end
