require "test_helper"
require "support/mesh_fixture"

module Web
  # "USE THIS VIEW AS PREVIEW" (2026-10-20): Files::PreviewsController. Share is pinned on all three
  # legs: the door stats the node through the port for its content token.
  class FilePreviewTest < ActionDispatch::IntegrationTest
    # A REAL STL with its content hash stamped (MeshFixture#write_model!), not create_node!'s "x"
    # placeholder: the hash IS the content token on share, and a node without one has no token
    # for the row to name.
    include MeshFixture
    # `assert_enqueued_jobs` is not on ActionDispatch::IntegrationTest here (public_file_view_test.rb).
    include ActiveJob::TestHelper

    PNG_1PX = Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    ).freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "fp-#{SecureRandom.hex(4)}@example.com", password: WEB_PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user)
      @node = write_model!(name: "part.stl", body: binary_stl)
    end

    def upload(bytes, type = "image/png")
      Rack::Test::UploadedFile.new(StringIO.new(bytes), type, original_filename: "preview.png")
    end

    def token = FileLayer.current.stat(@user, node_id: @node.node_id).content_token

    def post_preview(bytes, type = "image/png")
      post file_preview_path(@node.node_id), params: { image: upload(bytes, type) },
           headers: { "Accept" => "application/json" }
    end

    test "a PNG becomes the file's thumbnail, marked as the viewer's, at the file's current content" do
      post_preview(PNG_1PX)
      assert_response :created
      row = @user.maker_previews.find_by!(node_id: @node.node_id, kind: "thumbnail")
      assert_equal [ "viewer", "ready", token, 1, 1 ], [ row.source, row.status, row.version_id, row.width, row.height ]
      assert row.asset.attached?
      assert_equal row, Maker::Previews::Enqueue.current_preview(user: @user, node_id: @node.node_id,
                                                                  name: @node.name, version_id: token, kind: "thumbnail")
    end

    # TWO BODIES, BECAUSE THE TWO HALVES OF THE CHECK ARE TWO GUARDS. A GIF has no IHDR at offset 12
    # either, so it alone cannot tell whether the SIGNATURE is compared at all; a PNG's own chunks
    # behind a GIF's signature can.
    test "anything but a PNG is refused and nothing is written" do
      [ "GIF89a....".b, "GIF89a\0\0".b + PNG_1PX.byteslice(8..) ].each do |body|
        post_preview(body, "image/gif")
        assert_response :unprocessable_entity
      end
      assert_not @user.maker_previews.exists?(node_id: @node.node_id, source: "viewer")
    end

    test "an oversized PNG is refused" do
      big = PNG_1PX.dup.tap { |b| b[16, 8] = [ 4096, 4096 ].pack("NN") }
      post_preview(big)
      assert_response :unprocessable_entity
      assert_not @user.maker_previews.exists?(node_id: @node.node_id, source: "viewer")
    end

    test "an upload over the byte ceiling is refused before it is read" do
      post_preview(PNG_1PX + ("\0".b * Files::PreviewsController::MAX_BYTES))
      assert_response :unprocessable_entity
      assert_not @user.maker_previews.exists?(node_id: @node.node_id, source: "viewer")
    end

    test "another user's file is not found" do
      other = User.create!(email: "fpo-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current, omniauth_signup: true)
      theirs = other.nodes.create!(node_id: SecureRandom.uuid, name: "x.stl", kind: "file", size: 1, mtime: 1)
      post file_preview_path(theirs.node_id), params: { image: upload(PNG_1PX) },
           headers: { "Accept" => "application/json" }
      assert_response :not_found
      assert_not other.maker_previews.exists?
    end

    test "back to automatic hands the row to the renderer and queues a render" do
      post_preview(PNG_1PX)
      assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
        delete file_preview_path(@node.node_id)
      end
      row = @user.maker_previews.find_by!(node_id: @node.node_id, kind: "thumbnail")
      assert_equal [ "renderer", "rebuilding" ], [ row.source, row.status ]
      assert_redirected_to file_path(@node.node_id)
    end

    test "the file page offers both buttons only to its owner, and Back only for a viewer preview" do
      get file_path(@node.node_id)
      assert_select "[data-modelviewer-preview-url-value=?]", file_preview_path(@node.node_id)
      assert_select "button[data-action=?]", "modelviewer#usePreview"
      assert_select "form[action=?] input[name=_method][value=delete]", file_preview_path(@node.node_id), count: 0
      post_preview(PNG_1PX)
      get file_path(@node.node_id)
      assert_select "form[action=?] input[name=_method][value=delete]", file_preview_path(@node.node_id)
    end
  end
end
