require "test_helper"

module Web
  # SEVERAL FILES IN ONE SELECTION (slice 0, 2026-09-10).
  #
  # Found by using the app: a maker's project folder is a dozen files, and both upload doors took
  # one, so uploading four meant opening the picker four times. The model importer next door has
  # always accepted a batch — the app knew how; the two doors a maker lives in did not.
  #
  # THE SHARE LEG DRIVES REAL BYTES through the real port, because the interesting behaviour is
  # what happens when ONE file in the middle of a batch is refused: the batch must keep going and
  # SAY what did not land. A test that only counted nodes would pass over a silently dropped file.
  class UploadBatchTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "ub-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    def uploaded(name, body: nil)
      Rack::Test::UploadedFile.new(StringIO.new(body || "body-#{name}"),
                                   "application/octet-stream", original_filename: name)
    end

    def upload(*names, bodies: nil)
      files = names.each_with_index.map do |name, i|
        Rack::Test::UploadedFile.new(StringIO.new(bodies&.[](i) || "body-#{name}"),
                                     "application/octet-stream", original_filename: name)
      end
      post files_path, params: { file: files.size == 1 ? files.first : files }
    end

    # The house stub helper (Minitest 6 has no Object#stub). Replaces a SINGLETON method for the
    # block, removing an inherited one after.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    # --- the batch lands -------------------------------------------------------------------

    test "three files in one selection all land, and the flash counts them" do
      upload("seat.dxf", "cap.stl", "notes.md")

      assert_response :redirect
      %w[seat.dxf cap.stl notes.md].each do |name|
        assert @user.nodes.present.exists?(name:), "#{name} should have landed"
        assert_path_exists @root.join(name)
      end
      assert_match(/Uploaded 3 files/, flash[:notice].to_s)
    end

    # The top bar's, since redesign slice 4 moved the Files page's uploader there. This file runs on
    # a fresh SHARE library (setup), so the multipart form is the flow every leg renders here.
    test "the file field offers multiple, on the page a maker actually uses" do
      get files_path
      assert_response :success
      assert_select "header.topbar form.uploader input[type=file][multiple]", 1,
                    "the top bar's uploader must accept a selection, not one file"
    end

    # --- WHAT THE RENDERED FORM ACTUALLY SENDS ----------------------------------------------
    #
    # These two exist because the suite above passed while the real page 500'd. `f.file_field` with
    # `multiple: true` renders a companion `<input name="file[]" type="hidden" value="">`
    # (`include_hidden`), so the real `params[:file]` arrived as `["", <file>, …]` and the server
    # called #original_filename on a String. A Rack::Test POST of a Ruby array never sends that
    # marker, so no test here could see it — §14d's "assert the rendered field name", one attribute
    # over. The first pins the markup; the second pins the server against the shape regardless.

    # A COUNT OF ZERO IS ONLY EVIDENCE IF THE FORM IS THERE, so its presence is asserted first: with
    # the uploader gone from the page altogether, the `0` would pass over nothing.
    test "neither uploader renders the hidden empty-value companion" do
      get files_path
      assert_select "header.topbar form.uploader input[type=file][name='file[]']", 1
      assert_select "header.topbar form.uploader input[type=hidden][name='file[]']", 0,
                    "the empty marker puts a bare String at the head of params[:file]"
    end

    test "a blank entry beside real files is ignored rather than raising" do
      post files_path, params: { file: [ "", uploaded("real.stl") ] }
      assert_response :redirect
      assert @user.nodes.present.exists?(name: "real.stl")
      assert_equal "Uploaded real.stl.", flash[:notice],
                   "one real file beside the marker is still a single-file upload"
    end

    # --- ONE REFUSAL MUST NOT LOSE THE REST ------------------------------------------------
    #
    # The old code let FileLayer::UnsupportedOperation reach a controller-wide `rescue_from` that
    # redirected — right for one file, and for a batch it would abandon everything after the
    # refusal. This is the behaviour the whole shared loop exists for.

    test "a name that is already taken refuses only that file, and the others still land" do
      upload("dupe.stl")
      assert @user.nodes.present.exists?(name: "dupe.stl")

      upload("first.stl", "dupe.stl", "last.stl")

      assert @user.nodes.present.exists?(name: "first.stl"), "a file BEFORE the refusal must land"
      assert @user.nodes.present.exists?(name: "last.stl"),
             "a file AFTER the refusal must land — this is the whole point"
      assert_equal 1, @user.nodes.present.where(name: "dupe.stl").count,
                   "the clobber must not have created a second node"
      assert_equal "body-dupe.stl", @root.join("dupe.stl").binread,
                   "the original bytes survive the refusal"
    end

    test "the flash names what did not land rather than reporting a clean batch" do
      upload("dupe.stl")
      upload("ok.stl", "dupe.stl")

      assert_match(/Uploaded 1 file\b/, flash[:notice].to_s)
      assert_match(/not uploaded: dupe\.stl/, flash[:notice].to_s)
      assert_match(/already exists/, flash[:notice].to_s)
    end

    test "a batch in which nothing lands is an alert, not a notice claiming success" do
      upload("a.stl", "b.stl")
      # FOLLOW THE FIRST REDIRECT so its notice is actually consumed. Without this the flash from
      # the successful upload is still pending when the second request runs, and `flash[:notice]`
      # below reads THAT — the assertion would fail against a message the second upload never set.
      follow_redirect!

      upload("a.stl", "b.stl")

      assert_nil flash[:notice]
      assert_match(/not uploaded/, flash[:alert].to_s)
      assert_match(/a\.stl/, flash[:alert].to_s)
      assert_match(/b\.stl/, flash[:alert].to_s)
    end

    # --- WHAT THE PORT REFUSES BY NAME, MID-BATCH (F-S21-2) ------------------------------------
    #
    # Both writable adapters raise FileLayer::NotFound for a condition that belongs to ONE file: a
    # name the library reserves (`.DS_Store`, `._x`, `.git`), a name that is not a leaf, or a file
    # over FileLayer::MAX_BYTES. The loop isolated only UnsupportedOperation and FetchError, so a
    # `.DS_Store` in the middle of a selection escaped it. a.stl landed, the class-level rescue_from
    # said "File not found.", and b.stl was never tried.

    test "a reserved name in the middle of a selection refuses only that file, and the rest land" do
      upload("a.stl", ".DS_Store", "b.stl")

      assert_response :redirect
      %w[a.stl b.stl].each do |name|
        assert @user.nodes.present.exists?(name:), "#{name} should have landed"
        assert_path_exists @root.join(name)
      end
      assert_not @user.nodes.exists?(name: ".DS_Store"), "the refused file has no node"
      assert_not @root.join(".DS_Store").exist?, "and no bytes"
      assert_nil flash[:alert]
      assert_equal "Uploaded 2 files. This one was not uploaded: .DS_Store (the library cannot store it).",
                   flash[:notice]
    end

    # ONE such file is still the pre-batch condition: the loop re-raises it, and the class-level
    # rescue_from answers it exactly as it did before the loop learned to catch NotFound.
    test "one file the port refuses by name still gets the door's own answer, not the batch sentence" do
      upload(".DS_Store")
      assert_redirected_to files_path
      assert_equal "File not found.", flash[:alert]
    end

    # --- the single-file message is unchanged ----------------------------------------------
    #
    # Four suites assert the one-file sentence in full. Widening the door must not reword it.

    test "one file still redirects to its own page with exactly the old sentence" do
      upload("solo.stl")
      node = @user.nodes.present.find_by!(name: "solo.stl")
      assert_redirected_to file_path(node.node_id)
      assert_equal "Uploaded solo.stl.", flash[:notice]
    end

    # --- the JSON door stays single-file ----------------------------------------------------
    #
    # importer_controller and measure_controller each POST one file and read back the one node_id
    # they must attach; there is no sensible JSON shape for a batch, so it is refused rather than
    # answered with something invented.

    test "a multi-file POST asking for JSON is refused rather than given an invented shape" do
      files = %w[x.stl y.stl].map do |n|
        Rack::Test::UploadedFile.new(StringIO.new("b"), "application/octet-stream", original_filename: n)
      end
      post files_path, params: { file: files }, as: :json
      assert_response :unprocessable_entity
    end

    # THE DOOR THE BATCH BROKE, AND THE ONLY LEG THAT CAUGHT IT WAS THE BROWSER.
    #
    # `measure_controller.js` saves through `uploadPortFile`, which reads `data.error` off a 422 to
    # show the refusal IN WORDS. The first cut of the batch absorbed UnsupportedOperation inside
    # the loop, so `rescue_from` never rendered that JSON, the empty batch redirected instead,
    # fetch followed the redirect to an HTML page, and the user saw "upload failed (406)".
    # measure_export_test.rb caught it; nothing here could, because no test drove this door with a
    # name that was already taken. Now one does.

    test "a JSON upload of a taken name answers 422 with the message, not a redirect" do
      upload("taken.stl")
      follow_redirect!

      post files_path,
           params: { file: uploaded("taken.stl") },
           headers: { "Accept" => "application/json" }

      assert_response :unprocessable_entity,
                      "a redirect here is followed to HTML and reported as 'upload failed (406)'"
      assert_match(/already exists/i, JSON.parse(response.body)["error"].to_s,
                   "uploadPortFile shows data.error verbatim — it has to say what happened")
    end

    test "a single-file JSON upload still answers the node_id its callers need" do
      post files_path,
           params: { file: Rack::Test::UploadedFile.new(StringIO.new("b"), "application/octet-stream",
                                                        original_filename: "one.stl") },
           headers: { "Accept" => "application/json" }
      assert_response :created
      assert_equal @user.nodes.present.find_by!(name: "one.stl").node_id,
                   JSON.parse(response.body)["node_id"]
    end

    # --- ONE STAT-THEN-ENQUEUE FOR EVERY UPLOAD DOOR (F-S21-2) ---------------------------------
    #
    # The loop called an `enqueue_preview` it did not define, and each controller that includes it
    # carried its own near-identical private copy (FilesController, Projects::UploadsController)
    # beside Maker::Addons::LibraryOutput.enqueue_preview, the one Maker::TextSave already uses. Every
    # upload door now goes through that one. Recording what it is handed is what tells "every door
    # enqueues THROUGH it" from "every door enqueues": a door back on a copy of its own still enqueues
    # a job, and hands the recorder nothing.
    def preview_enqueues(&)
      calls = []
      record = ->(user, node_id, name) { calls << [ user.id, node_id, name ]; nil }
      replacing(Maker::Addons::LibraryOutput, :enqueue_preview, record, &)
      calls
    end

    test "both multipart doors enqueue each file's preview through LibraryOutput's one stat-then-enqueue" do
      entry = @user.maker_projects.create!(name: "Lamp").build_log_entries.create!(user: @user, body: "x")

      calls = preview_enqueues do
        upload("part.stl", "plate.stl")
        post build_log_entry_uploads_path(entry), params: { file: [ uploaded("photo.png") ] }
      end

      landed = @user.nodes.present.where(name: %w[part.stl plate.stl photo.png]).pluck(:node_id, :name)
      assert_equal 3, landed.size, "every file should have landed"
      assert_equal landed.map { |node_id, name| [ @user.id, node_id, name ] }.sort, calls.sort
    end

    # THE PRESIGNED DOOR (chunk_remote) finalizes one file per request. The deployment is made
    # syncable here because the door is `syncable`-gated. Constructing a ChunkRemote dials nothing,
    # and its finalize is stood in for, so this proves what the DOOR does with a finalized file, not
    # what a sync server answers.
    test "the presigned door's finalize enqueues through the same one" do
      FileLayer.current = FileLayer::ChunkRemote.new
      info = FileLayer::FileInfo.new(node_id: SecureRandom.uuid, name: "bracket.stl", kind: "file",
                                     size: 3, mtime: 1, content_token: "v1")
      finalized = FileLayer::UploadFinalized.new(version_id: "v1", seq: 7, info:)

      calls = replacing(FileLayer.current, :finalize_upload, ->(*, **) { finalized }) do
        preview_enqueues { post finalize_upload_files_path, params: { commit_id: "c1" }, as: :json }
      end

      assert_response :success
      assert_equal [ [ @user.id, info.node_id, "bracket.stl" ] ], calls
    end
  end
end
