require "test_helper"

module Maker
  # Which project each model on the 3D models view sits in (Maker::ModelProjects). BACKEND-NEUTRAL
  # FIXTURES ON PURPOSE, as in library_tree_test.rb: the class reads `nodes` and project rows and
  # never touches the port, so a bare create! is a complete fixture.
  class ModelProjectsTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "mp-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "lamp", "d-projects")
      dir("d-lamp-models", "models", "d-lamp")
      dir("d-shade", "shade", "d-lamp-models")
      dir("d-catan", "catan", "d-projects")
      dir("d-catan-models", "models", "d-catan")
      dir("d-loose", "3d models", nil)
      @lamp = project("Lamp", "d-lamp")
      @catan = project("catan", "d-catan")
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    def project(name, folder)
      @user.maker_projects.create!(name:).tap { |p| p.update_column(:folder_node_id, folder) }
    end

    # A sweep-made model: its key is a FOLDER for a folder model, the FILE for a one-file model.
    def auto_model(title, key, attach: key)
      @user.maker_models.create!(title:, origin: "auto", auto_node_id: key).tap do |m|
        m.file_attachments.create!(user: @user, node_id: attach, role: "model")
      end
    end

    def group(models = @user.maker_models.includes(:file_attachments).order(:id).to_a)
      Maker::ModelProjects.group(@user, models).map { |g| [ g.project&.name, g.models.map(&:title) ] }
    end

    test "a folder model and a one-file model inside a project's folder group under that project" do
      file("n-shade", "shade.stl", "d-shade")
      auto_model("shade", "d-shade", attach: "n-shade")
      # A one-file model's key is the FILE, which is not a dir: the walk starts at its parent.
      file("n-robber", "robber.stl", "d-catan-models")
      auto_model("robber", "n-robber")

      assert_equal [ [ "catan", %w[robber] ], [ "Lamp", %w[shade] ] ], group
    end

    test "a model in no project's folder groups last, after the projects by name" do
      file("n-benchy", "benchy.stl", "d-loose")
      auto_model("benchy", "n-benchy")
      file("n-root", "root.stl", nil)
      auto_model("at root", "n-root")
      file("n-robber", "robber.stl", "d-catan-models")
      auto_model("robber", "n-robber")

      assert_equal [ [ "catan", %w[robber] ], [ nil, [ "benchy", "at root" ] ] ], group
    end

    test "each group keeps the order the models were handed in" do
      %w[b a c].each do |t|
        file("n-#{t}", "#{t}.stl", "d-lamp-models")
        auto_model(t, "n-#{t}")
      end
      models = @user.maker_models.includes(:file_attachments).order(title: :desc).to_a

      assert_equal [ [ "Lamp", %w[c b a] ] ], group(models)
    end

    test "an import model is placed by its folder, and one with no folder by its first attachment" do
      kit = @user.maker_models.create!(title: "kit", origin: "import", folder_node_id: "d-shade")
      file("n-pip", "pip.stl", "d-catan-models")
      pip = @user.maker_models.create!(title: "pip", origin: "import")
      pip.file_attachments.create!(user: @user, node_id: "n-pip", role: "model")

      assert_equal [ [ "catan", %w[pip] ], [ "Lamp", %w[kit] ] ], group
    end

    test "the nearest project folder wins when one project's folder sits inside another's" do
      inner = project("Shade kit", "d-lamp-models")
      file("n-shade", "shade.stl", "d-shade")
      auto_model("shade", "d-shade", attach: "n-shade")

      assert_equal [ [ inner.name, %w[shade] ] ], group
    end

    test "an archived project still groups its models" do
      @lamp.update!(status: "archived")
      file("n-shade", "shade.stl", "d-shade")
      auto_model("shade", "d-shade", attach: "n-shade")

      assert_equal [ [ "Lamp", %w[shade] ] ], group
    end

    test "a broken chain reads as no project rather than raising" do
      @user.nodes.find_by(node_id: "d-lamp-models").update!(deleted: true)
      file("n-shade", "shade.stl", "d-shade")
      auto_model("shade", "d-shade", attach: "n-shade")

      assert_equal [ [ nil, %w[shade] ] ], group
    end

    test "with no project folders every model is one group with no project, and no models is no groups" do
      @user.maker_projects.update_all(folder_node_id: nil)
      file("n-shade", "shade.stl", "d-shade")
      auto_model("shade", "d-shade", attach: "n-shade")

      assert_equal [ [ nil, %w[shade] ] ], group
      assert_equal [], Maker::ModelProjects.group(@user, [])
    end
  end
end
