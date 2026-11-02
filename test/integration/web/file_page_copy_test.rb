require "test_helper"
require "support/git_repo_fixture"

module Web
  # THE FILE PAGE'S WORDS AND ITS ORDER (UX audit D4, D5, D6, D8, B5 and I, 2026-11-02): the facts
  # panel printed raw MIME types, Delete sat between Download and Back, the 3D, board and fallback
  # posters offered a second "Download NAME" under a head that already had one, the editor said
  # "keeps no history" over a History panel listing commits, the viewers said "Click" to a phone and
  # "Reset" where the 3D viewer says "Reset view", a photo of the file was an unnamed link, and
  # "Back to automatic preview" discarded the maker's chosen view without asking.
  #
  # PINNED TO A FRESH SHARE LIBRARY, so the pages render the same on every backend leg; the working
  # tree is a real repository (GitRepoFixture), scanned into the catalog.
  class FilePageCopyTest < ActionDispatch::IntegrationTest
    include GitRepoFixture

    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @library = @root
      @user = User.create!(email: "copy-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    # `content_hash` IS SHARE'S CONTENT TOKEN, and a page whose stat reports none renders "No content
    # yet." in place of every viewer this suite asserts about.
    def file!(name, **attrs)
      create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "file", size: 1, mtime: 1_000_000_000,
                          content_hash: "h-#{name}", **attrs)
    end

    test "the facts panel's Type is the list's label, never a MIME type" do
      node = file!("lid.lbrn2")
      get file_path(node.node_id)
      assert_response :success
      type = css_select("dl.meta dt").find { |dt| dt.text == "Type" }
      refute_nil type, "the facts panel lost its Type row"
      assert_equal "LBRN2", type.next_element.text.strip
      refute_includes response.body, "application/octet-stream"

      get inspector_file_path(node.node_id)
      assert_select "dl.meta dd", text: "LBRN2"
      refute_includes response.body, "application/octet-stream"
    end

    # DOWNLOAD · BACK · DELETE, destructive last, as the file menu and the inspector order them.
    test "the page head reads Download, Back, then Delete" do
      node = file!("lid.lbrn2")
      get file_path(node.node_id)
      labels = css_select(".page-head .page-actions").first.css("a.btn, button.btn").map { |el| el.text.strip }
      assert_equal %w[Download Back Delete], labels
    end

    # ONE DOWNLOAD PER PAGE: the head's. The posters keep theirs on a visitor's page, which passes
    # them a URL; the maker's passes none (files/_viewer's `poster_download: false`).
    test "no poster offers a second Download under a head that has one" do
      { "bracket.stl" => ".model-viewer-fallback", "board.gtl" => ".model-viewer-fallback",
        "firmware.bin" => ".preview-fallback" }.each do |name, poster|
        node = file!(name)
        get file_path(node.node_id)
        assert_response :success
        assert_select poster, { minimum: 1 }, "#{name}: the poster this asserts about did not render"
        assert_select "#{poster} a[href=?]", blob_file_path(node.node_id, download: 1), 0
        assert_select ".page-head a[href=?]", blob_file_path(node.node_id, download: 1), 1
      end
    end

    test "the posters say Choose, not Click, and Measure's reset is Reset view" do
      stl = file!("bracket.stl")
      get file_path(stl.node_id)
      assert_select ".model-viewer-fallback p", text: /\AChoose View in 3D to load an interactive preview\.\z/
      gtl = file!("board.gtl")
      get file_path(gtl.node_id)
      assert_select ".gerber-viewer [data-gerber-target=status]", text: /\AChoose View layer/
      dxf = file!("plate.dxf")
      get file_path(dxf.node_id)
      assert_select ".measure-actions button[data-action='measure#reset']", text: "Reset view"
      [ stl, gtl, dxf ].each { |n| get file_path(n.node_id); refute_match(/>\s*Click /, response.body) }
    end

    # GIT IS THE HISTORY IN A WORKING TREE: the note is for a file a save replaces with nothing behind
    # it, and inside a repository the History panel below lists what is behind it.
    test "the editor's no-history note is absent inside a working tree and present outside one" do
      inside = seed_repo_file!("notes.md", "old\n")
      outside = file!("loose.md")

      get file_path(inside.node_id)
      assert_response :success
      assert_select "[data-controller~=editor]", 1, "the editor must be here for the note to be about"
      assert_select "section.history-panel", 1
      assert_select ".no-history-note", 0, "a file whose history git holds was told it has none"

      get file_path(outside.node_id)
      assert_select "[data-controller~=editor]", 1
      assert_select ".no-history-note", text: /keeps no history for this file/
    end

    # A PHOTO OF THE FILE IS A NAMED LINK: its only content is a picture whose alt is empty.
    test "a connected photo's link is named for the photo" do
      node = file!("lid.lbrn2")
      photo = file!("lid on the bench.jpg")
      @user.maker_file_links.create!(kind: "photo_of", from_node_id: photo.node_id, to_node_id: node.node_id)
      get file_path(node.node_id)
      assert_select ".connections-photos a.photo-cell[aria-label=?]", "lid on the bench.jpg"
    end
  end

  # THE VIEWER PARTIALS' WORDS, RENDERED ALONE: two states a request cannot reach cheaply — a recipe
  # whose material height is 0, and a thumbnail the maker chose from the 3D view.
  class FileViewerCopyTest < ActionView::TestCase
    include FilesHelper

    test "a LightBurn recipe with no material height does not claim Material 0 mm" do
      html = render(partial: "files/lbrn_settings", locals: { meta: { "layers" => [], "material_height" => 0 } })
      refute_includes html, "Material"
      html = render(partial: "files/lbrn_settings", locals: { meta: { "layers" => [], "material_height" => 3.2 } })
      assert_includes html, "<dt>Material</dt><dd>3.2 mm</dd>"
    end

    test "Back to automatic preview asks before it discards the chosen view" do
      html = render(partial: "files/viewers/model3d",
                    locals: { named_url: "/x/a.stl", format: "stl", colors: [], unit_factor: 1.0, thumbnail: nil,
                              thumbnail_url: nil, download_url: nil, name: "a.stl", preview_url: "/x/preview",
                              viewer_preview: true })
      form = Nokogiri::HTML5.fragment(html).at_css("form[action='/x/preview']")
      refute_nil form, "the way back to the automatic preview did not render"
      assert_equal "Go back to the automatic preview of a.stl? The view you chose as its picture is discarded.",
                   form["data-turbo-confirm"]
    end
  end
end
