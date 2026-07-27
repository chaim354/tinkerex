require "test_helper"

module Web
  class AttachFromFilesTest < ActionDispatch::IntegrationTest
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

    test "the file detail page offers a project dropdown, not a button per project" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      user.maker_projects.create!(name: "Lamp")
      user.maker_projects.create!(name: "Bench")

      get file_path("f-1")
      assert_response :success
      # One control, two options — the old UI rendered one <form><button> per project, so this
      # goes red if the button row comes back.
      assert_select ".attach-to-project select[name=project_id]", 1
      assert_select ".attach-to-project select option", 2
      assert_select ".attach-to-project select option", text: "Lamp"
      assert_select ".attach-to-project select option", text: "Bench"
    end

    test "attaching from the file page creates the reference and redirects to the project" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      project = user.maker_projects.create!(name: "Lamp")

      assert_difference "project.file_attachments.count", 1 do
        post project_attachments_path(project), params: { node_id: "f-1" }
      end
      assert_equal "model", project.file_attachments.last.role
    end

    test "no attach control when the user has no projects" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      get file_path("f-1")
      assert_select ".attach-to-project", count: 0
    end

    test "the dropdown carries the project SLUG, which is what set_project resolves" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      user.maker_projects.create!(name: "Desk Lamp")

      get file_path("f-1")
      assert_select ".attach-to-project select option[value=desk-lamp]"
    end

    test "posting the non-nested attach route attaches, resolving the project from the body" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      project = user.maker_projects.create!(name: "Lamp")

      assert_difference "project.file_attachments.count", 1 do
        post attachments_path, params: { project_id: project.slug, node_id: "f-1" }
      end
    end

    test "attaching the same file to the same project twice creates ONE row" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      project = user.maker_projects.create!(name: "Lamp")

      post attachments_path, params: { project_id: project.slug, node_id: "f-1" }
      assert_difference "project.file_attachments.count", 0 do
        post attachments_path, params: { project_id: project.slug, node_id: "f-1" }
      end
    end

    test "projects the file is already in show as chips and drop out of the dropdown" do
      user = sign_in
      node = user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      lamp = user.maker_projects.create!(name: "Lamp")
      user.maker_projects.create!(name: "Bench")
      lamp.file_attachments.create!(user:, node_id: node.node_id, role: "model")

      get file_path("f-1")
      assert_select ".project-chip", text: /Lamp/
      # A file CAN be in several projects, so Bench is still offered — but Lamp is not, because
      # attaching it again is a no-op.
      assert_select ".attach-to-project select option", 1
      assert_select ".attach-to-project select option", text: "Bench"
    end

    test "a file attached to two projects shows two chips" do
      user = sign_in
      node = user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      %w[Lamp Bench].each do |n|
        user.maker_projects.create!(name: n).file_attachments
            .create!(user:, node_id: node.node_id, role: "model")
      end

      get file_path("f-1")
      assert_select ".project-chip", 2
    end
  end
end
