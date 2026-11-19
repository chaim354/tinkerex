require "test_helper"
require "support/public_fixture"

module Web
  # EMBEDDED FILES, SERVER HALF (2026-11-19; docs/superpowers/specs/2026-11-19-embedded-files-design.md):
  # an HTML file's page runs it in the sandboxed frame; a file's preview area renders on its own in the
  # bare `embed` layout; and a project page's File block shows either, on the maker's page and a
  # visitor's. The sandbox door itself is SandboxTest; the frame's isolation in a real browser is
  # test/system/embedded_files_test.rb.
  #
  # PINNED TO SHARE ON EVERY LEG (markdown_file_page_test.rb's reason): these pages and the door read
  # REAL BYTES through the port.
  class FileEmbedTest < ActionDispatch::IntegrationTest
    include PublicFixture

    VIEWER = "<!doctype html><title>Case</title><p>three.js goes here</p>\n".freeze

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "maker-#{SecureRandom.hex(3)}")
      sign_in_as(@user)
      @project = @user.maker_projects.create!(name: "PC Case")
      @folder = make_project_folder!(@user, @project)
      @viewer_dir = make_dir!(@user, "viewer", @folder)
      @html = file!("case.html", @viewer_dir, VIEWER)
      @notes = file!("notes.md", @folder, "# Build notes\n\nCut the walnut first.\n")
      @sheet = file!("cut list.xlsx", @folder, "PK")
    end

    def file!(name, parent, body)
      node = create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent&.node_id,
                                 mtime: 1, size: body.bytesize, content_hash: Digest::SHA256.hexdigest(body))
      @root.join(node.storage_path).binwrite(body)
      node
    end

    def block!(**attrs) = @project.blocks.create!(user: @user, **attrs)

    # The sandbox frame on the page, and its URL actually serving the file under the enforcing policy.
    def assert_sandbox_frame(scope = "")
      frame = css_select("#{scope} iframe.preview-html".strip).first
      assert frame, "no sandbox frame#{" in #{scope}" if scope.present?}"
      sandbox = frame["sandbox"].to_s.split
      assert_includes sandbox, "allow-scripts"
      assert_not_includes sandbox, "allow-same-origin", "the frame must never get this app's origin back"
      assert_equal Maker::HtmlSandbox::PERMISSIONS, frame["sandbox"], "the attribute and the header grant the same"
      assert frame["src"].start_with?("/sandbox/"), frame["src"]
      frame["src"]
    end

    # --- an HTML file's own page -------------------------------------------------------------------

    test "an HTML file's page runs it in the sandboxed frame, Rendered pressed and Source one press away" do
      get file_path(@html.node_id)
      assert_response :success

      assert_select ".html-view .view-toggle[role=group]" do
        assert_select "button.active[aria-pressed=true][data-markdown-view-pane-param=rendered]", text: "Rendered"
        assert_select "button[aria-pressed=false][data-markdown-view-pane-param=source]", text: "Source"
      end
      src = assert_sandbox_frame(".html-view .html-rendered")
      # Outside a working tree an .html is read-only (EDITABLE_WITHOUT_HISTORY), so Source is the viewer.
      assert_select ".html-view .markdown-source[hidden] .preview-code[data-controller=codeview]", 1

      get src
      assert_response :success
      assert_equal VIEWER, response.body
      assert_match(/\Asandbox /, response.headers["Content-Security-Policy"])
    end

    test "a file that is not HTML gets no frame and no toggle" do
      get file_path(@sheet.node_id)
      assert_response :success
      assert_select ".html-view", 0
      assert_select "iframe.preview-html", 0
    end

    # --- the bare preview area ---------------------------------------------------------------------

    test "the embed page is the file page's preview area in a bare layout whose links leave the frame" do
      get embed_file_path(@notes.node_id)
      assert_response :success

      assert_select "body.embed-body[data-turbo=false]"
      assert_select "head base[target=_top]", 1
      assert_select ".rail, .topbar, .tabbar", 0
      # THE SAME AREA AS THE FILE PAGE: the rendered Markdown, and the editor behind Source (a loose
      # .md is editable, exactly as on its page).
      assert_select ".embed-preview .markdown-view .markdown-rendered h1", text: "Build notes"
      assert_select ".embed-preview .markdown-source[hidden] .preview-code[data-controller=editor]", 1
    end

    test "a workbook's embed is its grid with Save, as on its page" do
      get embed_file_path(@sheet.node_id)
      assert_response :success
      assert_select ".embed-preview .spreadsheet[data-spreadsheet-save-url-value=?]", file_spreadsheet_path(@sheet.node_id)
    end

    test "a missing file answers in the frame, not a redirect" do
      other = make_owner!(handle: "other-#{SecureRandom.hex(3)}")
      theirs = other.nodes.create!(node_id: SecureRandom.uuid, name: "x.md", kind: "file", mtime: 1, size: 1)
      [ "no-such-node", theirs.node_id, @viewer_dir.node_id ].each do |id|
        get embed_file_path(id)
        assert_response :not_found, id
        assert_select "body.embed-body p.embed-gone", text: /not in the library/
        refute_includes response.body, "<%"
        refute_includes response.body, "%>"
      end
    end

    # --- the File block on the maker's page --------------------------------------------------------

    test "a File block shows an HTML file running and any other file's preview area, headed by a link to its page" do
      html = block!(kind: "file", node_id: @html.node_id, heading: "The case in 3D")
      notes = block!(kind: "file", node_id: @notes.node_id)

      get project_path(@project)
      assert_response :success

      assert_select "section.block-panel.block--file[id=?]", html.layout_key do
        assert_select "h2.block-file-heading a[href=?]", file_path(@html.node_id), text: "The case in 3D"
      end
      assert_sandbox_frame("section[id='#{html.layout_key}']")
      assert_select "section.block-panel.block--file[id=?]", notes.layout_key do
        # No heading of the maker's: the file's own name.
        assert_select "h2.block-file-heading a[href=?]", file_path(@notes.node_id), text: "notes.md"
        assert_select ".embed-frame iframe.embed-frame-view[src=?][loading=lazy]", embed_file_path(@notes.node_id)
        assert_select "iframe[sandbox]", 0
      end
    end

    test "a File block whose file is gone renders no slot" do
      block = block!(kind: "file", node_id: @notes.node_id)
      @notes.update!(deleted: true)

      get project_path(@project)
      assert_response :success
      assert_select "section[id=?]", block.layout_key, 0
    end

    test "the editor offers every file in the folder by its path, and a File block is one of the kinds" do
      block = block!(kind: "file", node_id: @sheet.node_id)

      get edit_layout_project_path(@project)
      assert_response :success

      assert_select "details.layout-add button[data-kind=file]", text: "File"
      assert_select "template[data-kind=file] select[data-field=file] option[value=?]", @html.node_id, text: "viewer/case.html"
      assert_select "div.panel-slot[data-key=?][data-file=?]", block.layout_key, @sheet.node_id do
        assert_select "select[data-field=file][data-action='change->layout-editor#field']" do
          assert_select "option[value=?][selected]", @sheet.node_id, text: "cut list.xlsx"
          assert_select "option[value=?]", @notes.node_id, text: "notes.md"
        end
        assert_select "input[data-field=heading]"
      end
    end

    # --- a visitor's page --------------------------------------------------------------------------

    test "a published project's File blocks are read-only and wholly public: a public token, a public embed" do
      @project.update!(visibility: "public")
      html = block!(kind: "file", node_id: @html.node_id)
      notes = block!(kind: "file", node_id: @notes.node_id)
      reset! # a stranger: no session

      get public_project_path(@user.handle, @project.slug)
      assert_response :success
      assert_no_private_urls

      src = assert_sandbox_frame("section[id='#{html.layout_key}']")
      assert_select "section[id=?] h2.block-file-heading a[href=?]", html.layout_key,
                    public_file_view_path(@user.handle, @project.slug, @html.node_id)
      embed = public_file_embed_path(@user.handle, @project.slug, @notes.node_id)
      assert_select "section[id=?] iframe.embed-frame-view[src=?]", notes.layout_key, embed

      get src
      assert_response :success
      assert_equal VIEWER, response.body

      get embed
      assert_response :success
      assert_select "body.embed-body"
      assert_no_private_urls
      # READ-ONLY: the code viewer, never the editor.
      assert_select ".preview-code[data-controller=editor]", 0
      assert_select ".preview-code[data-controller=codeview]", 1
    end

    test "a visitor's file page runs an HTML file too, and a private project's embed is a 404" do
      @project.update!(visibility: "public")
      reset! # a stranger: no session

      get public_file_view_path(@user.handle, @project.slug, @html.node_id)
      assert_response :success
      assert_sandbox_frame(".html-view")
      assert_no_private_urls

      @project.update!(visibility: "private")
      get public_file_embed_path(@user.handle, @project.slug, @notes.node_id)
      assert_response :not_found
    end
  end
end
