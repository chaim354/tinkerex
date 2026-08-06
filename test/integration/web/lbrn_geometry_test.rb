require "test_helper"

module Web
  # The .lbrn2 Measure view's coordinate endpoint. Chunk-shaped (it uploads through
  # Sync::Commit's two-phase flow), so it pins the backend and says so — see
  # test_helper#pin_file_layer_backend.
  class LbrnGeometryTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      @user = sign_in
      @node_id = upload("measure.lbrn2", file_fixture_bytes("real-export.lbrn2"))
    end

    PASSWORD = "correct horse battery staple".freeze

    def sign_in(email = "web@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    def file_fixture_bytes(name) = File.binread(Rails.root.join("test/fixtures/files", name))

    # Mirror the browser uploader: hash -> begin_upload -> PUT bytes -> finalize_upload. Copied
    # from files_flow_test.rb's own helper rather than reinvented.
    def upload(name, bytes)
      hash = Digest::SHA256.hexdigest(bytes)
      manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]
      post begin_upload_files_path, params: { name:, size: bytes.bytesize, manifest: }, as: :json
      assert_response :success
      begun = JSON.parse(response.body)

      (begun["put_urls"] || {}).each_value do |url|
        put url, params: bytes, headers: { "CONTENT_TYPE" => "application/octet-stream" }
        assert_response :ok
      end

      post finalize_upload_files_path, params: { commit_id: begun["commit_id"] }, as: :json
      assert_response :success
      begun["node_id"]
    end

    # THE REAL ROW #geometry WOULD LOOK UP — same node_id, same version_id (content_token) the
    # action resolves via FileLayer.current.stat. find_or_create_by!, not create!: the row may
    # already exist (e.g. a prior GET in the same test), and a plain create! would then hit the
    # (user, node, kind) uniqueness index instead of handing back the row a test wants to mutate.
    def preview_for(node_id)
      token = FileLayer.current.stat(@user, node_id:).content_token
      Maker::Preview.find_or_create_by!(user: @user, node_id:, version_id: token, kind: "geometry")
    end

    test "requires authentication" do
      delete destroy_user_session_path
      get geometry_file_path(@node_id)
      assert_redirected_to new_user_session_path
    end

    test "answers pending while the preview is being generated" do
      get geometry_file_path(@node_id)

      assert_response :success
      assert_equal "pending", response.parsed_body["status"]
    end

    test "answers ready with a blob url once the preview is generated" do
      perform_enqueued_jobs { get geometry_file_path(@node_id) }
      get geometry_file_path(@node_id)

      assert_response :success
      body = response.parsed_body
      assert_equal "ready", body["status"]
      assert body["url"].present?, "a ready geometry preview must expose its blob url"
    end

    test "the ready payload is the geometry, not an image" do
      perform_enqueued_jobs { get geometry_file_path(@node_id) }
      preview = @user.maker_previews.find_by!(node_id: @node_id, kind: "geometry")

      assert_equal "application/json", preview.asset.content_type
      assert_equal 4, JSON.parse(preview.asset.download)["shapes"].length
    end

    test "generating geometry does not disturb the thumbnail preview" do
      perform_enqueued_jobs { get geometry_file_path(@node_id) }

      assert @user.maker_previews.find_by(node_id: @node_id, kind: "geometry"),
             "the geometry row exists"
      # Two rows for one node, one per kind — Preview.rb: "ONE ROW PER (user, node, kind)".
      # If this ever finds the thumbnail row REPOINTED at JSON, the kind seam is broken.
      thumb = @user.maker_previews.find_by(node_id: @node_id, kind: "thumbnail")
      assert thumb.nil? || thumb.asset.content_type != "application/json"
    end

    test "surfaces a failed preview rather than 500ing" do
      preview_for(@node_id).update!(status: "failed", error: "boom")
      get geometry_file_path(@node_id)

      assert_response :success
      assert_equal "failed", response.parsed_body["status"]
      assert_equal "boom", response.parsed_body["error"]
    end

    test "surfaces unsupported with the job's own message" do
      preview_for(@node_id).update!(status: "unsupported",
                                    error: "lbrn2 is 40 MB, over the 32 MB preview ceiling")
      get geometry_file_path(@node_id)

      assert_equal "unsupported", response.parsed_body["status"]
      assert_match(/over the 32 MB preview ceiling/, response.parsed_body["error"])
    end

    test "404s for a node this user does not own" do
      other = User.create!(email: "other@example.com", password: PASSWORD, confirmed_at: Time.current)
      stranger = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs.lbrn2", kind: "file")

      get geometry_file_path(stranger.node_id)
      assert_response :not_found
    end

    test "an lbrn2 file page offers the Measure surface" do
      get file_path(@node_id)

      assert_response :success
      assert_select "[data-controller='lbrnmeasure']", 1
      # VALUE, not just presence — an attribute pointing at the wrong URL is exactly the bug a
      # presence check misses.
      assert_select "[data-lbrnmeasure-url-value='#{geometry_file_path(@node_id)}']", 1
      assert_select "button[data-action='lbrnmeasure#load']", 1
    end

    test "a non-lbrn file page does not" do
      other = upload("drawing.dxf", file_fixture_bytes("sample.dxf"))
      get file_path(other)

      assert_response :success
      assert_select "[data-controller='lbrnmeasure']", 0
    end

    # The :lbrn branch REPLACES the :thumbnail branch for these files, so everything that branch
    # handled has to still work. A ready thumbnail is the resting state — Measure is a button,
    # not a replacement.
    #
    # DIRECT ROW MANIPULATION, NOT `perform_enqueued_jobs { get file_path(@node_id) }` — the
    # latter was tried first and does NOT work: #show never enqueues anything (it only reads the
    # existing Preview row), so wrapping its GET in perform_enqueued_jobs has nothing to catch —
    # the block only inlines jobs ENQUEUED DURING it, and the thumbnail job from setup's upload was
    # already sitting in the queue before the block started (verified against activejob 8.1.3.1's
    # TestAdapter: only a NEW #enqueue call checks the perform-inline flag). Confirmed empirically:
    # that version left @thumbnail stuck at "pending" and failed this test for the wrong reason —
    # same idiom as files_flow_test.rb's "the detail page shows a ready thumbnail for a CAD file".
    test "the lbrn page still shows its thumbnail poster when one is ready" do
      token = FileLayer.current.stat(@user, node_id: @node_id).content_token
      preview = @user.maker_previews.find_by!(node_id: @node_id, version_id: token, kind: "thumbnail")
      preview.update!(status: "ready")
      preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png", content_type: "image/png")

      get file_path(@node_id)

      assert_response :success
      assert_select ".lbrn-measure-fallback img", 1
    end

    test "the lbrn page says so while the thumbnail is still generating" do
      get file_path(@node_id)

      assert_response :success
      assert_select ".lbrn-measure-fallback", text: /Generating preview/
    end
  end
end
