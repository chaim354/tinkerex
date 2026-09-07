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
      #       lid.mage               -> a MillMage CNC project: EXCLUDED_ROLES, so it never joins
      #       parts/
      #         clip.stl
      dir("d-shelf", "3D Models", nil)
      file("f-benchy", "benchy.stl", "d-shelf")
      file("f-notes",  "notes.pdf",  "d-shelf")
      dir("d-enc", "Enclosure", "d-shelf")
      file("f-body",   "body.stl",   "d-enc")
      file("f-manual", "manual.pdf", "d-enc")
      file("f-mage",   "lid.mage",   "d-enc")
      dir("d-parts", "parts", "d-enc")
      file("f-clip", "clip.stl", "d-parts")

      #     Plans/                   -> one model, the shape that shipped the bug
      #       part-a.obj, part-b.obj -> the model files
      #       part-a.mtl             -> the .obj's material sidecar
      #       part-a_tex.jpeg        -> its texture map
      #       drawing.dxf            -> a 2D drawing that has nothing to do with the mesh
      #       docs/readme.pdf        -> supporting, but nothing model-role sits beside it
      dir("d-plans", "Plans", "d-shelf")
      file("f-obj-a", "part-a.obj", "d-plans")
      file("f-obj-b", "part-b.obj", "d-plans")
      file("f-mtl", "part-a.mtl", "d-plans")
      file("f-tex", "part-a_tex.jpeg", "d-plans")
      file("f-dxf", "drawing.dxf", "d-plans")
      dir("d-plandocs", "docs", "d-plans")
      file("f-plandoc", "readme.pdf", "d-plandocs")

      #     Kit/                     -> a model whose OWN folder holds no model file
      #       notes.pdf              -> joins anyway: it is the model's own folder
      #       stl/part.stl           -> the model file, one level down
      #       photos/shot.jpg        -> does NOT join: no model file sits beside it
      dir("d-kit", "Kit", "d-shelf")
      file("f-kitnotes", "notes.pdf", "d-kit")
      dir("d-kitstl", "stl", "d-kit")
      file("f-kitpart", "part.stl", "d-kitstl")
      dir("d-kitphotos", "photos", "d-kit")
      file("f-kitshot", "shot.jpg", "d-kitphotos")

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

    # THE REPORTED BUG (tinkerex, `warso main/plans 1`): a folder holding three .obj files became
    # one model that also swallowed the .dxf drawings sitting beside them. A model claims the
    # meshes and what SUPPORTS them, not every file that shares their folder.
    test "a 2D drawing beside the model files does not join the model" do
      assert_not_includes classify.files_for("d-plans"), "f-dxf"
    end

    # THE OTHER HALF, AND THE ONE A ROLE FILTER IS MOST LIKELY TO BREAK. An .obj is not one file:
    # it loads its material from the .mtl and its texture from the image beside it, so filtering
    # to role "model" alone ships a mesh that renders untextured. `other` and `image` stay.
    test "an obj's material and texture sidecars join it" do
      files = classify.files_for("d-plans")
      assert_includes files, "f-mtl"
      assert_includes files, "f-tex"
      assert_equal %w[f-mtl f-obj-a f-obj-b f-tex], files.sort
    end

    # A SUBFOLDER WITH NO MODEL FILE IS NOT PART OF THE MODEL. This is what stops a firmware tree
    # or a build-artifact directory joining a model because one .stl sits somewhere in the repo:
    # measured on a real share library, `Projects/TheFlightWall_OSS` attached 2305 files, of which
    # 2 were meshes.
    test "a supporting file in a folder with no model file does not join" do
      assert_not_includes classify.files_for("d-plans"), "f-plandoc"
      assert_not_includes classify.files_for("d-kit"), "f-kitshot"
    end

    # THE MODEL'S OWN FOLDER IS ALWAYS PART OF IT, EVEN WITH NO MESH DIRECTLY IN IT -- the clause
    # the rule above would otherwise eat. `Kit/notes.pdf` beside `Kit/stl/part.stl` is an ordinary
    # download layout, and dropping the PDF there is the over-filter this pins against.
    test "a supporting file in the model's own folder joins even when the meshes are one level down" do
      assert_equal %w[f-kitnotes f-kitpart], classify.files_for("d-kit").sort
    end

    # THE DENYLIST DOES WORK ON A REAL FILE, not only on a constant. Added with `cnc_design` in
    # stage 4, S4-2 because the membership test below CANNOT catch an omission: it asks whether
    # every name in EXCLUDED_ROLES is a real role, so dropping one leaves it green. Mutation-checked
    # by removing `cnc_design` from the denylist -- this goes RED, and so does the "subfolder of a
    # shelf" case above, which is the same claim stated over the whole folder.
    test "a MillMage project inside a model folder does not join the model" do
      refute_includes classify.files_for("d-enc"), "f-mage"
    end

    # THE DENYLIST NAMES REAL ROLES. A typo -- "vectors", "documents" -- excludes nothing and every
    # test above still passes for the wrong reason, since each asserts about a role spelled
    # correctly elsewhere. Maker::FileAttachment owns the vocabulary (§14d); this only pins that
    # ModelIntake's policy is stated in it.
    test "every excluded role is a real role" do
      assert_empty Maker::ModelIntake::EXCLUDED_ROLES - Maker::FileAttachment::ROLES
      assert_not_includes Maker::ModelIntake::EXCLUDED_ROLES, Maker::ModelIntake::MODEL_ROLE
    end

    test "a tombstoned file is invisible" do
      @user.nodes.find_by!(node_id: "f-body").update!(deleted: true)
      assert_equal %w[f-clip f-manual], classify.files_for("d-enc").sort
    end
  end
end
