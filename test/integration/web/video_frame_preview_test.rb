require "test_helper"

module Web
  # "USE THIS FRAME AS PREVIEW" (2026-11-22): a video's player offers its frame as the file's tile,
  # through the 3D viewer's door (Files::PreviewsController). Nothing renders a video, so the frame
  # the maker chooses is the only picture one can have, and three things follow that a renderable
  # file never meets: the Library's tiles must draw a `viewer` row for a name the Registry does not
  # claim (FilesHelper#thumb_cell?), a frame whose content moved on must not be drawn, and "remove"
  # has no render to go back to.
  #
  # ROWS ONLY, BOTH TOKEN COLUMNS (template_hygiene_test.rb#file!'s shape), so every stat answers
  # on every backend leg without bytes behind it, and each leg asks its own adapter for the token.
  # The browser half — a frame drawn, posted and seen on the grid — is test/system/video_frame_test.rb.
  class VideoFramePreviewTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PNG_1PX = Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    ).freeze

    setup do
      @user = User.create!(email: "vf-#{SecureRandom.hex(4)}@example.com", password: WEB_PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user)
      @user.nodes.create!(node_id: "d-shop", name: "shop", kind: "dir", mtime: 1, size: 0)
      @clip = file!("n-clip", "jig.mp4")
    end

    def file!(node_id, name)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: "d-shop", mtime: 1, size: 5,
                          content_hash: "h-#{node_id}", current_version_id: "v-#{node_id}")
      node_id
    end

    def choose_frame!(node_id = @clip)
      post file_preview_path(node_id),
           params: { image: Rack::Test::UploadedFile.new(StringIO.new(PNG_1PX), "image/png", original_filename: "preview.png") },
           headers: { "Accept" => "application/json" }
      assert_response :created
    end

    def row = @user.maker_previews.find_by(node_id: @clip, kind: "thumbnail")

    # ---- The control: the maker's file page and embedded block, never the pane or a visitor ----

    test "a video's own page offers its frame as the preview, through the preview door" do
      get file_path(@clip)
      assert_response :success
      assert_select ".video-viewer[data-controller='videoframe'][data-videoframe-preview-url-value=?]", file_preview_path(@clip) do
        assert_select "video.preview-video[data-videoframe-target='video'][src=?]", blob_file_path(@clip)
        assert_select "button[data-action='videoframe#capture']", text: "Use this frame as preview"
        assert_select "[data-videoframe-target='status'][role='status']"
      end
      assert_select "video[crossorigin]", 0, "a crossorigin player does not play at all from a bucket without a CORS rule"
      assert_select "form[action=?] input[name=_method][value=delete]", file_preview_path(@clip), count: 0
    end

    test "with a frame chosen, the page offers to remove it" do
      choose_frame!
      get file_path(@clip)
      assert_select ".video-viewer form[action=?] input[name=_method][value=delete]", file_preview_path(@clip)
    end

    test "a project's embedded file block is the maker's too, and offers it" do
      get embed_file_path(@clip)
      assert_response :success
      assert_select "[data-videoframe-preview-url-value=?] button[data-action='videoframe#capture']", file_preview_path(@clip)
    end

    # THE PANE VIEWS, THE FILE PAGE WRITES (files/_viewer's `save:`): choosing a file's picture is a
    # write, as the Measure bar's Save twins are, so the model page plays the video and offers neither.
    test "the model page's pane plays the video and offers no frame" do
      model = @user.maker_models.create!(title: "Jig", folder_node_id: "d-shop")
      model.file_attachments.create!(user: @user, node_id: @clip, role: Maker::FileAttachment.role_for("jig.mp4"), position: 0)
      choose_frame!

      get model_path(model, file: @clip)
      assert_response :success
      assert_select "turbo-frame#model_stage video.preview-video[src=?]", blob_file_path(@clip)
      assert_select "[data-controller='videoframe']", 0
      assert_select "button[data-action='videoframe#capture']", 0
      assert_select "form[action=?]", file_preview_path(@clip), count: 0
    end

    # ---- The door, for a name no renderer claims ----

    test "the door stores a video's frame as a ready viewer row at the file's current content" do
      choose_frame!
      assert_equal [ "viewer", "ready", FileLayer.current.stat(@user, node_id: @clip).content_token ],
                   [ row.source, row.status, row.version_id ]
      assert row.asset.attached?
    end

    # ---- The tiles: a chosen frame is drawn wherever the Library draws a tile ----

    test "with no frame chosen a video keeps its type badge and no poll cell" do
      get files_path(folder: "d-shop", view: "grid")
      assert_select ".grid-card .thumb.generic-thumb", text: "MP4"
      assert_select ".file-cell[data-node-id=?]", @clip, count: 0
    end

    test "a chosen frame is the video's tile in the grid, the list, the inspector and Recent" do
      choose_frame!
      src = rails_blob_path(row.asset, only_path: true)

      get files_path(folder: "d-shop", view: "grid")
      assert_select ".grid-card.file-cell[data-node-id=?] .thumb.photo img[src=?]", @clip, src
      get files_path(folder: "d-shop", view: "list")
      assert_select "a.file-cell[data-node-id=?] .thumb.photo img[src=?]", @clip, src
      get inspector_file_path(@clip)
      assert_select ".inspector-stage .file-cell .thumb.photo img[src=?]", src
      get root_path
      assert_select ".grid-card.file-cell[data-node-id=?] .thumb.photo img[src=?]", @clip, src
    end

    # A STACK'S FIGURE IS ITS LATEST MEMBER'S PICTURE, so a video stack wears the frame of the newest.
    test "a version stack of videos wears its latest member's chosen frame" do
      @user.nodes.find_by!(node_id: @clip).update!(name: "jig v1.mp4")
      latest = file!("n-clip2", "jig v2.mp4")
      @user.nodes.find_by!(node_id: latest).update!(mtime: 2)
      choose_frame!(latest)
      src = rails_blob_path(@user.maker_previews.find_by!(node_id: latest).asset, only_path: true)

      get files_path(folder: "d-shop", view: "grid")
      assert_select ".stack-toggle.file-cell[data-node-id=?] .thumb.photo img[src=?]", latest, src
      get files_path(folder: "d-shop", view: "list")
      assert_select ".stack-toggle.file-cell[data-node-id=?] .thumb.photo img[src=?]", latest, src
    end

    # A ROW IS NOT A PICTURE. The v1 previews API makes a row for a name no renderer handles (its
    # `skip_unrenderable: false`), and its job writes `unsupported`; only the maker's own `viewer`
    # row makes a video's tile a picture cell.
    test "a renderer's unsupported row for a video leaves the badge" do
      @user.maker_previews.create!(node_id: @clip, kind: "thumbnail", status: "unsupported",
                                   version_id: FileLayer.current.stat(@user, node_id: @clip).content_token)

      get files_path(folder: "d-shop", view: "grid")
      assert_select ".grid-card .thumb.generic-thumb", text: "MP4"
      assert_select ".file-cell[data-node-id=?]", @clip, count: 0
    end

    # A FRAME OF OTHER BYTES IS NOT THIS FILE'S PICTURE. A renderable file's row is repointed by
    # Enqueue; a video's cannot be (no renderer), so the row stays behind, stale, and the tile must
    # go back to the badge rather than show footage the file no longer holds.
    test "a frame chosen before the content changed is not drawn" do
      choose_frame!
      @user.nodes.find_by!(node_id: @clip).update!(content_hash: "h-new", current_version_id: "v-new")

      get files_path(folder: "d-shop", view: "grid")
      assert_select ".grid-card .thumb.generic-thumb", text: "MP4"
      assert_select ".thumb img", 0
      get file_path(@clip)
      assert_select "form[action=?]", file_preview_path(@clip), count: 0
    end

    # The poll answers the same thing the page drew, so a cell holding a spinner for any reason
    # resolves to the picture, and a video with none resolves to the badge.
    test "the thumbnails poll answers ready for a chosen frame and unsupported without one" do
      get thumbnails_files_path(ids: @clip)
      assert_equal({ "status" => "unsupported", "url" => nil }, response.parsed_body[@clip])
      choose_frame!
      get thumbnails_files_path(ids: @clip)
      assert_equal "ready", response.parsed_body[@clip]["status"]
      assert_equal rails_blob_path(row.asset, only_path: true), URI(response.parsed_body[@clip]["url"]).path
    end

    # ---- Remove: no render to go back to ----

    test "removing a video's frame drops the row and queues no render" do
      choose_frame!
      assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
        delete file_preview_path(@clip)
      end
      assert_redirected_to file_path(@clip)
      assert_equal "jig.mp4 no longer uses the chosen frame as its preview.", flash[:notice]
      assert_nil row

      get files_path(folder: "d-shop", view: "grid")
      assert_select ".grid-card .thumb.generic-thumb", text: "MP4"
    end
  end
end
