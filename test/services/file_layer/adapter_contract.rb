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

  def test_contract_capabilities_answers_all_three_questions
    caps = adapter.capabilities
    assert_includes [ true, false ], caps.versioned?
    assert_includes [ true, false ], caps.syncable?
    assert_includes [ true, false ], caps.presignable?
  end
end
