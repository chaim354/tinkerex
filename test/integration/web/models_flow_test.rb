require "test_helper"

module Web
  class ModelsFlowTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # Views READ file metadata + capabilities through FileLayer.current; pin a real backend so a
    # LIBRARY_BACKEND=share CI leg (no LIBRARY_PATH) doesn't fail on backend construction.
    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
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

    test "show renders a 3D switcher over STL/3MF/OBJ only, excluding STEP" do
      user = sign_in
      m = user.maker_models.create!(title: "Multi")
      folder = m.ensure_library_folder!(user)
      { "body.stl" => "b1", "lid.3mf" => "l1", "clip.obj" => "c1", "cad.step" => "s1" }.each_with_index do |(name, nid), i|
        user.nodes.create!(node_id: nid, name:, kind: "file", parent_node_id: folder.node_id)
        m.file_attachments.create!(user:, node_id: nid, role: Maker::FileAttachment.role_for(name), position: i)
      end

      get model_path(m)
      assert_response :success
      assert_select ".model-hero.model-viewer[data-modelviewer-lazy-value=?]", "true"
      assert_select "select.model-viewer-source option", count: 3        # stl + 3mf + obj, NOT step
      assert_select "select.model-viewer-source option[data-url=?][data-format=?]", blob_file_path("b1"), "stl"
      assert_select "select.model-viewer-source option[data-format=?]", "3mf"
      assert_select "select.model-viewer-source option[data-format=?]", "obj"
      assert_select "select.model-viewer-source option", text: "cad.step", count: 0
      assert_select ".mv-launch [data-action~=?]", "modelviewer#load"
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
      assert_select ".model-hero.model-viewer[data-modelviewer-url-value=?]", blob_file_path("solo1")
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
