# Shared contract EVERY FileLayer adapter must satisfy. Include it into an adapter's test
# case and implement the hooks below. Phase 1 has one adapter (Chunk); the contract exists
# so that when Share and S3 land they cannot quietly diverge — and so chunk-specific
# assumptions can't leak into the port.
#
# Hooks the including test case must define:
#   adapter                        -> the FileLayer adapter under test
#   @user                          -> a User (set in setup)
#   create_file!(name:, bytes:)    -> node_id (String), having stored `bytes` in the backend.
#                                     The created file must carry a REAL current modification
#                                     time — in chunk mode that means passing `mtime:` through
#                                     to the commit; in share mode the filesystem supplies it.
#                                     The mtime-unit test below cannot pass otherwise.
#   delete_file!(node_id)          -> remove the file from the backend the way a USER would
#                                     (chunk: tombstone the node; share: move it out of the
#                                     indexed tree). It must NOT be the port's `delete`, which
#                                     does not exist yet.
#   trash_file!(node_id)           -> delete the file the way THIS DEPLOYMENT'S WEB UI does, i.e.
#                                     the branch FilesController#destroy makes: chunk ->
#                                     Sync::Mutation's tombstone, share/s3 -> the port's `delete`.
#                                     Distinct from delete_file! above ON PURPOSE — see the trash
#                                     tests, where the difference is the whole point.
#   with_off_box_presigning { }    -> configure this backend's STORE so that, if it has any way
#                                     at all to mint a URL pointing OFF-BOX, it will. Then yield;
#                                     restore on the way out. A backend with no URL signer
#                                     (Share) defines it as a bare `yield` — installing one there
#                                     would be faking the capability into existence rather than
#                                     observing it, and the presignable test below would then pin
#                                     the fixture instead of the adapter. Chunk needs real work
#                                     here (its memory/local stores presign to URLs RAILS serves,
#                                     so only an S3ChunkStore makes it redirect); S3 is always
#                                     off-box and yields.
#   with_transient_backend_failure { } -> make the backend fail in a way that is TEMPORARY and
#                                     not the file's fault (a 403/5xx/network blip; an
#                                     unmounted share), then yield. Must restore on the way out
#                                     — the test reads the file again afterwards to prove it.
#                                     Fault the TRANSPORT (the store/filesystem beneath the
#                                     adapter), never the adapter's own error classification —
#                                     stubbing that is what this test exists to check.
module FileLayerAdapterContract
  # mtime is unix NANOSECONDS across the whole sync engine (nodes.mtime is a bigint of nanos;
  # CLAUDE.md §7). Treating nanos as seconds already shipped once as a real bug in the WebDAV
  # and WinFsp adapters, so the contract pins the UNIT, not just the presence: a seconds value
  # is ~1.7e9 and milliseconds ~1.7e12, both far below this floor.
  NANOS_FLOOR = 1_000_000_000_000_000 # 1e15

  # Count the SQL this block really issues. Hand-rolled rather than Rails' assert_queries_count
  # because the assertion here is a COMPARISON of two counts, not a match against a literal —
  # see test_contract_stat_all_costs_a_number_of_queries..., where a literal would encode one
  # backend's query shape into a contract every backend runs.
  #
  # SCHEMA/TRANSACTION and PRAGMA are excluded: they are the adapter's cost only by accident of
  # being first, and a warm-up call in the test is what keeps them out of the measurement anyway.
  def count_contract_queries
    n = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
        n += 1
      end
    end
    yield
    n
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  def test_contract_stat_describes_an_existing_file
    id = create_file!(name: "a.stl", bytes: "hello")
    info = adapter.stat(@user, node_id: id)
    assert_equal id, info.node_id
    assert_equal "a.stl", info.name
    assert_equal "file", info.kind
    assert_equal 5, info.size
    assert info.content_token.present?, "every backend must expose a content token"
  end

  def test_contract_stat_raises_not_found_for_an_unknown_node
    assert_raises(FileLayer::NotFound) { adapter.stat(@user, node_id: "no-such-node") }
  end

  # stat_all IS stat, in bulk — so it must not become a SECOND answer to the same question.
  # FilesController#index calls stat_all and #show calls stat, and a user who clicks a row must
  # not watch the size change: two views disagreeing about one file is §9a-1's bug wearing the
  # port's own clothes, and it is the exact failure `file_info` exists as one copy to prevent.
  #
  # Compared as whole FileInfos rather than field by field: FileInfo is a Data, so `==` is value
  # equality across every member, and a new member added later is covered without touching this.
  def test_contract_stat_all_answers_exactly_what_stat_answers
    ids = 3.times.map { |i| create_file!(name: "bulk#{i}.stl", bytes: "b" * (i + 1)) }
    infos = adapter.stat_all(@user, node_ids: ids)

    assert_equal ids.size, infos.size
    ids.each do |id|
      assert_equal adapter.stat(@user, node_id: id), infos[id],
                   "stat_all must answer exactly what stat answers for #{id} — the browse view " \
                   "and the detail view describing one file differently is the divergence the " \
                   "port exists to prevent"
    end
  end

  # THE ABSENT KEY IS THE ANSWER, and it is a cross-backend rule rather than each adapter's taste.
  # stat is asked about ONE node and NotFound is its whole answer; a bulk caller holds a LIST, and
  # a row tombstoned between its query and this one must not take the page down. An adapter that
  # raised here instead would 404 an entire browse page on whichever deployment happened to race —
  # a divergence no caller could see coming, because the port's signature is the same on all three.
  def test_contract_stat_all_omits_what_stat_raises_not_found_for
    live = create_file!(name: "still-here.stl", bytes: "x")
    gone = create_file!(name: "removed.stl", bytes: "y")
    delete_file!(gone)

    infos = adapter.stat_all(@user, node_ids: [ live, gone, "no-such-node" ])

    assert infos.key?(live), "a live node must be described"
    assert_not infos.key?(gone),
               "a tombstoned node must be OMITTED — stat raises NotFound for it, and tombstoned " \
               "means gone on every backend"
    assert_not infos.key?("no-such-node"), "an unknown node must be omitted, not raise"
  end

  # THE POINT OF THE VERB, PINNED — and without this the whole thing is decoration.
  #
  # Every other test here passes for `node_ids.map { |id| stat(user, node_id: id) }`, which is the
  # N+1 this verb exists to remove: it answers stat exactly (that is its definition), and it omits
  # nothing... it RAISES, so only the test above rejects it. Nothing else here can tell a bulk read
  # from a loop, so a future "simplification" back to a loop would land green.
  #
  # Asserted as CONSTANT IN N rather than against a per-adapter number: chunk needs two queries
  # (nodes + a plucked batch of sizes) and share/s3 need one, so any literal here would either
  # encode one backend's shape into a shared contract or be loose enough to pass for a loop at
  # small N. "The cost does not grow with the list" is the property the caller actually needs, it
  # is the same sentence on all three, and a loop fails it by construction.
  def test_contract_stat_all_costs_a_number_of_queries_that_does_not_grow_with_the_list
    few  = 2.times.map { |i| create_file!(name: "few#{i}.stl", bytes: "f") }
    many = 20.times.map { |i| create_file!(name: "many#{i}.stl", bytes: "m") }

    adapter.stat_all(@user, node_ids: few) # warm: first-touch schema/statement loads are not the cost
    few_queries  = count_contract_queries { adapter.stat_all(@user, node_ids: few) }
    many_queries = count_contract_queries { adapter.stat_all(@user, node_ids: many) }

    assert_equal few_queries, many_queries,
                 "#{adapter.class}#stat_all cost #{few_queries} queries for 2 nodes and " \
                 "#{many_queries} for 20 — it is looping #stat, which is the N+1 the verb exists " \
                 "to remove (measured at 2000 nodes: 4000 queries and 527ms of a 676ms page)"
  end

  def test_contract_read_returns_the_bytes
    id = create_file!(name: "b.stl", bytes: "hello world")
    assert_equal "hello world", adapter.read(@user, node_id: id)
  end

  def test_contract_read_at_the_current_content_token_returns_the_bytes
    id = create_file!(name: "c.stl", bytes: "tokened")
    token = adapter.stat(@user, node_id: id).content_token
    assert_equal "tokened", adapter.read(@user, node_id: id, content_token: token)
  end

  # An adapter must not silently ignore content_token and serve current bytes: previews are
  # keyed on this token (maker_previews.version_id), so answering the wrong content state is a
  # correctness bug, not a nicety. Satisfiable by every backend — chunk mode finds no such
  # version; share/S3 keep no history, so any token that isn't the current hash is simply gone.
  def test_contract_read_raises_not_found_for_an_unavailable_content_token
    id = create_file!(name: "e.stl", bytes: "current")
    assert_raises(FileLayer::NotFound) do
      adapter.read(@user, node_id: id, content_token: "no-such-content-token")
    end
  end

  def test_contract_read_raises_not_found_for_an_unknown_node
    assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: "no-such-node") }
  end

  def test_contract_read_returns_binary_bytes
    id = create_file!(name: "d.bin", bytes: "\x00\x01\x02\xFF".b)
    assert_equal "\x00\x01\x02\xFF".b, adapter.read(@user, node_id: id)
  end

  # THE PORT'S ONE PROMISE ABOUT HOW BIG A read MAY GET, ASKED OF EVERY ADAPTER INSTEAD OF LEFT AS
  # PROSE. file_layer.rb calls MAX_BYTES "port-wide", but the rule lived only in that sentence: share
  # kept it twice and s3 twice, by two different mechanisms, and chunk_remote not at all -- and no
  # leg could notice, because nothing here asked. The obligation is what belongs in the contract; the
  # MECHANISM stays with the adapter (s3's ranged GET and share's cap+1 read each argue for
  # themselves, in place).
  #
  # THE MUTATION IS MEANINGFUL ON chunk_remote ALONE: deleting its manifest pre-check turns this red
  # while share and s3 stay green. A future reader must not read three green legs as three proofs.
  #
  # The constant is SHRUNK rather than a 256 MiB fixture seeded — the pattern share_test and s3_test
  # already established. BOTH ARMS ARE ASSERTED, and the second is what stops the first going
  # vacuous: with only the refusal pinned, `>= MAX_BYTES` would pass and "exactly at the cap" would
  # be nobody's answer.
  def test_contract_read_refuses_a_file_over_max_bytes
    id = create_file!(name: "capped.stl", bytes: "hello")

    with_max_bytes(4) do
      err = assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
      assert_match(/exceeds/, err.message)
    end

    with_max_bytes(5) do
      assert_equal "hello", adapter.read(@user, node_id: id),
                   "a file EXACTLY at the cap must still read — the refusal is > MAX_BYTES, and " \
                   "an adapter that refused here would truncate the boundary instead of bounding it"
    end
  end

  def with_max_bytes(bytes)
    original = FileLayer::MAX_BYTES
    FileLayer.send(:remove_const, :MAX_BYTES)
    FileLayer.const_set(:MAX_BYTES, bytes)
    yield
  ensure
    FileLayer.send(:remove_const, :MAX_BYTES)
    FileLayer.const_set(:MAX_BYTES, original)
  end

  def test_contract_stat_reports_mtime_in_unix_nanoseconds
    id = create_file!(name: "f.stl", bytes: "timed")
    mtime = adapter.stat(@user, node_id: id).mtime
    assert_kind_of Integer, mtime
    assert mtime > NANOS_FLOOR,
           "mtime must be unix nanoseconds, got #{mtime} (a seconds value is ~1.7e9)"
  end

  def test_contract_capabilities_answers_all_five_questions
    caps = adapter.capabilities
    assert_includes [ true, false ], caps.versioned?
    assert_includes [ true, false ], caps.syncable?
    assert_includes [ true, false ], caps.presignable?
    assert_includes [ true, false ], caps.scannable?
    assert_includes [ true, false ], caps.port_writable?
  end

  # THE PORT NAMES THE ORIGIN ITS PRESIGNED URLS CARRY, OR NOTHING. The CSP's connect-src asks it
  # per response, so a presignable adapter that answered nil would report every viewer fetch on
  # that backend, and a non-presignable one that answered an origin would widen the policy for a
  # redirect it never issues. An ORIGIN, not a URL: scheme, host and port, no path, no trailing
  # slash — a CSP source carrying a path matches only that path.
  def test_contract_presigned_origin_is_an_origin_iff_presignable
    origin = adapter.presigned_origin
    if adapter.capabilities.presignable?
      assert_match(%r{\Ahttps?://[^/\s]+\z}, origin.to_s,
                   "a presignable backend must name a bare origin")
    else
      assert_nil origin, "a backend that never redirects must not widen connect-src"
    end
  end

  # EVERY adapter answers this, and only Share answers true. Asserted in the shared contract
  # rather than per-adapter so a fourth backend cannot quietly omit it -- the omission would
  # read as "commits are unavailable here", which is indistinguishable from a correct false.
  def test_local_worktree_is_answered_and_only_share_says_yes
    caps = adapter.capabilities

    assert_includes [ true, false ], caps.local_worktree,
                    "local_worktree must be a real boolean, not nil"
    assert_equal adapter.is_a?(FileLayer::Share), caps.local_worktree?,
                 "only a real local filesystem can be handed to git in place"
  end

  # `port_writable` PINNED AGAINST WHAT write ACTUALLY DOES — Phase 4's Landmine 1.
  #
  # Capabilities are five hand-written booleans per adapter, and until Phase 3 NOTHING read them,
  # so no wrong one had ever been noticed. Phase 4 makes the UI hide features on them and the API
  # answer 501 on them, at which point a wrong boolean stops being inert documentation and becomes
  # a feature that silently vanishes — or one that is offered and then fails.
  #
  # Nothing mechanically ties `port_writable: false` to `write` actually raising. This does. It
  # lives in the READ contract, which EVERY adapter runs, rather than in any one adapter's test,
  # because "the adapters cannot diverge" is the contract's whole job.
  #
  # The spec predicted exactly this drift for `presignable` (§9a-3: answered statically, but a
  # property of the store, with Chunk.fetch duck-typing the same question elsewhere). This is the
  # mechanism that would have caught it.
  def test_contract_port_writable_agrees_with_what_write_actually_does
    if adapter.capabilities.port_writable?
      info = adapter.write(@user, parent_node_id: nil, name: "caps.stl", io: StringIO.new("w"))
      assert_equal "w", adapter.read(@user, node_id: info.node_id),
                   "port_writable? is true, so the port's write path must actually work"
    else
      err = assert_raises(NotImplementedError) do
        adapter.write(@user, parent_node_id: nil, name: "caps.stl", io: StringIO.new("w"))
      end
      # Assert the MESSAGE, not just the class: NotImplementedError is reachable from five places
      # in this codebase (FileLayer.build, ChunkStore's abstract methods, Sync::RetentionPolicy),
      # so the class alone would let an unrelated raise satisfy this.
      #
      # MATCHES THE PORT'S VOCABULARY, NOT ONE ADAPTER'S INTERNALS. This read /Sync::Commit/ until
      # chunk_remote was wired to this contract and failed on it -- a second chunk-family adapter is
      # the only thing that could reveal it, which is what a shared contract is for. Sync::Commit is
      # what happens UNDERNEATH the port in one deployment; a caller told to use it learns nothing
      # it can act on, and chunk_remote has no local Sync::Commit at all. `begin_upload` is the door
      # the caller actually uses, it is what §14a names, and Chunk's own message already said so --
      # the old pattern was matching its parenthetical.
      assert_match(/begin_upload/, err.message,
                   "a refusal must name the PORT VERB the caller should use, not the machinery " \
                   "beneath it -- a caller cannot act on the name of an internal service")
    end
  end

  # `presignable` PINNED AGAINST WHETHER A URL IS ACTUALLY REACHABLE — Landmine 1, and the exact
  # capability §9a-3 predicted would drift ("answered statically, but a property of the store").
  #
  # THE OBVIOUS VERSION OF THIS TEST CANNOT FAIL, and why is the whole design here. Task 1 left
  # this behind as a placeholder, and the shape it sketched was:
  #
  #     return unless caps.presignable?
  #     assert adapter.download(@user, node_id: id, disposition: "attachment")
  #
  # Both halves are inert. The `return` makes a FALSE claim unfalsifiable BY CONSTRUCTION — flip
  # Chunk to `presignable: false` and the test simply never runs — and `assert <a Delivery>` is
  # satisfied by ANY Delivery, so flipping Share to `presignable: true` passes too, on the
  # strength of the SendFile it hands back. Verified by mutation rather than by reading: both
  # mutants were green. A pin that passes for every possible value of the thing it pins is
  # decoration with a `?` on the end.
  #
  # So this asks the question the capability actually answers — "can this backend hand the
  # browser a URL instead of proxying the bytes through Rails?" (§15) — and compares the
  # DECLARATION against the Delivery the adapter really produces. Neither side is computed from
  # the other: no adapter's `download` reads `capabilities`, and the hook below configures a
  # STORE, not a claim. That independence is what test_contract_scannable_... argues for at
  # length, and it is the only reason a hardcoded boolean is worth trusting.
  #
  # Every adapter's declaration fails when flipped — chunk true->false, share false->true, s3
  # true->false, all three verified by mutation — which is the property that makes this a pin
  # rather than a comment. Note the FALSE half is the one the obvious version cannot reach, and
  # Share is the only adapter that answers false today: without it, nothing here would be tested
  # in that direction at all.
  def test_contract_presignable_agrees_with_whether_a_url_is_actually_reachable
    # BEFORE the hook: a backend whose store is swapped for a presign-only one has nowhere to put
    # the bytes (Chunk's create_file! would PUT over the network).
    id = create_file!(name: "presign.stl", bytes: "p")

    with_off_box_presigning do
      d = adapter.download(@user, node_id: id, disposition: "attachment")
      assert_equal adapter.capabilities.presignable?, d.is_a?(FileLayer::Delivery::Redirect),
                   "#{adapter.class} declares presignable=#{adapter.capabilities.presignable?} " \
                   "but download handed back a #{d.class.name.demodulize} with its store given " \
                   "every chance to presign — a backend that claims a URL it cannot mint (or " \
                   "the reverse) silently disables the redirect §15 depends on"
    end
  end

  # `scannable` PINNED AGAINST AN INDEPENDENT FACT — and the shape of this test is the whole point
  # of it, so read the trap before changing it.
  #
  # Until Phase 3, Capabilities had ZERO consumers: every flag was a boolean nothing read, so no
  # wrong one had ever been noticed. `scannable` is the first that is LOAD-BEARING —
  # Library::ScanJob.scan_all! gates on it, so a backend that answers it wrong is silently never
  # indexed, which is the exact failure the capability was introduced to end.
  #
  # THE OBVIOUS TEST CANNOT FAIL. Asserting that `scan_all!` acts iff `scannable?` is circular: the
  # gate READS the capability, so the two agree by construction. Written that way first, and a
  # Chunk mutated to `scannable: true` passed it — caught by mutation, not by review.
  #
  # So this compares the DECLARATION ("poll me") against a fact derived from somewhere else
  # entirely: whether an observer exists that could. ScanJob.observer_for is a plain class dispatch
  # that asks no capability, so neither side of this assertion is computed from the other, and both
  # halves fail when flipped (verified by mutating each adapter in turn).
  #
  # Phase 2b declined to add a capability precisely because a task could only pin the TRUE half —
  # the FALSE half has to be pinned by a backend that answers false, and Chunk is the only module
  # that runs this contract and does. Both halves are pinned here, by one test, because every
  # adapter runs it.
  def test_contract_scannable_matches_whether_a_scan_observer_exists_for_this_backend
    observer = Library::ScanJob.observer_for(@user, adapter)

    assert_equal adapter.capabilities.scannable?, !observer.nil?,
                 "#{adapter.class} declares scannable=#{adapter.capabilities.scannable?} but " \
                 "Library::ScanJob.observer_for #{observer ? "built a #{observer.class}" : 'has no observer for it'}" \
                 " — a backend that claims to be polled with nothing to poll it (or the reverse) " \
                 "is silently never indexed"
  end

  # Tombstoned means GONE, on every backend. Chunk could technically still serve a trashed
  # node's bytes (its versions live in the DB), but Share physically cannot — its trash is a
  # real filesystem move — so an adapter that answers differently is a divergence the maker
  # layer would see as "the file is still there" on one deployment and "missing" on another.
  def test_contract_read_raises_not_found_for_a_deleted_node
    id = create_file!(name: "gone.stl", bytes: "bye")
    delete_file!(id)
    assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
  end

  def test_contract_stat_raises_not_found_for_a_deleted_node
    id = create_file!(name: "gone2.stl", bytes: "bye")
    delete_file!(id)
    assert_raises(FileLayer::NotFound) { adapter.stat(@user, node_id: id) }
  end

  # The by-token path needs its OWN case: it resolves content directly and can bypass a
  # liveness check that only guards the current-version path — so without this, an adapter can
  # serve a trashed file's bytes to anyone holding a pre-deletion token and stay green. That is
  # the path the only production caller uses (GeneratePreviewJob always passes a version_id).
  # Cross-backend, not chunk-specific: share/S3 keep no history, so a token captured before
  # deletion is gone there too.
  def test_contract_read_at_a_token_captured_before_deletion_raises_not_found
    id = create_file!(name: "gone3.stl", bytes: "bye")
    token = adapter.stat(@user, node_id: id).content_token
    delete_file!(id)
    assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id, content_token: token) }
  end

  # THE TRASH, AND THE HOOK NAMES WHAT `delete_file!` DELIBERATELY DOES NOT: `delete_file!` is
  # the user removing the file OUT OF BAND (a tombstone set by the v1 API; an `rm` on the NAS),
  # which on share/s3 is exactly the case that is NOT a trash — the bytes are gone from storage we
  # do not own. `trash_file!` is the user clicking Delete IN THE WEB UI, which is the branch
  # FilesController#destroy makes: chunk -> Sync::Mutation, share/s3 -> the port's `delete`. Two
  # hooks because they are two different events; conflating them is what makes an adapter list a
  # file it can never restore.
  #
  # Backend-neutral by construction: what "in the trash" means differs (chunk keeps every version
  # forever; share/s3 moved the bytes to `.trash`), but "the thing I just deleted is listed, at
  # its real size, and can be told apart from a live file" is one answer everywhere. The SIZE is
  # the assertion Task 7 reported as missing: the trash view read current_user.versions, which is
  # empty on share and s3, so every Size cell was an em-dash.
  def test_contract_trashed_lists_a_file_this_deployment_trashed
    id = create_file!(name: "binned.stl", bytes: "0123456789")
    trash_file!(id)

    entry = adapter.trashed(@user).find { |e| e.node_id == id }
    assert entry, "a file deleted through this deployment's UI must be in its trash"
    assert_equal "binned.stl", entry.name
    assert_equal "file", entry.kind
    assert_equal 10, entry.size, "the trash must report the real size, not nil"
    assert entry.deleted_at.present?, "the trash view sorts and displays by deleted_at"
  end

  def test_contract_trashed_never_lists_a_live_file
    id = create_file!(name: "alive.stl", bytes: "here")
    assert_not_includes adapter.trashed(@user).map(&:node_id), id
  end

  # The single most consequential distinction in the port. A transient backend failure must
  # NEVER read as "the file is gone": NotFound is terminal (a preview is marked failed
  # forever), FetchError retries. This exists because a 403 during a credentials outage was
  # once swallowed as "missing chunk", permanently failing previews for healthy files — and
  # for Share the same mistake means an unmounted NAS looks like the user deleted the library.
  #
  # NotFound and FetchError are disjoint siblings of StandardError, so assert_raises(FetchError)
  # cannot be satisfied by the very bug it guards against.
  def test_contract_transient_backend_failure_raises_fetch_error_not_not_found
    id = create_file!(name: "flaky.stl", bytes: "still here")
    with_transient_backend_failure do
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    end
    # The failure was TRANSIENT and the hook restored: the file was healthy all along. Without
    # this the hook could satisfy the contract by breaking the backend permanently (unmount and
    # never remount) — green here, damage surfacing as unrelated failures later in the suite.
    assert_equal "still here", adapter.read(@user, node_id: id)
  end
end
