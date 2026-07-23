require "test_helper"

module Web
  # Exercises the SERVER side of the import sequence the importer Stimulus controller drives:
  #   POST /models (create + folder map)  ->  [browser uploads each file via /files/*]  ->
  #   POST /models/:slug/attachments (attach uploaded node, role derived, cover set).
  # The actual in-browser unzip + byte upload is manual-smoke only (no JS runner); the upload
  # endpoints themselves are covered by files_flow_test. Here we simulate an already-uploaded node.
  class ModelsImportTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
    end

    def sign_in(email = "maker@example.com")
      user = User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "create returns a folder map including requested subfolders" do
      user = sign_in
      post models_path(format: :json),
           params: { title: "Articulated Dragon", source_url: "https://printables.com/model/1",
                     dirs: [ "tail_segments" ] }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal "articulated-dragon", body["slug"]
      root_id = body.dig("folder_map", "")
      sub_id  = body.dig("folder_map", "tail_segments")
      assert root_id.present? && sub_id.present?
      assert_equal "tail_segments", user.nodes.find_by!(node_id: sub_id).name
      assert_equal root_id, user.nodes.find_by!(node_id: sub_id).parent_node_id
    end

    test "attach derives the role from the node name and can set the cover" do
      user = sign_in
      post models_path(format: :json), params: { title: "Dragon", dirs: [] }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      body = JSON.parse(response.body)
      model = user.maker_models.find_by!(slug: body["slug"])
      root_id = body.dig("folder_map", "")

      # Simulate the browser having uploaded two files into the model folder.
      user.nodes.create!(node_id: "hero", name: "dragon_hero.jpg", kind: "file", parent_node_id: root_id)
      user.nodes.create!(node_id: "body", name: "body.3mf", kind: "file", parent_node_id: root_id)

      post model_attachments_path(model, format: :json),
           params: { node_id: "hero", cover: true }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :created
      assert_equal "image", JSON.parse(response.body)["role"]

      post model_attachments_path(model, format: :json), params: { node_id: "body" }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      assert_equal "model", JSON.parse(response.body)["role"]

      model.reload
      assert_equal "hero", model.cover_node_id, "cover flag set the cover"
      assert_equal %w[body hero].sort, model.file_attachments.pluck(:node_id).sort
    end

    test "a blank title is a 422, not a 500" do
      sign_in
      post models_path(format: :json), params: { title: "", dirs: [] }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :unprocessable_entity
    end

    test "create skips traversal/reserved dot segments in dirs" do
      user = sign_in
      post models_path(format: :json),
           params: { title: "Safe", dirs: [ "..", ".maker-tmp-x", "good" ] }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :created
      body = JSON.parse(response.body)
      assert body.dig("folder_map", "good").present?, "a normal subfolder is created"
      assert_nil body.dig("folder_map", ".."), "traversal segment skipped"
      assert_nil body.dig("folder_map", ".maker-tmp-x"), "reserved dot-dir skipped"
      refute user.nodes.present.exists?(name: ".."), "no .. folder node created"
    end

    test "attaching an instructions PDF enqueues extraction; other files do not" do
      user = sign_in
      post models_path(format: :json), params: { title: "Doc", dirs: [] }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      model = user.maker_models.find_by!(slug: JSON.parse(response.body)["slug"])
      user.nodes.create!(node_id: "pdfx", name: "guide.pdf", kind: "file")
      user.nodes.create!(node_id: "stlx", name: "part.stl", kind: "file")

      assert_enqueued_with(job: Maker::ExtractPdfMetadataJob) do
        post model_attachments_path(model, format: :json), params: { node_id: "pdfx" }.to_json,
             headers: { "CONTENT_TYPE" => "application/json" }
      end
      assert_no_enqueued_jobs only: Maker::ExtractPdfMetadataJob do
        post model_attachments_path(model, format: :json), params: { node_id: "stlx" }.to_json,
             headers: { "CONTENT_TYPE" => "application/json" }
      end
    end
  end
end
