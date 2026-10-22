require "test_helper"

module Web
  # THE MODEL STRIP (structural redesign §5.4, slice 5): a catalogued model's folder shows its cover,
  # status, details and print log above the files, and its title links the model's own page.
  class ModelStripTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "strip-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @user.nodes.create!(node_id: "d-bracket", name: "bracket", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "n-bracket", name: "bracket.stl", kind: "file", parent_node_id: "d-bracket",
                          mtime: 1, size: 1, content_hash: "h", current_version_id: "v")
      @model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-bracket",
                                          designer: "Ada", license: "CC-BY", source_url: "https://example.com/b",
                                          print_settings: { "layer_height" => "0.2mm", "nozzle" => "0.4" })
      @model.file_attachments.create!(user: @user, node_id: "n-bracket", role: "model")
    end

    test "a model's folder shows the strip above its files" do
      get files_path(folder: "d-bracket")
      assert_response :success
      assert_select ".library-main > .model-strip", count: 1
      assert_select ".model-strip h2", text: "Wall Bracket"
      # THE TITLE OPENS THE MODEL'S OWN PAGE (2026-10-21), which every model renders now.
      assert_select ".model-strip h2 a[href=?]", model_path(@model)
      assert_select ".model-strip .badge.mstatus-want_to_print", text: "Wanted"
      assert_select ".model-strip", text: /Ada/
      assert_select ".model-strip a[href=?]", "https://example.com/b"
      assert_select ".model-strip dl", text: /Layer height\s*0\.2mm/
      assert_select ".model-strip a.btn[href=?]", edit_model_path(@model), text: "Edit"
      assert_select ".model-strip form[action=?] button", model_path(@model), text: "Delete"
      assert_select ".model-strip details.composer > summary", text: "Log a print"
      assert_select ".model-strip form[action=?]", model_print_runs_path(@model)
      # The strip is not a selection item and spends no accent (Upload is the folder's one action).
      assert_select ".model-strip [data-selection-target]", count: 0
      assert_select ".model-strip .btn.primary", count: 0
    end

    # THE COVER CELL POLLS ONLY FOR A LIVE NODE. The derived cover is the first mesh attachment, and an
    # attachment outlives its trashed node until Maker::AttachmentReaper's grace window — so a cell
    # here would poll /files/thumbnails for a node it omits, a spinner that never resolves (the case
    # models/_hero_poster guards). The placeholder is the 3D models icon, never an emoji.
    test "the cover polls for a live node, and a trashed one shows the placeholder" do
      get files_path(folder: "d-bracket")
      assert_select ".model-strip .model-strip-cover[data-controller='thumbs'][data-node-id='n-bracket']", count: 1

      @user.nodes.find_by!(node_id: "n-bracket").update!(deleted: true)
      get files_path(folder: "d-bracket")
      assert_select ".model-strip h2", text: "Wall Bracket"
      assert_select ".model-strip [data-controller~='thumbs']", count: 0
      assert_select ".model-strip .model-strip-cover--empty svg.rail-icon", count: 1
    end

    test "an auto model's strip says Remove from catalog, never Delete" do
      @model.update!(origin: "auto", auto_node_id: "d-bracket")
      get files_path(folder: "d-bracket")
      assert_select ".model-strip form[action=?] button", model_path(@model), text: "Remove from catalog"
      assert_select ".model-strip button", text: "Delete", count: 0
    end

    test "no strip on a plain folder, a project's folder, or for a dismissed model" do
      @user.nodes.create!(node_id: "d-plain", name: "plain", kind: "dir", mtime: 1, size: 0)
      get files_path(folder: "d-plain")
      assert_select ".model-strip", count: 0

      @user.maker_projects.create!(name: "Shelf Unit").update_column(:folder_node_id, "d-bracket")
      get files_path(folder: "d-bracket")
      assert_select ".model-strip", count: 0
    end

    test "a dismissed model shows no strip" do
      @model.update!(dismissed_at: Time.current)
      get files_path(folder: "d-bracket")
      assert_select ".model-strip", count: 0
    end

    test "logging a print from the strip returns to the folder" do
      get files_path(folder: "d-bracket")
      post model_print_runs_path(@model),
           params: { print_run: { printed_on: Date.current, outcome: "success" } },
           headers: { "HTTP_REFERER" => files_url(folder: "d-bracket") }
      assert_redirected_to files_url(folder: "d-bracket")
      assert_equal "printed", @model.reload.print_status
    end
  end
end
