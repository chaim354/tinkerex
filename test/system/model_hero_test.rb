require "application_system_test_case"

# THE MODEL PAGE'S HERO IS ONE INK-ON-PAPER CARD, IN BOTH THEMES (UX audit 2026-11-01, E7;
# design-system.md rule 5). The cell around the render used to wear `.thumb` itself and
# pages/models.css painted it `--raised`, which outranks the component's `--thumb-stage`: in
# Graphite the render sat on a small light patch inside a dark box the hero's width. Now the cell
# only sizes, and the `.thumb` inside it is the card at the hero's full width, with the component's
# ground, isolation and multiply. A request test sees markup and this is a cascade, so it is read as
# COMPUTED style, as preview_stage_test.rb reads the tiles.
#
# MUTATION-CHECKED (§15): putting `background: var(--raised)` back on `.model-hero-thumb` reddens the
# cell arm (`rgb(235, 232, 225)` where transparent was expected); putting back the old shrink-wrapped
# layout (a flex cell centring a `.thumb` sized by its image) reddens the `full` arm. Dropping only
# the card's `width: 100%` does not: a flex `.thumb` in a block cell fills it anyway. Outputs in
# this task's report.
class ModelHeroTest < ApplicationSystemTestCase
  CARD = { "light" => "rgb(252, 251, 248)", "dark" => "rgb(191, 187, 178)" }.freeze

  setup do
    @root = use_fresh_share_library!
    @root.join("bracket.stl").write("solid bracket\nendsolid bracket\n")
    @user = sign_in_as("model-hero@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @node = @user.nodes.find_by!(storage_path: "bracket.stl")
    @model = @user.maker_models.create!(title: "Bracket")
    @model.file_attachments.create!(user: @user, node_id: @node.node_id, role: "model")
    ready_thumbnail!(@node)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "the hero's render is the card, the hero's width, in both themes" do
    %w[light dark].each do |theme|
      with_theme(theme) do
        visit model_path(@model, file: "details")
        assert_selector ".model-hero-thumb .thumb img"
        hero = page.evaluate_script(<<~JS)
          (() => {
            const cell = document.querySelector(".model-hero-thumb")
            const card = cell.querySelector(".thumb")
            const img = card.querySelector("img")
            return {
              cell: getComputedStyle(cell).backgroundColor,
              stage: getComputedStyle(card).backgroundColor,
              isolation: getComputedStyle(card).isolation,
              blend: getComputedStyle(img).mixBlendMode,
              full: Math.abs(card.getBoundingClientRect().width - cell.getBoundingClientRect().width) < 1
            }
          })()
        JS
        assert_equal({ "cell" => "rgba(0, 0, 0, 0)", "stage" => CARD[theme], "isolation" => "isolate",
                       "blend" => "multiply", "full" => true }, hero, "the model hero in #{theme}")
      end
    end
    assert_no_console_errors
  end

  private

  # preview_stage_test.rb's helpers, for its reasons: the theme is a cookie the layout renders, and
  # a READY, CURRENT thumbnail takes both halves of "current" from the code that owns them.
  def with_theme(theme)
    page.execute_script("document.cookie = 'theme=#{theme}; path=/; max-age=31536000; samesite=lax'")
    yield
  ensure
    page.execute_script("document.cookie = 'theme=light; path=/; max-age=31536000; samesite=lax'")
  end

  # The scan has already queued this file's row (one row per node and kind), so it is made ready in
  # place rather than created beside it.
  def ready_thumbnail!(node)
    preview = @user.maker_previews.find_or_initialize_by(node_id: node.node_id, kind: "thumbnail")
    preview.update!(
      status: "ready",
      version_id: FileLayer.current.stat(@user, node_id: node.node_id).content_token,
      renderer_revision: Maker::Previews::Enqueue.revision_for_name(node.name, "thumbnail")
    )
    preview.asset.attach(io: StringIO.new(png(160, 90)), filename: "#{node.name}.png", content_type: "image/png")
  end

  # A solid white RGB PNG — a render's ground.
  def png(width, height)
    chunk = ->(type, data) { [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N") }
    rows = ([ 0 ] + [ 255, 255, 255 ] * width).pack("C*") * height
    "\x89PNG\r\n\x1a\n".b + chunk.("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC")) +
      chunk.("IDAT", Zlib::Deflate.deflate(rows)) + chunk.("IEND", "".b)
  end
end
