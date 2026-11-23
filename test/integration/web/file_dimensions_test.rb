require "test_helper"

module Web
  # THE DIMENSIONS ROW (spec 2026-11-22-material-estimate-design.md, Part 1), driven through the
  # real pages: the facts list on the file page and in the Library inspector shows a flat file's
  # drawn size in mm AND inches, read from its thumbnail row (FilesHelper#file_dimensions).
  #
  # Rows here carry a PICTURE, unlike settings_panel_test.rb's: the size is read from a SHOWABLE row
  # only, because a row repointed at new content keeps the previous content's metadata until its
  # render lands, and that size shown as this file's would be the lie `pending` exists to prevent.
  class FileDimensionsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "dims-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))

    def file_with(name, metadata, status: "ready", picture: true)
      node = create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "file", storage_path: name,
                                 content_hash: SecureRandom.hex(8))
      token = FileLayer.current.stat(@user, node_id: node.node_id).content_token
      # THIS BUILD'S revision, so the page's own heal (Enqueue.needs_job?) has nothing to rebuild and
      # the row's status is the one each test names.
      row = @user.maker_previews.create!(node_id: node.node_id, version_id: token, kind: "thumbnail",
                                         status:, metadata:,
                                         renderer_revision: Maker::Previews::Enqueue.revision_for_name(name, "thumbnail"))
      row.asset.attach(io: StringIO.new("\x89PNG".b), filename: "t.png", content_type: "image/png") if picture
      node
    end

    test "an SVG's facts give its drawing's size in mm and inches, and draw no Laser settings panel" do
      node = file_with("plate.svg", Maker::Previews::Dimensions.measure("plate.svg", fixture("plate.svg")))

      get file_path(node.node_id)
      assert_response :success
      assert_select "dl.meta dt", text: "Dimensions"
      assert_select "dl.meta dd.file-dimensions", text: "80 × 40 mm · 3.15 × 1.57 in"
      assert_select ".lbrn-settings", count: 0
    end

    test "a DXF's facts read the same way" do
      node = file_with("plate.dxf", Maker::Previews::Dimensions.measure("plate.dxf", fixture("plate.dxf")))

      get file_path(node.node_id)
      assert_select "dl.meta dd.file-dimensions", text: "80 × 40 mm · 3.15 × 1.57 in"
    end

    test "a LightBurn file's size moves from the Laser settings panel to the facts" do
      meta = Maker::Previews::LbrnMetadata.parse(fixture("nested-plate.lbrn2"))
      node = file_with("plate.lbrn2", meta)

      get file_path(node.node_id)
      assert_select "h2", text: "Laser settings"
      assert_select ".lbrn-settings dt", { text: "Job size", count: 0 }
      assert_select "dl.meta dd.file-dimensions", text: "60 × 40 mm · 2.36 × 1.57 in"
    end

    # The decimals a size actually HAS survive (recipe_num, never .to_i), and a whole number loses
    # its trailing zero — the two halves settings_panel_test.rb pinned on the old Job size line.
    test "a fractional size keeps its decimals and inches always show two" do
      node = file_with("frac.lbrn2", { "app_version" => "1.7.00", "job" => { "width" => 292.1, "height" => 144.6 } })

      get file_path(node.node_id)
      assert_select "dl.meta dd.file-dimensions", text: "292.1 × 144.6 mm · 11.50 × 5.69 in"
    end

    test "a multi-page file lists each page in both units, here and in the Pages table" do
      node = file_with("pages.lbrn2", Maker::Previews::LbrnMetadata.parse(fixture("pages.lbrn2")))

      get file_path(node.node_id)
      assert_select ".file-dimensions-page", text: /\APage 1:\s+205 × 50 mm · 8\.07 × 1\.97 in\z/
      assert_select ".file-dimensions-page", text: /\ABack \(in preview\):\s+50 × 50 mm · 1\.97 × 1\.97 in\z/
      assert_select ".file-dimensions-page", text: /\APage 3:\s+empty\z/
      assert_select ".lbrn-settings tr", text: /Page 1\s+205 × 50 mm · 8\.07 × 1\.97 in/
    end

    test "no row at all where the size is not known" do
      stl = file_with("bracket.stl", nil)
      old_svg = file_with("old.svg", nil) # a revision-1 build: a picture and no size
      repointed = file_with("moved.svg", { "job" => { "width" => 9.0, "height" => 9.0 } },
                            status: "pending", picture: false)

      [ stl, old_svg, repointed ].each do |node|
        get file_path(node.node_id)
        assert_response :success
        assert_select "dl.meta dt", { text: "Dimensions", count: 0 }, node.name
      end
    end

    test "a rebuilding row still shows its size: it is a rebuild of this same content" do
      node = file_with("plate.svg", { "job" => { "width" => 80.0, "height" => 40.0 } }, status: "rebuilding")

      get file_path(node.node_id)
      assert_select "dl.meta dd.file-dimensions", text: "80 × 40 mm · 3.15 × 1.57 in"
    end

    test "the Library inspector shows the same row" do
      node = file_with("plate.svg", { "job" => { "width" => 80.0, "height" => 40.0 } })

      get inspector_file_path(node.node_id)
      assert_response :success
      assert_select "turbo-frame#inspector dl.meta dd.file-dimensions", text: "80 × 40 mm · 3.15 × 1.57 in"
    end
  end
end
