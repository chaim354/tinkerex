require "test_helper"

module Maker
  # A PROJECT'S MODELS (Maker::ProjectModels, 2026-10-21): the ones its folder holds plus the ones
  # attached from elsewhere. BACKEND-NEUTRAL FIXTURES, as in model_projects_test.rb: the class reads
  # rows and never touches the port.
  class ProjectModelsTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pm-#{SecureRandom.hex(4)}@example.com",
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

    def auto_model(title, key, attach: key)
      @user.maker_models.create!(title:, origin: "auto", auto_node_id: key,
                                 folder_node_id: (key if key.start_with?("d-"))).tap do |m|
        m.file_attachments.create!(user: @user, node_id: attach, role: "model")
      end
    end

    def link(project, node_id) = project.file_attachments.create!(user: @user, node_id:, role: "model")

    def for_lamp
      Maker::ProjectModels.for(@user, @lamp, attached_node_ids: @lamp.file_attachments.pluck(:node_id))
    end

    # "apple" before "Banana": a case-sensitive sort would put the capital first.
    test "a model in the folder and a linked one both show, by title ignoring case; only the linked one is linked" do
      file("n-shade", "shade.stl", "d-shade")
      apple = auto_model("apple", "d-shade", attach: "n-shade")
      file("n-benchy", "benchy.stl", "d-loose")
      banana = auto_model("Banana", "n-benchy")
      link(@lamp, "n-benchy")

      r = for_lamp

      assert_equal [ apple, banana ], r.models
      assert_equal Set[banana.id], r.linked_ids
      assert_equal Set["n-benchy"], r.owned_node_ids
    end

    test "an emptied auto model in the folder does not show — hidden, as the 3D models view hides it" do
      @user.maker_models.create!(title: "shade", origin: "auto", auto_node_id: "d-shade",
                                 folder_node_id: "d-shade")

      assert_empty for_lamp.models
    end

    test "a one-file model loose in models/ is in the folder" do
      file("n-knob", "knob.stl", "d-lamp-models")
      knob = auto_model("knob", "n-knob")

      assert_equal [ knob ], for_lamp.models
      assert_empty for_lamp.linked_ids
    end

    test "a model both in the folder and linked shows once, as in the folder" do
      file("n-shade", "shade.stl", "d-shade")
      shade = auto_model("shade", "d-shade", attach: "n-shade")
      link(@lamp, "n-shade")

      r = for_lamp

      assert_equal [ shade ], r.models
      assert_empty r.linked_ids
      assert_equal Set["n-shade"], r.owned_node_ids
    end

    test "a dismissed model never shows, and its files stay unowned" do
      file("n-benchy", "benchy.stl", "d-loose")
      auto_model("Benchy", "n-benchy").update!(dismissed_at: Time.current)
      link(@lamp, "n-benchy")

      r = for_lamp

      assert_empty r.models
      assert_empty r.owned_node_ids
    end

    test "a model in another project's folder is not this project's" do
      file("n-robber", "robber.stl", "d-catan-models")
      auto_model("robber", "n-robber")

      assert_empty for_lamp.models
    end

    test "a file owned by two models links the older one" do
      file("n-shared", "shared.stl", "d-loose")
      older = @user.maker_models.create!(title: "Older", origin: "import")
      newer = @user.maker_models.create!(title: "Newer", origin: "import")
      older.file_attachments.create!(user: @user, node_id: "n-shared", role: "model")
      newer.file_attachments.create!(user: @user, node_id: "n-shared", role: "model")
      link(@lamp, "n-shared")

      assert_equal [ older ], for_lamp.models
    end

    # PINS A DEFERRED EDGE, not a wish: the oldest owner is dismissed, so the file reads as that
    # model's and the newer catalogued one gets no card. Why it is left — see
    # Maker::AttachToProject.owners_by_node.
    test "a file whose oldest owner is dismissed shows no model, not the newer owner" do
      file("n-shared", "shared.stl", "d-loose")
      auto_model("Gone", "n-shared").update!(dismissed_at: Time.current)
      newer = @user.maker_models.create!(title: "Kept", origin: "import")
      newer.file_attachments.create!(user: @user, node_id: "n-shared", role: "model")
      link(@lamp, "n-shared")

      r = for_lamp

      assert_empty r.models
      assert_empty r.owned_node_ids
    end

    test "a project with no folder still shows its linked models" do
      bare = @user.maker_projects.create!(name: "Bare")
      file("n-benchy", "benchy.stl", "d-loose")
      benchy = auto_model("Benchy", "n-benchy")
      link(bare, "n-benchy")

      r = Maker::ProjectModels.for(@user, bare, attached_node_ids: [ "n-benchy" ])

      assert_equal [ benchy ], r.models
    end
  end
end
