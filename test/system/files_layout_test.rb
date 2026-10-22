require "application_system_test_case"
require "zlib"

# WHERE THE FILES PAGES' PIXELS LAND (redesign slice 7) — three things only a browser's layout can
# answer, each a nit that shipped past a green suite because every request test asserts elements,
# never geometry:
#
#   - THE LIST'S ROW DIVIDER RUNS UNDER THE ACTIONS COLUMN, to the table's right edge, on the Library
#     and on the Trash. `td.row-actions` is `display: flex` (the .row-actions component), which makes
#     it a flex box inside an anonymous table cell rather than a cell: its own border left the
#     collapsed row line, sat at the bottom of a 44px box in a taller row, and faded with the cell's
#     hover opacity. Measured in PIXELS, from a screenshot, because the question is what is PAINTED
#     — a computed `border-bottom-width` says nothing about whether a collapsed border reaches an
#     anonymous cell. The row here carries notes, so its badge makes it taller than 44px: that
#     reproduces the break with the actions visible too, which is the state a hover-less browser
#     (CI's Linux Chrome reports `hover: none`) renders from the start.
#   - THE NOTE BADGE'S ICON DRAWS AT 12px. Its rule cannot sit beside `.note-badge` in
#     components.css: shell.css's bare `.rail-icon { width: 16px }` is a later layer and a layer
#     outranks specificity.
#   - THE 3D AND MEASURE FALLBACK POSTER IS CENTRED. `.preview-image` is `display: block` (and shared
#     with the addon bundles, so it is never restyled bare), which `text-align: center` on the
#     fallback does not move; the poster sat against the container's left padding. Since
#     2026-10-21 the poster sits in a `.render-card` (components.css), whose flex centring does it;
#     the `margin-inline: auto` rule that did it before went with the change.
#
# MUTATION-CHECKED (§15; outputs in the PR): deleting `table.files tbody tr { border-bottom }` and
# its cell reset from components.css reddens both divider tests; moving the badge icon's rule into
# components.css reddens the 12px assertion at 16; deleting `justify-content: center` from
# `.render-card` reddens the poster test on the 3D page and on the Measure page (2026-10-21; it
# was the `margin-inline: auto` rule in pages/preview.css until then).
class FilesLayoutTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("files-layout@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "the Library list's row divider runs under the actions column to the table's right edge" do
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "bracket.dxf", kind: "file",
                               size: 5, mtime: 1_000_000_000, content_hash: "h-bracket")
    2.times { |i| @user.maker_notes.create!(node_id: node.node_id, body: "note #{i}") }
    visit files_path(view: "list")
    assert_selector "table.files tbody tr td.row-actions", visible: :all

    assert_divider_spans_the_row

    icon = page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector("table.files .note-badge svg.rail-icon").getBoundingClientRect();
               return [r.width, r.height] })()
    JS
    assert_equal [ 12, 12 ], icon, "the note badge's icon should draw at its count's size, not the rail's 16px"
    assert_no_console_errors
  end

  test "the Trash list's row divider runs under the actions column too" do
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "old-bracket.dxf", kind: "file",
                               size: 5, mtime: 1_000_000_000, content_hash: "h-old")
    FileLayer.current.delete(@user, node_id: node.node_id)
    visit trash_index_path
    assert_selector "table.files tbody tr td.row-actions", visible: :all

    assert_divider_spans_the_row
    assert_no_console_errors
  end

  test "the 3D and Measure fallback posters sit centred in their containers" do
    model = create_node!(@user, node_id: SecureRandom.uuid, name: "bracket.stl", kind: "file",
                                size: 5, mtime: 1_000_000_000, content_hash: "h-stl")
    ready_thumbnail!(model)
    visit file_path(model.node_id)
    assert_poster_centred(".model-viewer-fallback")

    drawing = create_node!(@user, node_id: SecureRandom.uuid, name: "plate.dxf", kind: "file",
                                  size: 5, mtime: 1_000_000_000, content_hash: "h-dxf")
    ready_thumbnail!(drawing)
    visit file_path(drawing.node_id)
    assert_poster_centred(".measure-fallback")
  end

  private

  # A READY, CURRENT THUMBNAIL whose image has real dimensions, narrower than the fallback, so an
  # uncentred poster is visibly off-centre. Both halves of "current" come from the code that owns
  # them (public_fixture.rb's `ready_preview!` argues it); that helper is not included because its
  # module defines a `sign_in_as` of its own.
  def ready_thumbnail!(node)
    preview = @user.maker_previews.create!(
      node_id: node.node_id, kind: "thumbnail", status: "ready",
      version_id: FileLayer.current.stat(@user, node_id: node.node_id).content_token,
      renderer_revision: Maker::Previews::Enqueue.revision_for_name(node.name, "thumbnail")
    )
    preview.asset.attach(io: StringIO.new(png(160, 90)), filename: "#{node.name}.png", content_type: "image/png")
  end

  # A solid grey RGB PNG, written out: signature, IHDR, one deflated IDAT of filter-0 scanlines, IEND.
  def png(width, height)
    chunk = ->(type, data) { [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N") }
    rows = ([ 0 ] + [ 150, 150, 150 ] * width).pack("C*") * height
    "\x89PNG\r\n\x1a\n".b + chunk.("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC")) +
      chunk.("IDAT", Zlib::Deflate.deflate(rows)) + chunk.("IEND", "".b)
  end

  def assert_poster_centred(container)
    img = find("#{container} img.preview-image")
    wait_until(message: "the poster never loaded") { page.evaluate_script("arguments[0].naturalWidth", img).to_i.positive? }
    box = page.evaluate_script(<<~JS, img)
      (() => {
        const img = arguments[0], c = img.parentElement, s = getComputedStyle(c);
        const r = img.getBoundingClientRect(), b = c.getBoundingClientRect();
        const left = b.left + parseFloat(s.borderLeftWidth) + parseFloat(s.paddingLeft);
        const right = b.right - parseFloat(s.borderRightWidth) - parseFloat(s.paddingRight);
        return { img: (r.left + r.right) / 2, box: (left + right) / 2, width: r.width, inner: right - left };
      })()
    JS
    assert_operator box["width"], :<, box["inner"] - 40, "the poster must be narrower than #{container} for centring to mean anything"
    assert_in_delta box["box"], box["img"], 1, "the #{container} poster is not centred (#{box.inspect})"
  end

  # THE FIRST BODY ROW'S BOTTOM EDGE, SAMPLED FROM A SCREENSHOT: in a band of pixel rows around it,
  # the colour under the actions column (its left edge, its middle and the table's last pixel) must
  # match the colour under the Type column on every row of the band — and the Type column must
  # actually draw a line there, or a page with no divider at all would pass. The pointer is parked
  # on the page heading first: a hovered row repaints its background and un-fades its actions.
  def assert_divider_spans_the_row
    find("h1").hover
    geo = page.evaluate_script(<<~JS)
      (() => {
        const t = document.querySelector("table.files"), tr = t.querySelector("tbody tr");
        const ref = tr.querySelector("td.col-type"), act = tr.querySelector("td.row-actions");
        const r = (el) => el.getBoundingClientRect();
        return { bottom: r(tr).bottom, refX: (r(ref).left + r(ref).right) / 2,
                 actLeft: r(act).left, tableRight: r(t).right };
      })()
    JS
    ys = ((geo["bottom"] - 4).floor..(geo["bottom"] + 3).ceil).to_a
    ref_x = geo["refX"]
    act_xs = [ geo["actLeft"] + 3, (geo["actLeft"] + geo["tableRight"]) / 2, geo["tableRight"] - 1 ]
    inside = geo["bottom"] - 12
    points = ys.flat_map { |y| [ [ ref_x, y ], *act_xs.map { |x| [ x, y ] } ] } + [ [ ref_x, inside ] ]
    colours = screenshot_pixels(points)
    background = colours.pop
    rows = ys.each_with_index.map { |y, i| [ y, colours[i * 4, 4] ] }

    lined = rows.select { |_, (ref, *)| differs?(ref, background) }
    refute_empty lined, "no divider under the Type column either (band #{ys.minmax}) — the probe would pass over nothing"
    rows.each do |y, (ref, *under_actions)|
      under_actions.each_with_index do |colour, i|
        refute differs?(ref, colour),
               "at y=#{y} the actions column (x=#{act_xs[i].round}) paints #{colour.inspect} where the Type column paints #{ref.inspect}"
      end
    end
  end

  def differs?(a, b) = a.zip(b).any? { |p, q| (p - q).abs > 6 }

  # PIXELS OF THE VIEWPORT AS PAINTED: CDP takes the screenshot, the page decodes it into a canvas
  # (a data: URL image never taints one) and reads each point. Coordinates are CSS pixels.
  def screenshot_pixels(points)
    data = page.driver.browser.execute_cdp("Page.captureScreenshot", format: "png")["data"]
    page.evaluate_async_script(<<~JS, data, points)
      const [data, points, done] = arguments;
      const img = new Image();
      img.onload = () => {
        const c = document.createElement("canvas");
        c.width = img.width; c.height = img.height;
        const ctx = c.getContext("2d");
        ctx.drawImage(img, 0, 0);
        const k = window.devicePixelRatio;
        done(points.map(([x, y]) => Array.from(ctx.getImageData(Math.floor(x * k), Math.floor(y * k), 1, 1).data.slice(0, 3))));
      };
      img.src = "data:image/png;base64," + data;
    JS
  end
end
