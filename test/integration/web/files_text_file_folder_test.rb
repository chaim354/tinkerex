require "test_helper"

module Web
  # NEW TEXT FILE SAYS WHERE IT GOES (UX audit D9, 2026-11-02). The form carried the folder as a
  # hidden id, with no breadcrumb and no field, so a maker could not see where the file would land
  # and a "That folder is no longer here" refusal offered no way to pick another. It is a folder
  # field now, in the chooser's own spelling, and the crumb names the folder; every refusal
  # re-renders the form with both, in a sentence written for a maker (D10).
  #
  # PINNED TO A FRESH SHARE LIBRARY: the create writes real bytes through the port.
  class FilesTextFileFolderTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "tff-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @projects = create_node!(@user, node_id: "d-projects", name: "Projects", kind: "dir")
      @catan = create_node!(@user, node_id: "d-catan", name: "catan", kind: "dir", parent_node_id: @projects.node_id)
    end

    # The house stub (text_file_creation_test.rb carries the same body).
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    def assert_folder_field(value:, label:)
      assert_select "form .field .folder-field input[type=hidden][name=parent_node_id][value=?]", value
      assert_select "form .field .folder-field .ff-path", text: label
    end

    test "the form names the folder in a field and in the crumb" do
      get new_files_text_file_path(parent_node_id: @catan.node_id)
      assert_response :success
      assert_folder_field(value: @catan.node_id, label: "/Projects/catan")
      assert_select "nav.breadcrumb a[href=?]", files_path(folder: @projects.node_id), text: "Projects"
      assert_select "nav.breadcrumb a[href=?]", files_path(folder: @catan.node_id), text: "catan"
      assert_select "nav.breadcrumb [aria-current=page]", text: "New text file"
      # The top bar's Upload carries its own; the FORM must carry the folder once, in its field.
      assert_select "main form[action=?] input[name=parent_node_id]", files_text_files_path, 1
    end

    test "at the library root the field says so" do
      get new_files_text_file_path
      assert_folder_field(value: "", label: "/ (library root)")
    end

    # THE WAY OUT OF THE REFUSAL IS THE FIELD: the gone folder keeps its id, so a second Create
    # without choosing says so again instead of quietly writing to the root.
    test "a folder that has gone is refused with the folder field there to choose another" do
      FileLayer.current.delete(@user, node_id: @catan.node_id)
      post files_text_files_path, params: { name: "notes.txt", parent_node_id: @catan.node_id }
      assert_response :not_found
      assert_folder_field(value: @catan.node_id, label: "Choose a folder")
      assert_select "input[name=name][value=?]", "notes.txt"
      refute @user.nodes.present.exists?(name: "notes.txt"), "a refused create still wrote a file"
    end

    test "a name already in the folder is refused in a sentence, with no port internals" do
      create_node!(@user, node_id: "n-taken", name: "notes.txt", kind: "file", parent_node_id: @catan.node_id)
      replacing(Maker::TextSave, :call, ->(**) { raise FileLayer::UnsupportedOperation, "\"Projects/catan/notes.txt\" already exists" }) do
        post files_text_files_path, params: { name: "notes.txt", parent_node_id: @catan.node_id }
      end
      assert_response :unprocessable_entity
      assert_equal "A file named notes.txt is already in this folder. Choose another name.", flash[:alert]
      assert_folder_field(value: @catan.node_id, label: "/Projects/catan")
    end

    test "an unreachable library is refused in the app's one sentence for it" do
      replacing(Maker::TextSave, :call, ->(**) { raise FileLayer::FetchError, "\"d-catan\": ENOENT and the library root looks unmounted" }) do
        post files_text_files_path, params: { name: "notes.txt", parent_node_id: @catan.node_id }
      end
      assert_response :service_unavailable
      assert_equal "Couldn't reach your library. Try again.", flash[:alert]
      refute_includes flash[:alert], "ENOENT"
    end
  end
end
