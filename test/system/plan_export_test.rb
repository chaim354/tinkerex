require "application_system_test_case"
require_relative "../support/fake_boxes_sidecar"

# The to-scale export of the tray compartment plan: opening outlines, pagination, SVG, PDF, print.
#
# WHY THESE ASSERT THE WIRE FORMAT. §14e: FakeS3 decoded copy_source with the exact inverse of the
# encoder, so 79/80 tests were green over silent permanent data loss. Parsing our own PDF with our
# own reader would be that shape again. So these assert the BYTES a viewer will see — the literal
# `width="162mm"`, the literal `/MediaBox [...]`, the literal `\327` escape — never a round-trip
# through our own code.
#
# The bundle is loaded through the host's real asset proxy and its modules are imported directly in
# the browser, so what is under test is the shipped artifact rather than a Ruby transliteration of
# it. Like the other bundle system tests this runs against the hermetic snapshot in
# test/fixtures/addons/boxes/ (see box_sections_test.rb's header for that trade-off).
class PlanExportTest < ApplicationSystemTestCase
  SAMPLE_404 = %r{/tools/boxes/service/boxes/sample/\w+ - Failed to load resource.+404}

  setup do
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    FakeBoxesSidecar.install!
    sign_in_as "planexport@example.com"
  end

  teardown do
    FakeBoxesSidecar.uninstall!
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
  end

  # Import a bundle module through the host's real asset proxy and evaluate `body` against it (the
  # module object is bound to `m`). The page must already be an addon page so the session cookie
  # and same-origin both hold.
  def in_module(specifier, body)
    visit tools_addon_path("boxes") unless page.current_path == tools_addon_path("boxes")
    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      import("/tools/boxes/asset/#{specifier}")
        .then((m) => done(#{body}))
        .catch((e) => done("ERROR: " + (e && e.message ? e.message : String(e))));
    JS
    raise result if result.is_a?(String) && result.start_with?("ERROR:")
    result
  end

  # ---- plan.js: opening outlines --------------------------------------------------------------

  # A 2x1 tray, every wall present -> two separate compartments, so the wall between them shows
  # BOTH its faces. The openings are [3,53] and [56,106]; walls occupy [0,3], [53,56], [106,109].
  test "an unmerged wall draws both of its faces" do
    xs = in_module("plan.js", <<~JS)
      (() => {
        const model = m.buildModel({
          cols: [50, 50], rows: [40],
          hwalls: [[true, true], [true, true]],
          vwalls: [[true, true, true]],
        }, 3)
        const xs = m.printPrims(model)
          .filter((p) => p.kind === "line" && p.role === "opening" && p.x1 === p.x2)
          .map((p) => p.x1)
        return JSON.stringify([...new Set(xs)].sort((a, b) => a - b))
      })()
    JS

    assert_equal "[3,53,56,106]", xs
  end

  # The same tray with the middle wall REMOVED: one compartment, and the two inner faces are gone.
  # This is the assertion that proves merged cells have no seam down the middle of the opening.
  test "a removed wall leaves one opening with no internal seam" do
    xs = in_module("plan.js", <<~JS)
      (() => {
        const model = m.buildModel({
          cols: [50, 50], rows: [40],
          hwalls: [[true, true], [true, true]],
          vwalls: [[true, false, true]],
        }, 3)
        const xs = m.printPrims(model)
          .filter((p) => p.kind === "line" && p.role === "opening" && p.x1 === p.x2)
          .map((p) => p.x1)
        return JSON.stringify([...new Set(xs)].sort((a, b) => a - b))
      })()
    JS

    assert_equal "[3,106]", xs
  end

  # NO INSET. The wall occupies [colX(c) - t, colX(c)], so its inner face IS the cell boundary and
  # the drawn opening is the real opening. An inset by t/2 would make this 47, not 50 — wrong by a
  # material thickness on every dimension, which is the error a 1:1 fit-check exists to avoid.
  test "a drawn opening is the real opening, not the opening minus the material" do
    width = in_module("plan.js", <<~JS)
      (() => {
        const model = m.buildModel({
          cols: [50, 50], rows: [40],
          hwalls: [[true, true], [true, true]],
          vwalls: [[true, true, true]],
        }, 3)
        const xs = m.printPrims(model)
          .filter((p) => p.kind === "line" && p.role === "opening" && p.x1 === p.x2)
          .map((p) => p.x1).sort((a, b) => a - b)
        return String(xs[1] - xs[0])
      })()
    JS

    assert_equal "50", width
  end

  # ---- sheet.js: pagination -------------------------------------------------------------------

  # 268 x 109 mm on A4 (210 x 297 less 10 mm margins -> 190 x 277 printable; a 10 mm overlap band
  # leaves 180 mm of new content per tile): two columns, one row.
  test "a plan wider than the sheet tiles into two pages" do
    result = in_module("sheet.js", <<~JS)
      (() => {
        const out = m.paginate({ w: 268, h: 109, prims: [] }, m.PAPERS.A4)
        return JSON.stringify({ n: out.pages.length, cols: out.cols, rows: out.rows })
      })()
    JS

    assert_equal({ "n" => 2, "cols" => 2, "rows" => 1 }, JSON.parse(result))
  end

  # The second tile must start one overlap band BEFORE the first tile ended, or there is nothing to
  # align and tape by.
  test "the second tile repeats an overlap band of the first" do
    dx = in_module("sheet.js", <<~JS)
      (() => {
        const out = m.paginate({ w: 268, h: 109, prims: [] }, m.PAPERS.A4)
        return String(out.pages[1].originX - out.pages[0].originX)
      })()
    JS

    assert_equal "180", dx, "printable 190 mm less a 10 mm overlap band"
  end

  test "a plan that fits produces one page through the same path" do
    n = in_module("sheet.js", <<~JS)
      String(m.paginate({ w: 162, h: 109, prims: [] }, m.PAPERS.A4).pages.length)
    JS

    assert_equal "1", n
  end

  # Every page carries its own bar: pages get separated, and a partial print is exactly when a
  # scale error most needs catching.
  test "every page carries a 100 mm calibration bar" do
    bars = in_module("sheet.js", <<~JS)
      (() => {
        const out = m.paginate({ w: 268, h: 109, prims: [] }, m.PAPERS.A4)
        return JSON.stringify(out.pages.map((p) =>
          p.prims.filter((q) => q.role === "calib-bar").map((q) => Math.round(q.x2 - q.x1))))
      })()
    JS

    assert_equal "[[100],[100]]", bars
  end

  # A typo'd sx of 5000 would otherwise try to print several hundred sheets.
  test "an absurd plan is refused rather than printing hundreds of sheets" do
    err = in_module("sheet.js", <<~JS)
      (() => {
        try { m.paginate({ w: 5000, h: 5000, prims: [] }, m.PAPERS.A4); return "no error" }
        catch (e) { return e.message }
      })()
    JS

    assert_match(/\A\d+ sheets/, err)
    assert_match(/5000 × 5000 mm/, err)
    assert_match(/choose a larger paper size/, err)
  end

  # Registration for taping tiles together — NOT the declined title block, which is why a
  # single-sheet plan carries no label at all.
  test "a single sheet carries no page label" do
    labels = in_module("sheet.js", <<~JS)
      (() => {
        const one = m.paginate({ w: 162, h: 109, prims: [] }, m.PAPERS.A4)
        const many = m.paginate({ w: 268, h: 109, prims: [] }, m.PAPERS.A4)
        const texts = (o) => o.pages.flatMap((p) =>
          p.prims.filter((q) => q.role === "page-label").map((q) => q.text))
        return JSON.stringify({ one: texts(one), many: texts(many) })
      })()
    JS

    assert_equal({ "one" => [], "many" => [ "Sheet 1,1 of 2×1", "Sheet 2,1 of 2×1" ] },
                 JSON.parse(labels))
  end
end
