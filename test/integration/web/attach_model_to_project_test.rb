require "test_helper"

module Web
  # ATTACH A MODEL TO A PROJECT FROM EITHER END (2026-10-21; docs/superpowers/specs/
  # 2026-10-20-attach-model-to-project-design.md): Models::ProjectsController (attach, detach) and
  # the project page's Add-model picker (Projects::ModelsController). Runs on the ambient backend:
  # nothing here touches the port — a bundle attach writes rows only.
  class AttachModelToProjectTest < ActionDispatch::IntegrationTest
    setup do
      @user = sign_in_web!(User.create!(email: "amp-#{SecureRandom.hex(4)}@example.com",
                                        password: WEB_PASSWORD, confirmed_at: Time.current))
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @model = @user.maker_models.create!(title: "Shade", origin: "import")
      file("n-stl", "shade.stl")
      file("n-pdf", "howto.pdf")
      %w[n-stl n-pdf].each { |id| @model.file_attachments.create!(user: @user, node_id: id, role: "other") }
    end

    teardown { FileLayer.reset! }

    def file(node_id, name) = @user.nodes.create!(node_id:, name:, kind: "file", mtime: 1, size: 1)

    def node_ids(project = @project) = project.file_attachments.reload.pluck(:node_id).sort

    test "attach links every file of the model and goes back where it came from" do
      post model_projects_path(@model), params: { project_id: @project.slug },
                                        headers: { "HTTP_REFERER" => "http://www.example.com#{model_path(@model)}" }

      assert_redirected_to model_path(@model)
      assert_equal "Attached Shade to Desk Lamp.", flash[:notice]
      assert_equal %w[n-pdf n-stl], node_ids
    end

    test "attach from the picker goes to the project's Models panel" do
      post model_projects_path(@model), params: { project_id: @project.slug, return_to: "project" }

      assert_redirected_to project_path(@project, anchor: "models")
    end

    test "attaching twice says so and adds nothing" do
      2.times { post model_projects_path(@model), params: { project_id: @project.slug } }

      assert_equal "Shade is already in Desk Lamp.", flash[:notice]
      assert_equal %w[n-pdf n-stl], node_ids
    end

    test "a model with no live files is refused" do
      empty = @user.maker_models.create!(title: "Empty", origin: "import")

      post model_projects_path(empty), params: { project_id: @project.slug }

      assert_equal "That model has no files to attach.", flash[:alert]
      assert_empty node_ids
    end

    test "an archived project is refused" do
      @project.update!(status: "archived")

      post model_projects_path(@model), params: { project_id: @project.slug }

      assert_match "archived", flash[:alert]
      assert_empty node_ids
    end

    test "detach removes only this project's rows for this model's files" do
      file("n-own", "own.txt")
      @project.file_attachments.create!(user: @user, node_id: "n-own", role: "other")
      other = @user.maker_projects.create!(name: "Other")
      Maker::AttachToProject.new(user: @user, project: @project).attach_model(@model)
      Maker::AttachToProject.new(user: @user, project: other).attach_model(@model)

      delete model_project_path(@model, @project)

      assert_redirected_to project_path(@project)
      assert_equal "Detached Shade from Desk Lamp.", flash[:notice]
      assert_equal %w[n-own], node_ids
      assert_equal %w[n-pdf n-stl], node_ids(other)
      assert_equal 2, @model.file_attachments.count
      assert @user.nodes.present.exists?(node_id: "n-stl")
    end

    test "another user's model or project is a 404 and attaches nothing" do
      stranger = User.create!(email: "amp-stranger-#{SecureRandom.hex(4)}@example.com",
                              password: WEB_PASSWORD, confirmed_at: Time.current)
      their_model = stranger.maker_models.create!(title: "Theirs", origin: "import")
      their_project = stranger.maker_projects.create!(name: "Theirs")

      post model_projects_path(their_model), params: { project_id: @project.slug }
      assert_response :not_found
      post model_projects_path(@model), params: { project_id: their_project.slug }
      assert_response :not_found
      delete model_project_path(@model, their_project)
      assert_response :not_found
      assert_empty node_ids
    end

    test "the picker lists catalogued models matching the title, each attaching to this project" do
      base = @user.maker_models.create!(title: "Lamp Base", origin: "import")
      @user.maker_models.create!(title: "Lamp Arm", origin: "auto", auto_node_id: "n-arm", dismissed_at: Time.current)

      get new_project_model_path(@project, q: "LAMP")

      assert_response :success
      assert_select ".picker-result .picker-name", text: "Lamp Base"
      assert_select ".picker-result .picker-name", text: "Lamp Arm", count: 0
      assert_select ".picker-result .picker-name", text: "Shade", count: 0
      assert_select "form[action=?] input[name='project_id'][value=?]", model_projects_path(base), @project.slug
      assert_select "form[action=?] input[name='return_to'][value='project']", model_projects_path(base)
    end

    test "the picker with no query lists recent models" do
      get new_project_model_path(@project)

      assert_response :success
      assert_select ".picker-result .picker-name", text: "Shade"
    end
  end
end
