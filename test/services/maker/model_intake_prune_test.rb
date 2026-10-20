require "test_helper"

module Maker
  # THE REPAIR HALF of the 2026-09-02 rule change. Tightening Maker::ModelIntake fixes what it
  # writes NEXT; every row the loose rule already wrote survives, because the sweep only inserts.
  class ModelIntakePruneTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "prn-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      #   3D Models/                 <- shelf
      #     loose.stl                -> a one-file model
      #     Widget/                  -> one model
      #       body.stl               -> claimed
      #       drawing.dxf            -> the old rule attached it; the new one does not
      #       docs/notes.pdf         -> ditto: no mesh sits beside it
      dir("d-shelf", "3D Models", nil)
      file("f-loose", "loose.stl", "d-shelf")
      dir("d-widget", "Widget", "d-shelf")
      file("f-body", "body.stl", "d-widget")
      file("f-dxf", "drawing.dxf", "d-widget")
      dir("d-docs", "docs", "d-widget")
      file("f-notes", "notes.pdf", "d-docs")
      @user.maker_shelves.create!(path: "3D Models")

      # THE STATE THE OLD RULE LEFT: every file in the subtree, every role.
      Maker::ModelIntake.for_user(user: @user)
      @widget = @user.maker_models.find_by!(auto_node_id: "d-widget")
      %w[f-dxf f-notes].each do |node_id|
        @widget.file_attachments.create!(user: @user, node_id:,
                                         role: Maker::FileAttachment.role_for(node_id))
      end
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    def attached = @widget.file_attachments.reload.pluck(:node_id).sort

    # THE DEFAULT, AND THE POINT OF THE DEFAULT: it reports the list before anyone deletes it.
    test "a dry run reports what it would remove and writes nothing" do
      result = Maker::ModelIntake::Prune.for_user(user: @user)

      assert_equal 2, result.attachments
      assert_equal [ [ @widget, 2 ] ], result.detached
      assert_not result.applied
      assert_equal %w[f-body f-dxf f-notes], attached
    end

    test "it detaches what the current rule no longer claims" do
      Maker::ModelIntake::Prune.for_user(user: @user, apply: true)

      assert_equal %w[f-body], attached
    end

    test "a second run finds nothing left to do" do
      Maker::ModelIntake::Prune.for_user(user: @user, apply: true)

      assert_not Maker::ModelIntake::Prune.for_user(user: @user, apply: true).any?
    end

    test "it destroys an auto model on a folder a project claims" do
      @user.maker_projects.create!(name: "Widget", slug: "widget", folder_node_id: "d-widget")

      result = Maker::ModelIntake::Prune.for_user(user: @user, apply: true)

      assert_equal [ @widget ], result.destroyed
      assert_nil @user.maker_models.find_by(auto_node_id: "d-widget")
      assert_empty Maker::FileAttachment.where(user: @user, attachable: @widget)
    end

    # THE REAPER'S ROW, NOT THIS ONE. A tombstone is absent from `classify` (it reads `.present`),
    # so it looks exactly like a file the rule no longer claims -- and deleting it here would
    # pre-empt Maker::AttachmentReaper's grace window, which is the whole reason an undeleted file
    # comes back with its attachments intact (§14d).
    test "an attachment on a tombstoned node is left to the reaper" do
      @user.nodes.find_by!(node_id: "f-body").update!(deleted: true)

      Maker::ModelIntake::Prune.for_user(user: @user, apply: true)

      assert_includes attached, "f-body"
    end

    # A ROW THAT MAY BE A HAND ATTACH IS KEPT -- the node is not under the model's folder AND the
    # current rule places it in no model, so nothing shows the sweep wrote it and this repair does
    # not get to overrule it. It is ALSO the row a sweep-attached file leaves when it MOVES
    # somewhere no model claims, and that one is kept too: the two rows are identical, so this test
    # pins both (model-intake.md lists the moved one under "Not covered"). `Manuals` is a shelf (the
    # seeded `*`), and a PDF loose on it is no model's: nothing model-role keys there. THE FIXTURE
    # USED TO BE `loose.stl`, which the rule places in its own one-file model -- the shape a move
    # INTO A MODEL leaves (the next test) -- so it pinned the F-S07-2 defect as if it were the
    # guard.
    test "an attachment from outside the model's folder is left alone" do
      dir("d-manuals", "Manuals", nil)
      file("f-guide", "guide.pdf", "d-manuals")
      @widget.file_attachments.create!(user: @user, node_id: "f-guide", role: "instructions")

      Maker::ModelIntake::Prune.for_user(user: @user, apply: true)

      assert_includes attached, "f-guide"
    end

    # A MOVE KEEPS THE NODE_ID (Library::Reconciler pairs by content, §14b), SO "OUTSIDE THE FOLDER"
    # DOES NOT MEAN "THE SWEEP COULD NOT HAVE WRITTEN THIS ROW" (F-S07-2). The sweep attached
    # body.stl to Widget while it sat there; moved into Lamp/, the next sweep attaches it to Lamp
    # too and nothing removes Widget's row -- one file, two models. The rule places it under Lamp's
    # key, so Lamp is the model it belongs to and Widget's row is stale, wherever the file now sits.
    test "a mesh moved into another model's folder is detached from the model it left" do
      dir("d-lamp", "Lamp", "d-shelf")
      file("f-shade", "shade.stl", "d-lamp")
      file("f-lid", "lid.stl", "d-widget")
      Maker::ModelIntake.for_user(user: @user)
      @user.nodes.find_by!(node_id: "f-body").update!(parent_node_id: "d-lamp")
      Maker::ModelIntake.for_user(user: @user)
      lamp = @user.maker_models.find_by!(auto_node_id: "d-lamp")
      assert_includes lamp.file_attachments.pluck(:node_id), "f-body",
                      "precondition: the sweep attaches the moved mesh to the model it moved into"
      assert_includes attached, "f-body", "precondition: and nothing removed the row it left behind"

      Maker::ModelIntake::Prune.for_user(user: @user, apply: true)

      assert_not_includes attached, "f-body", "the moved mesh is still in the model it left"
      assert_includes attached, "f-lid", "Widget is still a model, and keeps what is still its own"
      assert_includes lamp.file_attachments.reload.pluck(:node_id), "f-body"
    end

    # A ONE-FILE MODEL HAS NO FOLDER, AND "no folder" IS NOT "the whole library". Dropping the
    # `where.not(folder_node_id: nil)` filter makes inside? compare against nil, which every node's
    # ancestry reaches -- so every hand-attached row on every loose model becomes prunable at once.
    # The sweep gave a loose model exactly one attachment, so there is nothing here to repair.
    test "a one-file model and what was hand-attached to it are untouched" do
      loose = @user.maker_models.find_by!(auto_node_id: "f-loose")
      loose.file_attachments.create!(user: @user, node_id: "f-dxf", role: "vector")

      Maker::ModelIntake::Prune.for_user(user: @user, apply: true)

      assert_equal %w[f-dxf f-loose], loose.file_attachments.reload.pluck(:node_id).sort
    end

    test "an imported model is not this sweep's to prune" do
      imported = @user.maker_models.create!(title: "Hand made", origin: "import",
                                            folder_node_id: "d-widget")
      imported.file_attachments.create!(user: @user, node_id: "f-dxf", role: "vector")

      Maker::ModelIntake::Prune.for_user(user: @user, apply: true)

      assert_equal [ "f-dxf" ], imported.file_attachments.reload.pluck(:node_id)
    end
  end
end
