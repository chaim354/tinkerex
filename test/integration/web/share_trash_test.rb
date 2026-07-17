require "test_helper"

module Web
  # The share-mode trash, driven end to end through the real controller: delete in the UI, see it
  # in the trash, restore it, read the bytes back.
  #
  # Verified before this task: #index built @versions_by_node from current_user.versions, which is
  # EMPTY on share and s3 -- every Size cell an em-dash, the same lie #index and #show told before
  # Task 6. And #restore called Sync::Trash.restore on every backend, which on a share library is
  # not a recovery: it clears the tombstone while the bytes stay in `.trash`, leaving a live node
  # with a NULL storage_path that no scan sees and no read can open.
  #
  # `FileLayer.current =` rather than pin_file_layer_backend, for the reason ShareDeliveryTest
  # gives: a Share adapter needs a tmpdir root, which the ENV-rebuilding pin cannot supply.
  class ShareTrashTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = Pathname.new(Dir.mktmpdir("share-trash"))
      @user = User.create!(email: "strash-#{SecureRandom.hex(4)}@example.com",
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

    # See ShareDeleteTest#scan! -- the guard is a percentage written for a NAS archive and these
    # fixtures are two files.
    def scan! = Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)

    # THE WHOLE ROUND TRIP, which is what "make it work" has to mean. Each half of this passed
    # while the other was broken: the trash listed the node (from the row) while Restore left the
    # bytes stranded in `.trash`.
    test "a share-mode file survives delete -> trash -> restore -> read" do
      id = index!("bracket.stl", "solid bracket")

      delete file_path(id)
      get trash_index_path
      assert_response :success
      assert_select "td", text: "bracket.stl"

      post restore_trash_path(id)
      assert_redirected_to files_path

      node = @user.nodes.find_by!(node_id: id)
      assert_not node.deleted, "restore must clear the tombstone"
      assert_equal "bracket.stl", node.storage_path,
                   "restore must give the node its path back -- a live node with a NULL " \
                   "storage_path is invisible to the scan and unreadable through the port"
      assert @root.join("bracket.stl").exist?, "the bytes must be back in the indexed tree"
      assert_not @root.join(".trash", id, "bracket.stl").exist?, "and gone from .trash"

      # The user's actual test: can I open my file again?
      get blob_file_path(id)
      assert_response :success
      assert_equal "solid bracket", response.body
    end

    # A restore whose destination is now taken must be an ALERT, not a 500. TrashController's
    # rescue lists exactly this case ("something is already at that path"), and it reached it via
    # FileLayer::NotFound until the clobber fix moved the class -- at which point the rescue's
    # sentence still named the case and the rescue no longer caught it. Both adapters can meet it,
    # so both pin it (s3_write_test.rb has the mirror); this is the share half.
    test "restoring into an occupied path is refused with an alert, not a 500" do
      id = index!("bracket.stl", "solid")
      delete file_path(id)
      File.binwrite(@root.join("bracket.stl"), "someone else's file")

      post restore_trash_path(id)

      assert_redirected_to trash_index_path
      assert_match(/Couldn't restore/, flash[:alert])
      assert_equal "someone else's file", File.binread(@root.join("bracket.stl")),
                   "restore must never clobber a live file"
      assert @root.join(".trash", id, "bracket.stl").exist?,
             "and the trashed bytes must survive the refusal"
    end

    # THE LIE TASK 7 REPORTED, in the spelling it reported it in. The size lives on the node row
    # here, not on a Version, and the page has to read the port to find it.
    test "the trash reports a real size on the share backend -- it used to be an em-dash" do
      id = index!("bracket.stl", "0123456789")
      delete file_path(id)

      get trash_index_path
      assert_response :success
      assert_select "td.num", text: /10 Bytes/
    end

    # A restored file must be a NORMAL indexed file again -- one the scan RECOGNISES. The old
    # Sync::Trash.restore path left storage_path NULL, which the Reconciler cannot see at all
    # (it reads only nodes that HAVE one), so the node survived as a zombie: live in the listing,
    # pointing nowhere, its bytes sitting in `.trash` until the purge job reclaimed them.
    #
    # ASSERTING "no duplicate node_id" IS NOT ENOUGH AND THIS TEST SAID SO FIRST: it passed on the
    # bug. The zombie is not a duplicate -- there is exactly one node either way -- and the file is
    # not observable, so nothing was ever created to collide with it. What separates the two is
    # whether the node still points at real bytes AFTER the scan has had its say.
    test "a restored share file is indexed at its path and readable after the next scan" do
      id = index!("bracket.stl", "solid bracket")
      delete file_path(id)
      post restore_trash_path(id)

      scan!

      assert_equal [ id ], @user.nodes.present.where(kind: "file").pluck(:node_id),
                   "the restored file must be the same node, not a duplicate under a new id"
      assert_equal "bracket.stl", @user.nodes.find_by!(node_id: id).storage_path,
                   "a live node with a NULL storage_path is a zombie: the scan cannot see it, " \
                   "so it is never repaired and never tombstoned"
      get blob_file_path(id)
      assert_response :success
      assert_equal "solid bracket", response.body
    end

    # A scan tombstone is not a trash: the user removed the file on the NAS, so its bytes were
    # never moved anywhere we can reach. Offering Restore for it would be a button that always
    # fails -- which is the thing this phase exists to stop.
    test "a file deleted on the NAS is not offered for restore" do
      index!("ballast.stl", "still here") # see ShareTest -- an empty root reads as unmounted
      id = index!("gone.stl", "bye")
      FileUtils.rm_f(@root.join("gone.stl"))
      scan!
      assert @user.nodes.find_by!(node_id: id).deleted, "the scan must have tombstoned it"

      get trash_index_path
      assert_response :success
      assert_select "td", text: "gone.stl", count: 0
    end

    # The trash is a recovery surface, so its failures must not read as "your library is broken"
    # -- and above all an unmounted NAS must never read as "your file is permanently gone"
    # (FileLayer::NotFound is terminal; this is not).
    test "restoring from an unmounted share is retryable, not a 500" do
      id = index!("bracket.stl", "solid bracket")
      delete file_path(id)
      FileUtils.remove_entry(@root) # the NAS drops off the network mid-session
      FileUtils.mkdir_p(@root)      # an unmounted mount point: present, and empty

      post restore_trash_path(id)
      assert_redirected_to trash_index_path
      assert_match(/Try again/, flash[:alert])
      assert @user.nodes.find_by!(node_id: id).deleted, "and it must stay in the trash"
    end
  end
end
