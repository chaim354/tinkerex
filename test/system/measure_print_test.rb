require "application_system_test_case"

# Selecting parts in the Measure view and printing them at 1:1 for paper fit testing.
#
# TWO TIERS IN ONE FILE, deliberately. The layout maths in lib/print_sheet.js is pure and is
# exercised directly through `in_print_sheet` with synthetic shapes, because a tiling assertion
# wants inputs chosen to land exactly on a tile boundary and no fixture does that. The
# end-to-end tests below drive real clicks against a real payload, because the maths being right
# about synthetic input proves nothing about whether the payload ever reaches it.
#
# WHY PURE ARITHMETIC EARNS A PLACE IN THIS TIER AT ALL. test/system/README.md's rule is that a
# behaviour qualifies only if it is observable ONLY in a browser, which layout maths does not meet
# as written. It meets it here because this repo has NO JS test runner: a browser is the only
# executor there is for lib/print_sheet.js, and plan_export_test.rb set that precedent for exactly
# the same kind of module.
#
# ASSERT THE WIRE FORMAT, NEVER A ROUND-TRIP THROUGH OUR OWN READER. CLAUDE.md §14e: FakeS3
# decoded copy_source with the exact inverse of the encoder, so 79/80 tests were green over
# silent permanent data loss. Parsing our own SVG with our own parser would be that shape again.
# These assert the literal `width="215.9mm"` and the literal point coordinates a printer will see.
#
# SHARE BACKEND, ASSIGNED DIRECTLY, exactly as lbrn_measure_test.rb does it and for the same
# reason: the geometry job has to read REAL BYTES back out of the port. The FileLayer.reset! in
# teardown is load-bearing — a direct assignment does not set @file_layer_backend_pinned, so
# test_helper's teardown will not clean up after it and a Share adapter pointing at a deleted
# tmpdir would leak into the next test in this forked worker.
class MeasurePrintTest < ApplicationSystemTestCase
  # x -30..30, y -20..20 plate with a ⌀10 hole on the same centre.
  NESTED = "nested-plate.lbrn2".freeze
  # A ⌀20 circle at x -10..10 and a 20 x 20 square at x 40..60. DISJOINT, and the gap between
  # their nearest edges is exactly 30 mm while their min-x values are 50 mm apart — which is what
  # makes it the fixture for the separation assertion.
  APART = "bezier-circle.lbrn2".freeze

  setup do
    @root = Pathname.new(Dir.mktmpdir("measure-print"))
    # The fixtures land BEFORE the first page render: FileLayer::Share reads an EMPTY root as an
    # unmounted mount point, and sign_in_as ends on /files, which renders through the port.
    [ NESTED, APART ].each do |f|
      File.binwrite(@root.join(f), File.binread(Rails.root.join("test/fixtures/files", f)))
    end
    FileLayer.current = FileLayer::Share.new(root: @root.to_s)

    @user = sign_in_as("measure-print@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @nested_id = @user.nodes.find_by!(storage_path: NESTED).node_id
    @apart_id  = @user.nodes.find_by!(storage_path: APART).node_id
    render_geometry!(@nested_id, NESTED)
    # @apart_id AND ITS PAYLOAD ARE HELD FOR THE TASKS 9-12 TIER — the end-to-end tests that drive
    # real clicks against a real payload. Nothing in the module tier reads it, so it looks unused
    # until that tier lands; it is rendered here rather than in a second setup because one class
    # gets one setup. If that tier is ever dropped, drop these lines with it.
    render_geometry!(@apart_id, APART)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # ---- lib/print_sheet.js: pagination ---------------------------------------------------------

  # MUTATION-CHECKED: dropping `- CALIB_H` from contentBox turns this RED ("Expected |230.4 -
  # 252.39999999999998| (21.99999999999997) to be <= 0.001") while the translation test below stays
  # GREEN — translateY is built from the content box's ORIGIN, which the calibration strip does not
  # move, so this is the only assertion in the file that can see the bottom strip at all.
  test "Letter's content box is the printable area less the two reserved strips" do
    box = JSON.parse(in_print_sheet("JSON.stringify(m.contentBox(m.PAPERS.Letter))"))

    # 215.9 - 20 margin = 195.9 wide; 279.4 - 20 margin - 7 header - 22 calibration = 230.4 tall.
    assert_in_delta 195.9, box["w"], 0.001
    assert_in_delta 230.4, box["h"], 0.001
    # And it carries its ORIGIN, which is what stops three call sites re-spelling MARGIN + HEADER_H.
    assert_in_delta 10.0, box["x"], 0.001
    assert_in_delta 17.0, box["y"], 0.001
  end

  # THE TRANSLATION IS THE WHOLE "TRUE POSITIONS" CLAIM, and it is relative rather than absolute:
  # the SELECTION's bbox origin is the datum, not the file's. A part sitting at x 500 in a 600 mm
  # laser sheet prints at the left edge of sheet 1, not on tile 3 of 12 with two blank ones.
  #
  # MUTATION-CHECKED TWICE, because two independent claims meet here and one mutation cannot see
  # both. Making the translation absolute (`translateX: content.x`) turns this RED ("Expected
  # |-490.0 - 10| (500.0) to be <= 0.001") — that pins the DATUM. Gutting unionBox to
  # `return shapes[0].b` turns it RED too ("Expected |-490.0 - -510| (20.0) to be <= 0.001") — that
  # pins the UNION, and it can only fail because the shape supplying the minima is second in the
  # array below. Neither turns the content-box test above red.
  test "a selection that fits produces one page whose translation puts it at the content origin" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets([
        // TWO SHAPES, AND THE ONE SUPPLYING THE MINIMA IS DELIBERATELY NOT FIRST. With a single
        // shape "the selection's bbox" and "this shape's bbox" are indistinguishable, so the test
        // cannot fail for the property it exists to pin: gutting unionBox to
        // `return shapes[0].b` stays GREEN. Verified — that mutation must turn this red.
        { b: [520, 320, 600, 400], p: [[520, 320], [600, 400]], k: 1, i: 0, o: 2 },
        { b: [500, 300, 560, 340], p: [[500, 300], [560, 340]], k: 1, i: 0, o: 1 },
      ], m.PAPERS.Letter))
    JS

    assert_equal 1, out["pages"].length
    assert_equal 1, out["cols"]
    assert_equal 1, out["rows"]
    # MARGIN (10) less the selection's own x0 (500); MARGIN + HEADER_H (17) less its y0 (300).
    assert_in_delta(-490.0, out["pages"][0]["translateX"], 0.001)
    assert_in_delta(-283.0, out["pages"][0]["translateY"], 0.001)
  end

  # 400 mm of content on Letter: the content box is 195.9 wide and the overlap band eats 10 of it,
  # so each tile after the first adds 185.9 mm of NEW content -> ceil((400 - 10) / 185.9) = 3.
  #
  # THIS IS THE FIRST TEST IN THE FILE THAT READS `unionBox`'s MAXIMA HALF — `cols` and `rows` are
  # its only consumers, since `translateX/Y` reads the minima alone. So it takes TWO SHAPES, WITH
  # THE ONE SUPPLYING THE MAXIMA DELIBERATELY SECOND, for the same reason the translation test
  # above puts its minima supplier second: over a one-element array `Math.max` and `Math.min` are
  # indistinguishable, so the single-shape input this task was drafted with could not fail for the
  # property it exists to pin. Verified — with one shape, flipping unionBox's max half to
  # `Math.min` stayed GREEN.
  #
  # MUTATION-CHECKED THREE WAYS, because three independent claims meet in this one number.
  # unionBox's maxima -> `Math.min`: RED ("Expected: 3, Actual: 1") — pins the UNION, and only
  # because the maxima supplier is second in the array. `stepX = content.w` (no overlap band):
  # RED ("Expected: 3, Actual: 2") — pins that a tile's NEW content is the step, not the width.
  # `Math.ceil` -> `Math.floor`: RED ("Expected: 3, Actual: 2") — pins that a part-full last tile
  # still gets a sheet. A floor leaves 2 columns, and column 1 starts at 185.9 and COVERS TO
  # 381.8, so the last 18.2 mm of the part never prints. (371.8 is 2 x stepX — the NEW content the
  # two tiles add, which is a different quantity from the extent they cover, and conflating the
  # two is exactly the mistake this `ceil` exists to avoid.)
  test "a selection wider than the sheet tiles into columns" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets([
        { b: [0, 0, 10, 10], p: [[0, 0], [10, 10]], k: 1, i: 0, o: 2 },
        { b: [0, 0, 400, 40], p: [[0, 0], [400, 40]], k: 1, i: 0, o: 1 },
      ], m.PAPERS.Letter))
    JS

    assert_equal 3, out["cols"]
    assert_equal 1, out["rows"]
    assert_equal 3, out["pages"].length
  end

  # THE SECOND TILE MUST START ONE OVERLAP BAND BEFORE THE FIRST TILE ENDED, or there is nothing
  # to align the two sheets against and the whole tiling is a butt joint you cannot register.
  #
  # MUTATION-CHECKED: `stepX = content.w` — the obvious "tile by the sheet width" spelling — turns
  # this RED ("Expected |185.9 - 195.9| (10.0) to be <= 0.001"). That is the whole overlap band.
  test "the second tile repeats an overlap band of the first" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [0, 0, 400, 40], p: [[0, 0], [400, 40]], k: 1, i: 0, o: 1 }],
        m.PAPERS.Letter))
    JS

    dx = out["pages"][1]["originX"] - out["pages"][0]["originX"]
    assert_in_delta 185.9, dx, 0.001, "content width 195.9 mm less a 10 mm overlap band"

    # AND THE GEOMETRY MUST ACTUALLY PAN BY THAT MUCH, not merely be RECORDED as starting there.
    # `originX` is a number in the page object; `translateX` is what moves the drawing. Dropping
    # `- originX` from the translation leaves every tile drawing tile 1's content — three identical
    # sheets labelled 1 of 3, 2 of 3, 3 of 3 — and the originX assertion above stays GREEN through
    # it. Verified. Asserted as the RELATIONSHIP (pan left by exactly what the origin moved right)
    # rather than as a second literal, so the two can never drift apart.
    dtx = out["pages"][1]["translateX"] - out["pages"][0]["translateX"]
    assert_in_delta(-dx, dtx, 0.001, "the tile's content pans left by exactly its origin step")

    # THE SPANNING SHAPE MUST REACH EVERY TILE IT CROSSES, INTERIOR ONES INCLUDED — and this is
    # the only assertion in the file with a shape on more than one tile, which is why it carries
    # weight far beyond its size. `touches` is an inclusive AABB OVERLAP test; swapping its two
    # assignment lines so x1/y1 take b[0]/b[1] silently turns it into a CONTAINMENT test, and
    # every other test here still passes because each of their shapes lands on exactly one tile.
    # The user-visible result of that mutation is three sheets, correctly numbered "1 of 3" to
    # "3 of 3", correctly margined, carrying the calibration bar — and COMPLETELY BLANK. Nothing
    # errors, nothing logs. This one line is what makes it red.
    #
    # MUTATION-CHECKED: the swap took the WHOLE SUITE green before this line existed (10 runs, 67
    # assertions, 0 failures — reproduced, not taken on trust); with it, RED here with actual
    # [[], [], []]. The twelve-row table on the filter test below is untouched by this, which is
    # why the assertion is here and not there — its fixture would have had to change, and every
    # row of that table would have needed re-measuring.
    assert_equal [ [ 1 ], [ 1 ], [ 1 ] ],
                 out["pages"].map { |pg| pg["shapes"].map { |sh| sh["o"] } },
                 "a 400 mm bar spans all three tiles, including the middle one"
  end

  # ROWS, NOT JUST COLUMNS. Every other tiling test here is one row tall, so the `row` loop,
  # `originY` and `translateY` are exercised only at row 0 — and a copy-paste slip like
  # `translateY: content.y - originX - box[1]` passes all of them. Letter's content box is 230.4 mm
  # tall and the overlap band eats 10, so ceil((500 - 10) / 220.4) = 3 rows.
  #
  # MUTATION-CHECKED FOUR WAYS, the row-axis twin of the column test above. `translateY` reading
  # `originX`: RED ("Expected |-220.39999999999998 - 0| (220.39999999999998) to be <= 0.001") —
  # this test is one column wide, so originX is 0 on every page and the slip pins every row's
  # content at row 1's. `stepY = content.h`: RED ("Expected |220.4 - 230.39999999999998|
  # (9.999999999999972) to be <= 0.001"). `Math.ceil` -> `Math.floor`: RED ("Expected: 3,
  # Actual: 2") — 490 / 220.4 is 2.22, so 2 rows cover to 450.8 and the last 49.2 mm of the part
  # never prints. Dropping the `h <= content.h ? 1 :` guard is RED too,
  # but in the FITS test below rather than here (h = 500 tiles either way) — see its comment for
  # why that one matters.
  test "a selection taller than the sheet tiles into rows" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [0, 0, 40, 500], p: [[0, 0], [40, 500]], k: 1, i: 0, o: 1 }],
        m.PAPERS.Letter))
    JS

    assert_equal 1, out["cols"]
    assert_equal 3, out["rows"]
    dy = out["pages"][1]["originY"] - out["pages"][0]["originY"]
    assert_in_delta 220.4, dy, 0.001, "content height 230.4 mm less a 10 mm overlap band"
    # THE RELATIONSHIP, not a second literal: translateY must pan by exactly the origin step, or
    # every tile draws row 1's content on a sheet labelled row 2.
    assert_in_delta(-dy, out["pages"][1]["translateY"] - out["pages"][0]["translateY"], 0.001)
  end

  # THE GRID MUST BE ASYMMETRIC OR col/row ARE UNOBSERVABLE. Every other tiling test here is 1xN
  # or Nx1, so `col` and `row` are never both non-zero and three separate mutations stay GREEN:
  # swapping `col:`/`row:` on the page object, swapping `cols:`/`rows:`, and transposing the loop
  # nesting. Task 6 draws "Sheet c,r of CxR" out of exactly these fields and Task 8 emits `pages`
  # in array order, so a maker with a 3x2 job would get sheets labelled transposed, or ordered
  # column-major against their own labels, with nothing anywhere going red.
  #
  # 2x2 WOULD NOT DO — with cols == rows every one of those swaps is invisible. 400 x 300 mm on
  # Letter gives 3 columns and 2 rows, which is the smallest grid that can see all three.
  #
  # MUTATION-CHECKED THREE WAYS, and each one fails a DIFFERENT assertion, which is how the two
  # assertions below are shown to carry independent weight. `col: row, row: col` on the page
  # object: RED on the order assertion, actual [[0,0],[0,1],[0,2],[1,0],[1,1],[1,2]] — the
  # emission order is still row-major, it is the LABELS that transposed. Transposing the loop
  # nesting: RED on the same assertion but a distinguishable actual,
  # [[0,0],[0,1],[1,0],[1,1],[2,0],[2,1]] — labels right, ORDER column-major. `cols: rows, rows:
  # cols`: RED on the whole-grid assertion ("Expected false to be truthy"), which the order
  # assertion cannot see at all because per-page col/row are untouched by it.
  test "pages are emitted row-major and carry their own grid position" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [0, 0, 400, 300], p: [[0, 0], [400, 300]], k: 1, i: 0, o: 1 }],
        m.PAPERS.Letter))
    JS

    assert_equal 3, out["cols"]
    assert_equal 2, out["rows"]
    assert_equal [ [ 0, 0 ], [ 1, 0 ], [ 2, 0 ], [ 0, 1 ], [ 1, 1 ], [ 2, 1 ] ],
                 out["pages"].map { |pg| [ pg["col"], pg["row"] ] }
    # Every page reports the WHOLE grid, not its own position twice over.
    assert out["pages"].all? { |pg| pg["cols"] == 3 && pg["rows"] == 2 }
  end

  # A selection that fits goes through the SAME path, with no small-selection branch to keep in
  # step with the tiled one.
  #
  # THE SECOND SELECTION IS SMALLER THAN THE OVERLAP BAND, AND THAT IS THE ONLY ONE OF THE TWO
  # THAT CAN SEE THE `w <= content.w ? 1 :` GUARD. Without the guard the count is
  # `ceil((w - OVERLAP) / stepX)`, which for anything under 10 mm is ceil(<= 0) = **0** — no pages
  # at all, no error, nothing printed. 60 x 40 cannot catch that (ceil(50 / 185.9) is still 1), so
  # the guard was unpinned as drafted: deleting it stayed GREEN. Verified in both directions. And
  # the input is not contrived — this file's own nested-plate fixture has a 10 mm hole, so
  # "select one small hole and print it" is the ordinary action that would have produced nothing.
  test "a selection that fits produces one page through the same call" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [0, 0, 60, 40], p: [[0, 0], [60, 40]], k: 1, i: 0, o: 1 }],
        m.PAPERS.Letter))
    JS

    assert_equal 1, out["pages"].length

    tiny = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [0, 0, 8, 8], p: [[0, 0], [8, 8]], k: 1, i: 0, o: 1 }],
        m.PAPERS.Letter))
    JS

    assert_equal 1, tiny["pages"].length, "a selection under one overlap band still gets a page"
    assert_equal 1, tiny["cols"]
    assert_equal 1, tiny["rows"]
  end

  # ---- lib/print_sheet.js: the sheet cap, and per-tile filtering -------------------------------

  # An SVG whose units were read 25.4x too large would otherwise silently spool 9,828 sheets.
  #
  # THE CAP IS TESTED IN BOTH DIRECTIONS IN ONE METHOD, because it is one guard and an
  # over-the-cap assertion alone cannot see an off-by-one in the comparison it is asserting on.
  #
  # MUTATION-CHECKED FOUR WAYS. Between them they turn all THREE blocks below red, which is how
  # each block is shown to carry weight of its own rather than restating its neighbour. Deleting
  # the guard: RED on the first ("Expected /\A9828 sheets/ to match 'NO ERROR'" — the count
  # assertion sits above the /more than 40 sheets/ one, so it is the one that reports). `>` ->
  # `>=`: RED on the at-cap block, and as an ERROR rather than a failure — that block calls
  # buildSheets BARE, so an unexpected throw comes back through in_print_sheet's own raise
  # verbatim ("RuntimeError: ERROR: 40 sheets — this selection is 1400 × 1000 mm, which is more
  # than 40 sheets of Letter."). Deleting `round` from the message: RED on the over-the-cap block
  # (actual "1600.04 × 1000 mm"). Swapping w and h in the message: RED on the same block (actual
  # "1000 × 1600 mm"). The guard's PLACEMENT is pinned by its own test below, not from here.
  test "an absurd selection is refused rather than printing hundreds of sheets" do
    err = in_print_sheet(<<~JS)
      (() => {
        try {
          m.buildSheets([
            // TWO SHAPES, MAXIMA SUPPLIER SECOND, for the reason the tiling tests above give: the
            // message quotes round(w) x round(h) off the UNION, and over a one-element array
            // unionBox's `Math.max` half and `Math.min` are indistinguishable, so the plan's
            // single 20000 mm shape could not fail for the size half of its own assertion.
            { b: [0, 0, 10, 10], p: [[0, 0], [10, 10]], k: 1, i: 0, o: 2 },
            { b: [10000, 10000, 20000, 20000], p: [[10000, 10000], [20000, 20000]], k: 1, i: 0, o: 1 },
          ], m.PAPERS.Letter)
          return "NO ERROR"
        } catch (e) { return e.message }
      })()
    JS

    # 9,828, not a round number: the message begins with the real count, and quoting a rounded
    # one would read as computed when it is not.
    assert_match(/\A9828 sheets/, err)
    assert_match(/more than 40 sheets/, err)
    assert_match(/20000 \u{00D7} 20000 mm/, err, "the message must name the size that caused it")

    # EXACTLY MAX_SHEETS IS ALLOWED — the constant is a maximum, not a ceiling one below it, and a
    # maker with a legitimately 40-sheet job must get their 40 sheets. 1400 x 1000 mm on Letter is
    # ceil(1390 / 185.9) = 8 columns by ceil(990 / 220.4) = 5 rows = exactly 40. Nothing else in
    # this file can see the comparison operator: every other input is orders of magnitude away.
    at_cap = JSON.parse(in_print_sheet(<<~JS))
      (() => {
        const r = m.buildSheets(
          [{ b: [0, 0, 1400, 1000], p: [[0, 0], [1400, 1000]], k: 1, i: 0, o: 1 }],
          m.PAPERS.Letter)
        return JSON.stringify([r.cols, r.rows, r.pages.length])
      })()
    JS

    # IF A CONSTANT CHANGES, RECHOOSE THE INPUT — DO NOT EDIT THIS EXPECTATION. 1400 x 1000 mm is
    # exactly MAX_SHEETS on Letter today; move MARGIN, HEADER_H or CALIB_H and this goes red, and
    # the tempting fix (write down whatever the new triple is) silently stops the boundary test
    # from sitting on the boundary. Pick a new size that lands on exactly MAX_SHEETS instead.
    assert_equal [ 8, 5, 40 ], at_cap, "40 sheets is the maximum ALLOWED, not the first refused"

    # And one column more is refused, which is what makes the assertion above a boundary rather
    # than a claim that the guard never fires. 1600.04 mm gives 9 columns x 5 rows = 45.
    #
    # THE .04 IS THE ONLY THING IN THE FILE THAT READS `round`. Every other extent here is a whole
    # number, so deleting the rounding leaves the message byte-identical and the helper unpinned —
    # while a real selection is a bbox off a bezier and essentially never lands on one. Asserted
    # as the whole message prefix rather than a substring, because the unrounded spelling
    # ("1600.04 x 1000 mm") still contains "1600" and a loose match would not see it.
    over = in_print_sheet(<<~JS)
      (() => {
        try {
          m.buildSheets(
            [{ b: [0, 0, 1600.04, 1000], p: [[0, 0], [1600.04, 1000]], k: 1, i: 0, o: 1 }],
            m.PAPERS.Letter)
          return "NO ERROR"
        } catch (e) { return e.message }
      })()
    JS

    assert_match(/\A45 sheets \u{2014} this selection is 1600 \u{00D7} 1000 mm,/, over,
                 "one sheet over the cap is refused, and the size it names is rounded")
  end

  # WHERE THE GUARD SITS, WHICH IS A DIFFERENT CLAIM FROM WHAT IT ANSWERS — hence its own test.
  # The three blocks above pin the refusal's VALUE and fail with a wrong string; this one pins its
  # PLACEMENT and fails by killing the browser, and four browser round-trips in one method means
  # the first failure hides the rest. A paper whose content box is exactly one overlap band wide
  # gives stepX = 0 and therefore cols = Infinity; checked above the loop, `Infinity * rows > 40`
  # refuses in constant time. Checked after the loop, the `col` loop never ends.
  #
  # MUTATION-CHECKED by moving the block below the loop: RED in 6.6 s as
  # "Selenium::WebDriver::Error::WebDriverError: tab crashed" — Chrome OOMs on the unbounded
  # pages.push long before Selenium's script timeout, so this reports faster and more legibly than
  # the hang it stands in for. Every assertion in the test above stays GREEN through it, since a
  # finite cols builds its pages and then throws exactly as before.
  #
  # THE COUNT IN THAT MESSAGE IS THE WORD "Infinity", DELIBERATELY UNASSERTED. It is nonsense to
  # print, and it is nonsense a user can never reach: a 30 mm paper is not in PAPERS. The refusal
  # is what matters here, so the assertion reads only that. Which is also why this closes ONE
  # degenerate paper rather than the class — see `buildSheets`' own comment.
  test "a paper too narrow to tile is refused rather than looped over forever" do
    sliver = in_print_sheet(<<~JS)
      (() => {
        try {
          m.buildSheets([{ b: [0, 0, 100, 10], p: [[0, 0], [100, 10]], k: 1, i: 0, o: 1 }],
                        { name: "Sliver", w: 30, h: 297 })
          return "NO ERROR"
        } catch (e) { return e.message }
      })()
    JS

    assert_match(/more than 40 sheets/, sliver, "a zero-width step must refuse, not loop forever")
  end

  # THE OTHER REFUSAL, which nothing else in this plan pins — verified by grepping every task, so
  # deleting the guard would have gone unnoticed end to end. It is a module PRECONDITION rather
  # than a user-facing message (Task 11's caller returns early on an empty set before ever calling
  # here), but an unpinned throw is an unpinned throw: `unionBox` on an empty array returns
  # [Infinity, Infinity, -Infinity, -Infinity], so without it `buildSheets` yields NaN geometry and
  # a page full of nothing rather than an error anyone can act on.
  test "an empty selection is refused rather than producing NaN geometry" do
    err = in_print_sheet(<<~JS)
      (() => {
        try { m.buildSheets([], m.PAPERS.Letter); return "NO ERROR" }
        catch (e) { return e.message }
      })()
    JS

    assert_equal "Nothing to print.", err
  end

  # Handing every tile every shape would put a thousand-contour selection into the DOM once per
  # sheet; the clipPath hides them, so nothing would look wrong while the print took as many times
  # as long to spool.
  #
  # A 2x2 GRID WITH A SHAPE PER QUADRANT AND THE WHOLE SELECTION OFFSET FROM THE ORIGIN, NOT THE
  # PLAN'S 1x2 ROW AT (0, 0). `touches` is FOUR comparisons and two datum shifts, and the plan's
  # input can see only two of the six. Swapped back to the plan's literal data and re-run
  # through this same browser harness, SEVEN mutations stayed GREEN — measured, not reasoned:
  #
  #   * dropping `y1 >= originY` and dropping `y0 <= originY + content.h` — one row means originY
  #     is 0 on every tile and every shape's y sits inside content.h, so both are unconditionally
  #     true and neither can ever exclude anything.
  #   * `y0 <= originY + content.w` and `x0 <= originX + content.h` — the axis copy-paste slip,
  #     the same shape as Task 2's `translateY: content.y - originX`. Nothing in a 1x2 grid lies
  #     between the two bounds (195.9 and 230.4), so swapping them changes no answer.
  #   * dropping `- box[0]`, dropping `- box[1]`, and swapping the two — a selection whose union
  #     box starts at (0, 0) makes the datum shift a NO-OP, so the whole selection-space
  #     conversion can be deleted with nothing going red.
  #
  # So: four quadrant shapes pin the four comparisons, two edge-band shapes pin the two bounds
  # against each other, and the +500/+300 offset makes the datum shift observable.
  #
  # MUTATION-CHECKED TWELVE WAYS against the strengthened input, all RED, each with a
  # distinguishable actual (expected is [[6, 1], [2, 5], [3], [4]] throughout):
  #
  #   drop `x1 >= originX`             [[6,1], [2,6,1,5], [3], [4,3]]
  #   drop `x0 <= originX + content.w` [[2,6,1,5], [2,5], [4,3], [4]]
  #   drop `y1 >= originY`             [[6,1], [2,5], [6,1,3], [2,4,5]]
  #   drop `y0 <= originY + content.h` [[6,1,3], [2,4,5], [3], [4]]
  #   `y1 >= originX` (cross-axis)     [[6,1], [], [6,1,3], [4]]
  #   `y0 <= originY + content.w`      [[1], [2,5], [3], [4]]
  #   `x0 <= originX + content.h`      [[6,1,5], [2,5], [3], [4]]
  #   drop `- box[0]`                  [[], [], [], []]
  #   drop `- box[1]`                  [[], [], [1], [2,5]]
  #   swap `box[0]`/`box[1]`           [[], [6,3], [], []]
  #   no filter at all                 [[2,6,4,1,5,3] x 4]
  #   swap originX/originY at the call [[6,1], [6,3], [2], [4]]
  #
  # DELIBERATELY NOT PINNED, AND RUN RATHER THAN ASSUMED: tightening any of the four comparisons
  # (`>=` -> `>`, `<=` -> `<`) comes back GREEN here — verified on `x1 >= originX`. It differs only
  # for a bbox whose edge lands EXACTLY on a tile boundary, where the shape is a hairline on the
  # new tile and is already whole on the previous one (the overlap band guarantees it), and
  # catching it would mean asserting float equality against 185.9. Recorded, not silently skipped.
  test "a tile carries only the shapes whose bbox touches it" do
    out = JSON.parse(in_print_sheet(<<~JS))
      // Selection x 500..810 (310 wide -> 2 columns), y 300..650 (350 tall -> 2 rows). In
      // SELECTION space the tiles are x 0..195.9 / 185.9..381.8 and y 0..230.4 / 220.4..450.8.
      // Deliberately scrambled, and the min-x supplier is NOT first, so `unionBox` gutted to
      // `shapes[0].b` retiles the whole thing rather than landing on the same answer. Verified:
      // that mutation gives one page carrying [[2]], and turns three other tests in this file red.
      JSON.stringify(m.buildSheets([
        { b: [800, 300, 810, 310], p: [[800, 300], [810, 310]], k: 1, i: 0, o: 2 }, // sel  300,0
        { b: [500, 500, 510, 510], p: [[500, 500], [510, 510]], k: 1, i: 0, o: 6 }, // sel    0,200
        { b: [800, 640, 810, 650], p: [[800, 640], [810, 650]], k: 1, i: 0, o: 4 }, // sel  300,340
        { b: [500, 300, 510, 310], p: [[500, 300], [510, 310]], k: 1, i: 0, o: 1 }, // sel    0,0
        { b: [700, 300, 710, 310], p: [[700, 300], [710, 310]], k: 1, i: 0, o: 5 }, // sel  200,0
        { b: [500, 640, 510, 650], p: [[500, 640], [510, 650]], k: 1, i: 0, o: 3 }, // sel    0,340
      ], m.PAPERS.Letter).pages.map((p) => p.shapes.map((s) => s.o)))
    JS

    # Shape 6 sits at selection y 200..210, between content.w (195.9) and content.h (230.4), so it
    # belongs to row 0 and ONLY the `+ content.h` bound keeps it there. Shape 5 sits at selection
    # x 200..210, in the same band on the other axis, so it belongs to column 1 and only the
    # `+ content.w` bound keeps it OUT of column 0. Each is the other's mirror, and each is the
    # only witness to its own bound.
    assert_equal [ [ 6, 1 ], [ 2, 5 ], [ 3 ], [ 4 ] ], out,
                 "row-major tiles, and the filter preserves array order within each tile"
  end

  # ---- lib/print_sheet.js: rendering -----------------------------------------------------------
  #
  # ONLY THE CLIP'S EFFECTIVENESS WAITS FOR TASK 5 — everything else about it is pinned here, and
  # the earlier version of this comment deferring the whole subject is what let a Critical bug
  # ship. `clip-path` and `transform` were on ONE group, so userSpaceOnUse resolved the window in
  # the TRANSLATED space and it travelled with the geometry: on this file's own nested-plate
  # fixture the sheet prints a 20 x 3 mm scrap of one corner, and for an ordinary laser file at
  # positive coordinates it prints BLANK. Twenty-four mutations could not see it, because the clip
  # was not asserted at all — deleting the <clipPath> element AND the clip-path attribute outright
  # left the whole suite green. The rect equalling contentBox, the reference matching the id, and
  # the nesting are all assertable WITHOUT layout, and now are.
  #
  # STILL UNEXERCISED, AND TASK 6 OWNS IT: `el`'s two new doors — the nullish attribute guard and
  # the `text` parameter — have no caller in this task, so both were mutation-checked and both came
  # back GREEN (measured at 19 runs / 132 assertions, before the stroke-width split below took the
  # file to 20/135) with the guard and the door deleted in turn.
  # That is not a weak input this tier can strengthen; it is a code path Task 4 never walks. Task 6
  # adds the five <text> call sites the door exists for — four on any one sheet, the sheet label
  # being conditional — and must pin both there.

  # The plan's render input: a 60 x 40 closed part at the origin, kept because the two scale
  # assertions want a part whose dimensions ARE the numbers being asserted.
  SIXTY_BY_FORTY = <<~JS.freeze
    [{ b: [0, 0, 60, 40], k: 1, i: 0, o: 1,
       p: [[0, 0], [60, 0], [60, 40], [0, 40], [0, 0]] }]
  JS

  # ONE SPELLING OF THE `meta` ARGUMENT rather than one per test. Nothing in renderSheet reads it
  # yet — the header, the calibration strip and the size labels are later tasks — but it is part of
  # the call, and `sizeLabel` returning null is the "no label for this shape" answer.
  META = '{ name: "plate.lbrn2", date: "2026-08-19", sizeLabel: () => null }'.freeze

  # THE SCALE MECHANISM, ASSERTED AS THE TWO LITERALS THAT CONSTITUTE IT. A width in px with the
  # same viewBox draws an identical-looking page at the wrong size, and no visual check catches it.
  #
  # TWO PAPERS, NOT THE PLAN'S ONE. Against Letter alone every one of these attributes can be a
  # HARD-CODED STRING and all three assertions stay GREEN, while the A4, A3 and Tabloid the picker
  # also offers come out DECLARED as Letter — the printer then fits a 210 mm page into a 215.9 mm
  # declaration and every part on it is 2.8% wrong. Verified: replacing all four interpolations
  # with Letter's own literals is GREEN through the Letter block and RED on the A4 one, and the
  # actual it prints is the giveaway — `width="215.9mm" ... viewBox="0 0 215.9 279.4"` wrapped
  # around a content rect of `width="190" height="248"`, which is A4's. The page knows its own
  # size; only what it DECLARES to the printer is wrong.
  #
  # MUTATION-CHECKED SIX WAYS, all RED here, all with a distinguishable actual:
  #   width `${paper.w}px`         width="215.9px"
  #   both pairs hard-coded        RED on the A4 block, `to include "width=\"210mm\""`
  #   width/height swapped         width="279.4mm" height="215.9mm"
  #   viewBox extents swapped      viewBox="0 0 279.4 215.9"
  #   viewBox spans the CONTENT    viewBox="0 0 195.9 230.39999999999998" — the float tail is the
  #                                giveaway that it came off contentBox. An earlier draft of this
  #                                row quoted 195.9 x 259.4, which is the PRINTABLE box (paper less
  #                                margins, no strips) — a different mutation, and the label and
  #                                the number disagreed.
  #   createElement, no namespace  viewbox="0 0 215.9 279.4" — setAttribute lowercases the name on
  #                                an HTML-namespace element, so the camel-cased literal is what
  #                                notices the elements are not SVG at all
  test "a sheet declares its size in millimetres and spans the same number of user units" do
    html = in_print_sheet(<<~JS)
      m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0], #{META}).outerHTML
    JS

    assert_includes html, 'width="215.9mm"'
    assert_includes html, 'height="279.4mm"'
    assert_includes html, 'viewBox="0 0 215.9 279.4"'

    a4 = in_print_sheet(<<~JS)
      m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.A4).pages[0], #{META}).outerHTML
    JS

    assert_includes a4, 'width="210mm"'
    assert_includes a4, 'height="297mm"'
    assert_includes a4, 'viewBox="0 0 210 297"'
  end

  # A 60 x 40 part must span 60 x 40 USER UNITS, which the assertion above has just established
  # are millimetres. Asserting only "a polygon exists" is answered exactly as well by a polygon of
  # the wrong size — CLAUDE.md §14h's Z-up lesson, one feature over.
  #
  # MUTATION-CHECKED: transposing the point format to `${y},${x}` is RED ("Expected |60.0 - 40.0|
  # (20.0) to be <= 0.001"). It is a SPAN test, though, so it cannot see a renderer that draws the
  # right extent out of the wrong data — see the exact-points assertion further down for what does.
  test "a 60 x 40 part spans exactly 60 by 40 user units on the sheet" do
    points = in_print_sheet(<<~JS)
      m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0], #{META})
       .querySelector("polygon").getAttribute("points")
    JS

    xs = points.split(/\s+/).map { |p| p.split(",").first.to_f }
    ys = points.split(/\s+/).map { |p| p.split(",").last.to_f }
    assert_in_delta 60.0, xs.max - xs.min, 0.001
    assert_in_delta 40.0, ys.max - ys.min, 0.001
  end

  # TWO PARTS MUST KEEP THEIR REAL SEPARATION — the entire point of "true positions". A transform
  # applied per shape instead of per page would draw both parts perfectly and stack them.
  #
  # MUTATION-CHECKED: emitting only the first shape is RED ("the two parts are 50 mm apart in the
  # file. Expected |50.0 - 0| (50.0) to be <= 0.001"), as is transposing the point format. It reads
  # the UNTRANSFORMED `points` attribute, so it is blind to the page transform itself — that is the
  # last test in this section, and nothing above it can see one.
  test "two parts keep their real separation on the sheet" do
    xs = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(Array.from(m.renderSheet(document,
        m.buildSheets([
          // Min-supplier second — see Task 1's union test.
          { b: [50, 0, 60, 10],  k: 1, i: 0, o: 2, p: [[50, 0], [60, 0], [60, 10], [50, 0]] },
          { b: [0, 0, 10, 10],   k: 1, i: 0, o: 1, p: [[0, 0], [10, 0], [10, 10], [0, 0]] },
        ], m.PAPERS.Letter).pages[0], #{META})
       .querySelectorAll("polygon")).map((n) =>
         Math.min(...n.getAttribute("points").split(/\\s+/).map((p) => parseFloat(p)))))
    JS

    assert_in_delta 50.0, xs.max - xs.min, 0.001, "the two parts are 50 mm apart in the file"
  end

  # THE CLIP IS PINNED AT STRING LEVEL HERE; ONLY ITS EFFECTIVENESS WAITS FOR TASK 5. Deleting
  # the <clipPath> element AND the clip-path attribute outright left the whole suite green — which
  # is exactly how a clip built in the wrong coordinate space survived 24 mutations. Neither claim
  # below needs layout: the rect must equal contentBox(paper), and the group must name the id the
  # clipPath actually carries (`clipId` is spelled twice, and a one-sided edit is silent — this
  # repo's own N-copies-that-must-agree shape).
  #
  # THE NESTING IS ALSO ASSERTED, because it is load-bearing rather than stylistic: the clip must
  # sit on an UNTRANSFORMED ancestor. Collapse the two groups and userSpaceOnUse resolves the
  # window in the translated space, so it travels with the geometry and the sheet prints blank.
  #
  # MUTATION-CHECKED FIVE WAYS, each failing a DIFFERENT one of the four assertions:
  #
  #   the two groups collapsed      clippedHasTransform — THE SHIPPED BUG, and this line is the
  #     back into one                 only thing in the file that sees it
  #   the clip removed entirely     RuntimeError: ERROR: Cannot read properties of null (reading
  #     (element and attribute)       'getAttribute') — an error rather than a failure, because
  #                                   `clipPath rect` is then null; red either way, and the whole
  #                                   suite was GREEN through this before the test existed
  #   rect = the PRINTABLE box      rect — Expected: [10, 17, 195.9, 230.4] Actual:
  #     instead of contentBox         [10, 10, 195.9, 259.4]
  #   `url(#${clipId}-content)`     refMatchesId — the one-sided edit of a twice-spelled id
  #   the transform deleted         transformInside (and the transform test below)
  test "the clip is a content-box rect on an untransformed ancestor of the moved geometry" do
    out = JSON.parse(in_print_sheet(<<~JS))
      (() => {
        const svg = m.renderSheet(document,
          m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0], #{META})
        const rect = svg.querySelector("clipPath rect")
        const clipped = svg.querySelector("[clip-path]")
        return JSON.stringify({
          // BY IDENTITY, NOT BY DOCUMENT ORDER. querySelector returns the FIRST element carrying
          // the attribute, which is the right one only while nothing else on the sheet has a clip
          // of its own. Counting is what stops the four assertions below silently re-targeting if
          // a later task gives a furniture element one.
          clipCount: svg.querySelectorAll("[clip-path]").length,
          rect: [ "x", "y", "width", "height" ].map((a) => Number(rect.getAttribute(a))),
          refMatchesId: clipped.getAttribute("clip-path") ===
                        `url(#${svg.querySelector("clipPath").id})`,
          // The clipping element must carry NO transform of its own...
          clippedHasTransform: clipped.hasAttribute("transform"),
          // ...and the transform must live on a descendant of it.
          transformInside: clipped.querySelector("[transform]") !== null,
        })
      })()
    JS

    assert_equal 1, out["clipCount"], "exactly one clipping element, so the four below cannot drift"
    assert_equal [ 10, 17, 195.9, 230.4 ], out["rect"].map { |v| v.round(4) }
    assert out["refMatchesId"], "the group must name the id the clipPath actually carries"
    refute out["clippedHasTransform"], "userSpaceOnUse resolves in the referencing element's space"
    assert out["transformInside"], "the page transform belongs on a descendant of the clip"
  end

  # THE STRIPS ARE RESERVED, NOT OVERLAID (the deliberate divergence from the boxes sibling), so a
  # part that runs past the content box must be CUT rather than printed across the calibration
  # ruler. The test above pins the clip's STRUCTURE out of the DOM; this one is the only thing in
  # the file that pins its EFFECT, and those are different claims — a clip-path naming an id that
  # does not exist is silently inert, and `getAttribute` reports it as present either way.
  #
  # THE INSTRUMENT IS HIT TESTING, AND THE PLAN'S `getBoundingClientRect` WAS THE WRONG ONE.
  # Measured before this test was written, not reasoned: against the CORRECT nested groups, the
  # drawn group's rect reads left=10.0 top=17.0 right=410.0 bottom=517.0 mm — the FULL, UNCLIPPED
  # extent of the part. Chrome's getBoundingClientRect ignores clip-path (so does getBBox, which
  # returned {x: 10, y: 17, w: 400, h: 500} on the same node), on the clipping element and on its
  # descendants alike. So the plan's `assert_in_delta 247.4 * scale, box["bottom"], 2.0` would have
  # gone RED against correct code and could never have observed the clip at all. `elementFromPoint`
  # DOES respect it — the instrument Task 4's own fix comment used to find the bug by hand.
  #
  # FOUR EDGES, NOT ONE. A `bottom`-only assertion cannot see a window displaced SIDEWAYS, and the
  # plan's 40 mm-wide part never reached the content box's right edge, so nothing about the
  # horizontal window was exercised at all. This part is 400 x 500 and runs past both edges, so
  # `right` and `bottom` can only be the WINDOW's.
  #
  # THE PART STARTS AT (0, 0) DELIBERATELY — keep it there. At positive coordinates the page
  # translate is negative, a mis-built window lands off-paper and NOTHING is painted; "it did not
  # escape into the ruler" is then satisfied by a blank sheet, green for the opposite of the right
  # reason. At the origin a displaced window paints in the WRONG PLACE instead, which is what the
  # four numbers below see. `insidePainted` is the premise guard that keeps a blank sheet from
  # reading as a pass through a bisection over nothing.
  #
  # MUTATION-CHECKED ELEVEN WAYS, every actual below copied out of the run rather than predicted.
  # Expected is [10.0, 17.0, 205.9, 247.4] = [left, top, right, bottom] throughout:
  #
  #   the two <g>s collapsed back      Actual: [20.0, 34.0, 215.9, 264.4] — THE SHIPPED BUG. All
  #     into one                         four move: userSpaceOnUse resolves the window in the
  #                                      TRANSLATED space, so it rides 10 right and 17 down with
  #                                      the geometry, slicing the part at the wrong place twice
  #                                      and running past the content box at the other two.
  #   the clip-path attribute          Actual: [9.9, 16.9, 215.9, 279.4] — the plan's own Step 3.
  #     removed                          The part now runs to the PAPER's edges, straight across
  #                                      both reserved strips; 9.9/16.9 is the 0.1 mm stroke halo
  #                                      a working window cuts off.
  #   `url(#${clipId}-content)` — a    Actual: [9.9, 16.9, 215.9, 279.4], INDISTINGUISHABLE from
  #     one-sided edit of the id         no clip at all — which mere PRESENCE of the attribute
  #     that is spelled twice           cannot see, since it is still there and still reads back.
  #                                     The structural test above catches this by cross-checking
  #                                     the id (`refMatchesId`); this one catches it by effect.
  #                                     Both are wanted: do not read this row as making that
  #                                     assertion dead weight.
  #   `svg.appendChild(clip)` dropped  Actual: [9.9, 16.9, 215.9, 279.4] — same, no <clipPath>.
  #   rect x = content.x + 30          Actual: [40.0, 17.0, 215.9, 247.4] — `bottom` is untouched,
  #                                      which is the whole argument against the plan's
  #                                      bottom-only assertion.
  #   rect y = content.y + 30          Actual: [10.0, 47.0, 205.9, 277.4]
  #   rect width = paper.w             Actual: [10.0, 17.0, 215.9, 247.4] — `right` ALONE.
  #   rect height = paper.h            Actual: [10.0, 17.0, 205.9, 279.4] — `bottom` ALONE.
  #   x + 30 AND width - 30            Actual: [40.0, 17.0, 205.9, 247.4] — `left` ALONE. This
  #                                      pair and the next exist because every mutation above
  #                                      that moves left or top also moves right or bottom, so
  #                                      without them those two numbers were riding along rather
  #                                      than carrying weight (CLAUDE.md §15).
  #   y + 30 AND height - 30           Actual: [10.0, 47.0, 205.9, 247.4] — `top` ALONE.
  #   rect x = content.x + 1000        The PREMISE fires instead, with its own sentence: "the part
  #     (the window off paper)           must paint inside the content box at all". Nothing is
  #                                      painted, and four edges bisected out of a blank sheet are
  #                                      four meaningless numbers rather than a legible failure.
  #
  # `fitsViewport` is the one assertion here with NO mutation of its own, and deliberately: it
  # guards an assumption about the BROWSER (screen_size, in application_system_test_case.rb), not
  # about this module, so nothing that can be done to print_sheet.js reaches it.
  test "a part running past the content box is clipped, not printed over the ruler" do
    out = JSON.parse(in_print_sheet(<<~JS))
      (() => {
        // 400 x 500 at the origin on Letter. Nine tiles; pages[0] is the top-left one, and the
        // part overruns its content box on the right and at the bottom.
        const page = m.buildSheets(
          [{ b: [0, 0, 400, 500], k: 1, i: 0, o: 1,
             p: [[0, 0], [400, 0], [400, 500], [0, 500], [0, 0]] }],
          m.PAPERS.Letter).pages[0]
        const svg = m.renderSheet(document, page,
          { name: "tall.lbrn2", date: "2026-08-19", sizeLabel: () => null })

        // INSTRUMENTATION OF THE OBSERVER, NOT OF THE THING OBSERVED. renderSheet draws
        // fill="none" — pinned as a wire literal by the black-and-classless test below, so this
        // override cannot hide a regression there — which leaves `pointer-events: visiblePainted`
        // hitting only the 0.2 mm stroke, with no interior to probe. The clip window is a
        // property of an ancestor and is identical either way.
        for (const n of svg.querySelectorAll("polygon, polyline")) n.setAttribute("fill", "#000")

        // Fixed at the viewport origin so client pixels and page millimetres differ by one
        // factor. The sheet is 816 x 1056 CSS px in a 1400 x 1257 viewport (measured), so every
        // probe below is on-screen — `fitsViewport` asserts that rather than assuming it, because
        // a point past the viewport edge hit-tests as EMPTY, which reads as "not painted" and
        // would silently walk an edge inward on a screen_size somebody shrank.
        svg.style.position = "fixed"; svg.style.left = "0px"; svg.style.top = "0px"
        svg.style.zIndex = "99999"
        document.body.appendChild(svg)

        // FINALLY, NOT A TRAILING remove(). in_print_sheet re-visits only when the path CHANGES,
        // so every test after this one shares this document — and a probe that threw would leave
        // a fixed, z-index 99999 sheet covering the page for the rest of the file.
        try {
          const host = svg.getBoundingClientRect()
          const S = host.width / 215.9
          // THROUGH THE TRANSFORMED GROUP, never a bare querySelector("polygon"). Task 6 appends
          // trim marks and a calibration gauge to this same sheet; the first polygon in document
          // order stops being the part the day any of them lands as one, and the fill sweep below
          // would blacken furniture instead. The contours are the only thing inside [transform].
          const part = svg.querySelector("[transform] polygon")
          // elementsFromPoint, NOT elementFromPoint — "is the part painted here", not "is the
          // part the TOPMOST thing here". Tasks 6-8 add a header, a calibration gauge and trim
          // marks to this same sheet, and the topmost reading would start answering about a
          // furniture element the day one of them overlaps a probe: the edges would walk inward
          // and this test would go red for somebody else's correct change.
          const painted = (xmm, ymm) =>
            document.elementsFromPoint(host.left + xmm * S, host.top + ymm * S).includes(part)
          // Bisect between a point known painted and one known not. 30 halvings of a 280 mm span
          // is a 2.6e-7 mm interval; roughly 25 of those 30 halvings are productive before the hit
          // test stops discriminating, which is not the same as landing inside the final interval:
          // the four edges come back [10.000001, 16.999999, 205.900005, 247.400007], a residual
          // of 7e-6 mm against a tolerance of 0.05. Read that as MEASURED, not as a guarantee —
          // an earlier draft of this comment quoted 0.002 mm and blamed Chrome's 1/64 px layout
          // quantum, and both halves were wrong: those numbers came off a throwaway probe using
          // elementFromPoint, and re-measuring through the code as it stands moved them by three
          // orders of magnitude. There is four orders of headroom either way.
          const edge = (from, to, probe) => {
            for (let i = 0; i < 30; i++) {
              const mid = (from + to) / 2
              if (probe(mid)) from = mid; else to = mid
            }
            return (from + to) / 2
          }
          return JSON.stringify({
            fitsViewport: host.right <= window.innerWidth && host.bottom <= window.innerHeight,
            insidePainted: painted(100, 100),
            left:   edge(100, 0,     (v) => painted(v, 100)),
            top:    edge(100, 0,     (v) => painted(100, v)),
            right:  edge(100, 215.9, (v) => painted(v, 100)),
            bottom: edge(100, 279.4, (v) => painted(100, v)),
          })
        } finally {
          svg.remove()
        }
      })()
    JS

    assert out["fitsViewport"], "the whole sheet must be on-screen or the bisection walks inward"
    assert out["insidePainted"], "the part must paint inside the content box at all"
    # contentBox(Letter) is x 10..205.9, y 17..247.4 — established by its own test at the top of
    # this file. The part is drawn at 10..410 x 17..517 in page space, so `right` and `bottom` are
    # the window's edges; `left` and `top` coincide with the part's own origin, which is what lets
    # them see a window displaced INWARD.
    #
    # ONE ASSERTION FOR ALL FOUR, because minitest ends a test at its FIRST failed assertion.
    # Written as four `assert_in_delta`s, a mutation that moves the whole window reported only
    # whichever edge came first — and for the plan's own Step 3 that is `left`, which fails by the
    # 0.1 mm stroke halo alone while `right` and `bottom` were failing by 10 and 32 mm out of
    # sight. Rounding to one decimal is the tolerance (+/- 0.05 mm) and the four numbers print
    # together, which is also the idiom the clip-rect test above already uses.
    assert_equal [ 10.0, 17.0, 205.9, 247.4 ],
                 out.values_at("left", "top", "right", "bottom").map { |v| v.round(1) },
                 "the painted part must be cut to the content box on every side"
  end

  # THE CONTOURS ARE BUILT FRESH FROM shape.p, NEVER CLONED FROM THE SCREEN. A clone would drag
  # the transparent fat hit-twin (.measure-contour--hit), the hover/selected/marked classes and
  # the layer colour onto paper — a printed sheet with an 8-unit-wide invisible stroke on it.
  #
  # MUTATION-CHECKED: dropping `stroke: "#000"` is RED (`to include "stroke=\"#000\""`), and
  # dropping `fill: "none"` is RED on the line below it. The refute is a TRIPWIRE rather than a
  # guard with a mutation of its own — nothing in this renderer can emit that string today, which
  # is the point: it goes red the day somebody reaches for cloneNode.
  test "the sheet carries no screen-only classes and prints in black" do
    html = in_print_sheet(<<~JS)
      m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0], #{META}).outerHTML
    JS

    refute_includes html, "measure-contour"
    assert_includes html, 'stroke="#000"'
    # AND AS AN OUTLINE, NOT A SILHOUETTE. SVG's default fill is BLACK, so a contourNode that
    # merely omitted `fill` prints every closed part as a solid black slab — hiding every internal
    # feature the sheet exists to check, and emptying a cartridge doing it. Neither assertion above
    # can see that: the stroke is still #000 and no screen-only class has appeared.
    assert_includes html, 'fill="none"'
  end

  # OPEN CONTOURS EXIST, AND A <polygon> CLOSES ONE FOR THEM. `k` is 0 for a path that never
  # closes — an engraved line, a DXF LWPOLYLINE with no closed flag — and a polygon draws a segment
  # from its last point back to its first that the design does not contain. Every shape in the four
  # tests above is `k: 1`, so `shape.k ? "polygon" : "polyline"` could be the constant "polygon"
  # with all of them GREEN.
  #
  # AND THE POINTS ARE ASSERTED AS THE EXACT STRING THE PRINTER WILL PARSE, which a "spans 60 user
  # units" assertion cannot substitute for in three separate directions. All three are
  # MUTATION-CHECKED, and the first two are GREEN in the span test above:
  #
  #   drawing shape.b's corners   ["0,0 30,0 30,20 0,20", "0,0 30,0 30,20 0,20"] — every part
  #     becomes its own BOUNDING BOX (a circle prints square) while spanning the identical extent.
  #     Not a hypothetical reach for this payload: `b` is the key every printed NUMBER must come
  #     from (§14h), which is exactly what makes it the easy slip here.
  #   `Math.round` on each coord  ["0,0 30,0 30,20 0,20 0,0", "0,0 13,20 30,5"] — at one user unit
  #     per millimetre a "tidy" rounds every vertex to the nearest MILLIMETRE, and whole-number
  #     test data cannot see it. Hence the 12.5.
  #   `${y},${x}` transposed      ["0,0 0,30 20,30 20,0 0,0", "0,0 20,12.5 5,30"]
  #
  # AND FOUR MORE, all RED here: always "polygon" ["polygon", "polygon"]; the ternary inverted
  # ["polyline", "polygon"]; emitting only the first shape ["polygon"]; createElement instead of
  # createElementNS ["POLYGON", "POLYLINE"] — tagName is upper-cased for an HTML-namespace element.
  # That last one is why stroke-width now has a test of its own rather than a third assertion here:
  # `assert_equal` stops at the first failure, so it reported `tags` and nothing after it.
  test "an open contour prints as a polyline and a closed one as a polygon" do
    out = JSON.parse(in_print_sheet(<<~JS))
      (() => {
        const svg = m.renderSheet(document, m.buildSheets([
          { b: [0, 0, 30, 20], k: 1, i: 0, o: 1, p: [[0, 0], [30, 0], [30, 20], [0, 20], [0, 0]] },
          // SAME BBOX as the closed part, and no vertex of it on a bbox corner.
          { b: [0, 0, 30, 20], k: 0, i: 0, o: 2, p: [[0, 0], [12.5, 20], [30, 5]] },
        ], m.PAPERS.Letter).pages[0], #{META})
        // Document order, which is the order the shapes were appended in.
        const nodes = Array.from(svg.querySelectorAll("polygon, polyline"))
        return JSON.stringify({
          tags: nodes.map((n) => n.tagName),
          points: nodes.map((n) => n.getAttribute("points")),
        })
      })()
    JS

    assert_equal [ "polygon", "polyline" ], out["tags"]
    assert_equal [ "0,0 30,0 30,20 0,20 0,0", "0,0 12.5,20 30,5" ], out["points"]
  end

  # SPLIT OUT OF THE TEST ABOVE RATHER THAN RIDING ALONG IN IT. `assert_equal` aborts the method at
  # its first failure, so while this sat third behind `tags` and `points` the createElement
  # mutation reported the tag names and the other two assertions never ran at all — a stroke-width
  # regression arriving alongside any other one was invisible. It is a different claim besides:
  # what a contour is drawn AS, against how thick the line is.
  #
  # 0.2 USER UNITS IS 0.2 mm, AND THE BARE NUMBER IS WHAT MAKES THAT TRUE. "0.2mm" is not a synonym
  # for it: a unit suffix inside an SVG attribute resolves through CSS at 96 dpi, so it would draw
  # 0.2 * 96 / 25.4 = 0.76 user units — a line nearly four times too fat to cut to, on a sheet that
  # otherwise still looks entirely right. MUTATION-CHECKED: RED, Actual ["0.2mm", "0.2mm"], and
  # nothing else in the file asserts stroke-width at all.
  test "every contour prints as a 0.2 mm line" do
    widths = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(Array.from(m.renderSheet(document, m.buildSheets([
        { b: [0, 0, 30, 20], k: 1, i: 0, o: 1, p: [[0, 0], [30, 0], [30, 20], [0, 20], [0, 0]] },
        { b: [0, 0, 30, 20], k: 0, i: 0, o: 2, p: [[0, 0], [12.5, 20], [30, 5]] },
      ], m.PAPERS.Letter).pages[0], #{META})
       .querySelectorAll("polygon, polyline")).map((n) => n.getAttribute("stroke-width")))
    JS

    assert_equal [ "0.2", "0.2" ], widths
  end

  # THE BITMAP PLACEHOLDER DRAWS DASHED, AND ONLY IT. The base64 is deliberately absent from the
  # payload (§14h) — what matters for fit is the RECTANGLE a photo occupies — so the dashes are the
  # only thing on paper that says "this outline is not a cut".
  #
  # TWO SHAPES, THE BITMAP FIRST, because one shape cannot tell a branch from a constant. Every
  # shape in the tests above is `i: 0`, so all three broken spellings are GREEN against them.
  # MUTATION-CHECKED, each with a distinguishable actual: the branch deleted [nil, nil]; the
  # dasharray set unconditionally ["4 3", "4 3"]; `if (!shape.i)` [nil, "4 3"]. (Emitting only the
  # first shape is RED here too, ["4 3"].)
  test "only a bitmap placeholder prints dashed" do
    dashes = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(Array.from(m.renderSheet(document, m.buildSheets([
        { b: [0, 0, 30, 20],  k: 1, i: 1, o: 1, p: [[0, 0], [30, 0], [30, 20], [0, 20], [0, 0]] },
        { b: [40, 0, 70, 20], k: 1, i: 0, o: 2, p: [[40, 0], [70, 0], [70, 20], [40, 20], [40, 0]] },
      ], m.PAPERS.Letter).pages[0], #{META})
       .querySelectorAll("polygon, polyline")).map((n) => n.getAttribute("stroke-dasharray")))
    JS

    assert_equal [ "4 3", nil ], dashes
  end

  # ONE TRANSFORM MOVES THE WHOLE PAGE, AND NOTHING ABOVE THIS LINE CAN SEE IT AT ALL. Every
  # assertion in this section reads `points`, which is written in FILE coordinates and is
  # byte-identical whether the page is translated, translated by the wrong amount, or not
  # translated at all — so deleting the `transform` outright is GREEN through all six of them.
  # The user-visible result is geometry drawn at its raw file coordinates: a bracket at x 500 in a
  # 600 mm laser sheet lands 490 mm from where it belongs — 284.1 mm past the right edge of a
  # 215.9 mm page — and the sheet prints blank. Nothing errors and nothing logs: this repo's
  # dominant failure shape.
  #
  # A SELECTION OFFSET FROM THE ORIGIN, for the reason Task 3's filter test gives: at (0, 0) the
  # datum shift is a no-op and `translate(10 17)` is indistinguishable from a hard-coded margin.
  # TWO SHAPES, because "every contour shares one parent" is trivially true of one.
  #
  # THE EXPECTATION COMES OFF THE PAGE OBJECT, not from a literal — whether those numbers are
  # right is Task 2's assertion and is pinned there; what is pinned HERE is that the renderer
  # applies them, once, to an ancestor of every contour.
  #
  # MUTATION-CHECKED SEVEN WAYS, AND EACH FAILS A DIFFERENT ASSERTION, which is how the four below
  # are shown to carry independent weight rather than restate each other:
  #
  #   transform deleted             transform:    Expected: "translate(-490 -283)" Actual: nil
  #   moved onto each contour       transform:    Expected: "translate(-490 -283)" Actual: nil
  #   translateX/Y swapped          transform:    Actual: "translate(-283 -490)"
  #   on the group AND each contour movedShapes:  Expected: 0 Actual: 2  (a DOUBLE move — the only
  #                                 one of the seven the transform assertion cannot see, since the
  #                                 group still carries exactly the right string)
  #   a <g> per contour             parents:      Expected: 1 Actual: 2
  #   BOTH <g>s dropped and the     parentTag:    Expected: "g" Actual: "svg". Stated as "transform
  #   transform put on the root                   on the root <svg>" this row was wrong: KEEPING the
  #   <svg>                                       groups and merely also transforming the root is a
  #                                               different mutation with rows 1-2's signature
  #                                               (Actual: nil), so the row would have been proving
  #                                               nothing the first two rows had not already proved.
  #   only the first shape emitted  contours:     Expected: 2 Actual: 1
  test "one transform moves the whole page and every contour rides on it" do
    out = JSON.parse(in_print_sheet(<<~JS))
      (() => {
        const page = m.buildSheets([
          { b: [500, 300, 560, 340], k: 1, i: 0, o: 1,
            p: [[500, 300], [560, 300], [560, 340], [500, 340], [500, 300]] },
          { b: [600, 300, 660, 340], k: 1, i: 0, o: 2,
            p: [[600, 300], [660, 300], [660, 340], [600, 340], [600, 300]] },
        ], m.PAPERS.Letter).pages[0]
        const svg = m.renderSheet(document, page, #{META})
        const nodes = Array.from(svg.querySelectorAll("polygon, polyline"))
        return JSON.stringify({
          contours: nodes.length,
          parents: new Set(nodes.map((n) => n.parentNode)).size,
          parentTag: nodes.length ? nodes[0].parentNode.tagName : null,
          transform: nodes.length ? nodes[0].parentNode.getAttribute("transform") : null,
          expected: `translate(${page.translateX} ${page.translateY})`,
          movedShapes: nodes.filter((n) => n.hasAttribute("transform")).length,
          translateX: page.translateX,
        })
      })()
    JS

    assert_equal 2, out["contours"]
    # GUARDING THIS TEST'S OWN PREMISE, not re-testing buildSheets — hence no mutation of its own.
    # At translate(10 17) a deleted datum shift looks exactly like a correct one, so if this ever
    # reads 10 the six assertions built on it have quietly stopped meaning anything.
    assert_in_delta(-490.0, out["translateX"], 0.001, "MARGIN (10) less the selection's x0 (500)")

    assert_equal 1, out["parents"], "every contour hangs off ONE node, so one move carries them all"
    assert_equal "g", out["parentTag"]
    assert_equal out["expected"], out["transform"]
    # PER PAGE, NEVER PER SHAPE. Moving the same translate onto each contour draws an identical
    # sheet today and stops doing so the moment anything is nested, sorted or reparented — and it
    # is the spelling that invites a per-shape VALUE, which is what actually stacks two parts on
    # top of each other.
    assert_equal 0, out["movedShapes"]
  end

  # ---- lib/print_sheet.js: sheet furniture -----------------------------------------------------
  #
  # THE PLAN'S 3x1 INPUT COULD NOT SEE HALF OF THIS SECTION, so every test below that needs a
  # tiled job uses 3 x 2. With one row, `row + 1` is always 1 and `rows` is always 1, so
  # `Sheet ${col + 1},1` and `of ${cols}x1` hard-coded are both GREEN — measured by running the
  # plan's four tests verbatim against each mutation, and both are RED here. A gauge guarded by
  # `if (row === 0)` is worse still: under one row that guard is unconditionally TRUE, so the
  # emitted DOM is byte-IDENTICAL to correct code and no test over a 3 x 1 job can exist that
  # sees it, however written. Here it is RED on two tests ("sheet 3: the bar labelled 100 mm",
  # "sheet 3 lost its ruler label"). 3 x 2 is the smallest job in which the column index, the row
  # index and the two counts are four different numbers.
  #
  #   cols = ceil((400 - 10) / 185.9) = 3, rows = ceil((300 - 10) / 220.4) = 2 -> 6 pages.
  TILED_3X2 = <<~JS.freeze
    [{ b: [0, 0, 400, 300], k: 1, i: 0, o: 1, p: [[0, 0], [400, 300]] }]
  JS

  # ON EVERY SHEET, not only the first. Pages get separated, and a partial print — someone
  # reprinting sheet 3 alone — is exactly when a scale error most needs catching.
  #
  # THIS ASSERTS THE LABELS ONLY; the gauge's GEOMETRY is asserted, also per sheet, further down.
  # The two are separable defects and the separation is not academic: wrapping only the ruler's
  # <line> elements in `if (col === 0 && row === 0)` while leaving their labels alone is GREEN
  # here — five sheets then carry the words "100 mm — check with a ruler" with no ruler under
  # them, which is worse than carrying neither.
  test "every sheet carries the calibration gauge labels and the do-not-scale warning" do
    texts = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(#{TILED_3X2}, m.PAPERS.Letter).pages.map((p) =>
        Array.from(m.renderSheet(document, p, #{META}).querySelectorAll("text"))
          .map((t) => t.textContent)))
    JS

    assert_equal 6, texts.length

    # A TRIPWIRE FOR A FUTURE TEXT, AND IT RUNS FIRST ON PURPOSE. Nothing this task prints as text
    # is derived from the content box, whose height serializes as 230.39999999999998 — SVG does not
    # care about that in an attribute and a reader cannot read it in a label. Placed AFTER the loop
    # below it would never execute: minitest ends a test at its first failed assertion, and any
    # float appended to one of these labels breaks that loop's exact string first. Verified — the
    # mutation was run in both orders. MUTATION-CHECKED by appending ` ${content.h}` to the ruler
    # label: RED, "a printed number needs rounding: \"100 mm — check with a ruler
    # 230.39999999999998\"". `sizeLabel` returns null throughout this file, so every string here is
    # furniture and none of them may carry a raw float.
    texts.flatten.each do |t|
      refute_match(/\d\.\d{3,}/, t, "a printed number needs rounding: #{t.inspect}")
    end

    texts.each_with_index do |sheet, i|
      assert_includes sheet, "100 mm — check with a ruler", "sheet #{i} lost its ruler label"
      assert_includes sheet, "20 mm", "sheet #{i} lost its calibration square label"
      assert_includes sheet, "Print at 100% — do NOT scale to fit", "sheet #{i} lost its warning"
    end
  end

  # GRID COORDINATES, not "Sheet 2 of 6": when you are taping six sheets together the column and
  # row tell you WHERE the sheet goes, which a running count does not.
  #
  # ASSERTED AS THE WHOLE ORDERED LIST rather than three assert_matches, so it pins row-major
  # emission at the same time — `Sheet 1,2` arriving second would mean the pages come out of the
  # printer in an order the labels contradict.
  test "a tiled job labels each sheet by grid position" do
    texts = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(#{TILED_3X2}, m.PAPERS.Letter).pages.map((p) =>
        Array.from(m.renderSheet(document, p, #{META}).querySelectorAll("text"))
          .map((t) => t.textContent)))
    JS

    assert_equal [ "1,1", "2,1", "3,1", "1,2", "2,2", "3,2" ].map { |g| "Sheet #{g} of 3×2" },
                 texts.map { |sheet| sheet.find { |t| t.start_with?("Sheet") } }
  end

  # AND A SINGLE SHEET CARRIES NO LABEL AT ALL — there is nothing to register against, so it would
  # be noise. This is the half a naive implementation gets wrong by printing "Sheet 1,1 of 1×1".
  test "a single sheet carries no page label" do
    texts = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(Array.from(m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0], #{META})
        .querySelectorAll("text")).map((t) => t.textContent))
    JS

    refute(texts.any? { |t| t.include?("Sheet") }, "a single sheet has nothing to register against")
    # THE PREMISE, because "no label" is satisfied exactly as well by no furniture at all — and a
    # `furniture()` call dropped from renderSheet outright would otherwise pass this test.
    assert_includes texts, "100 mm — check with a ruler", "the rest of the furniture is still there"
  end

  test "the header names the file and the date" do
    texts = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(Array.from(m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0], #{META})
        .querySelectorAll("text")).map((t) => t.textContent))
    JS

    assert_includes texts, "plate.lbrn2 · 2026-08-19"
  end

  # THE HEADER CARRIES A LIBRARY FILENAME, WHICH IS USER-CONTROLLED — and on a NAS-scanned share it
  # can legitimately contain `<`, because the scanner indexes whatever names the filesystem holds.
  # The sheet is rendered into a same-origin iframe (Task 8), so building the header as markup is
  # an injection into this app's own origin. `el`'s text door is what makes `textContent` the only
  # spelling available; this is the test that says why it exists rather than merely that it fires.
  #
  # MUTATION-CHECKED TWO WAYS, each actual copied out of the run. Deleting the door
  # (`if (text != null) node.textContent = text`) is RED in SIX tests, every textContent coming
  # back "" — this one, four above it, and the header-placement one below it. Spelling it `node.innerHTML = text` is RED HERE ALONE, on the
  # element list: "Expected [\"clipPath\", \"rect\", \"g\", \"g\", \"polygon\", ... \"text\",
  # \"script\", \"v2\", \"text\", ...] to not include \"script\"" — two elements minted out of a
  # filename, inside a <text> node, in the app's own origin. The header equality behind it would
  # read "alert(1)bracket.svg · 2026-08-19", the tags having been eaten by the parser.
  test "a filename that looks like markup prints as text, not as markup" do
    out = JSON.parse(in_print_sheet(<<~JS))
      (() => {
        const svg = m.renderSheet(document,
          m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0],
          { name: "<script>alert(1)</script>bracket<v2>.svg", date: "2026-08-19",
            sizeLabel: () => null })
        return JSON.stringify({
          header: svg.querySelector("text").textContent,
          // THE WHOLE SUBTREE, not a search for <script>: an innerHTML spelling parses `<v2>`
          // into an element too, and a sheet quietly carrying half the filename as unknown
          // elements is the same defect with a less alarming name.
          elements: Array.from(svg.querySelectorAll("*")).map((n) => n.tagName).join(","),
        })
      })()
    JS

    # THE REFUTES RUN FIRST for the reason the tripwire above does: an innerHTML spelling loses
    # part of the filename from `header` too, so with the equality first these two would never
    # execute for the mutation they exist for.
    elements = out["elements"].split(",")
    refute_includes elements, "script", "no element minted from the filename"
    refute_includes elements, "v2", "and not the innocuous-looking half of it either"
    # TRUNCATED, because this name is 40 characters and A4's budget is 15 — and the head and tail
    # it keeps still carry `<` and `>`, which is what the assertion needs. An innerHTML spelling
    # eats them exactly the same way (verified: the refutes above still fire), so the truncation
    # neither weakens this test nor is weakened by it.
    assert_equal "<script>…v2>.svg · 2026-08-19", out["header"]
  end

  # `el` HAS A SILENT MIS-CALL MODE AND THIS IS THE ONLY THING THAT CAN SEE IT. A string in the
  # `attrs` slot — `el(doc, "text", "Sheet 1,1 of 2×1")`, one dropped `{}` away from the five
  # sites this task adds — was expected to throw InvalidCharacterError, since an attribute name
  # cannot begin with a digit. It does not: Object.entries walks the string's own indices and
  # setAttribute accepts "0" as a name.
  #
  # MEASURED, by deleting the guard and reading what this test then returns verbatim:
  #
  #   NO THROW: <text 0="S" 1="h" 2="e" 3="e" 4="t" 5=" " 6="1" 7="," 8="1" 9=" " 10="o" 11="f"
  #             12=" " 13="2" 14="×" 15="1"></text>
  #
  # — sixteen junk attributes, no text content, an empty <text> that renders nothing on a page
  # that is otherwise perfectly formed. Nothing thrown, nothing logged.
  #
  # `el` IS EXPORTED FOR THIS TEST AND FOR NO OTHER REASON — nothing reachable through
  # renderSheet can put a string in that slot, so without the export this would be a guard that
  # has never failed, which CLAUDE.md §15 says is a guard that has not been shown to work.
  test "el refuses a string in the attribute slot rather than minting junk attributes" do
    out = in_print_sheet(<<~JS)
      (() => {
        try {
          const n = m.el(document, "text", "Sheet 1,1 of 2×1")
          return "NO THROW: " + n.outerHTML
        } catch (e) { return "THREW: " + e.message }
      })()
    JS

    assert_match(/\ATHREW: /, out, "a string in the attrs slot must not mint junk attributes")
    assert_match(/attribute map/, out, "and must say which argument is wrong")
  end

  # WHERE THE FURNITURE IS DRAWN, WHICH NOTHING ABOVE THIS LINE CAN SEE. Every assertion in this
  # section so far reads `textContent`, which is byte-identical whether the gauge is in the
  # reserved strip, on top of the geometry, off the paper, or inside the clip group where it is
  # erased entirely. Four separate defects, all invisible, all of them a sheet that prints wrong.
  #
  # AND PER SHEET, for the geometry as well as the labels. `:scope >` is itself an assertion, not
  # a convenience: furniture appended to the clipped group or to the page transform still answers
  # `querySelectorAll("line")` and still carries every label, while the gauge — which sits BELOW
  # the content box — is clipped away to nothing.
  #
  # THE EXPECTATION IS BUILT FROM THE CONTENT BOX'S FOUR NUMBERS, which have their own test at the
  # top of this file, not re-derived by calling contentBox() here. CLAUDE.md §14e: a fake that
  # shares the code's misunderstanding confirms it.
  #
  # MUTATION-CHECKED TWELVE WAYS, all RED here: the trim loop deleted; both crosshair arms drawn
  # horizontal; the crosshairs moved to the PRINTABLE box's corners; the bar drawn 90 mm; the tick
  # step 10 -> 20; every tick drawn at content.x; the ticks flattened onto the bar (`by - 3` ->
  # `by`); the square 15 mm wide; the square placed at `right` instead of `right - 20`; its
  # `fill: "none"` dropped; `stroke-width` spelled "0.2mm"; and the whole gauge moved to
  # `top + 14`. Three more are RED on this test among others: the furniture appended inside the
  # clip group, the `furniture()` call deleted, and the gauge guarded by `row === 0`.
  test "the furniture is drawn on the paper outside the clip, and identically on every sheet" do
    out = JSON.parse(in_print_sheet(<<~JS))
      (() => {
        const num = (n, as) => as.map((a) => Number(n.getAttribute(a)))
        const furniture = (svg) => ({
          lines: Array.from(svg.querySelectorAll(":scope > line"))
                      .map((n) => num(n, [ "x1", "y1", "x2", "y2" ])),
          rects: Array.from(svg.querySelectorAll(":scope > rect"))
                      .map((n) => num(n, [ "x", "y", "width", "height" ])),
        })
        const sheets = (paper) => m.buildSheets(#{TILED_3X2}, paper).pages.map((p) =>
          m.renderSheet(document, p, #{META}))
        const svgs = sheets(m.PAPERS.Letter)
        return JSON.stringify({
          nested: svgs[0].querySelectorAll(
            "[clip-path] line, [clip-path] rect, [clip-path] text, " +
            "[transform] line, [transform] rect, [transform] text").length,
          strokes: Array.from(svgs[0].querySelectorAll(":scope > line, :scope > rect"))
            .map((n) => n.getAttribute("stroke") + " " + n.getAttribute("stroke-width")),
          fills: Array.from(svgs[0].querySelectorAll(":scope > rect"))
                      .map((n) => n.getAttribute("fill")),
          pages: svgs.map(furniture),
          // A SECOND PAPER, for the reason the scale test two sections up gives: against Letter
          // alone every number below can be a hard-coded Letter literal and stay green.
          a4: furniture(sheets(m.PAPERS.A4)[0]),
        })
      })()
    JS

    assert_equal 0, out["nested"],
                 "furniture inside the clip or the page transform is erased or moved off paper"

    # THE EXPECTATION IS A FUNCTION OF THE CONTENT BOX'S FOUR EDGES, and it is applied to TWO
    # papers below. contentBox(Letter) is x 10..205.9, y 17..247.4 — pinned by its own test at the
    # top of this file; contentBox(A4) is x 10..200, y 17..265 by the same arithmetic on §MARGIN,
    # HEADER_H and CALIB_H (210 - 20 = 190 wide, 297 - 20 - 7 - 22 = 248 tall). Written out rather
    # than obtained by calling contentBox() here: CLAUDE.md §14e, a fake that shares the code's
    # misunderstanding confirms it.
    expected = lambda do |x0, y0, x1, y1|
      by = y1 + 14                                      # the calibration bar's baseline
      trim = [ [ x0, y0 ], [ x1, y0 ], [ x0, y1 ], [ x1, y1 ] ].flat_map do |x, y|
        [ [ x - 4, y, x + 4, y ], [ x, y - 4, x, y + 4 ] ]
      end
      ticks = (0..100).step(10).map { |i| [ x0 + i, by, x0 + i, by - 3 ] }
      [ trim + [ [ x0, by, x0 + 100, by ] ] + ticks, [ [ x1 - 20, y1 + 1, 20.0, 20.0 ] ] ]
    end
    x0, y0, x1, y1 = 10.0, 17.0, 205.9, 247.4
    expected_lines, expected_rects = expected.call(x0, y0, x1, y1)

    out["pages"].each_with_index do |f, i|
      lines = f["lines"].map { |l| l.map { |v| v.round(4) } }
      rects = f["rects"].map { |r| r.map { |v| v.round(4) } }

      # THE GAUGE MUST NOT LIE, and these two come FIRST so a bar labelled "100 mm" that is 90 mm
      # long fails with a legible number rather than inside a twenty-row array diff. A gauge that
      # is wrong is strictly worse than no gauge: it certifies a mis-scaled print.
      bar = lines.select { |l| l[1] == l[3] }.max_by { |l| (l[2] - l[0]).abs }
      assert_equal 100.0, (bar[2] - bar[0]).round(4), "sheet #{i}: the bar labelled 100 mm"
      assert_equal 1, rects.length, "sheet #{i}: one calibration square"
      assert_equal [ 20.0, 20.0 ], rects[0][2..3], "sheet #{i}: the square labelled 20 mm"

      # AND THEN EVERY LINE, IN PLACE. Nothing above distinguishes the eleven ticks from each
      # other, or from eleven lines drawn on top of one another at x0.
      assert_equal expected_lines, lines, "sheet #{i}: trim crosshairs, then the bar, then 11 ticks"
      assert_equal expected_rects, rects, "sheet #{i}: the calibration square"
    end

    # AND THE SAME FURNITURE ON A DIFFERENT PAPER. Every number above is a Letter number, so
    # `const right = 205.9` and `const bottom = 247.4` — the shape the scale test records for the
    # <svg> attributes — is GREEN through the whole loop. MUTATION-CHECKED: RED here alone.
    # The bar is still 100 mm and the square still 20 mm; what moves is where they are anchored.
    a4_lines, a4_rects = expected.call(10.0, 17.0, 200.0, 265.0)
    assert_equal a4_lines, out["a4"]["lines"].map { |l| l.map { |v| v.round(4) } }, "A4"
    assert_equal a4_rects, out["a4"]["rects"].map { |r| r.map { |v| v.round(4) } }, "A4"

    # BLACK AND HAIRLINE, LIKE THE CONTOURS. A calibration square with SVG's DEFAULT fill is a
    # solid black 20 mm slab; nothing else in the file can see that, because `fill="none"` is
    # still present on the contours it asserts.
    #
    # LAST, NOT FIRST. These two are the only assertions here whose failure carries no coordinate,
    # and `strokes` changes length for ANY defect that changes the element count — so ahead of the
    # loop it pre-empted the legible numbers with a twenty-against-twenty-one diff of identical
    # strings, defeating the ordering the loop's own comment argues for. Verified with
    # `i <= 100` -> `i < 100`: red either way, legible only in this order.
    assert_equal [ "none" ], out["fills"], "a filled calibration square is a 20 mm ink blot"
    assert_equal [ "#000 0.2" ] * 21, out["strokes"], "20 lines and the square, all hairline black"
  end

  # THE HEADER'S THREE TEXTS SIT AT THE LEFT, THE CENTRE AND THE RIGHT of the content box, and the
  # anchor is half of that claim: at the default `start`, the centred warning runs off the right
  # edge of the paper and the sheet label runs off it entirely, while every textContent assertion
  # above stays green.
  #
  # FONT-SIZE IS THE OTHER HALF. Omit it and SVG's initial value is 16px, which at one user unit
  # per millimetre is 16 mm tall — the header alone is then more than twice the 7 mm strip
  # reserved for it and prints across the geometry.
  #
  # THE HEADER HAS NO `text-anchor` AT ALL, which is the one call site `el`'s nullish attribute
  # guard exists for. Delete that guard and it becomes `text-anchor="undefined"` — an invalid
  # value, so SVG falls back to the initial `start` and the sheet still LOOKS exactly right
  # (measured: the rendered bbox x is byte-identical either way). The `nil` in the anchor tuple
  # below is what sees it, and it is a COMPLETE instrument: getAttribute answers null only when the
  # attribute is absent, and an empty attribute reads "" rather than nil. An earlier draft carried
  # a `refute ... hasAnchor` line as well, described in this comment as "the only thing that can
  # see it" — both halves were wrong. It was redundant with the tuple, and being placed AFTER the
  # tuple it never executed at all: the mutation fails the tuple, minitest ends the test there.
  # A second assertion that cannot run is not a second guard (CLAUDE.md §15).
  test "the header line places its three texts at the left, centre and right, at 3 mm" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(Array.from(m.renderSheet(document,
        m.buildSheets(#{TILED_3X2}, m.PAPERS.Letter).pages[1], #{META})
        .querySelectorAll(":scope > text")).map((n) => ({
          x: Number(n.getAttribute("x")), y: Number(n.getAttribute("y")),
          anchor: n.getAttribute("text-anchor"),
          size: n.getAttribute("font-size"), text: n.textContent,
        })))
    JS

    # Page 1 of the 3 x 2 job — column 2, row 1 — so the sheet label is present.
    assert_equal [ "plate.lbrn2 · 2026-08-19", "Print at 100% — do NOT scale to fit",
                   "Sheet 2,1 of 3×2", "100 mm — check with a ruler", "20 mm" ],
                 out.map { |t| t["text"] }
    # content.x; the content box's own centre (which is also the paper's, margins being equal);
    # its right edge. All three on the header baseline at MARGIN + 4. Then the two gauge labels.
    assert_equal [ [ 10.0, 14.0, nil ], [ 107.95, 14.0, "middle" ], [ 205.9, 14.0, "end" ],
                   [ 60.0, 265.9, "middle" ], [ 195.9, 259.4, "middle" ] ],
                 out.map { |t| [ t["x"].round(4), t["y"].round(4), t["anchor"] ] }
    assert_equal [ "3" ] * 5, out.map { |t| t["size"] }, "3 user units is 3 mm"
  end

  # THE HEADER'S LEFT TEXT IS THE ONLY ARBITRARY-LENGTH THING ON THE SHEET, AND UNTRUNCATED IT
  # OVERPRINTS THE WARNING — on the one sheet whose entire purpose is to say "do NOT scale to fit".
  # Measured on A4 before the fix, as rendered bbox right edges: `plate.lbrn2 · 2026-08-19` ended at
  # 41.83 (fine), `Rev C bracket assembly plate final.lbrn2 · …` at 81.48 against a warning starting
  # at 81.28 (collides), and a 70-character name at 124.15 (the warning almost wholly overprinted,
  # running on under the sheet label). Forty characters is an ordinary length on a NAS-scanned share.
  #
  # A4, NOT LETTER. 190 mm is the narrowest content box PAPERS offers, so it is the paper that
  # fails first and the only one worth pinning.
  #
  # AN ALL-`@` NAME, NOT THE ALL-`W` THE OBVIOUS GUESS SUGGESTS. Measured in this same browser at
  # 3 mm sans-serif, `@` advances 3.0432 mm and `W` only 2.8296 — a budget tuned on `W` is 7% short
  # of the true worst case, which for a filename (arbitrary user input) is the case that matters.
  # `widest` asserts that rather than assuming it: the day a CI font makes some other glyph widest,
  # this input stops being pathological and this line says so instead of the test quietly weakening.
  #
  # THE ASSERTION IS GEOMETRIC, and it validates all three of the module's measured constants at
  # once (WORST_GLYPH, DATE_GLYPH, WARNING_HALF) without exporting any of them — what matters is
  # not what they are but that the ink lands clear of the warning.
  test "a pathological filename is truncated rather than printed over the do-not-scale warning" do
    out = JSON.parse(in_print_sheet(<<~JS))
      (() => {
        const svg = m.renderSheet(document,
          m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.A4).pages[0],
          { name: "@".repeat(70), date: "2026-08-19", sizeLabel: () => null })
        document.body.appendChild(svg)
        try {
          const t = svg.querySelectorAll(":scope > text")
          const box = (n) => { const b = n.getBBox(); return [ b.x, b.x + b.width ] }
          // The widest printable-ASCII advance in THIS browser, so the input above is provably
          // the worst case rather than a plausible-looking one.
          const probe = document.createElementNS("http://www.w3.org/2000/svg", "text")
          probe.setAttribute("font-size", 3); probe.setAttribute("font-family", "sans-serif")
          svg.appendChild(probe)
          let widest = null, widestW = 0
          for (let c = 33; c < 127; c++) {
            probe.textContent = String.fromCharCode(c).repeat(20)
            const w = probe.getComputedTextLength() / 20
            if (w > widestW) { widestW = w; widest = String.fromCharCode(c) }
          }
          return JSON.stringify({
            widest, widestW, worstGlyph: m.WORST_GLYPH,
            left: box(t[0]), warning: box(t[1]), header: t[0].textContent,
          })
        } finally { svg.remove() }
      })()
    JS

    assert_equal "@", out["widest"], "the pathological input must be the browser's widest glyph"
    # THE BUDGET'S OWN CONSTANT AGAINST THE MEASUREMENT, because the geometric assertion below
    # cannot see it: the truncated header clears the warning by ~5.7 mm, so a budget tuned on `W`
    # (2.83) passes that test while being 7% short of the worst case a filename can actually
    # contain. Slack in the layout is safety and should not be spent to sharpen a test; this pins
    # the constant directly instead.
    assert_operator out["widestW"], :<=, out["worstGlyph"],
                    "WORST_GLYPH must not be under-measured"
    # THE COLLISION ITSELF. The left text's right edge must sit left of the warning's left edge —
    # not merely "somewhere on the paper", which an overprinted header satisfies perfectly.
    assert_operator out["left"][1], :<, out["warning"][0],
                    "the header ran into #{out['warning'].inspect}: #{out['header'].inspect}"
    # AND THE WARNING IS STILL WHERE IT BELONGS, so the assertion above cannot be satisfied by a
    # warning that was itself pushed off to the right.
    assert_in_delta 105.0, (out["warning"][0] + out["warning"][1]) / 2, 0.5,
                    "the warning stays centred on A4's content box"
  end

  # TRUNCATED IN THE MIDDLE, KEEPING THE EXTENSION. A maker telling `panel-v11.lbrn2` from
  # `panel-v12.svg` needs the tail as much as the head, so a trailing "…" — the obvious spelling,
  # and what `text-overflow: ellipsis` would do — cuts off exactly the discriminating end.
  #
  # THE DATE IS NEVER TRUNCATED, and the short name is left ALONE: a budget that ellipsised
  # `plate.lbrn2` would be a regression dressed as a fix. Both spellings of the mistake are pinned
  # here, and neither is visible to the geometric test above — an implementation that simply cut
  # the string short would clear the warning just as well.
  test "a long filename keeps its head and its extension, and a short one is left alone" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify([ "plate.lbrn2", "harbor-number-v4.svg",
                       "Rev C bracket assembly plate final.lbrn2" ].map((name) =>
        m.renderSheet(document, m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.A4).pages[0],
          { name, date: "2026-08-19", sizeLabel: () => null })
         .querySelector(":scope > text").textContent))
    JS

    assert_equal [ "plate.lbrn2 · 2026-08-19",
                   "harbor-…-v4.svg · 2026-08-19",
                   "Rev C b…l.lbrn2 · 2026-08-19" ], out
  end

  # EVERY PIECE OF FURNITURE INSIDE THE STRIP RESERVED FOR IT, READ OFF THE RENDERED BBOX so the
  # text's own ascender and descender count rather than its baseline.
  #
  # THIS IS WHAT KEEPS THE LAYOUT'S EIGHT OFFSETS HONEST AGAINST `HEADER_H` AND `CALIB_H`. The
  # gauge's `bottom + 14`, `by - 3`, `by + 4.5`, `bottom + 1` and `bottom + 12` are a designed
  # layout, not a formula, so nothing in the code makes them agree with the 22 mm the strip
  # reserves — shrink CALIB_H and the arithmetic still runs, the sheet still renders, and the ruler
  # simply prints off the bottom of the paper. contentBox's own comment argues at length against
  # exactly this shape of N-values-that-must-agree; a formula was the other option and is weaker,
  # because a formula can be wrong in the same silence. The bounds are read from the module's OWN
  # exported constants, so they are the definition rather than a second copy of it.
  test "the header sits in the header strip and the gauge in the calibration strip" do
    out = JSON.parse(in_print_sheet(<<~JS))
      (() => {
        const paper = m.PAPERS.A4, content = m.contentBox(paper)
        const svg = m.renderSheet(document,
          m.buildSheets(#{TILED_3X2}, paper).pages[1], #{META})
        document.body.appendChild(svg)
        try {
          const items = Array.from(svg.querySelectorAll(":scope > line, :scope > rect, :scope > text"))
            .map((n) => { const b = n.getBBox(); return { top: b.y, bottom: b.y + b.height } })
          const bottom = content.y + content.h
          // STRICTLY inside, and that is not a nicety: the trim crosshairs sit exactly ON the
          // content edges, so a horizontal arm's zero-height bbox has bottom === content.y and a
          // bottom arm's has top === bottom. With `<=`/`>=` they join the strips they straddle and
          // the two counts below read 5 and 17.
          const header = items.filter((i) => i.bottom < content.y)
          const gauge  = items.filter((i) => i.top > bottom)
          return JSON.stringify({
            headerCount: header.length, gaugeCount: gauge.length,
            headerTop: Math.min(...header.map((i) => i.top)),
            headerBottom: Math.max(...header.map((i) => i.bottom)),
            gaugeBottom: Math.max(...gauge.map((i) => i.bottom)),
            limits: [ m.MARGIN, m.MARGIN + m.HEADER_H, paper.h - m.MARGIN ],
          })
        } finally { svg.remove() }
      })()
    JS

    # THE COUNTS ARE THE PREMISE: a piece of furniture that escaped its strip entirely would drop
    # out of both filters, and "everything I found is in bounds" is trivially true of nothing.
    assert_equal 3, out["headerCount"], "filename, warning, sheet label"
    assert_equal 15, out["gaugeCount"], "the bar, 11 ticks, two labels and the square"
    margin, header_bottom, page_bottom = out["limits"]
    assert_operator out["headerTop"], :>=, margin, "the header must not print into the paper margin"
    assert_operator out["headerBottom"], :<=, header_bottom,
                    "the header must not print into the content box"
    assert_operator out["gaugeBottom"], :<=, page_bottom,
                    "the gauge must not print into the bottom paper margin"
  end

  private

    def in_print_sheet(body)
      visit file_path(@nested_id) unless page.current_path == file_path(@nested_id)
      result = page.evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1];
        import("lib/print_sheet")
          .then((m) => done(#{body}))
          .catch((e) => done("ERROR: " + (e && e.message ? e.message : String(e))));
      JS
      raise result if result.is_a?(String) && result.start_with?("ERROR:")
      result
    end

    # The geometry preview, rendered through the REAL renderer against the REAL fixture bytes, in
    # this process rather than by the job runner. A system test cannot wait for the job:
    # ActiveJob's test adapter never runs what it queues, and `perform_enqueued_jobs`' block form
    # only inlines jobs enqueued DURING the block — the geometry job is enqueued by the browser's
    # own first poll, inside the server thread. `perform_now` sidesteps the adapter and is
    # deterministic, while still being the real pipeline.
    def render_geometry!(node_id, filename)
      token = FileLayer.current.stat(@user, node_id: node_id).content_token
      preview = Maker::Previews::Enqueue.call(user: @user, node_id: node_id, name: filename,
                                              version_id: token, kind: "geometry")
      Maker::GeneratePreviewJob.perform_now(preview.id, filename: filename)
      assert_equal "ready", preview.reload.status, "the geometry payload must be ready to measure"
    end
end
