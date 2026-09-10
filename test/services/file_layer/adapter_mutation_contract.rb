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
#   - `undelete`'s DESTINATION FOR AN ORPHAN is NOT on this list any more either. It used to read
#     "Share restores under the (tombstoned) parent's path... chunk restores to the ROOT... Both
#     are right for their backend" -- that divergence is now CLOSED: an orphaned restore is
#     REFUSED on every backend that can reach the state at all, rather than answered differently
#     per adapter (CLAUDE.md 14a has the full argument for why the old rule was overturned by its
#     own recorded evidence). Pinned below, gated on `dir_deletable?` for the same reason the
#     delete-refusal test further down is: a cascading directory delete is the only PORT door that
#     ever produces a live child under a tombstoned parent, and share/s3 have no such door at all
#     -- see test_mutation_contract_undelete_refuses_an_orphan_whose_parent_is_still_tombstoned.
#   - A MOVE ONTO A TAKEN NAME is NOT on this list any more -- Task 4 closed it. All three
#     backends now refuse it identically through the port (UnsupportedOperation), pinned below
#     rather than left to each adapter's own suite -- see
#     test_mutation_contract_move_refuses_a_taken_destination for what that closes and what it
#     deliberately does not (the sync engine's OWN doors, e.g. a device push through the mount,
#     are untouched -- CLAUDE.md 14c's recorded gap stays open. NOT 12 item 11, which is about
#     a project-scoped upload deduping per-folder rather than project-wide -- a different gap one
#     layer up, and an easy mis-citation because both end in a duplicate name).
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

  # UNLIKE "A MOVE ONTO A TAKEN NAME" ABOVE, THIS ONE MUST ANSWER IDENTICALLY ON EVERY BACKEND --
  # CLAUDE.md 14a's whole point, and the reason it does not join that list of deliberate
  # divergences. mkdir's own idempotence check above is scoped `kind: "dir"`, so it is blind to a
  # live FILE already at this exact (parent_node_id, name); without a refusal here a backend could
  # silently mint a dir node and a file node sharing one identity, and no real filesystem can
  # represent that as a single directory entry -- every mount (FUSE/CfAPI/WebDAV) eventually hits
  # it as an unrepresentable collision. Share and s3 already refuse this on their own
  # (Share#mkdir's `dest.exist? && !dest.directory?`; S3#mkdir's `destination_vacant!`); this pins
  # them to keep doing so, and pins Chunk to the same answer, rather than trusting any of the
  # three not to drift.
  def test_mutation_contract_mkdir_refuses_a_cross_kind_collision
    make_file(name: "mover.stl", bytes: "b")
    assert_raises(FileLayer::UnsupportedOperation) do
      adapter.mkdir(@user, parent_node_id: nil, name: "mover.stl")
    end
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

  # THE PORT'S ANSWER TO "THE DESTINATION IS TAKEN" ON MOVE, PINNED ACROSS ALL THREE BACKENDS AS
  # OF TASK 4 -- see the header note above for what this closes (every PORT caller now gets one
  # answer) and what it deliberately does not (the sync engine's own doors -- CLAUDE.md 14c's
  # recorded gap stays open: a device push through the mount can still land a duplicate sibling on
  # chunk, because Sync::Commit validates a manifest exhaustively and the name not at all. NOT
  # 12 item 11, which is a different gap one layer up -- see the module header).
  def test_mutation_contract_move_refuses_a_taken_destination
    a = make_file(name: "a.stl", bytes: "aaa")
    make_file(name: "b.stl", bytes: "bbb")

    assert_raises(FileLayer::UnsupportedOperation) do
      adapter.move(@user, node_id: a, new_parent_node_id: nil, new_name: "b.stl")
    end
  end

  # THE CASE AN OVER-EAGER VERSION OF THAT REFUSAL BREAKS: a no-op move -- same parent, same name
  # -- must stay legal, because the clobber check has to exclude the node being moved from its
  # own destination lookup. Without that exclusion a node collides with ITSELF the moment it is
  # asked to "move" to where it already is -- exactly what Maker::MoveNode.collision?'s
  # except_node_id: parameter exists to prevent on the web side, and what CLAUDE.md 15's mutation-
  # check step (Task 4's report) pins by dropping the exclusion and watching this go red.
  def test_mutation_contract_move_onto_its_own_current_name_is_not_a_collision
    node_id = make_file(name: "a.stl", bytes: "aaa")

    adapter.move(@user, node_id:, new_parent_node_id: nil, new_name: "a.stl")

    assert_equal "a.stl", adapter.stat(@user, node_id:).name
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

  # THE PORT'S ERROR TAXONOMY IS CLOSED, AND undelete IS WHERE IT LEAKED. Chunk delegates to
  # Sync::Trash.restore, which opens with find_by! and so raised ActiveRecord::RecordNotFound --
  # a class from OUTSIDE FileLayer's vocabulary -- where share and s3 both answered
  # FileLayer::NotFound. It went unnoticed because TrashController happens to rescue both classes;
  # a caller rescuing FileLayer::* alone would have missed it entirely.
  #
  # Pinned HERE rather than in one adapter's suite because "which class does the port raise" is a
  # property of the PORT, not of a backend -- the same argument adapter_write_contract.rb makes for
  # putting the clobber class in a contract rather than leaving it to each adapter's taste.
  def test_mutation_contract_undelete_raises_the_ports_own_not_found_for_an_unknown_node
    assert_raises(FileLayer::NotFound) do
      adapter.undelete(@user, node_id: "no-such-node-#{SecureRandom.uuid}")
    end
  end

  def test_mutation_contract_undelete_restores_the_same_node_and_bytes
    node_id = make_file(name: "back.stl", bytes: "restored")
    adapter.delete(@user, node_id:)
    adapter.undelete(@user, node_id:)

    assert_not @user.nodes.find_by!(node_id:).deleted
    assert_equal "restored", adapter.read(@user, node_id:)
  end

  # AN ORPHANED RESTORE MUST ANSWER THE SAME WAY ON EVERY BACKEND THAT CAN REACH THE STATE AT
  # ALL -- CLAUDE.md 14a's rule, and its own reversal. This used to be a documented, PERMITTED
  # divergence (see this file's header, before it was rewritten): chunk reparented the orphan to
  # the library root, chunk_remote's server refused with a 409. A real journey suite against a
  # standalone sync server is what caught the two disagreeing (§15: probe over argument, not for
  # the first time). Both now refuse: an outcome that is silent, reached on the MAINLINE path (one
  # cascading directory delete orphans every descendant), and irreversible once taken, is worth
  # refusing even though refusing is less convenient than reparenting to the root -- a refusal is
  # recoverable (restore the folder, then the file); a scatter is not.
  #
  # UNCONDITIONAL SINCE 2026-09-10. This was gated on `dir_deletable?` and SKIPPED on share and s3,
  # where a directory delete was refused outright and the state was structurally unreachable. All
  # three cascade now, so all three can tombstone a parent out from under a live child, and all
  # three must refuse the restore rather than reparent the orphan to the root — a refusal is
  # recoverable, a scatter is not.
  #
  # THE ADAPTERS DISCRIMINATE ON THE TOMBSTONE KIND, NOT ON `deleted:`, and this test only reaches
  # the trash kind. A SCAN tombstone keeps `storage_path` and restoring into one is self-healing
  # (the folder is recreated, that is positive evidence, and the next scan revives the same dir
  # node). Writing this refusal as `parent&.deleted?` breaks that, which share's own suite caught.
  def test_mutation_contract_undelete_refuses_an_orphan_whose_parent_is_still_tombstoned
    dir_id = make_dir(name: "orphan-parent")
    child_id = make_file(name: "kid.stl", bytes: "b")
    adapter.move(@user, node_id: child_id, new_parent_node_id: dir_id, new_name: "kid.stl")

    adapter.delete(@user, node_id: dir_id) # cascades -- dir AND child are now tombstoned

    assert_raises(FileLayer::UnsupportedOperation) do
      adapter.undelete(@user, node_id: child_id)
    end
    assert @user.nodes.find_by!(node_id: child_id).deleted,
           "a refused restore must not half-apply"
  end

  # The capability from Task 1, asserted as a CONDITIONAL rather than a fixed expectation, because
  # both answers are correct and which one is right is a property of the backend.
  # UNCONDITIONAL SINCE 2026-09-10, and that is the point rather than a simplification. This was a
  # conditional keyed on `dir_deletable?` while share and s3 refused a directory delete; both cascade
  # now, the capability is gone, and a directory delete is part of the contract EVERY backend
  # answers. A shared assertion is the only thing that can catch the two adapters diverging here.
  def test_mutation_contract_delete_cascades_a_directory
    dir_id = make_dir(name: "adir")
    child_id = make_file(name: "kid.stl", bytes: "b")
    adapter.move(@user, node_id: child_id, new_parent_node_id: dir_id, new_name: "kid.stl")

    adapter.delete(@user, node_id: dir_id)

    assert @user.nodes.find_by!(node_id: dir_id).deleted, "the directory is not tombstoned"
    # THE CHILD IS THE ASSERTION THAT MATTERS. A directory tombstoned alone leaves its children live
    # at paths whose bytes have moved into `.trash`, where the scan refuses to look — nothing can
    # pair them, and the mass-deletion guard then refuses that scan and every scan after it.
    assert @user.nodes.find_by!(node_id: child_id).deleted,
           "a child survived as a live node under a deleted directory"
    assert_nil @user.nodes.find_by!(node_id: child_id).storage_path,
               "a trash tombstone must release its path or create_or_revive! will revive it"
  end
end
