require "test_helper"

module Web
  # "IN PROJECTS" ON A MODEL (2026-10-21; docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md):
  # the model's folder strip and the model page render one partial (models/_projects). Node rows
  # only — both pages read the catalog, never the port.
  class ModelProjectsRowTest < ActionDispatch::IntegrationTest
    setup do
      @user = sign_in_web!(User.create!(email: "mpr-#{SecureRandom.hex(4)}@example.com",
                                        password: WEB_PASSWORD, confirmed_at: Time.current))
      @lamp = @user.maker_projects.create!(name: "Lamp")
      @desk = @user.maker_projects.create!(name: "Desk")
    end

    teardown { FileLayer.reset! }

    def model_with_file(title, parent:, folder: nil)
      file = @user.nodes.create!(node_id: "n-#{SecureRandom.hex(4)}", name: "#{title.downcase}.stl", kind: "file",
                                 parent_node_id: parent, mtime: 1, size: 1)
      @user.maker_models.create!(title:, origin: "auto", auto_node_id: folder || file.node_id,
                                 folder_node_id: folder).tap do |m|
        m.file_attachments.create!(user: @user, node_id: file.node_id, role: "model")
      end
    end

    test "a model's folder strip lists its projects with Detach and offers the rest" do
      @user.nodes.create!(node_id: "d-shade", name: "shade", kind: "dir", mtime: 1, size: 0)
      shade = model_with_file("Shade", parent: "d-shade", folder: "d-shade")
      Maker::AttachToProject.new(user: @user, project: @lamp).attach_model(shade)

      get files_path(folder: "d-shade")

      assert_response :success
      assert_select ".model-strip .model-projects .project-chip a", text: "Lamp"
      assert_select ".model-strip .model-projects form[action=?]", model_project_path(shade, @lamp)
      options = ".model-strip .model-projects form[action=?] select[name='project_id'] option"
      assert_select options, model_projects_path(shade), count: 1
      assert_select options, model_projects_path(shade), text: "Desk"
    end

    # THE LOCATED CHIP HAS NO ×: the model is the project's by where it is, so there is no row to
    # detach and a button here would only answer "wasn't in".
    test "a model inside a project's folder shows that project's chip with no Detach" do
      folder = project_folder_rows!(@user, @lamp)
      @user.nodes.create!(node_id: "d-arm", name: "arm", kind: "dir", parent_node_id: folder.node_id, mtime: 1, size: 0)
      arm = model_with_file("Arm", parent: "d-arm", folder: "d-arm")

      get files_path(folder: "d-arm")

      assert_response :success
      assert_select ".model-strip .model-projects .project-chip", count: 1
      assert_select ".model-strip .model-projects .project-chip", text: "Lamp" do
        assert_select "button", count: 0
        assert_select "form", count: 0
      end
      assert_select ".model-strip .model-projects form[action=?]", model_project_path(arm, @lamp), count: 0
      assert_select ".model-strip .model-projects select[name='project_id'] option", text: "Desk"
    end

    # IN THE DETAILS PANE since the model page became files-left, pane-right (#457): the row sits with
    # the rest of the model's metadata, and ModelsController#load_details builds it only for that pane.
    test "the model page's Details pane shows the same row" do
      knob = model_with_file("Knob", parent: nil)

      get model_path(knob, file: "details")

      assert_response :success
      assert_select ".model-details .model-projects select[name='project_id'] option", count: 2
    end
  end
end
