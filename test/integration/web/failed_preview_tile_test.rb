require "test_helper"
require "support/public_fixture"

module Web
  # A FAILED PREVIEW SAYS SO AT PAGE LOAD (F onboarding, 2026-10-13). files/_thumb.html.erb rendered a
  # `failed` row through the same terminal branch as an `unsupported` one ("Preview not supported"),
  # so a render that broke read as a type with no preview, and thumbs_controller.js said otherwise
  # only for a failure that landed while the page was open. The row's own state now picks the title
  # and the `thumb-failed` mark, and the two surfaces agree.
  #
  # THE ROWS ARE CURRENT, OR THE VIEW NEVER SEES THEM. ThumbnailMap keeps a row only when its
  # version_id is the node's content token (on share, content_hash) and its renderer_revision is the
  # deployed build's (Enqueue.current_preview?); a row failing either renders a spinner, and the
  # assertions below would pass over nothing. Both halves come from the code that owns them, as
  # PublicFixture#ready_preview! does it. No asset is attached: a render that did not finish has none.
  #
  # BOTH FILES ARE .stl, ON PURPOSE. The Files page renders this partial only for a name a renderer
  # handles, so an `unsupported` row reaches it when the toolchain is missing on this server, never
  # for a type with no renderer (that file gets the plain format badge instead).
  class FailedPreviewTileTest < ActionDispatch::IntegrationTest
    include PublicFixture # make_owner!, sign_in_as

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      sign_in_as(@user)
      @dir = create_node!(@user, node_id: SecureRandom.uuid, name: "parts", kind: "dir")
    end

    def file_with_preview!(name, status)
      node = create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "file",
                                 parent_node_id: @dir.node_id, mtime: 1, size: 1, content_hash: "h-#{name}")
      @user.maker_previews.create!(
        node_id: node.node_id, kind: "thumbnail", status:, error: ("render crashed" if status == "failed"),
        version_id: FileLayer.current.stat(@user, node_id: node.node_id).content_token,
        renderer_revision: Maker::Previews::Enqueue.revision_for_name(name, "thumbnail")
      )
      node
    end

    test "a failed render carries the mark and its own title; an unsupported one carries neither" do
      file_with_preview!("bracket.stl", "failed")
      file_with_preview!("panel.stl", "unsupported")

      get files_path(folder: @dir.node_id)

      assert_response :success
      assert_select ".thumb.thumb-failed", 1
      assert_select ".thumb.thumb-failed .thumb-icon[title=?]", "Preview couldn't be rendered", text: "STL"
      assert_select ".thumb:not(.thumb-failed) .thumb-icon[title=?]", "Preview not supported", text: "STL"
    end
  end
end
