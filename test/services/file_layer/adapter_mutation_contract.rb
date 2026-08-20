# The contract EVERY adapter's METADATA verbs must satisfy -- mkdir, move, delete, undelete.
#
# EXTRACTED FROM FileLayerWritableContract, not written beside it. Those four tests lived there
# because, when it was written, the only adapters answering them were the two port_writable ones;
# Stage 2 gave chunk all four, so the grouping had become "the verbs share and s3 happen to share"
# rather than a real boundary. A second copy for chunk would have been two sets of assertions
# about one contract, free to drift -- this repo's most-recorded failure shape.
#
# THE REAL BOUNDARY IS BYTES. What stayed behind in FileLayerWritableContract is `write`, which
# takes an IO. Chunk does not have it and must never grow it: chunk uploads are Sync::Commit's
# two-phase presigned flow precisely so bytes never travel through Rails (CLAUDE.md 15). These
# four verbs move NO bytes, so 15 does not bind and all three adapters answer them.
#
# Include alongside FileLayerAdapterContract; its hooks (`adapter`, `@user`) are assumed.
#
# TWO HOOKS the including test case must define:
#
#   make_file(name:, bytes:) -> create one live FILE node carrying those bytes, through whatever
#                       door this backend really uses, and return its node_id. A HOOK rather than
#                       a shared helper because the doors genuinely differ -- share and s3 write
#                       through the port, chunk commits through the sync engine -- and a contract
#                       that reached for one of them would test that backend twice and the other
#                       not at all. It must produce REAL READABLE BYTES: three of these tests
#                       assert on adapter.read, which is what proves a move or an undelete kept
#                       the node_id resolving to the same content rather than merely to a row.
#
#   make_dir(name:)  -> the same, for a DIRECTORY node. Returns its node_id.
#
# WHAT THIS DELIBERATELY DOES NOT PIN:
#
#   - DIRECTORY DELETION. That is `dir_deletable`, and both answers are correct: chunk cascades
#     via Sync::SubtreeDelete, share strands children at paths that no longer exist while their
#     bytes sit in .trash, s3 has no directory at all. Asserted below as a capability-conditional,
#     never as one fixed expectation.
#   - WHERE THE BYTES GO. Share's `.trash/<node_id>/<name>` layout is share's own test; s3 trashes
#     by key prefix; chunk moves no bytes. Encoding one backend's storage layout in a shared
#     contract is the leak the port exists to prevent.
#   - `undelete`'s DESTINATION FOR AN ORPHAN. Share restores under the (tombstoned) parent's path,
#     which still exists on a filesystem; chunk restores to the ROOT, because a tombstoned parent
#     has no path to restore under. Both are right for their backend.
#   - A MOVE ONTO A TAKEN NAME. Share and s3 refuse it (UnsupportedOperation -- a clobber); chunk
#     does NOT, because Sync::Mutation performs no name check at all and Sync::Commit validates a
#     manifest exhaustively and the name not at all (CLAUDE.md 14c). Two live siblings sharing one
#     (parent, name) really are reachable on chunk. The WEB path is still protected --
#     Maker::MoveNode.collision! runs before it calls the port -- so this is not a regression
#     Stage 2 introduces, and closing it is a separate decision (CLAUDE.md 12 item 11), not
#     something a refactor does silently. It stays asserted in share's and s3's OWN tests.
#   - A MOVE OF A DIRECTORY. Share allows it; s3 refuses (`movable_file!`). Every test here moves
#     a FILE for that reason.
module FileLayerMutationContract
  # mkdir is a WRITE-path verb, so every writable backend answers it identically: a navigable dir
  # node, and idempotent (Maker::LibraryFolder walks a path and calls it per segment, repeatedly).
  # All three adapters answer it now — chunk's mkdir goes through the sync engine rather than the
  # port itself — so this pins Share, S3 and Chunk to not diverge on it.
  def test_mutation_contract_mkdir_creates_a_dir_node_and_is_idempotent
    info = adapter.mkdir(@user, parent_node_id: nil, name: "ContractDir")
    node = @user.nodes.find_by!(node_id: info.node_id)
    assert_equal "dir", node.kind
    assert_equal "ContractDir", node.name
    assert_equal info.node_id, adapter.mkdir(@user, parent_node_id: nil, name: "ContractDir").node_id,
                 "mkdir is idempotent — same dir node, not a duplicate"
  end

  # The port's whole promise. A move that mints a new node_id breaks every project
  # attachment, BOM link and tag pointing at that file — on any backend.
  def test_mutation_contract_move_keeps_the_node_id
    node_id = make_file(name: "before.stl", bytes: "same")
    adapter.move(@user, node_id:, new_parent_node_id: nil, new_name: "after.stl")

    assert_equal "same", adapter.read(@user, node_id:),
                 "a move must keep node_id resolving to the same bytes"
    assert_equal "after.stl", adapter.stat(@user, node_id:).name
  end

  # Tombstoned = gone is already pinned by the READ contract (§9a-1). This pins the other
  # half: delete gets you there, and it tombstones rather than destroying — the row is what
  # makes a project say "file missing" instead of the attachment vanishing.
  def test_mutation_contract_delete_tombstones_rather_than_destroying
    node_id = make_file(name: "bye.stl", bytes: "gone")
    adapter.delete(@user, node_id:)

    assert @user.nodes.find_by!(node_id:).deleted, "the row survives"
    assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id:) }
  end

  def test_mutation_contract_undelete_restores_the_same_node_and_bytes
    node_id = make_file(name: "back.stl", bytes: "restored")
    adapter.delete(@user, node_id:)
    adapter.undelete(@user, node_id:)

    assert_not @user.nodes.find_by!(node_id:).deleted
    assert_equal "restored", adapter.read(@user, node_id:)
  end

  # The capability from Task 1, asserted as a CONDITIONAL rather than a fixed expectation, because
  # both answers are correct and which one is right is a property of the backend.
  def test_mutation_contract_delete_refuses_a_directory_unless_dir_deletable
    dir_id = make_dir(name: "adir")
    if adapter.capabilities.dir_deletable?
      adapter.delete(@user, node_id: dir_id)
      assert @user.nodes.find_by!(node_id: dir_id).deleted, "a dir_deletable backend tombstones it"
    else
      assert_raises(FileLayer::UnsupportedOperation) { adapter.delete(@user, node_id: dir_id) }
      assert_not @user.nodes.find_by!(node_id: dir_id).deleted, "a refused delete must not half-apply"
    end
  end
end
