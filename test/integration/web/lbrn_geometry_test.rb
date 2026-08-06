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
  end
end
