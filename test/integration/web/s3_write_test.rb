require "test_helper"
require_relative "../../support/fake_s3"

module Web
  # The S3-mode WRITE path through the real controller: upload, delete, trash, restore.
  #
  # WHY THIS FILE EXISTS. s3_delivery_test.rb is delivery-only, so nothing drove
  # FilesController#create / #destroy or TrashController in s3 mode -- while share had all three
  # (share_delivery_test.rb, share_delete_test.rb, share_trash_test.rb). The risk is genuinely low
  # (the `port_writable` branch these actions take is ONE branch, shared with share, and a
  # whole-branch review probed all five of these and found them green), so this is about locking
  # the coverage in, not about a suspected bug.
  #
  # THE ASYMMETRY IS THE POINT, not the individual assertions. Every one of these is a
  # controller-layer question the adapter's own suite structurally cannot answer -- s3_test.rb
  # pins what FileLayer::S3 does when CALLED, and these pin that the controller calls it, on this
  # backend, for these buttons. Share had that pinned on both halves and s3 on neither; a
  # regression in the shared branch would have been caught by share's tests and reported as a
  # share bug, and one in an s3-only path by nothing at all.
  #
  # `FileLayer.current =` rather than pin_file_layer_backend, for the reason S3DeliveryTest gives:
  # an S3 adapter needs an injected stub client, which the ENV-rebuilding pin cannot supply. The
  # FileLayer.reset! in teardown is therefore load-bearing, not decoration.
  class S3WriteTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    PREFIX = "library".freeze

    setup do
      @fake = FakeS3.new
      @user = User.create!(email: "s3w-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                            secret_access_key: "sk", prefix: PREFIX,
                                            client: @fake.client)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end
    teardown { FileLayer.reset! }

    # Seeded as another tool would have (s3 cp / the console), then indexed with THE REAL OBSERVER
    # -- the call Library::ScanJob makes in production. max_delete_pct: 100 for s3_test.rb's
    # reason: a fixture is not about the mass-deletion guard, and these are one or two objects.
    def index!(rel, bytes)
      @fake.seed!("#{PREFIX}/#{rel}", bytes, last_modified: Time.now)
      scan!
      @user.nodes.find_by!(storage_path: rel).node_id
    end

    def scan! = Library::S3Observer.call(@user, adapter: FileLayer.current, max_delete_pct: 100)

    def upload!(name, bytes)
      post files_path, params: {
        file: Rack::Test::UploadedFile.new(StringIO.new(bytes), "application/octet-stream",
                                           original_filename: name)
      }
    end

    # --- #create ---------------------------------------------------------------

    test "the direct upload writes through the port in s3 mode" do
      upload!("bracket.stl", "solid bracket")

      assert_response :redirect
      assert_equal "solid bracket", @fake.objects["#{PREFIX}/bracket.stl"].body,
                   "the bytes must reach the user's bucket"
      assert @user.nodes.find_by(storage_path: "bracket.stl"), "and the node must be indexed"
    end

    # The upload must not wait on a scan to become usable -- #create redirects to the file's own
    # page, so a node that only appeared 15 minutes later would 404 the page it just sent you to.
    test "an uploaded file is immediately browsable, not scan-interval later" do
      upload!("gear.stl", "gear")
      follow_redirect!

      assert_response :success
      assert_match(/gear\.stl/, response.body)
    end

    # Item 2's user-visible half, on the second adapter: the contract pins the class, this pins
    # that the class reaches the user as something they can act on. "File not found." about a file
    # in the list is the answer this replaced.
    test "a duplicate-name upload says the name is taken, not 'File not found'" do
      upload!("dupe.stl", "first")
      upload!("dupe.stl", "second")

      assert_redirected_to files_path
      assert_match(/already exists/, flash[:alert])
      assert_no_match(/not found/i, flash[:alert])
      assert_equal "first", @fake.objects["#{PREFIX}/dupe.stl"].body, "the original bytes survive"
    end

    # --- #destroy --------------------------------------------------------------

    # The share-mode bug in its s3 spelling: #destroy used to call Sync::Mutation on EVERY
    # backend, which tombstones the row and moves nothing. A TEST THAT ONLY ASSERTS THE TOMBSTONE
    # PASSES ON THAT BUG -- it tombstones correctly. The object moving is the assertion that
    # catches it.
    test "an s3-mode delete copies the object into the trash prefix" do
      id = index!("bracket.stl", "solid bracket")

      delete file_path(id)
      assert_redirected_to files_path

      assert_nil @fake.objects["#{PREFIX}/bracket.stl"], "the object must leave the indexed prefix"
      trashed = @fake.objects["#{PREFIX}/#{Library::Scanner::TRASH_PREFIX}/#{id}/bracket.stl"]
      assert trashed, "the bytes must be in the trash prefix, recoverable -- a tombstone alone " \
                      "leaves them live at their old key"
      assert_equal "solid bracket", trashed.body
    end

    # THE BUG AS THE USER MET IT, and the half that a tombstone-only assertion cannot reach: the
    # object was never moved, so the next scan observed it and revived the node by storage_path.
    # The user deleted a file and it came back.
    test "an s3-mode delete survives the next scan -- it used to come back" do
      id = index!("bracket.stl", "solid bracket")
      delete file_path(id)
      assert @user.nodes.find_by!(node_id: id).deleted, "the node must be tombstoned"

      scan!

      assert @user.nodes.find_by!(node_id: id).deleted,
             "the scan revived the deleted node -- the object was never copied out of the " \
             "indexed prefix, so create_or_revive! matched the tombstone by storage_path"
      assert_equal 0, @user.nodes.present.count
    end

    # 2b Landmine 2, which S3 inherits exactly: a trash tombstone that KEPT its storage_path would
    # hand a new, unrelated object dropped at that key this node's node_id -- and with it every
    # attachment -- while the old bytes waited in the trash for an undelete that would then
    # collide. Nulling it is what makes the revive above unable to fire.
    test "an s3-mode delete releases the storage_path" do
      id = index!("bracket.stl", "solid bracket")
      delete file_path(id)

      node = @user.nodes.find_by!(node_id: id)
      assert node.deleted
      assert_nil node.storage_path
    end

    # S3 refuses a directory delete, and diverges from Share by refusing a directory MOVE too --
    # there is no directory and no rename here, so a dir node's key simply does not exist. Pinned
    # at the controller because that is what turns the refusal into an answer a user can read:
    # UnsupportedOperation is a StandardError, so rescue_from reaches it (NotImplementedError, a
    # ScriptError, would not -- it would be the 500 spec §6 forbids).
    test "an s3-mode delete of a directory is refused, not wedged" do
      @fake.seed!("#{PREFIX}/cad/part.stl", "part", last_modified: Time.now)
      scan!
      dir_id = @user.nodes.find_by!(storage_path: "cad", kind: "dir").node_id

      delete file_path(dir_id)
      assert_redirected_to files_path
      assert_match(/files only/, flash[:alert])
      assert_not @user.nodes.find_by!(node_id: dir_id).deleted, "the directory must survive"
      assert_equal "part", @fake.objects["#{PREFIX}/cad/part.stl"].body,
                   "its children's bytes must not move"
    end

    # --- TrashController -------------------------------------------------------

    # THE WHOLE ROUND TRIP, which is what "make it work" has to mean. Each half of this passed
    # while the other was broken: the trash listed the node (from the row) while Restore ran
    # Sync::Trash.restore, which on an s3 library is not a recovery -- it clears the tombstone
    # while the bytes stay in the trash prefix, leaving a live node with a NULL storage_path that
    # no scan sees and no read can open.
    test "an s3-mode file survives delete -> trash -> restore -> read" do
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
                   "restore must give the node its key back -- a live node with a NULL " \
                   "storage_path is invisible to the scan and unreadable through the port"
      assert_equal "solid bracket", @fake.objects["#{PREFIX}/bracket.stl"].body,
                   "and the bytes must be back at the real key, not stranded in the trash"
    end

    # The trash Size column came from current_user.versions, which is EMPTY on s3 -- every cell an
    # em-dash. TrashEntry is backend-neutral by construction; this is the controller-layer proof
    # that the page reads it.
    test "the s3 trash reports the real size, not an em-dash" do
      id = index!("sized.stl", "0123456789")
      delete file_path(id)

      get trash_index_path
      assert_response :success
      assert_match(/10 Bytes/, response.body,
                   "the trash must report the real size -- versions are empty on this backend")
    end

    # A restore whose destination is occupied must not clobber, and must not claim the file is
    # gone either: the alert promises nothing it cannot keep.
    test "restoring into an occupied key is refused without destroying either file" do
      id = index!("bracket.stl", "solid")
      delete file_path(id)
      upload!("bracket.stl", "someone else's file")

      post restore_trash_path(id)

      assert_redirected_to trash_index_path
      assert_equal "someone else's file", @fake.objects["#{PREFIX}/bracket.stl"].body,
                   "restore must never clobber a live object"
      assert @fake.objects["#{PREFIX}/#{Library::Scanner::TRASH_PREFIX}/#{id}/bracket.stl"],
             "and the trashed bytes must survive the refusal"
    end

    # Cross-user, on the write path: s3_delivery_test pins it for reads, and a delete that took
    # another user's node_id would be strictly worse than a read that did.
    test "another user's node cannot be deleted" do
      id = index!("mine.stl", "secret")
      other = User.create!(email: "o3-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      delete destroy_user_session_path
      post user_session_path, params: { user: { email: other.email, password: PASSWORD } }

      delete file_path(id)

      assert_not @user.nodes.find_by!(node_id: id).deleted, "the owner's node must be untouched"
      assert_equal "secret", @fake.objects["#{PREFIX}/mine.stl"].body,
                   "and their bytes must not move"
    end
  end
end
