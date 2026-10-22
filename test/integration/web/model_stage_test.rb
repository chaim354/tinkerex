require "test_helper"

module Web
  # THE MODEL PAGE (2026-10-21, docs/superpowers/specs/2026-10-21-file-click-and-model-page-design.md):
  # every model renders its own page, the list on the left targets the `model_stage` frame on the
  # right, and `?file=` picks what that pane shows — one of this model's live files, `details`, or the
  # default for anything else (the first live instructions file, else Details). Never an error.
  #
  # ROWS ONLY, BOTH TOKEN COLUMNS (template_hygiene_test.rb#file!'s shape), so the stat answers on
  # every backend leg without bytes behind it.
  class ModelStageTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "ms-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @user.nodes.create!(node_id: "d-bracket", name: "bracket", kind: "dir", mtime: 1, size: 0)
      file!("n-stl", "bracket.stl")
      file!("n-pdf", "assembly.pdf")
      file!("n-src", "notes.txt")
      @model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-bracket")
      attach!("n-stl", "model", 0)
      attach!("n-pdf", "instructions", 1)
      attach!("n-src", Maker::FileAttachment.role_for("notes.txt"), 2)
    end

    def file!(node_id, name)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: "d-bracket", mtime: 1, size: 5,
                          content_hash: "h-#{node_id}", current_version_id: "v-#{node_id}")
    end

    def attach!(node_id, role, position)
      @model.file_attachments.create!(user: @user, node_id:, role:, position:)
    end

    test "a folder model renders its own page, opening on its instructions" do
      get model_path(@model)
      assert_response :success
      assert_select ".page-head h1", text: "Wall Bracket"
      assert_select "turbo-frame#model_stage iframe.preview-pdf[src=?]", blob_file_path("n-pdf")
      assert_select ".model-index a[aria-current='true'][href=?]", model_path(@model, file: "n-pdf")
    end

    test "with no instructions the pane opens on Details" do
      @model.file_attachments.find_by!(node_id: "n-pdf").destroy!
      get model_path(@model)
      assert_select "turbo-frame#model_stage .model-details"
      assert_select ".model-index a.model-index-details[aria-current='true']"
    end

    test "?file=details shows Details even when the model has instructions" do
      get model_path(@model, file: "details")
      assert_select "turbo-frame#model_stage .model-details"
      assert_select "turbo-frame#model_stage iframe.preview-pdf", count: 0
    end

    test "?file= shows a listed file in the pane, with its own Download and file-page doors" do
      get model_path(@model, file: "n-stl")
      assert_select "turbo-frame#model_stage .model-viewer"
      assert_select "turbo-frame#model_stage .model-stage-head a[href=?]", file_path("n-stl"), text: "Open file page"
      assert_select "turbo-frame#model_stage .model-stage-head a[href=?]", blob_file_path("n-stl", download: 1),
                    text: "Download"
      assert_select ".model-index a[aria-current='true'][href=?]", model_path(@model, file: "n-stl")
    end

    # THE PANE VIEWS, THE FILE PAGE EDITS: a text file is the read-only code viewer here, never the
    # editor, and Measure carries no save doors (files/_viewer's `editable:`/`save:`).
    test "the pane is read-only" do
      get model_path(@model, file: "n-src")
      assert_select "turbo-frame#model_stage [data-controller='codeview']"
      assert_select "turbo-frame#model_stage [data-controller='editor']", count: 0
    end

    test "a foreign node, a tombstone, a folder, garbage and a non-string fall back to the default" do
      other = User.create!(email: "ms-o-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: "n-theirs", name: "x.stl", kind: "file", mtime: 1, size: 1)
      file!("n-gone", "gone.stl").update!(deleted: true)
      attach!("n-gone", "model", 3)
      # A LIVE NODE THE PAGE ALREADY HOLDS IS NOT ENOUGH: the cover joins the page's node index
      # whether or not it is attached (ModelsController#show), so only a check against the model's
      # live ATTACHMENTS refuses it. Every other id here is absent from that index anyway.
      file!("n-cover", "cover.png")
      @model.update!(cover_node_id: "n-cover")
      [ "n-theirs", "n-gone", "d-bracket", "n-cover", "no-such-node" ].each do |id|
        get model_path(@model, file: id)
        assert_response :success
        # THE COUNT IS SPELLED OUT, NEVER LEFT TO THE MESSAGE'S SLOT: after the `?` value,
        # assert_select reads the next argument as the EQUALITY, and a String there is a TEXT match
        # against the iframe — an assertion that can never pass. The message goes after it.
        assert_select "turbo-frame#model_stage iframe.preview-pdf[src=?]", blob_file_path("n-pdf"),
                      { count: 1 }, "#{id} did not fall back to the default"
      end
      get "#{model_path(@model)}?file[]=n-stl"
      assert_response :success
      assert_select "turbo-frame#model_stage iframe.preview-pdf"
    end

    # A FRAME REQUEST IS THE PANE ALONE, so switching files costs one viewer's setup: no page head, no
    # list, no Details sections.
    test "a frame request renders the pane alone" do
      get model_path(@model, file: "n-stl"), headers: { "Turbo-Frame" => "model_stage" }
      assert_response :success
      assert_select "turbo-frame#model_stage .model-viewer"
      assert_select ".page-head", count: 0
      assert_select ".model-index", count: 0

      get model_path(@model, file: "details"), headers: { "Turbo-Frame" => "model_stage" }
      assert_select "turbo-frame#model_stage .model-details"
      assert_select ".model-index", count: 0
    end

    test "the list's file links target the pane and open the file page in a new tab" do
      get model_path(@model)
      links = css_select(".model-index .tree-fname")
      assert_equal %w[n-pdf n-src n-stl].sort, links.map { |a| a["href"][/file=([^&]+)/, 1] }.sort
      links.each do |a|
        id = a["href"][/file=([^&]+)/, 1]
        assert_equal "model_stage", a["data-turbo-frame"]
        assert_equal "advance", a["data-turbo-action"]
        assert_equal file_path(id), a["data-fileopen-new-tab-url"]
        assert_includes a["data-action"], "click->fileopen#click"
      end
    end
  end
end
