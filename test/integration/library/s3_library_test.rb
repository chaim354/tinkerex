require "test_helper"
require_relative "../../support/fake_s3"

module Library
  # The promise of an S3-backed library, end to end: point us at a bucket that already has the
  # user's files in it, attach an object to a project, let the user reorganize it with whatever
  # tool they like, and the attachment still resolves to the bytes.
  #
  # This is the sibling of share_library_test.rb, and deliberately the same shape: everything else
  # in this phase is machinery in service of these assertions. The pieces have their own unit tests
  # (ObjectIdentityTest, S3ObserverTest, ReconcilerTest, s3_test.rb + both shared contracts); what
  # only this file can catch is those pieces being individually right and jointly useless — a real
  # bucket listing, a real reconcile, a real maker-layer attachment, real bytes back.
  #
  # The adapter is constructed EXPLICITLY rather than taken from FileLayer.current: this test is
  # about the S3 adapter, so it says so, instead of asserting whatever LIBRARY_BACKEND the process
  # happens to carry. (That is also why it passes under all three CI legs.)
  #
  # And it drives Library::S3Observer DIRECTLY rather than Library::ScanJob, mirroring the share
  # sibling's Library::Scanner.call, for a reason that is not style: ScanJob resolves its adapter
  # from FileLayer.current, which builds from ENV — it has no seam for the fake client, so going
  # through the job would test the ambient backend rather than this one. The job's own job (that
  # its `scannable?` gate reaches this observer at all) is Task 8's, and is pinned in
  # test/jobs/library/scan_job_test.rb.
  class S3LibraryTest < ActiveSupport::TestCase
    PREFIX = "library".freeze

    setup do
      @fake = FakeS3.new
      @user = User.create!(email: "s3e2e-#{SecureRandom.hex(4)}@example.com")
      @adapter = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                   secret_access_key: "sk", prefix: PREFIX, client: @fake.client)
    end

    # No max_delete_pct override anywhere in this file, deliberately — the share sibling's reason
    # transfers verbatim: these scans run against the deployment's real guard threshold, because
    # "a reorganization is not a mass deletion" is one of the things under test. Passing 100 would
    # disable the very mechanism the second test is about.
    #
    # This is a DEPARTURE FROM THE PLAN, which drafted every scan here as `scan!(max_delete_pct: 100)`.
    # See the first test for what that would have cost.
    def scan! = Library::S3Observer.call(@user, adapter: @adapter)

    # Seeded, never written through @adapter#write — the premise of this backend is that the bucket
    # ALREADY HAS THE USER'S FILES IN IT, put there by some other tool. Setting the fixture up with
    # our own write path would prove only that the app can read back what the app wrote, which is
    # not the claim. (The write path has its own test below, and its own shared contract.)
    def seed!(rel, body, **kw) = @fake.seed!("#{PREFIX}/#{rel}", body, **kw)

    # `s3 mv` / rclone / Cyberduck / the console: the object appears under a new key, byte-identical,
    # and nothing tells us it happened. Deliberately NOT @adapter#move — that is the app moving its
    # own file and it knows the node_id; the case this backend exists to survive is the one where it
    # does not.
    def mv!(from, to) = @fake.objects["#{PREFIX}/#{to}"] = @fake.objects.delete("#{PREFIX}/#{from}")

    # THE HEADLINE. A user renames one file in a library of several — and the ballast is the point
    # of the fixture, not padding.
    #
    # The share sibling moves the library's ONLY file, which is a 100% vanish. That is a fine test
    # of the guard's post-pairing rule, and it is the second test below. But it is the WRONG fixture
    # for THIS claim, and the difference is what a mutation shows: break Reconciler#best_pairing and
    # a one-file library dies at `scan!` with UnsafeScan 1/1 — the guard catching it, incidentally,
    # before the attachment is ever consulted. The orphaned attachment this test is named for is
    # never reached, so the assertion that matters is never exercised.
    #
    # With five untouched neighbours the same break lands at 1/6 = 16.7%, under the 20% threshold —
    # the guard waves it through, exactly as it would in a real library, the old node is tombstoned
    # and a new node_id is minted for the new key. THEN the attachment is orphaned, and THEN the
    # read through it is the only thing standing between that and a green suite. Verified by
    # mutation, not reasoned.
    #
    # Which is also the realistic shape: renaming one file out of six is what a user does. A library
    # whose only file moves is the degenerate case where the guard happens to backstop the bug.
    test "a project attachment survives the user reorganizing their bucket" do
      seed!("stl/bracket.stl", "solid bracket")
      5.times { |i| seed!("misc/keep#{i}.stl", "ballast #{i}") }
      scan!

      node = @user.nodes.find_by!(storage_path: "stl/bracket.stl")
      project = @user.maker_projects.create!(name: "Printer mods")
      attachment = project.file_attachments.create!(user: @user, node_id: node.node_id,
                                                    role: "model")

      # The user reorganizes: new prefix, new name.
      mv!("stl/bracket.stl", "cad/printer/bracket-v2.stl")
      scan!

      # The attachment is the thing under test, so read the bytes THROUGH it — via the node_id it
      # has been holding since before the move, never via a fresh lookup of the new path (which
      # would pass with the attachment orphaned, i.e. with the bug).
      assert_equal "solid bracket", @adapter.read(@user, node_id: attachment.node_id),
                   "the attachment must still resolve to the bytes after a reorganization"

      # And nothing rewrote the attachment to make that work: the NODE moved underneath it. That is
      # the whole design — a stable node_id reconciled by scan, so every attachment, BOM link, tag
      # and preview pointing at this object is untouched by a rename.
      assert_equal node.node_id, attachment.reload.node_id

      moved = @user.nodes.find_by!(node_id: attachment.node_id)
      assert_equal "cad/printer/bracket-v2.stl", moved.storage_path
      assert_not moved.deleted

      # S3 HAS NO DIRECTORIES, so the tree on both sides of the move is synthesized from key
      # prefixes and nothing else. The new chain exists...
      assert_equal moved.parent_node_id,
                   @user.nodes.find_by!(storage_path: "cad/printer", kind: "dir").node_id
      assert_not @user.nodes.find_by!(storage_path: "cad", kind: "dir").deleted
      # ...and the emptied one is gone, rather than lingering as a ghost folder in every browse
      # view. `stl` has no key of its own to disappear — it stops existing because its only child
      # moved, which is the only way a prefix can.
      assert @user.nodes.find_by!(storage_path: "stl", kind: "dir").deleted
    end

    # The guard fires on the POST-pairing tombstone count: here every object vanishes from its old
    # key at once — a 100% "vanish" against a 20% threshold — while the real deletion count is zero.
    # A guard reading the pre-pairing number would refuse the scan and make wholesale reorganization,
    # the exact thing a bucket owner does with `aws s3 mv --recursive`, impossible.
    #
    # This is the fixture the first test deliberately is NOT, and the pair covers what neither does
    # alone: revert the guard to reading vanished_paths and THIS one dies (5/5 = 100%), while the
    # first stays green at 16.7%. Break the pairing and the FIRST one dies on the attachment, while
    # this one dies here. Two mutations, two tests, one each.
    #
    # What it adds beyond the arithmetic (which is pinned in reconciler_test.rb) is the multi-object
    # reorganization end to end through real listings, real ETags and real adapter reads, where a
    # candidate consumed twice would show.
    test "reorganizing the whole bucket at once is not mistaken for a mass deletion" do
      5.times { |i| seed!("old/f#{i}.stl", "content #{i}") }
      scan!
      ids = @user.nodes.present.where(kind: "file").pluck(:storage_path, :node_id).to_h

      5.times { |i| mv!("old/f#{i}.stl", "new/g#{i}.stl") }

      assert_nothing_raised { scan! }

      5.times do |i|
        node = @user.nodes.find_by!(node_id: ids.fetch("old/f#{i}.stl"))
        assert_equal "new/g#{i}.stl", node.storage_path, "every object kept its node_id"
        assert_not node.deleted
        assert_equal "content #{i}", @adapter.read(@user, node_id: node.node_id)
      end
    end

    # SAME SIZE, SAME last_modified, DIFFERENT BYTES — and all three halves of that are the test.
    #
    # The share sibling cannot do this: it has no identity in hand, so its skip is (mtime, size) and
    # its edit test has to change the SIZE to be noticed at all. S3 is the case where that is not
    # good enough, and Reconciler#unchanged? says so: `last_modified` is SECOND-granularity, so an
    # edit landing in the same second as the last one, at the same size, is INVISIBLE to (mtime,
    # size) and would be skipped forever. The ETag is what closes that window, and this fixture is
    # the window — drop the identity half of `unchanged?` and this test is the one that dies.
    test "editing an object gives it a new content token, so previews re-render" do
      seed!("e.stl", "v1")
      scan!
      id = @user.nodes.find_by!(storage_path: "e.stl").node_id
      first = @adapter.stat(@user, node_id: id).content_token

      seed!("e.stl", "v2") # 2 bytes -> 2 bytes, at the identical last_modified
      scan!

      assert_equal id, @user.nodes.find_by!(storage_path: "e.stl").node_id,
                   "an edit in place keeps the node_id; only the content token moves"
      assert_not_equal first, @adapter.stat(@user, node_id: id).content_token
      assert_equal "v2", @adapter.read(@user, node_id: id)
      # A preview keyed on the old token must not resolve — it describes content that is gone. S3
      # keeps no history, so answering with the CURRENT bytes would silently hand back content that
      # is not the content asked for.
      assert_raises(FileLayer::NotFound) { @adapter.read(@user, node_id: id, content_token: first) }
    end

    # The write path's headline claim, end to end: bytes the app itself put in the bucket can be
    # attached to, deleted, and restored, and the attachment holds the same node_id throughout.
    #
    # The reads THROUGH `attachment.node_id` are what carry this test. The delete/undelete pair
    # never touches Maker::FileAttachment at all — no code path here can rewrite it — so asserting
    # its node_id is unchanged proves nothing on its own. What can fail is the NODE: undelete
    # reviving the tombstone rather than minting a new row is the whole promise, and the only way to
    # see it is to resolve the id the attachment has been holding since before the delete.
    test "upload, attach, delete to trash, undelete — the attachment survives all of it" do
      info = @adapter.write(@user, parent_node_id: nil, name: "bracket.stl",
                            io: StringIO.new("solid bracket"))
      project = @user.maker_projects.create!(name: "Printer mods")
      attachment = project.file_attachments.create!(user: @user, node_id: info.node_id,
                                                    role: "model")
      assert_equal "solid bracket", @adapter.read(@user, node_id: attachment.node_id)

      @adapter.delete(@user, node_id: info.node_id)

      # The attachment still NAMES the node — a project shows "file missing" rather than an
      # attachment silently vanishing.
      assert_equal info.node_id, attachment.reload.node_id
      assert @user.nodes.find_by!(node_id: info.node_id).deleted
      # ...and the bytes really MOVED, rather than a flag being flipped over an object still sitting
      # at its key. Asserted on the bucket because the raise below cannot see it: `read` refuses on
      # the tombstone in live_node! and never reaches S3, so without this the delete could leave the
      # object exactly where it was and every assertion here would still pass.
      assert_not @fake.objects.key?("#{PREFIX}/bracket.stl"),
                 "delete must move the bytes out of the library keyspace"
      assert_equal [ "solid bracket" ],
                   @fake.objects.select { |k, _| k.start_with?("#{PREFIX}/.trash/") }
                        .values.map(&:body)
      assert_raises(FileLayer::NotFound) { @adapter.read(@user, node_id: attachment.node_id) }

      # Undeleted: the same node_id resolves to the same bytes. Reviving the tombstone rather than
      # creating a new node is what makes this hold — a fresh node_id would leave the attachment
      # pointing at a row that no longer describes the object, and this read would raise.
      @adapter.undelete(@user, node_id: info.node_id)
      assert_equal info.node_id, attachment.reload.node_id
      assert_equal "solid bracket", @adapter.read(@user, node_id: attachment.node_id),
                   "the attachment must resolve to the bytes again after an undelete"
    end

    # The structural hazard the whole delete design is shaped around (spec §6): bytes copied into
    # `.trash` are in the one region the observer refuses to list, so a live node still pointing at
    # the old key could never be paired and the scan would want to tombstone it — or, in the other
    # direction, a tombstone that kept its storage_path would be REVIVED by the next observation of
    # that key. Both are invisible to the unit tests, which do not run a scan over a real trashed
    # object.
    #
    # No max_delete_pct override, and it is not needed for the reason that IS the design: `delete`
    # sets `deleted: true`, which keeps the node out of `present`, which is what
    # observable_live_paths plucks — so a port-deleted object is invisible to vanished_paths,
    # doomed is 0, and the guard short-circuits before it computes a percentage. (The plan drafted
    # this test with `max_delete_pct: 100`, which would have hidden exactly that.)
    test "a trash-deleted object stays deleted across a scan, and the trash is never indexed" do
      info = @adapter.write(@user, parent_node_id: nil, name: "gone.stl", io: StringIO.new("bye"))
      @adapter.delete(@user, node_id: info.node_id)

      scan!
      scan! # twice: a resurrection bug often needs a second pass to show

      assert @user.nodes.find_by!(node_id: info.node_id).deleted,
             "the scan must not resurrect a trashed object (the pull_snapshot ghost class, spec §6)"
      assert_equal 0, @user.nodes.present.where(kind: "file").count
      assert_equal 0, @user.nodes.where("storage_path LIKE '.trash%'").count
    end

    # A UI delete is not a mass deletion, settled end to end. It holds for the reason spelled out
    # above: `deleted: true` keeps the node out of the guard's numerator entirely.
    #
    # Take the tombstone out of FileLayer::S3#delete and this dies with `UnsafeScan 4/5 (80.0% > 20%)`,
    # which is the mutation this test is for.
    test "deleting most of the library through the port does not refuse the next scan" do
      ids = 5.times.map do |i|
        @adapter.write(@user, parent_node_id: nil, name: "f#{i}.stl", io: StringIO.new("x#{i}")).node_id
      end
      ids.first(4).each { |id| @adapter.delete(@user, node_id: id) } # 80% >> the 20% threshold

      assert_nothing_raised { scan! }
      assert_equal 1, @user.nodes.present.where(kind: "file").count
      # The survivor kept its node_id through a scan that saw four of its neighbours disappear — the
      # scan must not have paired it against one of the trashed objects.
      assert_equal "x4", @adapter.read(@user, node_id: ids.last)
    end
  end
end
