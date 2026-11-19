require "test_helper"

module Web
  # The file page's recipe panel, driven end to end.
  #
  # `show.html.erb` picks between TWO partials off one metadata Hash — MillMage's "operations"
  # get the CNC panel, LightBurn's "layers" get the laser one. No unit test can see that choice:
  # both renderers return a Hash and both partials render fine in isolation, so getting the
  # branch backwards shows a CNC job a "Laser settings" table with empty Speed/Power/Passes
  # columns and no tooling at all — wrong, and silent. Only driving the page catches it.
  class SettingsPanelTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      # A real share library so FileLayer.current can answer `stat` for these fixtures.
      @root = use_fresh_share_library!
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def sign_in(email = "panel@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(user, password: PASSWORD)
    end

    # A node + a ready thumbnail carrying `metadata`. The panel reads ONLY the metadata, so the
    # rendered asset is irrelevant here and is deliberately left unattached — that also proves the
    # panel does not quietly depend on having an image.
    def node_with_metadata(user, name, metadata)
      # In chunk mode the content_token IS the current version id, so a node needs one or the
      # page has nothing to key a thumbnail to.
      # content_hash IS THE CONTENT TOKEN ON SHARE, and it has to be set explicitly rather than
      # left to the fixture's defaults: the panel finds its thumbnail by the node's CURRENT token,
      # so a nil one keys the preview row to nil and the page silently renders no panel at all --
      # which reads as "the panel is broken" rather than "the fixture is incomplete". On embedded
      # chunk the current version id played this role, which is what the note above was about.
      node = create_node!(user, node_id: SecureRandom.uuid, name:, kind: "file", storage_path: name,
                                content_hash: SecureRandom.hex(8),
                                current_version_id: SecureRandom.uuid)
      # The page finds its thumbnail by the node's CURRENT content_token, not by node_id alone
      # (that is what keeps a stale render off the page), so the row has to be keyed to whatever
      # the port reports right now rather than to a literal.
      token = FileLayer.current.stat(user, node_id: node.node_id).content_token
      user.maker_previews.create!(node_id: node.node_id, version_id: token, kind: "thumbnail",
                                  status: "ready", metadata:)
      node
    end

    test "a MillMage file gets the CNC panel, with its tooling" do
      user = sign_in
      meta = Maker::Previews::MageMetadata.parse(
        File.binread(Rails.root.join("test/fixtures/files/real-export.mage"))
      )
      node = node_with_metadata(user, "pocket.mage", meta)

      get file_path(node.node_id)
      assert_response :success
      assert_select "h2", text: "CNC settings"
      assert_select "th", text: /\ASpindle\s+rpm\z/
      # The tool is a second line under its operation (2026-10-25), with its diameter, rather than
      # a column of its own that the side column's width truncated.
      assert_select "td.lbrn-op .lbrn-tool", text: "1.5 mm endmil · 1.5 mm"
      assert_select "td", text: "20000"
      # "100 × 60", not "100.0 × 60.0": a whole number's trailing zero is noise. The decimals a
      # value actually HAS are preserved — pinned by the test below, which is the half that broke.
      assert_select "dd", text: "100 × 60 mm"
      assert_select "h2", { text: "Laser settings", count: 0 }, "the laser panel must not render"
    end

    test "a LightBurn file still gets the laser panel" do
      user = sign_in("panel2@example.com")
      meta = Maker::Previews::LbrnMetadata.parse(
        File.binread(Rails.root.join("test/fixtures/files/laser-settings.lbrn2"))
      )
      node = node_with_metadata(user, "cut.lbrn2", meta)

      get file_path(node.node_id)
      assert_response :success
      assert_select "h2", text: "Laser settings"
      assert_select "th", text: "Power"
      assert_select "h2", { text: "CNC settings", count: 0 }, "the CNC panel must not render"
    end

    # THE FRACTIONAL SETTING, driven through the page because that is the only place the bug
    # lived — LbrnMetadata parsed 6.67 correctly all along and the view called `.to_i` on it.
    #
    # The metadata is written by hand rather than parsed from a fixture on purpose: every
    # checked-in .lbrn2 uses whole speeds and powers, which is exactly why nothing caught this.
    # 6.67 mm/s is a real value off `reference card.lbrn2` in the deployed share library, where a
    # cut layer displayed as "6 mm/s" — truncated, not rounded, and wrong by 10 %.
    test "a fractional speed or power keeps its decimals" do
      user = sign_in("panel3@example.com")
      meta = { "app_version" => "1.7.00",
               "job" => { "width" => 292.1, "height" => 144.6 },
               "layers" => [ { "index" => "0", "name" => "C00", "mode" => "Cut",
                               "speed" => 6.67, "power_max" => 42.5, "power_min" => 12.25,
                               "passes" => 1 } ] }
      node = node_with_metadata(user, "fractional.lbrn2", meta)

      get file_path(node.node_id)
      assert_response :success
      # The unit is in the column heading (2026-10-25); the cell is the number alone.
      assert_select "th", text: /\ASpeed\s+mm\/s\z/
      assert_select "td", text: "6.67"
      assert_select "td", text: /42\.5%/
      assert_select "td", text: /12\.25%/
      assert_select "dd", text: "292.1 × 144.6 mm"
    end

    # THE PANEL HEADS THE SIDE COLUMN (2026-10-25, at the user's request): it used to share the main
    # column with the preview, half each. The preview row must hold the viewer alone, and the panel
    # must sit ABOVE the file's facts — first in the column, which is what `:first-child` pins.
    test "the recipe panel heads the side column, above the facts, and the preview keeps the main column" do
      user = sign_in("placement@example.com")
      node = node_with_metadata(user, "cut.lbrn2", { "layers" => [ { "index" => "0", "name" => "C00" } ] })

      get file_path(node.node_id)
      assert_response :success
      assert_select ".workspace.has-recipe"
      assert_select ".workspace-main .lbrn-settings", count: 0
      assert_select ".workspace-side > .lbrn-settings:first-child + dl.meta"
    end

    test "a page with no recipe keeps the ordinary side column" do
      user = sign_in("no-recipe@example.com")
      node = node_with_metadata(user, "plain.lbrn2", nil)

      get file_path(node.node_id)
      assert_response :success
      assert_select ".workspace"
      assert_select ".workspace.has-recipe", count: 0
      assert_select ".workspace-side > dl.meta:first-child"
    end

    # THE TEXT STARTS CLOSED (2026-10-25, at the user's request): a sheet of labels has dozens of text
    # shapes, and their strings as one long line pushed the settings out of view. Closed means no
    # `open` attribute on the <details>; the count is in the summary and each string is its own item.
    test "a LightBurn file's text strings are a closed list under a count" do
      user = sign_in("text@example.com")
      meta = { "layers" => [ { "index" => "0", "name" => "C00" } ], "text" => [ "x 1/1", "x 2/1", "Lid" ] }
      node = node_with_metadata(user, "labels.lbrn2", meta)

      get file_path(node.node_id)
      assert_response :success
      assert_select ".lbrn-settings details.lbrn-text:not([open])" do
        assert_select "summary", text: /\AText\s+3 strings\z/
        assert_select "li", 3
        assert_select "li", text: "Lid"
      end
    end

    # A multi-page file (LightBurn 2.2) has a size per page and no single job size: its pages share
    # one coordinate space, so a size over all of them measures nothing anyone will cut.
    test "a multi-page LightBurn file lists each page with its own size instead of one job size" do
      user = sign_in("pages@example.com")
      meta = Maker::Previews::LbrnMetadata.parse(File.binread(Rails.root.join("test/fixtures/files/pages.lbrn2")))
      node = node_with_metadata(user, "pages.lbrn2", meta)

      get file_path(node.node_id)
      assert_response :success
      assert_select ".lbrn-settings th", text: "Page"
      assert_select ".lbrn-settings tr", text: /Page 1\s+205 × 50 mm/
      assert_select ".lbrn-settings tr", text: /Back \(in preview\)\s+50 × 50 mm/
      assert_select ".lbrn-settings tr", text: /Page 3\s+empty/
      assert_select ".lbrn-settings dt", { text: "Job size", count: 0 }
    end

    test "a multi-page MillMage file lists its pages the same way" do
      user = sign_in("mage-pages@example.com")
      meta = Maker::Previews::MageMetadata.parse(File.binread(Rails.root.join("test/fixtures/files/pages.mage")))
      node = node_with_metadata(user, "pages.mage", meta)

      get file_path(node.node_id)
      assert_response :success
      assert_select "h2", text: "CNC settings"
      assert_select ".lbrn-settings tr", text: /Top \(in preview\)\s+100 × 60 mm/
      assert_select ".lbrn-settings tr", text: /Bottom\s+20 × 20 mm/
      assert_select ".lbrn-settings dt", { text: "Job size", count: 0 }
    end
  end
end
