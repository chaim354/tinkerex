# The contract EVERY adapter implementing the port's WRITE path must satisfy. Separate from
# adapter_contract.rb (the read contract) on purpose: that one runs against every adapter,
# and Chunk does not implement this path — chunk-mode writes are Sync::Commit's two-phase
# flow, and forcing a server-side write here would duplicate it, have no caller, and reach
# into the sync engine the port exists to stay out of (spec §10).
#
# Include this into a writable adapter's test case. Share includes it now; S3 in Phase 3 —
# that is the point. The read contract's hooks (adapter, @user) are assumed; include this
# alongside it.
#
# One ADDITIONAL hook the including test case must define:
#   with_transient_write_failure { } -> make the WRITE transport fail temporarily and not the
#                                    file's fault (a PUT 5xx; a full or unmounted share), then
#                                    yield. Restore on the way out.
#                                    SEPARATE from the read contract's
#                                    with_transient_backend_failure on purpose: read and write
#                                    are different transports (Share: File.binread vs
#                                    File.binwrite; S3: GET vs PUT), and the read hook's test
#                                    ends by re-reading the file to prove the fault was
#                                    transient — one hook faulting both would stop that
#                                    assertion isolating the read path. Fault the TRANSPORT,
#                                    never the adapter's own error classification.
#
# These assert only what is BACKEND-AGNOSTIC. Share's `.trash/<node_id>/<name>` layout is NOT
# in here: S3 trashes by key prefix, and encoding one backend's storage layout in a shared
# contract is exactly the leak the port exists to prevent. Where the bytes go is Share's test.
#
# `parent_node_id: nil` MEANS THE ROOT throughout, and that is a tree fact rather than a
# filesystem one — so it needs no `root_parent_node_id` hook to stay backend-agnostic. `nodes`
# is the shared catalog on every backend (the scanner indexes into it; parent_node_id is a
# plain column), so "no parent" is the top of the library whether that resolves to the share
# root or to a bare S3 key with no sub-prefix. Phase 3's own S3 tests already address the root
# exactly this way.
#
# WHAT THIS CONTRACT DELIBERATELY DOES NOT PIN — `undelete` is here even though spec §3.2 lists
# only write/delete/move and calls undelete "a move back". That is mechanically impossible on
# Share and the divergence is deliberate: `move` starts with live_node! (a tombstone is not
# live) and resolves its source through `absolute_path(node)` -> `node.storage_path`, which
# `delete` NULLS (Landmine 2) — so a "move back" would resolve to the library root and rename
# the whole library. The bytes live somewhere only a trash-aware verb can find. Phase 3 keeps
# the same shape (its plan has S3 undelete tests). Task 9's docs record the divergence.
module FileLayerWritableContract
  def test_write_contract_bytes_round_trip
    info = adapter.write(@user, parent_node_id: nil, name: "rt.stl", io: StringIO.new("payload"))
    assert_equal "payload", adapter.read(@user, node_id: info.node_id)
  end

  # The port's whole promise. A move that mints a new node_id breaks every project
  # attachment, BOM link and tag pointing at that file — on any backend.
  def test_write_contract_move_keeps_the_node_id
    info = adapter.write(@user, parent_node_id: nil, name: "before.stl", io: StringIO.new("same"))
    adapter.move(@user, node_id: info.node_id, new_parent_node_id: nil, new_name: "after.stl")

    assert_equal "same", adapter.read(@user, node_id: info.node_id),
                 "a move must keep node_id resolving to the same bytes"
    assert_equal "after.stl", adapter.stat(@user, node_id: info.node_id).name
  end

  # Tombstoned = gone is already pinned by the READ contract (§9a-1). This pins the other
  # half: delete gets you there, and it tombstones rather than destroying — the row is what
  # makes a project say "file missing" instead of the attachment vanishing.
  def test_write_contract_delete_tombstones_rather_than_destroying
    info = adapter.write(@user, parent_node_id: nil, name: "bye.stl", io: StringIO.new("gone"))
    adapter.delete(@user, node_id: info.node_id)

    assert @user.nodes.find_by!(node_id: info.node_id).deleted, "the row survives"
    assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: info.node_id) }
  end

  def test_write_contract_undelete_restores_the_same_node_and_bytes
    info = adapter.write(@user, parent_node_id: nil, name: "back.stl", io: StringIO.new("restored"))
    adapter.delete(@user, node_id: info.node_id)
    adapter.undelete(@user, node_id: info.node_id)

    assert_not @user.nodes.find_by!(node_id: info.node_id).deleted
    assert_equal "restored", adapter.read(@user, node_id: info.node_id)
  end

  # NOT IN THE PLAN, and the omission is load-bearing rather than tidy-up: Phase 3's plan
  # requires `move` and `undelete` to refuse an occupied destination but says nothing of the
  # sort for `write`, so an S3 adapter built to that plan would PUT straight over the user's
  # file — while Share, three feet away, refuses. That is the divergence this module exists to
  # stop, and the omission in a downstream plan is the evidence it is not decoration.
  #
  # It matters MORE here than it would in chunk mode, and that is the argument for making it a
  # contract rule rather than each adapter's taste: every backend this module will ever cover is
  # CURRENT-STATE ONLY (spec decision 3 — no versions, no history, no restore). A clobber in
  # chunk mode is a new version and the old bytes are one restore away; a clobber on a share or
  # a bucket is the user's file, permanently gone, from a name collision in an upload form.
  #
  # Best-effort by nature and that is honest, not a hole: File.exist?-then-rename is TOCTOU, and
  # S3 has no portable conditional put (R2/SeaweedFS) — the same race Phase 3's plan already
  # documents for `move`'s identical check. This pins the CHECK, which is what stops the ordinary
  # case (a user re-uploading a name that is already there) from destroying data. It does not
  # claim an atomicity neither backend offers.
  #
  # UnsupportedOperation, NOT NotFound, AND THE CLASS IS THE HALF THAT REACHES THE USER. Both
  # adapters raised NotFound here until the Phase 4 follow-up, and FilesController maps that to
  # "File not found." — told to someone looking at the file it is about. The bytes surviving is
  # only half of "refuses"; the other half is saying so intelligibly, and a test that asserted the
  # bytes alone passed for the nonsense answer (it did, for two phases).
  #
  # In the CONTRACT rather than each adapter's test because the class is the port's, not the
  # backend's: FileLayer's taxonomy sorts on WHO IS WRONG and WHEN YOU CAN KNOW, and by that axis
  # a clobber is the client, at runtime, per-path — the same shape as the directory delete the
  # class was written for. See FileLayer::UnsupportedOperation, which carries the full argument.
  def test_write_contract_write_refuses_to_clobber_an_existing_name
    adapter.write(@user, parent_node_id: nil, name: "keep.stl", io: StringIO.new("original"))
    err = assert_raises(FileLayer::UnsupportedOperation) do
      adapter.write(@user, parent_node_id: nil, name: "keep.stl", io: StringIO.new("clobber"))
    end
    assert_match(/already exists/, err.message,
                 "the refusal must say the name is taken — this message is rendered to the user")
    assert_equal "original", adapter.read(@user, node_id: @user.nodes.find_by!(storage_path: "keep.stl").node_id),
                 "the existing bytes must survive — on a current-state-only backend there is no restore"
  end

  # THE SAME CONDITION MUST GET THE SAME ANSWER FROM EVERY VERB THAT CAN MEET IT, which is why
  # this exists next to the test above rather than being folded into it. "The destination is
  # taken" is one condition; write, move and undelete can all hit it. Fixing only `write` — the
  # one the review named — would have left a user renaming onto a taken name with "File not
  # found." while uploading onto one got an honest 422: one condition, two answers, inside one
  # adapter. That is the drift this module exists to stop, so it is pinned per-verb.
  #
  # NOT a test that undelete/move refuse a clobber AT ALL — each adapter's own suite already pins
  # that, with the storage-layout assertions this module deliberately has no business making. This
  # pins only the CLASS, which is the part that is the port's.
  def test_write_contract_every_verb_answers_a_taken_destination_the_same_way
    a = adapter.write(@user, parent_node_id: nil, name: "occupied.stl", io: StringIO.new("first"))
    b = adapter.write(@user, parent_node_id: nil, name: "mover.stl", io: StringIO.new("second"))

    assert_raises(FileLayer::UnsupportedOperation, "move onto a taken name") do
      adapter.move(@user, node_id: b.node_id, new_parent_node_id: nil, new_name: "occupied.stl")
    end

    # Trash `a`, then put a NEW file at its old name: undelete now has nowhere to land.
    adapter.delete(@user, node_id: a.node_id)
    adapter.write(@user, parent_node_id: nil, name: "occupied.stl", io: StringIO.new("squatter"))
    assert_raises(FileLayer::UnsupportedOperation, "undelete into a taken name") do
      adapter.undelete(@user, node_id: a.node_id)
    end
  end

  # Terminal-vs-retryable, the port's most consequential distinction, applies to writes too:
  # a transient backend failure must NEVER read as "the file is gone".
  def test_write_contract_transient_failure_on_write_raises_fetch_error
    with_transient_write_failure do
      assert_raises(FileLayer::FetchError) do
        adapter.write(@user, parent_node_id: nil, name: "flaky.stl", io: StringIO.new("b"))
      end
    end
    # ...and it left no half-state: a node whose bytes never landed is a browse entry that 404s
    # forever. Verified against the real code: Share#write creates the row only after the rename
    # returns, and Phase 3's plan pins the same order for S3 ("a failed write indexes nothing").
    assert_nil @user.nodes.find_by(storage_path: "flaky.stl")
  end
end
