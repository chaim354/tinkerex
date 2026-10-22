require "application_system_test_case"

# INK ON PAPER (design-system.md rule 5, 2026-10-21): every thumbnail keeps a pure-white ground and
# is MULTIPLIED onto a card that is light in both themes, so the white becomes the card and the
# file's own ink stays readable. What only a browser can say, asserted as COMPUTED style because a
# request test sees markup and this is a cascade: the card's colour per theme, the `isolation` that
# keeps the blend inside the card, the blend itself on the image, the photo's opt-out, and the
# Measure stage, which is the same card in Graphite (it was transparent onto #141512, so a black
# LightBurn layer drew black on near-black).
#
# MUTATION-CHECKED (§15; outputs in the PR, then reverted): deleting `mix-blend-mode: multiply` from
# `.thumb img` reddens the tile arm; deleting `isolation: isolate` from `.render-card` reddens the
# poster arm; deleting `mix-blend-mode: normal` from `.thumb.photo img` reddens the photo arm;
# deleting the Measure stage's `background` reddens the Measure test in both themes; setting
# Graphite's `--thumb-stage` back to `#ffffff` reddens every dark arm.
class PreviewStageTest < ApplicationSystemTestCase
  CARD = { "light" => "rgb(252, 251, 248)", "dark" => "rgb(191, 187, 178)" }.freeze
  SAMPLE = "sample.lbrn2".freeze

  setup do
    @root = use_fresh_share_library!
    # The Measure fixture lands BEFORE the first page render: an EMPTY share root reads as an
    # unmounted mount point (lbrn_measure_test.rb's setup says why).
    File.binwrite(@root.join(SAMPLE), File.binread(Rails.root.join("test/fixtures/files", SAMPLE)))
    @user = sign_in_as("preview-stage@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "a render is multiplied onto a card that is light in both themes, and a photo is not" do
    render = create_node!(@user, node_id: SecureRandom.uuid, name: "bracket.stl", kind: "file",
                                 size: 5, mtime: 1_000_000_000, content_hash: "h-stl")
    ready_thumbnail!(render)
    photo = create_node!(@user, node_id: SecureRandom.uuid, name: "bench.jpg", kind: "file",
                                size: 5, mtime: 1_000_000_000, content_hash: "h-jpg")
    ready_thumbnail!(photo)

    %w[light dark].each do |theme|
      with_theme(theme) do
        visit files_path(view: "grid")
        tile = tile_style("bracket.stl")
        assert_equal({ "stage" => CARD[theme], "isolation" => "isolate", "blend" => "multiply" }, tile,
                     "a render's tile in #{theme}")
        pic = tile_style("bench.jpg")
        assert_equal "normal", pic["blend"], "a photo is not ink on paper, so it is never multiplied (#{theme})"

        visit file_path(render.node_id)
        poster = page.evaluate_script(<<~JS)
          (() => {
            const img = document.querySelector(".model-viewer-fallback .render-card img.preview-image")
            if (!img) return null
            const card = getComputedStyle(img.closest(".render-card"))
            return { stage: card.backgroundColor, isolation: card.isolation, blend: getComputedStyle(img).mixBlendMode }
          })()
        JS
        assert_equal({ "stage" => CARD[theme], "isolation" => "isolate", "blend" => "multiply" }, poster,
                     "the file page's poster in #{theme}")
      end
    end
    assert_no_console_errors
  end

  test "the Measure stage is the card in both themes, because it draws the file's own colours" do
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    node_id = @user.nodes.find_by!(storage_path: SAMPLE).node_id
    token = FileLayer.current.stat(@user, node_id:).content_token
    preview = Maker::Previews::Enqueue.call(user: @user, node_id:, name: SAMPLE, version_id: token, kind: "geometry")
    Maker::GeneratePreviewJob.perform_now(preview.id, filename: SAMPLE)
    assert_equal "ready", preview.reload.status, "the geometry payload must be ready to measure"

    %w[light dark].each do |theme|
      with_theme(theme) do
        visit file_path(node_id)
        click_on "Measure"
        assert_selector ".measure-view--ready"
        assert_equal CARD[theme],
                     page.evaluate_script("getComputedStyle(document.querySelector('.measure-stage')).backgroundColor"),
                     "the Measure stage in #{theme}"
      end
    end
    assert_no_console_errors
  end

  private

  # THE THEME IS A COOKIE THE LAYOUT RENDERS (design-system.md rule 7), so it is set and the page is
  # then visited; the ensure puts Paper back for whatever test this worker runs next.
  def with_theme(theme)
    page.execute_script("document.cookie = 'theme=#{theme}; path=/; max-age=31536000; samesite=lax'")
    yield
  ensure
    page.execute_script("document.cookie = 'theme=light; path=/; max-age=31536000; samesite=lax'")
  end

  # The tile of the grid card naming `name`, read as the three properties the rule is made of. nil
  # when no such tile or image exists, which fails the equality rather than passing vacuously.
  def tile_style(name)
    page.evaluate_script(<<~JS)
      (() => {
        const card = [...document.querySelectorAll(".grid-card")].find((c) => c.textContent.includes(#{name.to_json}))
        const img = card?.querySelector(".thumb img")
        if (!img) return null
        const tile = getComputedStyle(img.closest(".thumb"))
        return { stage: tile.backgroundColor, isolation: tile.isolation, blend: getComputedStyle(img).mixBlendMode }
      })()
    JS
  end

  # A READY, CURRENT THUMBNAIL (files_layout_test.rb's helper, for its reason: both halves of
  # "current" come from the code that owns them, and public_fixture.rb's copy is not included
  # because its module defines a `sign_in_as` of its own).
  def ready_thumbnail!(node)
    preview = @user.maker_previews.create!(
      node_id: node.node_id, kind: "thumbnail", status: "ready",
      version_id: FileLayer.current.stat(@user, node_id: node.node_id).content_token,
      renderer_revision: Maker::Previews::Enqueue.revision_for_name(node.name, "thumbnail")
    )
    preview.asset.attach(io: StringIO.new(png(160, 90)), filename: "#{node.name}.png", content_type: "image/png")
  end

  # A solid white RGB PNG — a render's ground — written out: signature, IHDR, one deflated IDAT of
  # filter-0 scanlines, IEND.
  def png(width, height)
    chunk = ->(type, data) { [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N") }
    rows = ([ 0 ] + [ 255, 255, 255 ] * width).pack("C*") * height
    "\x89PNG\r\n\x1a\n".b + chunk.("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC")) +
      chunk.("IDAT", Zlib::Deflate.deflate(rows)) + chunk.("IEND", "".b)
  end
end
