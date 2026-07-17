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

  def test_contract_stat_reports_mtime_in_unix_nanoseconds
    id = create_file!(name: "f.stl", bytes: "timed")
    mtime = adapter.stat(@user, node_id: id).mtime
    assert_kind_of Integer, mtime
    assert mtime > NANOS_FLOOR,
           "mtime must be unix nanoseconds, got #{mtime} (a seconds value is ~1.7e9)"
  end

  def test_contract_capabilities_answers_all_four_questions
    caps = adapter.capabilities
    assert_includes [ true, false ], caps.versioned?
    assert_includes [ true, false ], caps.syncable?
    assert_includes [ true, false ], caps.presignable?
    assert_includes [ true, false ], caps.scannable?
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
