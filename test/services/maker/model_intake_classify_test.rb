require "test_helper"

module Maker
  # THE RULE, table-driven, with no writes anywhere. A folder is either a shelf or a model, and the
  # nearest shelf ancestor decides which.
  class ModelIntakeClassifyTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "cls-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      #   3D Models/                 <- shelf
      #     benchy.stl               -> its own model
      #     notes.pdf                -> not a model, and not attached to one
      #     Enclosure/               -> one model
      #       body.stl
      #       manual.pdf
      #       parts/
      #         clip.stl
      dir("d-shelf", "3D Models", nil)
      file("f-benchy", "benchy.stl", "d-shelf")
      file("f-notes",  "notes.pdf",  "d-shelf")
      dir("d-enc", "Enclosure", "d-shelf")
      file("f-body",   "body.stl",   "d-enc")
      file("f-manual", "manual.pdf", "d-enc")
      dir("d-parts", "parts", "d-enc")
      file("f-clip", "clip.stl", "d-parts")

      @user.maker_shelves.create!(path: "3D Models")
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    def classify = Maker::ModelIntake.classify(@user)

    test "a loose model file directly under a shelf is its own model" do
      assert_includes classify.model_keys, "f-benchy"
    end

    test "a subfolder of a shelf is one model claiming its whole subtree" do
      plan = classify
      assert_includes plan.model_keys, "d-enc"
      assert_equal %w[f-body f-clip f-manual], plan.files_for("d-enc").sort
    end

    test "a part deep in a model folder is not a model of its own" do
      plan = classify
      assert_not_includes plan.model_keys, "d-parts"
      assert_not_includes plan.model_keys, "f-clip"
    end

    test "a non-model file loose on a shelf becomes nothing" do
      plan = classify
      assert_not_includes plan.model_keys, "f-notes"
      assert_empty plan.model_keys.select { |k| plan.files_for(k).include?("f-notes") }
      # NOTHING CLAIMS IT AT ALL, which is a stronger statement than "no MODEL claims it" and is
      # the one the two assertions above cannot make: they only ever look at model_keys, so both
      # stay green when the owners filter is deleted -- mutation-checked, and it was green.
      assert_empty plan.files_for("f-notes")
    end

    test "a one-file model claims only itself" do
      assert_equal [ "f-benchy" ], classify.files_for("f-benchy")
    end

    # THE NESTED CASE: marking the inner folder a shelf makes its children models instead, and the
    # outer model stops at it. Nearest ancestor wins.
    test "a shelf inside a model folder takes over its children" do
      @user.maker_shelves.create!(path: "3D Models/Enclosure")
      plan = classify
      assert_not_includes plan.model_keys, "d-enc"
      assert_includes plan.model_keys, "f-body"
      assert_includes plan.model_keys, "d-parts"
      assert_equal [ "f-clip" ], plan.files_for("d-parts")
    end

    test "a wildcard shelf matches one segment" do
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "desk-lamp", "d-projects")
      dir("d-lampmodels", "models", "d-lamp")
      file("f-shade", "shade.stl", "d-lampmodels")
      @user.maker_shelves.create!(path: "Projects/*/models")

      assert_includes classify.model_keys, "f-shade"
    end

    # DELETING THE ROOT SHELF IS A LEGITIMATE CHOICE, not a gap -- loose root files are simply not
    # catalogued. The fixture has no root shelf, so this is already the state under test.
    test "a file with no shelf ancestor is not catalogued" do
      file("f-orphan", "orphan.stl", nil)
      plan = classify
      assert_not_includes plan.model_keys, "f-orphan"
      assert_includes plan.skips.map(&:last), :no_shelf
    end

    test "a tombstoned file is invisible" do
      @user.nodes.find_by!(node_id: "f-body").update!(deleted: true)
      assert_equal %w[f-clip f-manual], classify.files_for("d-enc").sort
    end
  end
end
