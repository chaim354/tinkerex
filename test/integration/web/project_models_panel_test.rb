require "test_helper"

module Web
  # THE PROJECT PAGE'S MODELS PANEL (2026-10-21; docs/superpowers/specs/
  # 2026-10-20-attach-model-to-project-design.md). Node ROWS only and project_folder_rows!, so the
  # page reads a folder without the port on every backend leg.
  class ProjectModelsPanelTest < ActionDispatch::IntegrationTest
    setup do
      @user = sign_in_web!(User.create!(email: "pmp-#{SecureRandom.hex(4)}@example.com",
                                        password: WEB_PASSWORD, confirmed_at: Time.current))
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = project_folder_rows!(@user, @project)
      @models_dir = row("d-models", "models", "dir", @folder.node_id)
      @elsewhere = row("d-lib", "3d models", "dir", nil)
      @shade = located_model!("Shade")
      @knob = elsewhere_model!("Knob")
    end

    teardown { FileLayer.reset! }

    def row(node_id, name, kind, parent)
      @user.nodes.create!(node_id:, name:, kind:, parent_node_id: parent, mtime: 1, size: (kind == "file" ? 1 : 0))
    end

    # A folder model inside the project's models/ — Maker::ModelIntake's `Projects/*/models` shelf.
    def located_model!(title)
      key = "d-#{SecureRandom.hex(4)}"
      row(key, title.downcase, "dir", @models_dir.node_id)
      file = row("n-#{SecureRandom.hex(4)}", "#{title.downcase}.stl", "file", key)
      @user.maker_models.create!(title:, origin: "auto", auto_node_id: key, folder_node_id: key).tap do |m|
        m.file_attachments.create!(user: @user, node_id: file.node_id, role: "model")
      end
    end

    # A one-file model outside the project.
    def elsewhere_model!(title)
      file = row("n-#{SecureRandom.hex(4)}", "#{title.downcase}.stl", "file", @elsewhere.node_id)
      @user.maker_models.create!(title:, origin: "auto", auto_node_id: file.node_id).tap do |m|
        m.file_attachments.create!(user: @user, node_id: file.node_id, role: "model")
      end
    end

    def attach(model) = Maker::AttachToProject.new(user: @user, project: @project).attach_model(model)

    test "the panel shows the folder's models and the linked ones; only linked ones carry Detach" do
      attach(@knob)

      get project_path(@project)

      assert_response :success
      assert_select "section.models-panel .model-name", text: "Knob"
      assert_select "section.models-panel .model-name", text: "Shade"
      assert_select "section.models-panel form[action=?]", model_project_path(@knob, @project)
      assert_select "section.models-panel form[action=?]", model_project_path(@shade, @project), count: 0
      assert_select "section.models-panel a[href=?]", new_project_model_path(@project), text: "Add model"
    end

    test "a linked model's files leave Linked from elsewhere" do
      attach(@knob)

      get project_path(@project)

      assert_no_match "Linked from elsewhere", response.body
    end

    test "with the panel hidden, a linked model's files stay in Linked from elsewhere" do
      attach(@knob)
      @project.update!(panels: { "hidden" => %w[models] })

      get project_path(@project)

      assert_select "section.models-panel", count: 0
      assert_match "Linked from elsewhere", response.body
    end

    test "a project with no models says so beside Add model" do
      bare = @user.maker_projects.create!(name: "Bare")
      project_folder_rows!(@user, bare)

      get project_path(bare)

      assert_select "section.models-panel", text: /No models yet\./
      assert_select "section.models-panel a[href=?]", new_project_model_path(bare)
    end

    test "the page's query count does not grow with the number of models" do
      counts = [ 1, 4 ].map do |n|
        n.times { |i| located_model!("Located #{n} #{i}"); attach(elsewhere_model!("Linked #{n} #{i}")) }
        get project_path(@project)
        count_queries { get project_path(@project) }
      end

      assert_equal counts.first, counts.last,
                   "the project page issued #{counts.first} queries with few models and #{counts.last} with more"
    end

    private

      def count_queries
        n = 0
        sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
          n += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
        end
        yield
        n
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end
  end
end
