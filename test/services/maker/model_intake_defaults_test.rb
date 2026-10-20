require "test_helper"

module Maker
  # THE FOUR CASES THE FEATURE WAS ASKED FOR, AGAINST THE SEEDED SHELF SET AND NOTHING ELSE.
  #
  # Every other test in this suite builds its own shelves, which means all of them would stay green
  # while the DEFAULTS produced something nobody wants -- and they did. Measured on a real share
  # library before `*` was seeded: `3D Models/` collapsed into one catalog entry titled "3D Models"
  # holding every file beneath it, and the whole `Projects/` tree became one entry titled
  # "Projects". The rule was right and the seeded set was wrong, and no test could see it.
  #
  # So this file pins the defaults specifically. If SEEDS changes, this is the test that should
  # argue with you.
  class ModelIntakeDefaultsTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "def-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      #   3D Models/
      #     benchy.stl                     -> its own model
      #     Enclosure/body.stl             -> one model, "Enclosure"
      #   Projects/desk-lamp/              -> discovery's by position, so NOT a model (F-S07-1)
      #     cad/mount.stl                  -> nothing: its key is desk-lamp, which is claimed
      #     models/bracket.stl             -> its own model
      #     models/enclosure/lid.stl       -> one model, "enclosure"
      dir("d-3d", "3D Models", nil)
      file("f-benchy", "benchy.stl", "d-3d")
      dir("d-enc", "Enclosure", "d-3d")
      file("f-body", "body.stl", "d-enc")

      dir("d-projects", "Projects", nil)
      dir("d-lamp", "desk-lamp", "d-projects")
      dir("d-cad", "cad", "d-lamp")
      file("f-mount", "mount.stl", "d-cad")
      dir("d-models", "models", "d-lamp")
      file("f-bracket", "bracket.stl", "d-models")
      dir("d-lid", "enclosure", "d-models")
      file("f-lid", "lid.stl", "d-lid")
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    test "the seeded shelves produce one model per design, not one per top-level folder" do
      Maker::ModelIntake.for_user(user: @user)

      assert_equal %w[Enclosure benchy bracket enclosure],
                   @user.maker_models.order(:title).pluck(:title)
    end

    # THE TWO ENTRIES THAT MUST NEVER COME BACK. Named rather than implied: a title equal to a
    # top-level folder name is the signature of the root shelf being the nearest one, which is
    # what `*` exists to prevent.
    test "no top-level folder becomes a model of its own" do
      Maker::ModelIntake.for_user(user: @user)

      titles = @user.maker_models.pluck(:title)
      assert_not_includes titles, "3D Models"
      assert_not_includes titles, "Projects"
    end

    test "a folder under a shelf claims its whole subtree, and a loose file claims only itself" do
      Maker::ModelIntake.for_user(user: @user)

      assert_equal %w[f-body],
                   @user.maker_models.find_by!(title: "Enclosure").file_attachments.pluck(:node_id)
      assert_equal %w[f-benchy],
                   @user.maker_models.find_by!(title: "benchy").file_attachments.pluck(:node_id)
    end

    # THE DEEPER PATTERN IS THE NEARER SHELF, so `Projects/*/models` is not shadowed by `*` making
    # `Projects` one. Both seeds are load-bearing and they do different work.
    #
    # `desk-lamp` ITSELF IS NOT A MODEL, AND THIS USED TO PIN THE OPPOSITE (until F-S07-1,
    # 2026-10-19): `*` makes it the shelf's direct child, so `cad/mount.stl` keyed to it and the
    # whole project folder was one model titled "desk-lamp" -- the state a discovery that has not
    # reached the folder yet used to leave behind. No project row exists here, and the folder is
    # discovery's by position all the same (Maker::ProjectDiscovery.positional_claims).
    test "files under a project's models folder are their own models, not part of the project's" do
      Maker::ModelIntake.for_user(user: @user)

      assert_nil @user.maker_models.find_by(title: "desk-lamp"),
                 "a folder discovery owns by position became a model"
      assert_empty Maker::FileAttachment.where(user: @user, node_id: "f-mount")
      assert_equal %w[f-bracket],
                   @user.maker_models.find_by!(title: "bracket").file_attachments.pluck(:node_id)
      assert_equal %w[f-lid],
                   @user.maker_models.find_by!(title: "enclosure").file_attachments.pluck(:node_id)
    end
  end
end
