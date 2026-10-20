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
      # A hermetic library for this suite. It pinned embedded chunk until Arc D Part 2; with that
      # backend retired it would otherwise run on the AMBIENT one, which on the s3 leg means real
      # Aws calls (the stub is opt-in per file) and on chunk_remote means a live sync server.
      # What these tests are about is the web layer, not which backend holds the bytes.
      @root = use_fresh_share_library!
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def sign_in(email = "maker@example.com")
      user = User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(user, password: PASSWORD)
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

    # THE RACE TASK 9a's FOLLOW-UP CLOSES HERE, GENUINELY (unlike Maker::AttachToProject#call —
    # see that method's own comment for the correction). Models::AttachmentsController#create
    # calls a BARE create!, with no find-first step of any kind, so a concurrent request landing
    # the identical (user, attachable_type, attachable_id, node_id) tuple raised
    # ActiveRecord::RecordNotUnique straight through to a 500 the moment the table gained a unique
    # index — verified directly (bin/rails runner) before this fix existed. "Already attached" is
    # this request's intent already satisfied by someone else, not an error, so the fix is
    # create_or_find_by! (see the controller's own comment) and this drives the REAL HTTP path
    # under a deterministically-injected race (with_concurrent_file_attachment, test_helper.rb) to
    # prove it: no 500, a 200 rather than a false 201, exactly one row, and no double-dispatched
    # extraction job for a row this request did not actually create.
    test "attaching a file that a concurrent request just attached answers 200, not a 500" do
      user = sign_in
      post models_path(format: :json), params: { title: "Raced", dirs: [] }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      model = user.maker_models.find_by!(slug: JSON.parse(response.body)["slug"])
      user.nodes.create!(node_id: "racedpdf", name: "guide.pdf", kind: "file")

      assert_no_enqueued_jobs only: Maker::ExtractPdfMetadataJob do
        with_concurrent_file_attachment(role: "instructions") do
          post model_attachments_path(model, format: :json), params: { node_id: "racedpdf" }.to_json,
               headers: { "CONTENT_TYPE" => "application/json" }
        end
      end

      assert_response :ok
      assert_equal 1, model.file_attachments.where(node_id: "racedpdf").count
    end
  end
end
