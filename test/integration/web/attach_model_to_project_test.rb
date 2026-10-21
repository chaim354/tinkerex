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

    # THE REFERER IS NOT THE FALLBACK (model_path), so "went back" and "fell back" are told apart.
    test "attach links every file of the model and goes back where it came from" do
      post model_projects_path(@model), params: { project_id: @project.slug },
                                        headers: { "HTTP_REFERER" => "http://www.example.com#{files_path}" }

      assert_redirected_to files_path
      assert_equal "Attached Shade to Desk Lamp.", flash[:notice]
      assert_equal %w[n-pdf n-stl], node_ids
    end

    test "a foreign-host referer falls back to the model, never off-site" do
      post model_projects_path(@model), params: { project_id: @project.slug },
                                        headers: { "HTTP_REFERER" => "http://evil.example/x" }

      assert_redirected_to model_path(@model)
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

    # PINS `attachable_type` IN #destroy. Ids are per-table, so a project and a model sharing one is
    # ordinary; forcing it here makes the case deterministic rather than an accident of fixture order.
    test "detach leaves the model's own rows alone when a project shares the model's id" do
      twin_id = [ Maker::Project.maximum(:id), Maker::Model.maximum(:id) ].max + 1
      twin = @user.maker_projects.create!(name: "Twin").tap { |p| p.update_column(:id, twin_id) }
      model = @user.maker_models.create!(title: "Twin Shade", origin: "import").tap { |m| m.update_column(:id, twin_id) }
      file("n-twin", "twin.stl")
      model.file_attachments.create!(user: @user, node_id: "n-twin", role: "model")
      Maker::AttachToProject.new(user: @user, project: twin).attach_model(model)
      assert_equal twin.id, model.id

      delete model_project_path(model, twin)

      assert_empty node_ids(twin)
      assert_equal %w[n-twin], model.file_attachments.reload.pluck(:node_id)
    end

    # A SHARED FILE IS ITS OWNER'S LINK (Maker::AttachToProject.owners_by_node, the Models panel's
    # rule). @model is the older row on n-stl, so the project's n-stl row is @model's card; detaching
    # the newer model must not take it. Mutation-checked: #destroy over ALL of the model's node ids
    # leaves only n-pdf here, and this goes red.
    test "detach leaves a shared file's row to the older model that owns it" do
      file("n-arm", "arm.stl")
      newer = @user.maker_models.create!(title: "Arm", origin: "import")
      %w[n-stl n-arm].each { |id| newer.file_attachments.create!(user: @user, node_id: id, role: "model") }
      Maker::AttachToProject.new(user: @user, project: @project).attach_model(@model)
      Maker::AttachToProject.new(user: @user, project: @project).attach_model(newer)
      assert_equal %w[n-arm n-pdf n-stl], node_ids

      delete model_project_path(newer, @project)

      assert_equal "Detached Arm from Desk Lamp.", flash[:notice]
      assert_equal %w[n-pdf n-stl], node_ids
    end

    test "detaching a model that is not in the project says so" do
      delete model_project_path(@model, @project)

      assert_redirected_to project_path(@project)
      assert_equal "Shade wasn't in Desk Lamp.", flash[:notice]
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
      assert_empty node_ids(their_project)
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

    # `%` AND `_` ARE LITERALS IN A TITLE: without `ESCAPE '\'` SQLite matches sanitize_sql_like's
    # backslash literally and "50%" finds nothing at all (the share leg is SQLite).
    test "the picker matches LIKE wildcards in a query literally" do
      @user.maker_models.create!(title: "50% Shade", origin: "import")
      @user.maker_models.create!(title: "500 Shade", origin: "import")

      get new_project_model_path(@project, q: "50%")

      assert_response :success
      assert_select ".picker-result .picker-name", text: "50% Shade"
      assert_select ".picker-result .picker-name", count: 1
    end

    test "the picker for an archived project says so and offers no Attach" do
      @project.update!(status: "archived")

      get new_project_model_path(@project)

      assert_response :success
      assert_select "p", text: "Desk Lamp is archived — unarchive it to attach models."
      assert_select ".picker-result", count: 0
      assert_select "form[action=?]", model_projects_path(@model), count: 0
    end
  end
end
