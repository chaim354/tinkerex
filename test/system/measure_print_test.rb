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
