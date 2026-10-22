require "test_helper"

module Maker
  # ATTACHING A MODEL BY NAME (Maker::AttachToProject#attach_model, 2026-10-21) and the batched
  # owner lookup the project page's Models panel reads (.owners_by_node). BACKEND-NEUTRAL FIXTURES:
  # a bundle attach writes attachment rows and moves nothing, so bare node rows are complete.
  class AttachModelTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "am-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Lamp")
      @model = @user.maker_models.create!(title: "Shade", origin: "import")
    end

    def file(node_id, name, deleted: false)
      @user.nodes.create!(node_id:, name:, kind: "file", mtime: 1, size: 1, deleted:)
    end

    def member(model, node_id) = model.file_attachments.create!(user: @user, node_id:, role: "other")

    def service = Maker::AttachToProject.new(user: @user, project: @project)

    test "every live file of the model is attached once, each with its own role, and nothing moves" do
      file("n-stl", "shade.stl")
      file("n-pdf", "howto.pdf")
      file("n-gone", "old.stl", deleted: true)
      %w[n-stl n-pdf n-gone].each { |id| member(@model, id) }

      result = service.attach_model(@model)

      assert_equal :model_bundle, result.relocation
      assert result.created
      assert_equal @model, result.model
      assert_equal({ "n-pdf" => "instructions", "n-stl" => "model" },
                   @project.file_attachments.reload.to_h { |a| [ a.node_id, a.role ] })
      assert_nil @user.nodes.find_by!(node_id: "n-stl").parent_node_id
    end

    test "a second attach adds no row and says nothing was created" do
      file("n-stl", "shade.stl")
      member(@model, "n-stl")
      service.attach_model(@model)

      again = service.attach_model(@model)

      refute again.created
      # Still a bundle of one, not :empty_model — "nothing new" is not "nothing there".
      assert_equal :model_bundle, again.relocation
      assert_equal 1, again.attachments.size
      assert_equal 1, @project.file_attachments.count
    end

    test "a model with no live file is :empty_model and writes nothing" do
      file("n-gone", "old.stl", deleted: true)
      member(@model, "n-gone")

      result = service.attach_model(@model)

      assert_equal :empty_model, result.relocation
      assert_empty result.attachments
      assert_equal 0, @project.file_attachments.count
    end

    test "owners_by_node answers the oldest model per node — #model_owning's rule" do
      # A THROWAWAY MODEL FIRST, so the owner's id is not the project's: with equal ids a project
      # row would read as the right answer and the attachable_type filter would go untested.
      @user.maker_models.create!(title: "Throwaway", origin: "import")
      owner = @user.maker_models.create!(title: "Owner", origin: "import")
      newer = @user.maker_models.create!(title: "Other", origin: "import")
      refute_equal @project.id, owner.id
      stranger = User.create!(email: "am-x-#{SecureRandom.hex(4)}@example.com",
                              confirmed_at: Time.current, omniauth_signup: true)
      theirs = stranger.maker_models.create!(title: "Theirs", origin: "import")
      file("n-shared", "shared.stl")
      file("n-project-only", "loose.stl")
      # Rows OLDER than the owner's that must not win: another user's model naming the same
      # node_id, and this project's own row on it.
      stranger.nodes.create!(node_id: "n-shared", name: "theirs.stl", kind: "file") # ids are unique per user, not globally
      theirs.file_attachments.create!(user: stranger, node_id: "n-shared", role: "other")
      @project.file_attachments.create!(user: @user, node_id: "n-shared", role: "model")
      member(owner, "n-shared")
      member(newer, "n-shared")
      # Attached to the project only — no model owns it.
      @project.file_attachments.create!(user: @user, node_id: "n-project-only", role: "model")

      assert_equal({ "n-shared" => owner.id },
                   Maker::AttachToProject.owners_by_node(@user, [ "n-shared", "n-project-only", "n-none" ]))
      assert_equal owner, service.model_owning(@user.nodes.find_by!(node_id: "n-shared"))
      assert_equal({}, Maker::AttachToProject.owners_by_node(@user, []))
    end
  end
end
