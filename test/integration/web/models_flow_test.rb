require "test_helper"
require "support/mesh_fixture"
require "support/three_mf_fixture"

module Web
  class ModelsFlowTest < ActionDispatch::IntegrationTest
    # Real 3MF bytes for the switcher's manifest attributes — the hero reads them per OPTION, and a
    # node with no bytes behind it would answer nil on every leg and prove nothing.
    include ThreeMfFixture

    PASSWORD = "correct horse battery staple".freeze

    # Views READ file metadata + capabilities through FileLayer.current; pin a real backend so a
    # LIBRARY_BACKEND=share CI leg (no LIBRARY_PATH) doesn't fail on backend construction.
    setup do
      # A hermetic library for this suite. It pinned embedded chunk until Arc D Part 2; with that
      # backend retired it would otherwise run on the AMBIENT one, which on the s3 leg means real
      # Aws calls (the stub is opt-in per file) and on chunk_remote means a live sync server.
      # What these tests are about is the web layer, not which backend holds the bytes.
      @root = use_fresh_share_library!
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "requires login" do
      get models_path
      assert_redirected_to new_user_session_path
    end

    test "index lists the user's models with an empty state otherwise" do
      user = sign_in
      get models_path
      assert_response :success
      assert_select "h1", "Models"
      assert_select ".models-empty"

      user.maker_models.create!(title: "Dragon", print_status: "printed")
      get models_path
      assert_select ".model-card .model-name", text: "Dragon"
      assert_select ".model-card .badge.mstatus-printed"
    end

    test "index shows only the current user's models" do
      sign_in("a@example.com").maker_models.create!(title: "Mine")
      User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
          .maker_models.create!(title: "Theirs")
      get models_path
      assert_select ".model-name", text: "Mine"
      assert_select ".model-name", text: "Theirs", count: 0
    end

    test "index filters by status and searches by title" do
      user = sign_in
      user.maker_models.create!(title: "Printed Dragon", print_status: "printed")
      user.maker_models.create!(title: "Wanted Gear", print_status: "want_to_print")
      get models_path(status: "printed")
      assert_select ".model-name", text: "Printed Dragon"
      assert_select ".model-name", text: "Wanted Gear", count: 0
      get models_path(q: "gear")
      assert_select ".model-name", text: "Wanted Gear"
      assert_select ".model-name", text: "Printed Dragon", count: 0
    end

    test "show renders title, status pill, metadata, and the file tree (folders preserved)" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon", designer: "cults", license: "CC BY",
                                    source_url: "https://printables.com/model/1", print_status: "printed")
      # A realistic imported structure: Models/dragon/parts/body.stl.
      folder = m.ensure_library_folder!(user)
      sub = user.nodes.create!(node_id: "sub1", name: "parts", kind: "dir", parent_node_id: folder.node_id)
      user.nodes.create!(node_id: "mdl1", name: "body.stl", kind: "file", parent_node_id: sub.node_id)
      m.file_attachments.create!(user:, node_id: "mdl1", role: "model")
      get model_path(m)
      assert_response :success
      assert_select "h1", text: /Dragon/
      assert_select ".badge.mstatus-printed"
      assert_select ".file-tree-box .tree-folder", text: "parts"          # folder structure shown
      assert_select ".file-tree-box .tree-fname", text: "body.stl"        # file under it
      assert_select "a[href=?]", "https://printables.com/model/1"
    end

    # THE PANEL SHOWS THE MODEL'S FILES, NOT THE FOLDER'S CONTENTS (2026-09-02). It walked
    # folder_node_id's subtree, which was the same set back when a folder model claimed everything
    # under it -- so when Maker::ModelIntake stopped claiming the whole subtree, this panel went on
    # listing the .dxf drawings the catalog had just let go, under a heading counting them. An empty
    # folder is dropped with its files, or the page grows a `docs/` that opens onto nothing.
    test "the file tree omits folder files the model does not claim" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon")
      folder = m.ensure_library_folder!(user)
      user.nodes.create!(node_id: "mdl1", name: "body.stl", kind: "file", parent_node_id: folder.node_id)
      user.nodes.create!(node_id: "dxf1", name: "drawing.dxf", kind: "file", parent_node_id: folder.node_id)
      docs = user.nodes.create!(node_id: "docs1", name: "docs", kind: "dir", parent_node_id: folder.node_id)
      user.nodes.create!(node_id: "txt1", name: "names.txt", kind: "file", parent_node_id: docs.node_id)
      m.file_attachments.create!(user:, node_id: "mdl1", role: "model")

      get model_path(m)

      assert_select ".file-tree-box .tree-fname", text: "body.stl"
      assert_select ".file-tree-box .tree-fname", text: "drawing.dxf", count: 0
      assert_select ".file-tree-box .tree-folder", text: "docs", count: 0
      # THE COUNT IN THE HEADING READS THE SAME SET -- it is built from the tree, so a panel that
      # filtered while the heading did not would be the same contradiction one line higher up.
      assert_select "h2", text: /Files\s*\(1\)/
    end

    # STEP IS IN THE SWITCHER SINCE 2026-09-06 and this test used to assert the opposite ("STL/3MF/
    # OBJ only, excluding STEP") — the Online3DViewer slice gave the browser an OpenCascade importer,
    # so the reason for that exclusion is gone. What has NOT changed is that the switcher is
    # filtered at all: `.f3d` is the file that must still be absent, and it is the honest
    # replacement because no engine we ship reads it.
    test "show renders a 3D switcher over every viewable file, excluding the ones nothing can read" do
      user = sign_in
      m = user.maker_models.create!(title: "Multi")
      folder = m.ensure_library_folder!(user)
      { "body.stl" => "b1", "lid.3mf" => "l1", "clip.obj" => "c1", "cad.step" => "s1",
        "scene.glb" => "g1", "part.f3d" => "f1" }.each_with_index do |(name, nid), i|
        user.nodes.create!(node_id: nid, name:, kind: "file", parent_node_id: folder.node_id)
        m.file_attachments.create!(user:, node_id: nid, role: Maker::FileAttachment.role_for(name), position: i)
      end

      get model_path(m)
      assert_response :success
      assert_select ".model-hero.model-viewer[data-modelviewer-lazy-value=?]", "true"
      assert_select "select.model-viewer-source option", count: 5        # everything but the .f3d
      # THE NAMED BLOB ROUTE HERE TOO — the engine reads the importer off the URL's own trailing
      # extension, so a `data-url` without one switches the viewer to a file it cannot identify.
      assert_select "select.model-viewer-source option[data-url=?][data-format=?]",
                    named_blob_file_path("b1", filename: "body.stl"), "stl"
      %w[3mf obj step glb].each do |fmt|
        assert_select "select.model-viewer-source option[data-format=?]", fmt
      end
      assert_select "select.model-viewer-source option", text: "part.f3d", count: 0
      assert_select ".mv-launch [data-action~=?]", "modelviewer#load"
      # EVERY OPTION CARRIES THE MANIFEST PAIR, whatever its format. `load()` copies both into the
      # controller on a switch, so an option missing them would leave the PREVIOUS file's colours
      # and unit factor in place — and these rows have no bytes, so the honest answer is the no-op
      # pair rather than a manifest.
      assert_select "select.model-viewer-source option[data-colors][data-unit-factor]", count: 5
      assert_select "select.model-viewer-source option[data-colors=?]", "[]", count: 5
      assert_select "select.model-viewer-source option[data-unit-factor=?]", "1", count: 5
    end

    # THE MANIFEST IS PER FILE, WHICH IS WHY IT RIDES ON THE OPTION. Two 3MFs with different slicer
    # palettes and different declared units: the switcher has to hand the viewer the right one for
    # whichever file is selected, and building it on the ELEMENT instead would paint the second
    # model with the first one's colours.
    test "each 3D option carries its own file's slicer colours and unit factor" do
      @user = sign_in
      m = @user.maker_models.create!(title: "Painted")
      bambu = write_model!(name: "plate.3mf",
                           body: bambu_3mf(objects: [ { extruder: 1 }, { extruder: 2 } ],
                                           filaments: %w[#161616 #F98C36 #FFFFFF]))
      metres = write_model!(name: "part.3mf", body: plain_3mf(unit: "meter"))
      [ bambu, metres ].each_with_index do |node, i|
        m.file_attachments.create!(user: @user, node_id: node.node_id, role: "model", position: i)
      end

      get model_path(m)
      assert_response :success
      assert_select "select.model-viewer-source option[value=?][data-colors=?][data-unit-factor=?]",
                    bambu.node_id, '["#161616","#F98C36"]', "1.0"
      assert_select "select.model-viewer-source option[value=?][data-colors=?][data-unit-factor=?]",
                    metres.node_id, "[null]", "1000.0"
    end

    # THE SINGLE-FILE HERO PUTS THE SAME PAIR ON THE ELEMENT, because there is no option to carry
    # them — the two branches of the same template, and only one of them was ever exercised above.
    test "a lone 3MF hero carries its manifest on the element" do
      @user = sign_in
      m = @user.maker_models.create!(title: "Solo 3MF")
      node = write_model!(name: "part.3mf", body: plain_3mf(unit: "inch"))
      m.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")

      get model_path(m)
      assert_response :success
      assert_select ".model-hero.model-viewer[data-modelviewer-unit-factor-value=?]", "25.4"
      assert_select ".model-hero.model-viewer[data-modelviewer-colors-value=?]", "[null]"
    end

    test "show marks the cover file as the default selected option in the switcher" do
      user = sign_in
      m = user.maker_models.create!(title: "Cover")
      folder = m.ensure_library_folder!(user)
      { "body.stl" => "cv1", "lid.3mf" => "cv2", "clip.obj" => "cv3" }.each_with_index do |(name, nid), i|
        user.nodes.create!(node_id: nid, name:, kind: "file", parent_node_id: folder.node_id)
        m.file_attachments.create!(user:, node_id: nid, role: "model", position: i)
      end
      m.update!(cover_node_id: "cv2") # not the first by position

      get model_path(m)
      assert_response :success
      # Exactly one option is selected, and it is the cover file (cv2 = lid.3mf), not the first (cv1).
      assert_select "select.model-viewer-source option[selected]", count: 1
      assert_select "select.model-viewer-source option[selected][value=?]", "cv2"
    end

    test "show renders the 3D button without a switcher for a single 3D file" do
      user = sign_in
      m = user.maker_models.create!(title: "Solo")
      folder = m.ensure_library_folder!(user)
      user.nodes.create!(node_id: "solo1", name: "body.stl", kind: "file", parent_node_id: folder.node_id)
      m.file_attachments.create!(user:, node_id: "solo1", role: "model")

      get model_path(m)
      assert_response :success
      assert_select ".model-hero.model-viewer[data-modelviewer-url-value=?]",
                    named_blob_file_path("solo1", filename: "body.stl")
      assert_select ".model-hero.model-viewer[data-modelviewer-format-value=?]", "stl"
      assert_select "select.model-viewer-source", count: 0
      assert_select ".mv-launch [data-action~=?]", "modelviewer#load"
    end

    test "show renders the plain hero with no 3D controls when no viewable 3D files" do
      user = sign_in
      m = user.maker_models.create!(title: "Flat")
      folder = m.ensure_library_folder!(user)
      user.nodes.create!(node_id: "img1", name: "cover.png", kind: "file", parent_node_id: folder.node_id)
      m.file_attachments.create!(user:, node_id: "img1", role: "image")

      get model_path(m)
      assert_response :success
      assert_select ".model-hero"
      assert_select ".model-hero.model-viewer", count: 0
      assert_select "[data-action~=?]", "modelviewer#load", count: 0
    end

    test "show renders a print-settings panel when present, hides it otherwise" do
      user = sign_in
      m = user.maker_models.create!(title: "P", print_settings: { "material" => "PET", "layer_height" => "0.2 mm" })
      get model_path(m)
      assert_select ".model-print-settings dt", text: "Material"
      assert_select ".model-print-settings dd", text: "PET"
      assert_select ".model-print-settings dt", text: "Layer height"
      get model_path(user.maker_models.create!(title: "NoSettings"))
      assert_select ".model-print-settings", count: 0
    end

    test "show 404s for another user's model" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      m = other.maker_models.create!(title: "Theirs")
      get model_path(m)
      assert_response :not_found
    end

    test "edit + update changes metadata, status, and tags" do
      user = sign_in
      m = user.maker_models.create!(title: "Old")
      get edit_model_path(m)
      assert_response :success
      patch model_path(m), params: { model: { title: "New", designer: "me",
                                              print_status: "failed", tag_list: "dragon, toy" } }
      m.reload
      assert_equal "New", m.title
      assert_equal "failed", m.print_status
      assert_equal %w[dragon toy], m.tag_list.split(", ").sort
      assert_redirected_to model_path(m)
    end

    test "destroy removes the model record but leaves library files" do
      user = sign_in
      m = user.maker_models.create!(title: "Doomed")
      user.nodes.create!(node_id: "keep1", name: "keep.stl", kind: "file")
      m.file_attachments.create!(user:, node_id: "keep1", role: "model")
      assert_difference "Maker::Model.count", -1 do
        delete model_path(m)
      end
      assert_redirected_to models_path
      assert user.nodes.exists?(node_id: "keep1"), "the library file must survive deleting the model"
    end

    test "cannot detach an attachment via a different model's URL" do
      user = sign_in
      a = user.maker_models.create!(title: "A")
      b = user.maker_models.create!(title: "B")
      user.nodes.create!(node_id: "bnode", name: "b.stl", kind: "file")
      att = b.file_attachments.create!(user:, node_id: "bnode", role: "model")
      assert_no_difference "Maker::FileAttachment.count" do
        delete model_attachment_path(a, att)
      end
      assert b.file_attachments.exists?(att.id), "B's attachment survives"
    end
  end
end
