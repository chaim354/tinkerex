require "test_helper"

module Web
  class ProjectAttachmentsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    # Seed a library node + attach it to a project via the model (attach UI is Task 6).
    def attach_node(user, project, name:, node_id:, role: "model")
      user.nodes.create!(node_id:, name:, kind: "file")
      project.file_attachments.create!(user:, node_id:, role:)
    end

    test "attached files render as tiles linking to the file view" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      attach_node(user, project, name: "base.stl", node_id: "n-1", role: "model")

      get project_path(project)
      assert_response :success
      assert_select ".attachments-panel .attachment-tile", 1
      assert_select ".attachment-tile a[href=?]", file_path("n-1")
      assert_select ".attachment-tile .badge", text: /model/
    end

    test "a missing/deleted attached node degrades to an unavailable placeholder, never a 500" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      # Attachment row whose node_id has no live Node (deleted / never present).
      project.file_attachments.create!(user:, node_id: "gone", role: "model", label: "ghost.stl")

      get project_path(project)
      assert_response :success
      assert_select ".attachment-tile.unavailable"
    end

    # --- attach existing + detach ----------------------------------------------

    test "attach picker lists the user's recent files and searches by name" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      user.nodes.create!(node_id: "f-2", name: "manual.pdf", kind: "file")

      get new_project_attachment_path(project)
      assert_response :success
      assert_select ".picker-result", 2

      get new_project_attachment_path(project), params: { q: "bracket" }
      assert_select ".picker-result", 1
      assert_select ".picker-result", text: /bracket.stl/
    end

    test "attach creates a reference with an inferred role" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")

      assert_difference "project.file_attachments.count", 1 do
        post project_attachments_path(project), params: { node_id: "f-1" }
      end
      assert_equal "model", project.file_attachments.last.role   # .stl -> model
      assert_redirected_to project_path(project)
    end

    test "attach refuses a node the user does not own" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      other = User.create!(email: "z@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.nodes.create!(node_id: "theirs", name: "secret.stl", kind: "file")

      assert_no_difference "Maker::FileAttachment.count" do
        post project_attachments_path(project), params: { node_id: "theirs" }
      end
      assert_redirected_to new_project_attachment_path(project)
    end

    test "detach removes the reference but never the library node" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      att = project.file_attachments.create!(user:, node_id: "f-1", role: "model")

      assert_difference "Maker::FileAttachment.count", -1 do
        delete attachment_path(att)
      end
      assert user.nodes.present.exists?(node_id: "f-1"), "the library file must survive a detach"
      assert_redirected_to project_path(project)
    end
  end
end
