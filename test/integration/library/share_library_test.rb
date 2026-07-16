require "test_helper"
require "tmpdir"

module Library
  # The promise of a share-backed library, end to end: point us at a folder, attach a file to a
  # project, let the user reorganize their NAS in Finder, and the attachment still resolves.
  #
  # Everything else in this phase is machinery in service of these assertions. The pieces have
  # their own unit tests (ScannerTest, ReconcilerTest, ShareTest + the shared adapter contract);
  # what only this file can catch is those pieces being individually right and jointly useless —
  # a real file on a real disk, a real scan, a real maker-layer attachment, real bytes back.
  #
  # The adapter is constructed EXPLICITLY rather than taken from FileLayer.current: this test is
  # about the Share adapter, so it says so, instead of asserting whatever LIBRARY_BACKEND the
  # process happens to carry. (That is also why it passes under both CI legs.)
  class ShareLibraryTest < ActiveSupport::TestCase
    setup do
      @root = Pathname.new(Dir.mktmpdir("share-e2e"))
      @user = User.create!(email: "e2e-#{SecureRandom.hex(4)}@example.com")
      @adapter = FileLayer::Share.new(root: @root.to_s)
    end
    teardown { FileUtils.remove_entry(@root) if @root&.exist? }

    # No max_delete_pct override anywhere in this file, deliberately: these scans run against the
    # deployment's real guard threshold, because "a reorganization is not a mass deletion" is one
    # of the things under test. Passing 100 here would disable the very mechanism the second test
    # is about.
    def scan! = Library::Scanner.call(@user, root: @root.to_s)

    test "a project attachment survives the user reorganizing their NAS" do
      FileUtils.mkdir_p(@root.join("stl"))
      File.binwrite(@root.join("stl/bracket.stl"), "solid bracket")
      scan!

      node = @user.nodes.find_by!(storage_path: "stl/bracket.stl")
      project = @user.maker_projects.create!(name: "Printer mods")
      attachment = project.file_attachments.create!(user: @user, node_id: node.node_id,
                                                    role: "model")

      # The user reorganizes in Finder: new folder, new name.
      FileUtils.mkdir_p(@root.join("cad/printer"))
      FileUtils.mv(@root.join("stl/bracket.stl"), @root.join("cad/printer/bracket-v2.stl"))
      FileUtils.rmdir(@root.join("stl"))
      scan!

      # The attachment is the thing under test, so read the bytes THROUGH it — via the node_id it
      # has been holding since before the move, never via a fresh lookup of the new path (which
      # would pass with the attachment orphaned, i.e. with the bug).
      assert_equal "solid bracket", @adapter.read(@user, node_id: attachment.node_id),
                   "the attachment must still resolve to the bytes after a reorganization"

      # And nothing rewrote the attachment to make that work: the NODE moved underneath it. That
      # is the whole design — a stable node_id reconciled by scan, so every attachment, BOM link,
      # tag and preview pointing at this file is untouched by a rename.
      assert_equal node.node_id, attachment.reload.node_id

      moved = @user.nodes.find_by!(node_id: attachment.node_id)
      assert_equal "cad/printer/bracket-v2.stl", moved.storage_path
      assert_not moved.deleted
      # The emptied directory is gone rather than lingering as a ghost folder in every browse view.
      assert @user.nodes.find_by!(storage_path: "stl", kind: "dir").deleted
    end

    # The guard (Task 7) fires on the POST-pairing tombstone count: here every file vanishes from
    # its old path at once — a 100% "vanish" against a 20% threshold — while the real deletion
    # count is zero. A guard reading the pre-pairing number would refuse the scan and make
    # wholesale reorganization, the exact thing a NAS user does, impossible.
    #
    # What this adds over the one-file case above is the multi-file reorganization end to end:
    # five simultaneous pairings through real files, real hashes and real adapter reads, where a
    # candidate consumed twice would show. It is NOT the guard's arithmetic — like the one-file
    # case, `doomed` is 0 and the guard short-circuits before the percentage. That arithmetic is
    # pinned in reconciler_test.rb (the 4/5 = 80% case), and the one-file test above already dies
    # if the guard is reverted to reading the pre-pairing count.
    test "reorganizing the whole library at once is not mistaken for a mass deletion" do
      FileUtils.mkdir_p(@root.join("old"))
      5.times { |i| File.binwrite(@root.join("old/f#{i}.stl"), "content #{i}") }
      scan!
      ids = @user.nodes.present.where(kind: "file").pluck(:storage_path, :node_id).to_h

      FileUtils.mkdir_p(@root.join("new"))
      5.times { |i| FileUtils.mv(@root.join("old/f#{i}.stl"), @root.join("new/g#{i}.stl")) }
      FileUtils.rmdir(@root.join("old"))

      assert_nothing_raised { scan! }

      5.times do |i|
        node = @user.nodes.find_by!(node_id: ids.fetch("old/f#{i}.stl"))
        assert_equal "new/g#{i}.stl", node.storage_path, "every file kept its node_id"
        assert_not node.deleted
        assert_equal "content #{i}", @adapter.read(@user, node_id: node.node_id)
      end
    end

    test "editing a file on disk gives it a new content token, so previews re-render" do
      File.binwrite(@root.join("e.stl"), "v1")
      scan!
      id = @user.nodes.find_by!(storage_path: "e.stl").node_id
      first = @adapter.stat(@user, node_id: id).content_token

      # No sleep to force an mtime change: the edit changes the SIZE (2 -> 12 bytes), and the
      # scan's skip condition is (path, mtime, size) ALL unchanged, so this file is re-hashed
      # deterministically — on any filesystem, whatever its mtime granularity.
      File.binwrite(@root.join("e.stl"), "v2 different")
      scan!

      assert_equal id, @user.nodes.find_by!(storage_path: "e.stl").node_id,
                   "an edit in place keeps the node_id; only the content token moves"
      assert_not_equal first, @adapter.stat(@user, node_id: id).content_token
      assert_equal "v2 different", @adapter.read(@user, node_id: id)
      # A preview keyed on the old token must not resolve — it describes content that is gone.
      # Share keeps no history, so answering with the CURRENT bytes would silently hand back
      # content that is not the content asked for.
      assert_raises(FileLayer::NotFound) { @adapter.read(@user, node_id: id, content_token: first) }
    end
  end
end
