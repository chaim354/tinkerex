require "test_helper"

module Web
  # A REFUSAL IS A SENTENCE FOR A MAKER, NEVER THE PORT'S MESSAGE (UX audit D10, 2026-11-02). Those
  # messages are written for a log: share's FetchError names ENOENT and the library root, s3's
  # UnsupportedOperation a raw node id and its copy cap, chunk_remote's the sync server's wire code,
  # and MoveNode's InvalidName the inspect of a String. FilesController printed four of them — into
  # a flash, and into the editor's and the history panel's status line.
  #
  # PINNED TO A FRESH SHARE LIBRARY, so each door meets a real adapter on every backend leg.
  class FilesRefusalCopyTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    INTERNALS = /ENOENT|FileLayer|node_id|"[^"]*"\s*(is|already)|parent_deleted|5GiB/

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "ref-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @dir = create_node!(@user, node_id: "d-laser", name: "laser", kind: "dir")
    end

    # The house stub (text_file_creation_test.rb carries the same body).
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    test "the editor's save over an unreachable library answers the app's one sentence for it" do
      node = create_node!(@user, node_id: "n-notes", name: "notes.txt", kind: "file", size: 1, content_hash: "h1")
      replacing(Maker::TextSave, :call, ->(**) { raise FileLayer::FetchError, "\"n-notes\": ENOENT and the library root looks unmounted" }) do
        patch file_path(node.node_id), params: { content: "x", base_token: "h1" }, as: :json
      end
      assert_response :service_unavailable
      assert_equal "Couldn't reach your library. Try again.", JSON.parse(response.body)["error"]
    end

    # THE ONE HTML DOOR THE CLASS-LEVEL rescue_from STILL ANSWERS: a single-file upload whose name is
    # taken. "already exists" is the pinned wording (share_delivery_test, s3_write_test); the port's
    # `"dupe.stl" already exists` is not what the maker reads.
    test "a duplicate upload says the name is taken in the door's words" do
      2.times do |i|
        post files_path, params: { file: Rack::Test::UploadedFile.new(StringIO.new("v#{i}"), "application/octet-stream",
                                                                      original_filename: "dupe.stl") }
      end
      assert_equal "A file with that name already exists in this folder. Rename one of them, then upload again.",
                   flash[:alert]
    end

    # A NAME ON DISK THE CATALOG HAD NOT SEEN, or the sync server's 409: the port refuses, and the
    # maker is answered on the page the rename came from rather than dropped at the library root.
    test "a rename the port refuses lands on the page it came from, in words" do
      node = create_node!(@user, node_id: "n-plate", name: "plate.svg", kind: "file", parent_node_id: @dir.node_id)
      replacing(Maker::MoveNode, :call, ->(*, **) { raise FileLayer::UnsupportedOperation, "\"laser/lid.svg\" already exists" }) do
        patch rename_file_path(node.node_id), params: { name: "lid.svg" }
      end
      assert_redirected_to file_path(node.node_id)
      # NEUTRAL on purpose: the port refuses a rename for more than one reason (s3's copy cap too),
      # so the sentence never asserts the name is taken.
      assert_equal "plate.svg couldn't be renamed to lid.svg; it is unchanged. If something in this folder already has that name, choose another.", flash[:alert]
    end

    test "a move the port refuses lands on the page it came from, in words" do
      node = create_node!(@user, node_id: "n-plate", name: "plate.svg", kind: "file")
      replacing(Maker::MoveNode, :call, ->(*, **) { raise FileLayer::UnsupportedOperation, "\"n-plate\" is 6000000000 bytes: over S3's 5GiB copy cap" }) do
        patch move_file_path(node.node_id), params: { parent_node_id: @dir.node_id, return_to: "library" }
      end
      assert_redirected_to files_path(selected: node.node_id)
      assert_equal "plate.svg can't be moved to laser; it is still where it was.", flash[:alert]
    end

    # A NAME A DEVICE SYNCED THAT NO WEB DOOR WOULD MINT (a backslash, on chunk_remote): MoveNode's
    # message is `"a\\b.stl" is not a valid file name`; the maker is told what to do instead.
    test "a file whose own name cannot be moved is told to rename it first" do
      node = @user.nodes.create!(node_id: "n-slash", name: "a\\b.stl", kind: "file")
      patch move_file_path(node.node_id), params: { parent_node_id: @dir.node_id }
      assert_redirected_to file_path(node.node_id)
      assert_equal "a\\b.stl can't be moved here: its name holds a character the library can't use. Rename it first.",
                   flash[:alert]
    end

    # THE SWEEP: no flash any of these doors set carries the port's vocabulary.
    test "none of the refusals above carries the port's own words" do
      node = create_node!(@user, node_id: "n-plate", name: "plate.svg", kind: "file")
      replacing(Maker::MoveNode, :call, ->(*, **) { raise FileLayer::UnsupportedOperation, "\"n-plate\": parent_deleted" }) do
        patch move_file_path(node.node_id), params: { parent_node_id: @dir.node_id }
      end
      refute_match INTERNALS, flash[:alert].to_s
    end
  end
end
