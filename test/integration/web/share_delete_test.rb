require "test_helper"

module Web
  # Share-mode delete through the real controller. Verified before this task: #destroy called
  # Sync::Mutation on EVERY backend, which tombstones the row and moves nothing -- so the file
  # stayed on the NAS, the next scan observed it, and Reconciler#create_or_revive! revived the
  # node by storage_path. The user deleted a file in the web UI and it came back.
  #
  # A TEST THAT ONLY ASSERTS THE NODE IS TOMBSTONED PASSES ON THAT BUG: the bug tombstones
  # correctly. The two assertions that catch it are that the BYTES MOVED and that A SUBSEQUENT
  # SCAN DOES NOT REVIVE IT -- the second is the one the user actually experienced.
  #
  # `FileLayer.current =` rather than pin_file_layer_backend, for the reason ShareDeliveryTest
  # gives: a Share adapter needs a tmpdir root, which the ENV-rebuilding pin cannot supply. The
  # FileLayer.reset! in teardown is therefore load-bearing, not decoration.
  class ShareDeleteTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = Pathname.new(Dir.mktmpdir("share-delete"))
      @user = User.create!(email: "sdel-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      FileLayer.current = FileLayer::Share.new(root: @root.to_s)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end
    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def index!(rel, bytes)
      path = @root.join(rel)
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, bytes)
      scan!
      @user.nodes.find_by!(storage_path: rel).node_id
    end

    # max_delete_pct: 100 disables the mass-deletion guard -- these fixtures are one or two files,
    # so any deletion is a large fraction of the library and the guard, a percentage written for a
    # NAS archive, would refuse the scan. The guard has its own tests; this is about what the scan
    # does to a deleted node, which is a different question. (ShareTest's create_file! makes the
    # same call for the same reason.)
    def scan! = Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)

    test "a share-mode delete moves the bytes into .trash" do
      id = index!("bracket.stl", "solid bracket")

      delete file_path(id)
      assert_redirected_to files_path

      assert_not @root.join("bracket.stl").exist?, "the file must leave the indexed tree"
      trashed = @root.join(Library::Scanner::TRASH_PREFIX, id, "bracket.stl")
      assert trashed.exist?, "the bytes must be in .trash, recoverable -- a tombstone alone " \
                             "leaves them live at their old path"
      assert_equal "solid bracket", trashed.binread
    end

    # THE BUG, AS THE USER MET IT. Everything above can pass while this fails: the old code
    # tombstoned the row and left the file, so this scan observed it and revived the node.
    test "a share-mode delete survives the next scan -- it used to come back" do
      id = index!("bracket.stl", "solid bracket")
      delete file_path(id)
      assert @user.nodes.find_by!(node_id: id).deleted, "the node must be tombstoned"

      scan!

      assert @user.nodes.find_by!(node_id: id).deleted,
             "the scan revived the deleted node -- the bytes were never moved out of the " \
             "indexed tree, so create_or_revive! matched the tombstone by storage_path"
      assert_equal 0, @user.nodes.present.count
    end

    # storage_path: nil is what makes the revive above unable to fire (2b Landmine 2), so it is
    # asserted rather than left as an implementation detail: a trash tombstone that kept its path
    # would hand a NEW file dropped there this node's node_id, and with it every attachment.
    test "a share-mode delete releases the storage_path" do
      id = index!("bracket.stl", "solid bracket")
      delete file_path(id)
      node = @user.nodes.find_by!(node_id: id)
      assert node.deleted
      assert_nil node.storage_path
    end

    # The port refuses a directory delete (it would strand the children's nodes at paths that no
    # longer exist while their bytes sat in .trash, where the scan refuses to look -- a permanent
    # wedge). Pinned HERE because the controller is what turns that refusal into an answer a user
    # can read: FileLayer::UnsupportedOperation is a StandardError, so rescue_from reaches it.
    test "a share-mode delete of a directory is refused, not wedged" do
      FileUtils.mkdir_p(@root.join("cad"))
      File.binwrite(@root.join("cad/part.stl"), "part")
      scan!
      dir_id = @user.nodes.find_by!(storage_path: "cad", kind: "dir").node_id

      delete file_path(dir_id)
      assert_redirected_to files_path
      assert_match(/files only/, flash[:alert])
      assert_not @user.nodes.find_by!(node_id: dir_id).deleted, "the directory must survive"
      assert @root.join("cad/part.stl").exist?, "its children's bytes must not move"
    end
  end
end
