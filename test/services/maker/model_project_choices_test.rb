require "test_helper"

module Maker
  # A MODEL'S "IN PROJECTS" ROW (Maker::ModelProjectChoices, 2026-10-21). Backend-neutral rows.
  class ModelProjectChoicesTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "mpc-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "lamp", "d-projects")
      dir("d-lamp-models", "models", "d-lamp")
      dir("d-shade", "shade", "d-lamp-models")
      @user.nodes.create!(node_id: "n-shade", name: "shade.stl", kind: "file", parent_node_id: "d-shade", mtime: 1, size: 1)
      @lamp = project("Lamp", "d-lamp")
      @desk = project("desk", nil)
      @bench = project("Bench", nil)
      @old = project("Old", nil).tap { |p| p.update!(status: "archived") }
      @shade = @user.maker_models.create!(title: "shade", origin: "auto", auto_node_id: "d-shade", folder_node_id: "d-shade")
      @shade.file_attachments.create!(user: @user, node_id: "n-shade", role: "model")
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def project(name, folder)
      @user.maker_projects.create!(name:).tap { |p| p.update_column(:folder_node_id, folder) }
    end

    def link(project) = project.file_attachments.create!(user: @user, node_id: "n-shade", role: "model")

    def choices = Maker::ModelProjectChoices.for(@user, @shade)

    test "the folder's project is located, attached ones are linked, the rest are offered by name" do
      link(@desk)
      link(@old)

      c = choices

      assert_equal @lamp, c.located
      assert_equal [ @desk ], c.linked
      assert_equal [ @bench ], c.available
    end

    test "a project that holds the model and also links it is located only" do
      link(@lamp)

      c = choices

      assert_equal @lamp, c.located
      assert_empty c.linked
      assert_equal [ @bench, @desk ], c.available
    end

    test "a model in no project's folder has no located project" do
      @user.nodes.create!(node_id: "n-loose", name: "loose.stl", kind: "file", mtime: 1, size: 1)
      loose = @user.maker_models.create!(title: "loose", origin: "auto", auto_node_id: "n-loose")
      loose.file_attachments.create!(user: @user, node_id: "n-loose", role: "model")

      c = Maker::ModelProjectChoices.for(@user, loose)

      assert_nil c.located
      assert_equal [ @bench, @desk, @lamp ], c.available
    end
  end
end
