# The contract every adapter implementing the port's BYTE write path must satisfy -- `write`,
# which takes an IO. Separate from adapter_contract.rb (the read contract, which runs against
# every adapter) and from adapter_mutation_contract.rb (mkdir/move/delete/undelete, which ALSO
# runs against every adapter, chunk included, since Stage 2).
#
# Chunk does not implement THIS one and must never be made to: chunk-mode uploads are
# Sync::Commit's two-phase presigned flow, and a server-side byte write here would push bytes
# through Rails, which CLAUDE.md 15 forbids. That is a NARROWER claim than this header used to
# make -- it said chunk could not satisfy the write path at all, which stopped being true for the
# four metadata verbs when they moved to adapter_mutation_contract.rb.
#
# Include this into a writable adapter's test case. Share includes it now; S3 in Phase 3 —
# that is the point. The read contract's hooks (adapter, @user) are assumed; include this
# alongside it.
#
# TWO ADDITIONAL hooks the including test case must define:
#   change_store_content!(node_id, bytes) -> put different bytes at this node's location IN THE
#                                    STORE, BEHIND THE CATALOG — no scan, no port call, so the row
#                                    still names the old content. This is the whole premise of the
#                                    `expect_token:` pair below: it models the desktop edit the
#                                    catalog has not observed yet, which is the case a door
#                                    comparing tokens against `stat` structurally cannot see. It is
#                                    a hook rather than a shared body because "the store" is a
#                                    mounted directory on one backend and a bucket on the other,
#                                    and this module does not encode either layout (see the note
#                                    below about `.trash/<node_id>/<name>`).
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

  # `replace: true` IS THE OPT-IN THAT THE REFUSAL ABOVE IS THE DEFAULT FOR — and the two tests
  # belong side by side, because the whole claim is that adding this does not weaken that.
  # `write` refuses a clobber because an UNASKED write must never destroy bytes; `replace: true` is
  # a caller saying "I asked, and a user confirmed". Every existing caller omits it and gets the
  # refusal unchanged.
  #
  # THE NODE_ID MUST SURVIVE, and that is the assertion this test exists for rather than the bytes.
  # A replace implemented as delete-then-create would pass a bytes-only check while orphaning every
  # attachment, BOM link and tag pointing at that file — §14a's recorded landmine, whose whole
  # signature is that nothing errors and nothing logs. Same node, new content.
  #
  # In the CONTRACT rather than each adapter's suite for the reason the clobber test gives: the
  # mechanisms differ per backend (Share renames over the destination, S3 puts to the same key) and
  # the ANSWER must not.
  def test_write_contract_write_replaces_in_place_when_asked
    first = adapter.write(@user, parent_node_id: nil, name: "iterate.svg", io: StringIO.new("v1"))

    second = adapter.write(@user, parent_node_id: nil, name: "iterate.svg",
                           io: StringIO.new("v2-longer"), replace: true)

    assert_equal first.node_id, second.node_id,
                 "a replace must reuse the node — a new node_id orphans every attachment (§14a)"
    assert_equal "v2-longer", adapter.read(@user, node_id: first.node_id)
    assert_equal 1, @user.nodes.present.where(storage_path: "iterate.svg").count,
                 "a replace must leave ONE live node at that path, not a second alongside it"
    assert_equal "v2-longer".bytesize, @user.nodes.find_by!(node_id: first.node_id).size,
                 "the node's indexed size must follow the new content, or the next scan disagrees"
  end

  # `expect_token:` — A REPLACE MAY NAME THE CONTENT IT IS REPLACING, and naming the current one
  # changes nothing. Beside the pair above for the reason they are beside each other: the claim is
  # that each opt-in leaves the previous behaviour exactly where it was. Every existing caller
  # passes no token and none of the tests above changed.
  #
  # In the CONTRACT because the ANSWER is the port's while the MECHANISM is each backend's — Share
  # re-hashes the file, S3 HEADs the object through the identity ladder — which is the same split
  # the clobber and replace tests are here for.
  def test_write_contract_a_replace_naming_the_current_content_writes_in_place
    first = adapter.write(@user, parent_node_id: nil, name: "named.md", io: StringIO.new("v1"))

    second = adapter.write(@user, parent_node_id: nil, name: "named.md", io: StringIO.new("v2"),
                           replace: true, expect_token: first.content_token)

    assert_equal first.node_id, second.node_id,
                 "naming the current content is an ordinary replace — it must still reuse the node"
    assert_equal "v2", adapter.read(@user, node_id: first.node_id)
  end

  # AND NAMING CONTENT THE STORE NO LONGER HOLDS IS REFUSED WITH NOTHING WRITTEN. This is the test
  # the whole `expect_token:` pair exists for, and the fixture is what gives it teeth: the bytes are
  # changed IN THE STORE with no scan, so the CATALOG still names the caller's token. An adapter
  # that compared against `existing.content_hash` — the row — would find agreement and clobber, and
  # would pass a version of this test written with a made-up token. Only asking the store answers.
  #
  # That gap is not hypothetical: it is what Maker::TextSave's own stale check does, correctly, and
  # cannot close from where it stands (§14b's bounded staleness — a Finder edit made between render
  # and Save with no scan in between was overwritten, measured). The port is where "current" is
  # knowable, so this is where the refusal is.
  #
  # StaleContent, AND IT IS AN UnsupportedOperation — asserted rather than assumed, because the
  # subclass is what lets a caller that does NOT branch (every door passing no token, plus any
  # future one that forgets) keep the port's 422 instead of falling to a 500. Both halves of
  # "refused" are pinned: the class, and the store's own bytes still being there afterwards.
  def test_write_contract_a_replace_naming_stale_content_is_refused
    first = adapter.write(@user, parent_node_id: nil, name: "raced.md", io: StringIO.new("mine"))
    change_store_content!(first.node_id, "a desktop edit the scan has not seen")

    err = assert_raises(FileLayer::StaleContent) do
      adapter.write(@user, parent_node_id: nil, name: "raced.md", io: StringIO.new("clobber"),
                    replace: true, expect_token: first.content_token)
    end

    assert_kind_of FileLayer::UnsupportedOperation, err,
                   "a caller that does not branch must still get the port's ordinary refusal"
    assert_match(/changed since it was read/, err.message,
                 "the refusal must say WHY — this message is what a door turns into a sentence")
    assert_equal "a desktop edit the scan has not seen", adapter.read(@user, node_id: first.node_id),
                 "nothing may have been written: on a current-state-only backend there is no restore"
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

  # A DIRECTORY OCCUPIES A NAME EXACTLY AS A FILE DOES, and this is the CROSS-KIND half of the
  # test above rather than a repeat of it. The two adapters answer the same-kind case identically
  # and diverged on this one, which is precisely the shape this module exists to catch: Share
  # answers in ONE namespace (File.exist? is true for a directory), while S3 has two — a flat
  # keyspace where a file is `<key>` and a directory is `<key>/`, plus the `nodes` catalog, whose
  # only uniqueness rule is a KIND-AGNOSTIC partial unique index. Asking the bucket alone let all
  # four verbs through to a raw ActiveRecord::RecordNotUnique — a 500, after the object had been
  # written — and `move` reached it with the SOURCE ALREADY DELETED (§14a's copy -> delete ->
  # orphaned-node landmine). Share passed this the day it was written; that is the mechanism
  # working, not a reason to keep the test in one adapter's suite.
  #
  # THE CLASS IS WHAT THIS PINS, per the note above — plus the one backend-agnostic consequence
  # that makes "refused" mean something: the source is still there afterwards. Where the bytes
  # were NOT left (a stray marker, an undeleted source key) is storage layout and lives in the
  # adapter's own suite.
  def test_write_contract_a_directory_occupies_a_name_for_every_verb_that_writes
    adapter.mkdir(@user, parent_node_id: nil, name: "cad")
    mover = adapter.write(@user, parent_node_id: nil, name: "mover.stl", io: StringIO.new("bytes"))

    err = assert_raises(FileLayer::UnsupportedOperation, "write onto a directory's name") do
      adapter.write(@user, parent_node_id: nil, name: "cad", io: StringIO.new("file over a folder"))
    end
    assert_match(/already exists/, err.message,
                 "the same sentence the same-kind clobber gets — one condition, one answer")

    # The kinds swapped: mkdir over a FILE's name is the same condition read the other way.
    assert_raises(FileLayer::UnsupportedOperation, "mkdir over a file's name") do
      adapter.mkdir(@user, parent_node_id: nil, name: "mover.stl")
    end

    assert_raises(FileLayer::UnsupportedOperation, "move onto a directory's name") do
      adapter.move(@user, node_id: mover.node_id, new_parent_node_id: nil, new_name: "cad")
    end
    assert_equal "bytes", adapter.read(@user, node_id: mover.node_id),
                 "a refused move must leave the source readable — it is copy-then-delete on S3"
    assert_equal "mover.stl", @user.nodes.find_by!(node_id: mover.node_id).storage_path,
                 "and the row must still name where the bytes actually are"

    restorable = adapter.write(@user, parent_node_id: nil, name: "restore.stl", io: StringIO.new("r"))
    adapter.delete(@user, node_id: restorable.node_id)
    adapter.mkdir(@user, parent_node_id: nil, name: "restore.stl") # a folder takes the vacated name

    assert_raises(FileLayer::UnsupportedOperation, "undelete into a directory's name") do
      adapter.undelete(@user, node_id: restorable.node_id)
    end
    assert @user.nodes.find_by!(node_id: restorable.node_id).deleted,
           "a refused undelete must leave the node trashed, not half-restored"
  end

  # THE SKIP-LIST COUPLING, pinned for every writable backend. The observers skip OS clutter
  # (.DS_Store, ._*, __MACOSX/, macOS volume metadata) so it never becomes a node; the moment they
  # do, those names join `.trash`/`.maker-tmp-` as UNOBSERVABLE, so the write path must refuse them
  # as destinations too — or an upload named `.DS_Store`, a rename onto one, or a restore into a
  # `__MACOSX/` parent lands a live node at a path no scan can ever pair, which wedges the
  # mass-deletion guard PERMANENTLY (the blind spot phase 2b/4 paid for four times). The reject
  # predicate (`observable!`) and the observer skip are the SAME Library::OsClutter definition, so
  # they cannot drift. This is in the shared contract, not each adapter's suite, because the names,
  # the class and the message are identical on every current-state-only backend — the divergence
  # this module exists to stop.
  #
  # NotFound, NOT UnsupportedOperation, and the class is deliberate: it matches the existing
  # `.trash`/`.maker-tmp-` reserved-path refusal (Share#observable!/S3#observable! both raise
  # NotFound with /reserved path/), which is the class this coupling extends. A clobber is
  # UnsupportedOperation; a reserved/unobservable destination is NotFound. Two different refusals.
  OS_CLUTTER_DESTINATIONS = %w[.DS_Store ._resource.stl __MACOSX .Spotlight-V100].freeze

  def test_write_contract_write_refuses_os_clutter_destinations
    OS_CLUTTER_DESTINATIONS.each do |name|
      err = assert_raises(FileLayer::NotFound, "write(#{name.inspect}) must be refused") do
        adapter.write(@user, parent_node_id: nil, name: name, io: StringIO.new("x"))
      end
      assert_match(/reserved path/, err.message, name)
      assert_nil @user.nodes.find_by(storage_path: name),
                 "#{name.inspect} must not have landed a node — that is the wedge this prevents"
    end
  end

  def test_write_contract_move_refuses_os_clutter_destinations
    OS_CLUTTER_DESTINATIONS.each do |name|
      info = adapter.write(@user, parent_node_id: nil, name: "mv-#{name.delete('.')}.stl",
                                  io: StringIO.new("b"))
      err = assert_raises(FileLayer::NotFound, "move to #{name.inspect} must be refused") do
        adapter.move(@user, node_id: info.node_id, new_parent_node_id: nil, new_name: name)
      end
      assert_match(/reserved path/, err.message, name)
    end
  end

  # undelete does not take a destination from the caller — it RECONSTRUCTS one from the tombstone's
  # PARENT (delete NULLs the node's own storage_path). So a clutter segment reaches `observable!`
  # through a poisoned parent, not an argument, which is the exact route write/move cannot cover.
  # The poisoned-row standard (update_column) is the same one the reserved-path and escape-guard
  # tests use: storage_path is a plain column, and "no caller writes anything bad today" is the
  # assumption this coupling has been wrong about repeatedly.
  def test_write_contract_undelete_refuses_an_os_clutter_parent
    parent = @user.nodes.create!(node_id: SecureRandom.uuid, name: "sub", kind: "dir",
                                 deleted: false, storage_path: "sub")
    child = adapter.write(@user, parent_node_id: parent.node_id, name: "a.stl",
                                 io: StringIO.new("bytes"))
    adapter.delete(@user, node_id: child.node_id)

    parent.update_column(:storage_path, "__MACOSX")
    err = assert_raises(FileLayer::NotFound, "undelete into a __MACOSX parent must be refused") do
      adapter.undelete(@user, node_id: child.node_id)
    end
    assert_match(/reserved path/, err.message)
    # The restore was refused, not half-done: the node stays tombstoned and its bytes stay in the
    # trash, where a corrected undelete can still find them.
    assert @user.nodes.find_by!(node_id: child.node_id).deleted
  end

  # A GIT REPOSITORY'S OWN DIRECTORY — the same coupling the clutter block above pins, arrived at
  # from the opposite side. Library::RepoMetadata keeps the MARKER and skips what is under it: the
  # observers observe `.git` and refuse to descend, so `.git/**` is unobservable and must be
  # unwritable, or a write lands a live node at a path no observation can ever pair — the wedge
  # phase 2b/4 paid for four times.
  #
  # THE MARKER IS REFUSED TOO, though it is observable, and that asymmetry is deliberate rather
  # than an over-reach: nothing in this app has any business MINTING a `.git`. The real one arrives
  # on disk from git itself and is observed, never written by us, so refusing costs nothing real —
  # while allowing it lets a hand-made marker silently switch off the intake sweep for a whole
  # folder (Maker::AttachToProject's :in_working_tree reads exactly this marker and asks nothing
  # else). Refusing at-or-beneath needs no new predicate: RepoMetadata.marker_prefix is non-nil for
  # both, which is why `observable!` grows one term rather than a second raise.
  #
  # NotFound with /reserved path/, per the clutter block above: a clobber is UnsupportedOperation,
  # a reserved/unobservable destination is NotFound. Two different refusals.
  REPO_METADATA_DESTINATIONS = %w[.git].freeze

  def test_write_contract_write_refuses_repo_metadata_destinations
    REPO_METADATA_DESTINATIONS.each do |name|
      err = assert_raises(FileLayer::NotFound, "write(#{name.inspect}) must be refused") do
        adapter.write(@user, parent_node_id: nil, name: name, io: StringIO.new("x"))
      end
      assert_match(/reserved path/, err.message, name)
      assert_nil @user.nodes.find_by(storage_path: name),
                 "#{name.inspect} must not have landed a node — that is the wedge this prevents"
    end
  end

  def test_write_contract_move_refuses_repo_metadata_destinations
    REPO_METADATA_DESTINATIONS.each do |name|
      info = adapter.write(@user, parent_node_id: nil, name: "mv-#{name.delete('.')}.stl",
                                  io: StringIO.new("b"))
      err = assert_raises(FileLayer::NotFound, "move to #{name.inspect} must be refused") do
        adapter.move(@user, node_id: info.node_id, new_parent_node_id: nil, new_name: name)
      end
      assert_match(/reserved path/, err.message, name)
    end
  end

  # MINTING IS THE VERB THIS RULE IS ABOUT, so the directory-making one is pinned beside the two
  # above. `mkdir` is how a `.git` would actually be conjured through a web door — `write` puts a
  # FILE there, which a repo could at least survive, while a directory named `.git` is the thing
  # Maker::AttachToProject reads as "this is a working tree" and stops filing under. Both adapters
  # route mkdir through the same `observable!`, which is exactly the claim worth pinning rather
  # than assuming. (The clutter block above has this gap too; it is narrower there, because nobody
  # is trying to mint a `.DS_Store` DIRECTORY.)
  def test_write_contract_mkdir_refuses_repo_metadata_destinations
    REPO_METADATA_DESTINATIONS.each do |name|
      err = assert_raises(FileLayer::NotFound, "mkdir(#{name.inspect}) must be refused") do
        adapter.mkdir(@user, parent_node_id: nil, name: name)
      end
      assert_match(/reserved path/, err.message, name)
      assert_nil @user.nodes.find_by(storage_path: name),
                 "#{name.inspect} must not have landed a dir node — minting one is the whole point"
    end
  end

  # THE NEGATIVE CASE, AND THE BLOCK ABOVE IS UNSOUND WITHOUT IT. Every assertion so far is a
  # REFUSAL, so nothing above distinguishes "at-or-beneath a `.git` SEGMENT" from "any path
  # CONTAINING the characters `.git`" — a review replaced the guard's term with
  # `rel.to_s.include?(RepoMetadata::DIR_NAME)`, which still names the constant, and the whole
  # suite stayed green while `.gitignore`, `.gitmodules` and `.github/workflows/ci.yml` became
  # unwritable. Those are paths Library::Scanner explicitly INDEXES (pinned in its own suite), so
  # that mutation ships a destination the observer observes and the write guard 404s as a
  # "reserved path" — §14a's one-condition-two-answers, in the direction that makes a working
  # tree's own files un-uploadable. Task 3 gave both observer suites this exact negative case;
  # this restores the symmetry on the write half of the law.
  #
  # DEPTH IS LOAD-BEARING, and a root-only fixture would be a weaker test that looks the same. The
  # `.github` case is the one that fails a segment-PREFIX match (`.github` survives while
  # everything under it silently vanishes), and it cannot be written as a leaf — `leaf!` forbids
  # separators in `name` — so it is built through real mkdirs, which is also what proves mkdir does
  # not refuse the ancestors.
  def test_write_contract_git_adjacent_destinations_stay_writable
    %w[.gitignore .gitmodules].each do |name|
      info = adapter.write(@user, parent_node_id: nil, name: name, io: StringIO.new("tmp/"))
      assert_equal "tmp/", adapter.read(@user, node_id: info.node_id),
                   "#{name.inspect} is an ordinary file — a whole-segment rule must let it through"
    end

    dot_github = adapter.mkdir(@user, parent_node_id: nil, name: ".github")
    workflows = adapter.mkdir(@user, parent_node_id: dot_github.node_id, name: "workflows")
    ci = adapter.write(@user, parent_node_id: workflows.node_id, name: "ci.yml",
                              io: StringIO.new("on: push"))

    assert_equal "on: push", adapter.read(@user, node_id: ci.node_id),
                 "`.github/workflows/ci.yml` is indexed by the scan, so it must be writable too"
    assert_equal ".github/workflows/ci.yml",
                 @user.nodes.find_by!(node_id: ci.node_id).storage_path
  end

  # A destination BENEATH the marker, which no leaf name can express — the contents half of the
  # rule, and the half that is a ghost rather than a policy. Reached through a poisoned parent, the
  # same `update_column` standard the reserved-path and escape-guard tests use, for the reason they
  # state: storage_path is a plain column, and "no caller writes anything bad today" is the
  # assumption this coupling has been wrong about repeatedly.
  def test_write_contract_write_refuses_a_destination_beneath_the_marker
    parent = adapter.mkdir(@user, parent_node_id: nil, name: "firmware")
    @user.nodes.find_by!(node_id: parent.node_id).update_column(:storage_path, "firmware/.git")

    err = assert_raises(FileLayer::NotFound) do
      adapter.write(@user, parent_node_id: parent.node_id, name: "config", io: StringIO.new("x"))
    end
    assert_match(/reserved path/, err.message)
    assert_nil @user.nodes.find_by(storage_path: "firmware/.git/config"),
               "a node beneath the marker is unpairable — the tombstone wedges every later scan"
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
