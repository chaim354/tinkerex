require "test_helper"

module Web
  # NO PICTURE COMING, NO EMPTY CARD (UX audit 2026-11-01, E3). The model page's Details pane opened
  # on a large blank card above "View in 3D" whenever the cover's render had finished without a
  # picture (an unsupported format, a failed render). With a file the 3D viewer opens, the hero now
  # says so in a line instead; a render still on its way keeps its card and spinner, because a
  # picture is coming. test/system/model_hero_test.rb pins the card's colours.
  #
  # MUTATION-CHECKED (§15): models/_hero_poster's note condition replaced with `false` reddens the
  # finished-without-a-picture arm. Output in this task's report.
  class ModelHeroPosterTest < ActionDispatch::IntegrationTest
    setup do
      @root = use_fresh_share_library!
      @root.join("bracket.stl").write("solid bracket\nendsolid bracket\n")
      @user = User.create!(email: "hero-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
      Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
      @node = @user.nodes.find_by!(storage_path: "bracket.stl")
      @model = @user.maker_models.create!(title: "Bracket")
      @model.file_attachments.create!(user: @user, node_id: @node.node_id, role: "model")
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # The thumbnail row the scan queued (one per node and kind), at the file's current content.
    def thumbnail!(status)
      preview = @user.maker_previews.find_or_initialize_by(node_id: @node.node_id, kind: "thumbnail")
      preview.update!(status:, version_id: FileLayer.current.stat(@user, node_id: @node.node_id).content_token,
                      renderer_revision: Maker::Previews::Enqueue.revision_for_name(@node.name, "thumbnail"))
    end

    test "a render that finished without a picture is a line beside View in 3D, not an empty card" do
      %w[unsupported failed].each do |status|
        thumbnail!(status)
        get model_path(@model, file: "details")
        assert_response :success
        assert_select ".model-viewer .mv-launch button", text: "View in 3D"
        assert_select ".model-viewer-fallback p.model-hero-note", text: /no preview picture for this model/
        assert_select ".model-viewer-fallback .model-hero-thumb", 0
      end
    end

    test "a render on its way keeps its card, which polls for it" do
      thumbnail!("pending")
      get model_path(@model, file: "details")
      assert_select ".model-viewer-fallback .model-hero-thumb[data-controller='thumbs'][data-node-id=?] .thumb .thumb-spinner",
                    @node.node_id
      assert_select ".model-hero-note", 0
    end
  end
end
