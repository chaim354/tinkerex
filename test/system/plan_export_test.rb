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
    @user = sign_in_as "planexport@example.com"
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

  # ---- pdf.js ---------------------------------------------------------------------------------

  def pdf_bytes(prims_js, pages_js = nil)
    in_module("pdf.js", <<~JS)
      (() => {
        const pages = #{pages_js || "[{ paper: { name: 'A4', w: 210, h: 297 }, prims: #{prims_js} }]"}
        const bytes = m.buildPdf(pages)
        return JSON.stringify({
          text: new TextDecoder("latin1").decode(bytes),
          ascii: [...bytes].every((b) => b < 128),
        })
      })()
    JS
  end

  test "the PDF declares its page size in points" do
    doc = JSON.parse(pdf_bytes("[]"))["text"]

    assert doc.start_with?("%PDF-1.4"), "not a PDF: #{doc[0, 40].inspect}"
    assert_includes doc, "/MediaBox [0 0 595.28 841.89]"
    assert_includes doc, "/BaseFont /Helvetica"
    assert_includes doc, "/Encoding /WinAnsiEncoding"
    assert_includes doc, "%%EOF"
  end

  # THE Y-FLIP. PDF's origin is bottom-left; SVG's is top-left. A flipped plan is INVISIBLE on a
  # symmetric tray, so this uses a deliberately asymmetric one: a line 10 mm from the TOP must land
  # 287 mm up the page (813.54 pt), not 10 mm up (28.35 pt).
  test "PDF coordinates are flipped from SVG's top-left origin" do
    doc = JSON.parse(pdf_bytes(
      "[{ kind: 'line', x1: 0, y1: 10, x2: 50, y2: 10, role: 'outline' }]"))["text"]

    assert_includes doc, "813.54 l"
    assert_not_includes doc, "28.35 l"
  end

  # × is the only non-ASCII character the drawing itself emits, and the calibration caption adds an
  # em dash. \327 and \227 are those two under WinAnsiEncoding; being octal escapes they keep the
  # file byte-for-byte ASCII.
  test "non-ASCII characters become octal escapes and the file stays ASCII" do
    result = JSON.parse(pdf_bytes(<<~PRIMS.strip))
      [{ kind: 'text', x: 50, y: 50, size: 3, text: '120×80', role: 'label' },
       { kind: 'text', x: 50, y: 80, size: 3, text: '100 mm — check', role: 'calib-label' }]
    PRIMS

    assert_includes result["text"], "(120\\32780) Tj"
    assert_includes result["text"], "(100 mm \\227 check) Tj"
    assert result["ascii"], "the PDF must stay byte-for-byte ASCII"
  end

  # Every /Page's /Parent must name the Pages object, whose id is only known after the pages are
  # written. Predicting byte offsets and ids is how this kind of writer goes silently wrong, so the
  # writer asserts its own prediction — this proves the prediction is right for >1 page too.
  test "a multi-page PDF wires every page to the pages object" do
    doc = JSON.parse(pdf_bytes(nil, <<~PAGES.strip))
      [{ paper: { name: 'A4', w: 210, h: 297 }, prims: [] },
       { paper: { name: 'A4', w: 210, h: 297 }, prims: [] }]
    PAGES

    parent = doc["text"][/\/Parent (\d+) 0 R/, 1]
    assert_includes doc["text"], "#{parent} 0 obj\n<< /Type /Pages /Count 2"
    assert_equal 2, doc["text"].scan(/\/Type \/Page[^s]/).size
  end

  # ---- export.js: the SVG renderer ------------------------------------------------------------

  # THE WIRE FORMAT, and the whole feature. A viewBox alone is what the on-screen panel already
  # had, and a viewBox alone is exactly what is NOT to scale — the physical width/height attributes
  # are what give the drawing a size rather than merely a shape.
  test "a page SVG carries its physical size in millimetres" do
    head = in_module("export.js", <<~JS)
      (() => {
        const svg = m.pageSvg({ paper: { name: "A4", w: 210, h: 297 }, prims: [] })
        return svg.slice(0, svg.indexOf(">") + 1)
      })()
    JS

    assert_includes head, 'width="210mm"'
    assert_includes head, 'height="297mm"'
    assert_includes head, 'viewBox="0 0 210 297"'
  end

  # What goes to the library: the whole plan at full size, untiled. Tiling is a property of the
  # printer, not of the drawing.
  test "the library SVG is the whole untiled plan at full size" do
    head = in_module("export.js", <<~JS)
      (() => {
        const model = m.buildModelFor({
          cols: [50, 50, 50, 50, 50], rows: [50, 50],
          hwalls: [[1,1,1,1,1],[1,1,1,1,1],[1,1,1,1,1]].map((r) => r.map(Boolean)),
          vwalls: [[1,1,1,1,1,1],[1,1,1,1,1,1]].map((r) => r.map(Boolean)),
        }, 3)
        const svg = m.planSvgFor(model)
        return svg.slice(0, svg.indexOf(">") + 1)
      })()
    JS

    # 5 x 50 mm cells + 4 inner walls + 2 outer = 268 mm; 2 x 50 + 1 + 2 = 109 mm.
    assert_includes head, 'width="268mm"'
    assert_includes head, 'height="109mm"'
  end

  test "a plan too big for the paper still exports as one untiled library SVG" do
    pages = in_module("export.js", <<~JS)
      (() => {
        const model = m.buildModelFor({
          cols: [50, 50, 50, 50, 50], rows: [50, 50],
          hwalls: [[1,1,1,1,1],[1,1,1,1,1],[1,1,1,1,1]].map((r) => r.map(Boolean)),
          vwalls: [[1,1,1,1,1,1],[1,1,1,1,1,1]].map((r) => r.map(Boolean)),
        }, 3)
        return String(m.pagesFor(model, "A4").pages.length)
      })()
    JS

    assert_equal "2", pages
  end

  # ---- the editor surface ---------------------------------------------------------------------

  def open_generator(key)
    visit tools_addon_path("boxes")
    find(".addon-card", text: key).click
    assert_selector ".box-topview svg", wait: 5
  end

  # Resolved through the PORT, not through a Node lookup: the suite runs on all three
  # LIBRARY_BACKEND legs and `stat` is the one question all three answer.
  def saved_files
    Maker::AddonState.order(:id).last.files.map { |f| FileLayer.current.stat(@user, node_id: f.node_id) }
  end

  def saved_names = saved_files.map(&:name).sort

  def saved_node_id_for(suffix)
    saved_files.find { |f| f.name.end_with?(suffix) }.node_id
  end

  test "the top view offers print and export controls" do
    open_generator("TrayLayout")

    assert_selector '[data-export="print"]'
    assert_selector '[data-export="pdf"]'
    assert_selector '[data-export="svg"]'
    assert_selector '[data-export="paper"]'
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # The print surface is a hidden iframe: not window.open (popup blockers) and not a print-only div
  # in the host page (which would mean hiding chrome the bundle does not own). Asserting on that
  # iframe's real document is asserting on exactly what the printer is handed.
  test "printing builds a sheet whose SVG is sized in millimetres" do
    open_generator("TrayLayout")

    find('[data-export="print"]').click
    head = page.evaluate_script(<<~JS)
      (() => {
        const f = document.querySelector("iframe.plan-print-frame")
        if (!f) return "NO FRAME"
        const s = f.contentDocument.querySelector("svg")
        return s ? s.outerHTML.slice(0, s.outerHTML.indexOf(">") + 1) : "NO SVG"
      })()
    JS

    assert_includes head, 'width="210mm"'
    assert_includes head, 'height="297mm"'
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # The default TrayLayout (sx 50*3, sy 50*2, t 3) is 162 x 109 mm, so it fits one A4 sheet and the
  # tiler produces a single page through the same path a tiled plan takes.
  test "a tray that fits prints as one sheet" do
    open_generator("TrayLayout")

    find('[data-export="print"]').click
    count = page.evaluate_script(<<~JS)
      document.querySelector("iframe.plan-print-frame").contentDocument.querySelectorAll("svg").length
    JS

    assert_equal 1, count
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # A generator with no compartments has no panel, so it has no controls — the same self-gating
  # that keeps FrontPanel's very different `layout` DSL out.
  test "a generator with no compartments offers no export controls" do
    visit tools_addon_path("boxes")
    find(".addon-card", text: "ABox").click
    assert_selector ".box-preview"

    assert page.has_no_selector?('[data-export="print"]')
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # MAX_FILES is 8 and parse_files already refuses duplicate names within a batch, so a second
  # output needs no host change. §14c's "each save writes ONE file" recorded deleting the
  # write-only .params.json, which duplicated AddonState#data; a second genuine output is not that.
  test "saving a tray writes the plan beside the cut sheet" do
    open_generator("TrayLayout")

    find('[data-role="name"]').set("Drawer insert")
    find('[data-role="save"]').click
    assert_selector '[data-role="save-status"]', text: "Saved."

    assert_equal [ "drawer-insert-plan.svg", "drawer-insert.svg" ], saved_names
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # The saved plan is the ARCHIVAL artifact: full size and untiled, not the A4 page the printer got.
  test "the saved plan is the untiled drawing, not a paper sheet" do
    open_generator("TrayLayout")

    find('[data-role="name"]').set("Insert")
    find('[data-role="save"]').click
    assert_selector '[data-role="save-status"]', text: "Saved."

    svg = FileLayer.current.read(@user, node_id: saved_node_id_for("-plan.svg"))
    assert_includes svg, 'width="162mm"'
    assert_includes svg, 'height="109mm"'
    assert_not_includes svg, 'width="210mm"'
  end
end
