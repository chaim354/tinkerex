require "test_helper"

module Web
  # Choosing a project's cover image, and the derived fallback that was there before it.
  #
  # BACKEND-NEUTRAL: the cover is a `node_id` on a maker row and the chooser reads the shared
  # `nodes` catalog, so nothing here touches the port.
  class ProjectCoverTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      # A hermetic library for this suite. It pinned embedded chunk until Arc D Part 2; with that
      # backend retired it would otherwise run on the AMBIENT one, which on the s3 leg means real
      # Aws calls (the stub is opt-in per file) and on chunk_remote means a live sync server.
      # What these tests are about is the web layer, not which backend holds the bytes.
      @root = use_fresh_share_library!
      @user = User.create!(email: "cover-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @user.nodes.create!(node_id: "n-photo", name: "hero.png", kind: "file")
      @user.nodes.create!(node_id: "n-part", name: "arm.stl", kind: "file")
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def attach(node_id, role)
      @project.file_attachments.create!(user: @user, node_id:, role:)
    end

    # --- the form ---------------------------------------------------------------

    test "the new-project form offers a cover chooser in FILE mode" do
      get new_project_path
      assert_select ".folder-field[data-filechooser-mode-value=file]"
      assert_select "input[type=hidden][name=?]", "project[cover_node_id]"
    end

    test "the edit form offers it too, pre-filled with the chosen file's name" do
      @project.update!(cover_node_id: "n-photo")
      get edit_project_path(@project)
      assert_select "input[type=hidden][name=?][value=?]", "project[cover_node_id]", "n-photo"
      assert_select ".folder-field .ff-path", text: "hero.png"
    end

    # THE READER FALLS BACK TO THE DERIVED PICK, so pre-filling the field from the METHOD would turn
    # "nobody has chosen" into an explicit choice the moment the user saved anything else on the
    # form — silently pinning a cover they never picked.
    test "a project with no chosen cover pre-fills nothing, whatever the derived pick is" do
      attach("n-photo", "image")
      assert_equal "n-photo", @project.cover_node_id, "the derived pick should be in play"

      get edit_project_path(@project)
      # Read the attribute rather than matching `[value=""]`: `hidden_field_tag` OMITS the attribute
      # entirely for a nil value, so a `[value=""]` selector fails on the correct markup and would
      # have sent this fix chasing the wrong thing.
      field = css_select("input[type=hidden][name='project[cover_node_id]']").first
      assert field, "the cover field must still render"
      assert field["value"].blank?, "pre-filled with #{field['value'].inspect} — the derived pick leaked in"
      assert_select ".folder-field .ff-path", text: "Choose automatically"
    end

    # --- saving -----------------------------------------------------------------

    test "choosing a cover on create stores it" do
      post projects_path, params: { project: { name: "Lamp Two", cover_node_id: "n-photo" } }
      assert_equal "n-photo", @user.maker_projects.find_by!(slug: "lamp-two")[:cover_node_id]
    end

    test "choosing a cover on edit stores it and wins over the derived pick" do
      attach("n-part", "model")
      patch project_path(@project), params: { project: { name: "Desk Lamp", cover_node_id: "n-photo" } }
      assert_equal "n-photo", @project.reload.cover_node_id
    end

    # THE WAY BACK. Without it, choosing a cover is a one-way door: the chooser can produce no value
    # meaning "none", so a user who picked one could never return to the automatic pick.
    test "the clear checkbox returns the project to picking automatically" do
      attach("n-photo", "image")
      @project.update!(cover_node_id: "n-part")
      assert_equal "n-part", @project.cover_node_id

      patch project_path(@project),
            params: { project: { name: "Desk Lamp", cover_node_id: "n-part", cover_clear: "1" } }
      @project.reload
      assert_nil @project[:cover_node_id], "the stored choice must be gone"
      assert_equal "n-photo", @project.cover_node_id, "and the derived pick takes over again"
    end

    # THE ONE COMBINATION THE FORM CANNOT SHOW THE OUTCOME OF, so it is pinned rather than left to
    # be discovered. Clearing wins: a stray blank costs two clicks to re-pick, where ignoring an
    # explicit Clear would be a control the user ticked and watched do nothing.
    test "clearing beats choosing when a submit somehow carries both" do
      patch project_path(@project),
            params: { project: { name: "Desk Lamp", cover_node_id: "n-photo", cover_clear: "1" } }
      assert_nil @project.reload[:cover_node_id]
    end

    # `cover_clear` is not a column. Permitting it would hand `update` an unknown attribute and
    # raise — a 500 on the ordinary edit path.
    test "the clear flag never reaches the model as an attribute" do
      patch project_path(@project), params: { project: { name: "Desk Lamp", cover_clear: "0" } }
      assert_response :redirect
      assert_equal "Desk Lamp", @project.reload.name
    end

    # --- what the rest of the app reads ------------------------------------------

    test "the projects index renders the chosen cover, not the derived one" do
      attach("n-part", "model")
      @project.update!(cover_node_id: "n-photo")
      get projects_path
      assert_response :success
      assert_equal "n-photo", @project.reload.cover_node_id
    end

    # The whole point of the fallback: every project that existed before this column looks exactly
    # as it did. First image, else first model, else first attachment by position.
    test "with nothing chosen the derived order is unchanged: image, then model, then first" do
      attach("n-part", "model")
      assert_equal "n-part", @project.cover_node_id
      attach("n-photo", "image")
      assert_equal "n-photo", @project.reload.cover_node_id, "an image outranks a model"
    end
  end
end
