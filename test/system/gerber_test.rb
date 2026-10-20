require "application_system_test_case"
require "support/gerber_fixture"

# tracespace ACTUALLY RENDERING a Gerber in a real browser. Everything else about the `:gerber`
# branch — which extensions reach it, the data attributes, the two project pages' absence of a
# viewer, the `.gbrjob` rules — is request-level (test/integration/web/gerber_preview_test.rb, cheap, and
# already covers the parts a browser adds nothing to). What only a browser can see is this file's
# whole subject: does the vendored module load, does it parse real RS-274X and Excellon bytes, does
# it paint geometry rather than an empty `<svg>`, and does the CSP (report-only, but this is the
# check that matters per test/system/README.md) let the module and its fetches through.
#
# THE SVG LANDS IN THE LIGHT DOM, WHICH IS WHY THIS FILE IS SIMPLER THAN kicanvas_test.rb.
# `<kicanvas-embed>` paints into an open shadow root several custom elements deep, so that suite
# needs a recursive `shadowRoot` probe in JS — Capybara's Selenium-backed `:css` finder does not
# pierce shadow boundaries. gerber_controller.js assigns markup it built itself into the stage, so
# a plain `assert_selector ".gerber-viewer svg path"` works and is the honest assertion.
#
# `data-gerber-state="ready"` IS SET AFTER THE RENDER, NOT BEFORE IT — again unlike KiCanvas, whose
# `ready` fires as soon as the embed is inserted and whose own async load then continues. Here the
# fetch, the parse, the plot and the serialisation have all happened by the time the attribute
# lands, so the path assertion below is not a race and needs no poll of its own.
#
# EVERY CASE CLICKS THE LAUNCH BUTTON FIRST. The viewer wears the 3D viewer's chrome (2026-09-06),
# so nothing — not the module, not a byte — loads until "View layer" / "View board" is clicked; a
# `visit` followed straight by the ready assertion would wait out the timeout on a poster. The
# label is the server's: "View layer" for a single file, "View board" for a .gbrjob or a zip.
#
# A DRILL FILE RENDERS A `<circle>`, NOT A `<path>` — measured against the vendored bundle, not
# assumed. So the single-layer assertion below is on a `.gtl`; the board assertions are on a set
# whose copper layers supply the paths. An assertion written as "any Gerber renders a path" would
# be red on a drill file while the viewer worked perfectly.
class GerberTest < ApplicationSystemTestCase
  include GerberFixture

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("gerber@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # MUTATION (§15, test/system/README.md; run for real, output in the PR, then reverted):
  # gerber_controller.js's `await import("tracespace")` changed to `await import("tracespace-x")` —
  # a specifier the importmap has no pin for — reds this test on the `ready` assertion, because the
  # catch block sets data-gerber-state="failed" instead.
  test "a real Gerber layer renders in the browser once launched, and the bar shows its size" do
    node = write_gerber!(name: "board.gtl")

    visit file_path(node.node_id)

    # AT REST: the poster, the launch button, and NO svg — nothing has been fetched.
    assert_selector ".gerber-viewer .mv-launch button", text: "View layer"
    assert_no_selector ".gerber-viewer svg"
    click_button "View layer"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    # GEOMETRY, NOT MERELY AN <svg>. tracespace emits a well-formed empty document for a file it
    # parsed and found nothing in, so asserting the element alone would pass over a viewer that
    # loaded and rendered nothing — this repo's dominant failure shape.
    assert_selector ".gerber-viewer svg path", minimum: 1
    # The stage fills its box rather than rendering at the board's physical size — the controller
    # overrides the attributes tracespace writes, and CSS cannot beat them (see gerber_controller.js).
    assert_equal "100%", find(".gerber-viewer svg")[:width]
    # …and the physical size those attributes carried is what the bar shows, in mm, one decimal.
    # 10.5, NOT 10: the fixture's square is 10 mm on a side and is drawn with a 0.5 mm round
    # aperture, so the copper's outer extent — which is what tracespace sizes the render to —
    # overhangs by 0.25 mm on each edge. Measured against the vendored bundle, not derived.
    assert_selector ".gerber-viewer .model-viewer-dims", text: "10.5 × 10.5 mm"
    assert_no_console_errors
  end

  test "a drill file renders too, as circles rather than paths" do
    node = write_gerber!(name: "board.drl", body: MINIMAL_DRILL)

    visit file_path(node.node_id)
    click_button "View layer"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    assert_selector ".gerber-viewer svg circle", minimum: 1
    assert_no_console_errors
  end

  # THE ZIP IS UNPACKED IN THE BROWSER, AND ONLY A BROWSER CAN SHOW THAT. The server never opens a
  # member (Maker::GerberArchive lists the central directory and stops); everything below the fetch
  # — JSZip loading the archive, pulling the four members the server named, and tracespace
  # identifying each one from its BASENAME three directories down — happens here and nowhere else in
  # the suite. A request test can only assert that the paths were written into the attribute.
  #
  # MUTATION (§15, test/system/README.md; run for real, output in the PR, then reverted):
  # gerber_controller.js's `zip.file(path)` changed to `zip.file(path + "x")` reds this test on the
  # `ready` assertion — the member miss throws and the catch sets data-gerber-state="failed".
  test "a zipped Fusion export renders as a board, and the Bottom toggle swaps the side" do
    node = write_gerber_zip!

    visit file_path(node.node_id)
    click_button "View board"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    # GEOMETRY, NOT MERELY AN <svg> — the copper layers inside the archive supply the paths, which
    # is what proves the members were really extracted and parsed rather than merely fetched.
    assert_selector ".gerber-viewer svg path", minimum: 1
    # THE BOARD'S SIZE, WHICH ONLY A BOARD PAGE CAN PIN. `renderBoard` emits an <svg> carrying no
    # `width` and no `height` at all, so a size read off the PAINTED element was empty on exactly
    # the pages that say "board" while the single-layer case above stayed green — nothing pinned
    # this until now. The controller takes it off the first layer's RENDER instead
    # (gerber_controller.js#sizeFrom).
    #
    # 10.0, AND EVERY DIGIT OF THAT IS EVIDENCE — measured against the vendored bundle, not derived.
    # 10.0 rather than the 10.5 above: this archive carries an OUTLINE (`profile.gbr`), and
    # tracespace sizes a board by its outline's own square — 10 mm on a side, centre line — where a
    # lone layer with no outline is sized by the stroked copper's extent (a 0.5 mm aperture
    # overhanging 0.25 mm on each edge). And 10.0 rather than 0.8: the members are name-ordered, so
    # the FIRST layer here is `drill_1_64.xln`, whose own geometry is one 0.8 mm hit — reading 10.0
    # off it is what proves tracespace places every per-layer render on the one shared board
    # viewBox, which is what makes "the first layer's render" the board's extent in both branches.
    assert_selector ".gerber-viewer .model-viewer-dims", text: "10.0 × 10.0 mm"
    top = find(".gerber-viewer .model-viewer-stage")["innerHTML"]

    find("button[data-gerber-side='bottom']").click

    assert_selector "button[data-gerber-side='bottom'].active"
    bottom = find(".gerber-viewer .model-viewer-stage")["innerHTML"]
    assert_not_equal top, bottom, "the Bottom toggle rendered the same SVG as Top"
    assert_no_console_errors
  end

  # ------------------------------------------------------------------------------------------
  # THE HANDS: pan, zoom, Fit and the per-layer toggles (lib/svg_pan_zoom.js + gerber_controller.js)
  #
  # ALL FOUR ARE BROWSER-ONLY BY CONSTRUCTION. The viewBox is written by a wheel or pointer
  # listener and read back off the live element; the toggles re-compose a tracespace render that
  # only exists after a fetch, a parse and a plot in this browser. There is no server contract to
  # assert against — `gerber_preview_test.rb` covers everything the server says about a board and
  # is deliberately unchanged by this feature.
  #
  # THESE ARE ALSO THE ONLY PIN THE MEASURE VIEW'S PAN/ZOOM HAS. The maths moved out of
  # measure_controller.js into lib/svg_pan_zoom.js on 2026-09-06 so both stages could share one
  # copy; nothing under test/system/*measure* drives a wheel or a drag, so a regression in the
  # shared module shows up HERE and nowhere else. Mutation-checked in both directions: neutering
  # `zoomAbout` reds the zoom case below and leaves every Measure test green.
  #
  # CAPYBARA CANNOT SEND A WHEEL EVENT, so the two helpers at the bottom of this file dispatch
  # real `WheelEvent`/`PointerEvent` objects through `execute_script`. Probed rather than assumed:
  # a synthetic `PointerEvent` with `pointerId: 1` is accepted by `setPointerCapture` in this
  # headless Chrome (it does NOT raise the `NotFoundError` an inactive pointer id can), so the
  # drag below exercises the same capture path a real mouse takes.

  test "the wheel zooms the board about the cursor" do
    node = write_gerber_zip!

    visit file_path(node.node_id)
    click_button "View board"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    _home_x, _home_y, home_w, home_h = view_box
    # THE CURSOR IS A WHOLE PIXEL, AND THE FIXED POINT IS READ THROUGH THE BROWSER'S OWN TRANSFORM.
    # Chrome stores a synthetic WheelEvent's clientX/clientY as whole numbers (measured 2026-09-07,
    # Chrome 148: `new WheelEvent("wheel", { clientX: 100.5 }).clientX` is 100, where a PointerEvent
    # keeps the .5), so a wheel "at the element's centre" lands up to half a pixel off it whenever
    # that centre is fractional — which it became the moment S4-3's Path row made this page tall
    # enough to scroll and the scrollbar took an odd number of pixels off the stage. The earlier
    # spelling asserted the viewBox's CENTRE stayed put within 0.001 mm and failed by 0.0011 mm for
    # exactly that half pixel. This asks the stronger question directly: the user-space point under
    # the pixel the event really carries, before and after, through `getScreenCTM()` — the browser's
    # own client→user mapping, which the module's letterbox arithmetic must agree with.
    cx, cy = wheel_target
    before = user_point_at(cx, cy)
    wheel_on(delta_y: -100, at: [ cx, cy ])
    after = user_point_at(cx, cy)
    _x, _y, w, h = view_box

    assert_operator w, :<, home_w, "a wheel up must narrow the viewBox"
    assert_operator h, :<, home_h, "the aspect ratio must survive a zoom"
    # ZOOMED ABOUT THE CURSOR, WHICH IS THE WHOLE POINT AND THE PART A NAIVE IMPLEMENTATION GETS
    # WRONG: a zoom about the ORIGIN moves this point by a visible distance (mutation-checked: scaling
    # about the viewBox's corner instead moved it 0.65 mm on this 10 mm fixture, four orders of
    # magnitude over the tolerance) and throws the board off screen; a correct one moves it by float
    # noise, hence 1e-4 mm.
    assert_in_delta before[0], after[0], 1e-4, "the point under the cursor must stay put (x)"
    assert_in_delta before[1], after[1], 1e-4, "the point under the cursor must stay put (y)"
    assert_no_console_errors
  end

  test "a drag pans the board" do
    node = write_gerber_zip!

    visit file_path(node.node_id)
    click_button "View board"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    home_x, home_y, home_w, home_h = view_box

    drag_on(dx: 80, dy: 0)
    x, y, w, h = view_box

    # DRAGGING RIGHT MOVES THE CONTENT RIGHT, WHICH MOVES THE viewBox LEFT — the sign is the thing
    # to get wrong, and a pan that inverted it would still change `x` by the right amount.
    assert_operator x, :<, home_x, "dragging right must move the viewBox left"
    assert_in_delta home_y, y, 0.001, "a horizontal drag must not move the view vertically"
    assert_in_delta home_w, w, 0.001, "a pan must not change the zoom"
    assert_in_delta home_h, h, 0.001, "a pan must not change the zoom"
    assert_no_console_errors
  end

  test "Fit returns the view to the whole board" do
    node = write_gerber_zip!

    visit file_path(node.node_id)
    click_button "View board"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    home = view_box

    # MOVED ON BOTH AXES OF THE FEATURE BEFORE FITTING, so this cannot pass on a Fit that only
    # undoes one of them — or on one that never ran, which is what asserting against `home` alone
    # would do on an untouched view.
    wheel_on(delta_y: -100)
    drag_on(dx: 60, dy: 40)
    assert_not_equal home, view_box, "premise: the view must be off home before Fit"

    find(".gerber-viewer .mv-actions .btn", exact_text: "Fit").click

    assert_equal home, view_box, "Fit must return the viewBox the render arrived with"
    assert_no_console_errors
  end

  # THE TOGGLE RE-COMPOSES FROM THE ONE RENDER, so what it must prove is that geometry LEFT the
  # picture — not merely that a button changed colour. The fixture's zipped export carries top
  # copper, bottom copper, an outline and a drill; the Top view draws two paths (the copper and
  # the outline) and one circle (the drill, in the mask), so hiding top copper takes the path
  # count from 2 to 1. Measured against the vendored bundle, not assumed.
  test "a layer toggle hides that layer, and the view survives it" do
    node = write_gerber_zip!

    visit file_path(node.node_id)
    click_button "View board"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    # ZOOMED FIRST, so the "the view survives" assertion below is about a view the toggle could
    # actually have lost. Against the fit view it would pass on a re-render that reset everything.
    wheel_on(delta_y: -100)
    zoomed = view_box
    before = all(".gerber-viewer svg path", visible: :all).size
    assert_operator before, :>, 1, "premise: the board must draw more than one layer's paths"

    find(".gerber-tools .btn", exact_text: "top copper").click

    assert_selector ".gerber-tools .btn[aria-pressed='false']", exact_text: "top copper"
    assert_no_selector ".gerber-tools .btn.active", exact_text: "top copper"
    assert_operator all(".gerber-viewer svg path", visible: :all).size, :<, before,
                    "hiding top copper must remove its geometry from the render"
    assert_equal zoomed, view_box, "a toggle must not throw the reader back to the fit view"
    assert_no_console_errors
  end

  # ✕ IMAGE KEEPS THE RENDER. The way back to the poster drops the SVG, the toggles and the dims —
  # and keeps the parsed board, so the next "View board" is a re-compose and NO fetch: the resource
  # timeline is the witness, counting the blob URL's entries before and after. A re-open that
  # fetched again would pass every other assertion here and cost a twelve-layer board its whole
  # parse for a click that should be free.
  #
  # MUTATION (§15, test/system/README.md; run for real, output in the PR, then reverted):
  # gerber_controller.js's `if (!this.rendered) await this.render()` changed to
  # `await this.render()` reds this test on the fetch count (2 where 1 is expected).
  test "✕ Image returns to the poster, and View board re-opens the render without a fetch" do
    node = write_gerber_zip!

    visit file_path(node.node_id)
    click_button "View board"
    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    assert_selector ".gerber-viewer svg path", minimum: 1
    fetches = -> { page.evaluate_script("performance.getEntriesByType('resource').filter(e => e.name.includes('/blob')).length") }
    assert_equal 1, fetches.call, "the archive is fetched exactly once on launch"

    click_button "✕ Image"

    assert_no_selector ".gerber-viewer.model-viewer--ready"
    assert_no_selector ".gerber-viewer[data-gerber-state]"
    assert_no_selector ".gerber-viewer svg"
    assert_selector ".gerber-viewer .mv-launch button", text: "View board"

    click_button "View board"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    assert_selector ".gerber-viewer svg path", minimum: 1
    assert_equal 1, fetches.call, "re-opening fetched the archive again"
    assert_no_console_errors
  end

  # A RELAUNCH DURING THE FIRST FETCH JOINS IT, AND THE TOGGLES ACT ON THE RENDER THAT WAS PAINTED.
  # Launch, ✕ Image while the archive is still downloading, launch again: without a shared in-flight
  # promise that is two fetches, and whichever render resolved LAST owned `this.rendered` while the
  # stage and the toggles came from the other — a toggle then said "hidden" over a layer still drawn
  # (measured: paths 2 -> 2 where a plain launch gives 2 -> 1), with nothing in the console.
  #
  # THE FETCH IS COUNTED AT THE CALL, NOT ON THE RESOURCE TIMELINE, which is what the ✕ Image case
  # above can use and this one cannot: the stub DEFERS the archive's request rather than slowing it,
  # so a request that has been started but not yet sent has no `performance` entry at all and the
  # count read a superseded second fetch as zero. `window.fetch` being called twice for the archive
  # is exactly the claim, so the stub counts that. Only the archive's own URL is delayed — handing
  # the 1500 ms to whatever call came first would give it to a Turbo prefetch on the way to the
  # button and let the archive arrive at once.
  #
  # THE POLL BEFORE THE TOGGLE IS THE PART TO KEEP. A superseded render lands with NO DOM event of
  # its own — that silence is the bug — so there is nothing for Capybara to wait on, and clicking
  # the toggle the instant the stage is ready would let a late second render arrive after the
  # assertions and pass. The loop gives it every chance: it returns the moment the controller's own
  # render stops being the one the toggles were built from, and otherwise costs its budget once, on
  # a case already waiting on a 1500 ms fetch. Then the invariant is stated directly, and the path
  # count is the user-visible half of the same claim.
  #
  # THE TOGGLE IS PICKED BY LABEL, not `first(...)`: "top copper" is the one the case above measured
  # at 2 -> 1, where the drill's toggle hides circles and would leave the path count flat whether or
  # not the fix is in.
  #
  # THE FETCH COUNT COMES LAST ON PURPOSE, and the order is what gives each half of the fix a
  # failure of its own. Dropping the shared promise breaks BOTH counts — a second fetch AND, when
  # the assignment also moves back inside `render()`, a clobbered render — so with the count
  # asserted first every mutation reds there and the toggle assertions would never be shown to
  # carry weight (§15: mutate to prove each assertion does something). Asserted last, the
  # no-sharing mutation passes the render and toggle checks and fails on the count, while the
  # assignment mutation fails on the render before it ever reaches the count.
  #
  # MUTATION (§15, test/system/README.md; run for real, output in the PR, then reverted):
  # gerber_controller.js's `this.pending ||= this.render()…` changed to a bare `await this.render()`
  # (no sharing) reds this on the fetch count; moving the two assignments back into `render()` ahead
  # of the generation check reds it on the render the toggles were built from, and on the paths.
  test "a relaunch during the first fetch shares it, and a toggle still hides its layer" do
    node = write_gerber_zip!

    visit file_path(node.node_id)
    page.execute_script(<<~JS)
      window.__blobFetches = 0
      const real = window.fetch
      let delayed = false
      window.fetch = (...args) => {
        const url = String(args[0] && args[0].url ? args[0].url : args[0])
        if (!url.includes("/blob")) return real(...args)
        window.__blobFetches++
        const gate = delayed ? Promise.resolve() : new Promise((resolve) => setTimeout(resolve, 1500))
        delayed = true
        return gate.then(() => real(...args))
      }
    JS
    click_button "View board"
    assert_selector ".gerber-viewer[data-gerber-state='loading']"
    click_button "✕ Image"
    assert_selector ".gerber-viewer .mv-launch button", text: "View board"
    click_button "View board"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    assert_selector ".gerber-viewer svg path", minimum: 1

    painted = first(".gerber-tools [data-gerber-layer-id]")["data-gerber-layer-id"]
    deadline = Time.now + 2
    sleep 0.05 until Time.now > deadline || held_render_id != painted
    assert_equal painted, held_render_id,
                 "a superseded render replaced the one the stage and the toggles were built from"

    before = all(".gerber-viewer svg path", visible: :all).size
    find(".gerber-tools .btn", exact_text: "top copper").click

    assert_selector ".gerber-tools .btn[aria-pressed='false']", exact_text: "top copper"
    assert_operator all(".gerber-viewer svg path", visible: :all).size, :<, before,
                    "the toggle said hidden but the layer is still drawn"
    assert_equal 1, page.evaluate_script("window.__blobFetches"),
                 "the relaunch started a second fetch instead of joining the first"
    assert_no_console_errors
  end

  # BACK TO A BOARD PAGE WHOSE VIEWER WAS OPEN RESTS AT THE POSTER. Turbo restores its snapshot of
  # the page with the stage drawn, the toggles built and `data-gerber-state="ready"` set, and then
  # connects a fresh controller that holds no render for any of it. `connect()` resets the element
  # (gerber_controller.js's "AT REST, WHATEVER THE MARKUP SAYS"), and until this test nothing
  # pinned that: no test drove Back. The 3D viewer and the Measure view lacked the same rule (audit
  # 2026-10-19, F-S22-1 and F-S09-1), and their twins of this test use the same helper.
  #
  # GREEN BEFORE THOSE FIXES, deliberately: it pins existing behaviour that had no test. The toggle
  # count is the second half. It shows the relaunch builds ONE set of toggles over ONE stage, and
  # does not add a second set beside the restored one.
  #
  # MUTATION (§15; run for real, output in the PR, then reverted): dropping `this.rest()` from
  # gerber_controller.js's `connect()` reds this on the `--ready` assertion.
  test "Back to a board page whose viewer was open rests at the poster" do
    node = write_gerber_zip!

    visit file_path(node.node_id)
    click_button "View board"
    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    toggles = all(".gerber-tools [data-gerber-layer-id]").size
    assert_operator toggles, :>, 1, "premise: a board builds one toggle per layer"

    back_through_turbo_cache

    assert_no_selector ".gerber-viewer.model-viewer--ready"
    assert_no_selector ".gerber-viewer[data-gerber-state]"
    assert_no_selector ".gerber-viewer .model-viewer-stage svg", visible: :all
    assert_no_selector "[data-gerber-layer-id]", visible: :all
    assert_selector ".gerber-viewer .mv-launch button", text: "View board"

    click_button "View board"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    assert_selector ".gerber-viewer .model-viewer-stage svg", count: 1, visible: :all
    assert_selector ".gerber-tools [data-gerber-layer-id]", count: toggles
    assert_no_console_errors
  end

  # A SINGLE LAYER GETS THE BAR'S OWN ACTIONS AND NOTHING ELSE. There is one layer, so a toggle for
  # it is a button whose only effect is to blank the stage — and the side buttons are absent for the
  # same reason the template omits them (one render, two buttons showing the same picture).
  # A STAGE WITH NO SIZE MUST NOT POISON THE VIEW. Screen -> user-space conversion divides by the
  # element's on-screen scale, and an element with a 0 x 0 rect (a hidden browser pane, a collapsed
  # container, a background tab) has none: the first draft of the shared module put `NaN` into the
  # viewBox on one wheel event over the real Wheel Clock board, and every pan after that stayed NaN
  # until Fit. Measured in the desktop app's hidden preview pane, where the viewport itself is 0 x 0
  # — which is why headless Chrome never saw it. The lib now answers the view's centre for a point
  # on a sizeless element and refuses a non-finite viewBox outright.
  # MUTATION: removing both guards in lib/svg_pan_zoom.js reds this on the finite assertion.
  test "a wheel over a stage collapsed to no size leaves the view finite" do
    node = write_gerber_zip!

    visit file_path(node.node_id)
    click_button "View board"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    home = view_box
    page.execute_script(<<~JS)
      const stage = document.querySelector('.gerber-viewer .model-viewer-stage')
      stage.style.width = "0px"; stage.style.height = "0px"; stage.style.overflow = "hidden"
      stage.querySelector("svg").style.width = "0px"; stage.querySelector("svg").style.height = "0px"
    JS
    assert_equal [ 0, 0 ], page.evaluate_script(<<~JS), "premise: the stage must really be sizeless"
      (() => { const r = document.querySelector('.gerber-viewer svg').getBoundingClientRect(); return [r.width, r.height] })()
    JS

    wheel_on(delta_y: -100)
    drag_on(dx: 40, dy: 10)
    # THE RAW ATTRIBUTE, NOT `view_box`: Ruby's `"NaN".to_f` is 0.0, so a parsed viewBox is finite
    # by construction and an assertion on it passed with `NaN NaN …` on the element (the mutation
    # was caught only by Chrome logging the invalid attribute). The string is the honest witness.
    raw = page.evaluate_script("document.querySelector('.gerber-viewer svg').getAttribute('viewBox')")

    assert_no_match(/NaN|Infinity/, raw, "the viewBox must stay finite on a sizeless stage")
    # The wheel still zooms — about the view's centre, the only point a sizeless element can name.
    assert_operator view_box[2], :<, home[2], "the zoom itself must still apply"
    assert_no_console_errors
  end

  test "the single-layer page offers Fit and no layer toggles" do
    node = write_gerber!(name: "board.gtl")

    visit file_path(node.node_id)
    click_button "View layer"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    assert_selector ".gerber-viewer .mv-actions .btn", exact_text: "Fit"
    assert_no_selector "[data-gerber-layer-id]"
    assert_no_selector "[data-gerber-side]"
    assert_no_console_errors
  end

  private
    # THE ID OF THE FIRST LAYER IN THE RENDER THE CONTROLLER IS HOLDING — the one `compose()` will
    # filter on the next toggle. The toggles carry the ids of the render they were BUILT from, so
    # comparing the two is the whole of "the toggles act on what was painted", and it is reachable
    # only through the live controller: a superseded render swaps `this.rendered` and touches no
    # DOM. `window.Stimulus` is the application object controllers/application.js exports, already
    # used this way by o3dv_test.rb and measure_print_test.rb.
    def held_render_id
      page.evaluate_script(<<~JS)
        (() => {
          const el = document.querySelector(".gerber-viewer")
          const c = window.Stimulus.getControllerForElementAndIdentifier(el, "gerber")
          return c && c.rendered && c.rendered.layers[0].id
        })()
      JS
    end

    # THE VIEWBOX AS FOUR FLOATS. Split on whitespace AND commas, because the SVG spec allows both
    # and a board's box is routinely negative in y (`viewBox="-0.25 -10.25 10.5 10.5"` on this
    # fixture — measured, and the 0.25 is the drawing aperture's overhang), so a
    # number scan that dropped the signs would read a pan as a no-op.
    def view_box(selector = ".gerber-viewer")
      raw = page.evaluate_script(<<~JS)
        (() => {
          const el = document.querySelector("#{selector} svg")
          return el && el.getAttribute("viewBox")
        })()
      JS
      raw.to_s.strip.split(/[\s,]+/).map(&:to_f)
    end

    # A REAL `WheelEvent` AT THE ELEMENT'S CENTRE. Capybara's Selenium driver has no wheel action
    # that can carry a chosen `deltaY` to a chosen point, and the listener reads `deltaY`,
    # `clientX` and `clientY` — so this constructs the event the listener actually sees.
    # `cancelable: true` matters: the handler calls `preventDefault()`, and a non-cancelable event
    # makes that a silent no-op plus a console warning the sweep would catch.
    # `at:` is a WHOLE-PIXEL [clientX, clientY]; without it the element's centre is rounded, because
    # Chrome stores a synthetic WheelEvent's coordinates as whole numbers and an unrounded centre
    # would silently land half a pixel from where the test believes it did (see the zoom test).
    def wheel_on(selector = ".gerber-viewer", delta_y:, at: nil)
      cx, cy = at || wheel_target(selector)
      page.execute_script(<<~JS)
        (() => {
          const el = document.querySelector("#{selector} svg")
          el.dispatchEvent(new WheelEvent("wheel", {
            deltaY: #{delta_y}, clientX: #{cx}, clientY: #{cy},
            bubbles: true, cancelable: true
          }))
        })()
      JS
    end

    # The element's centre, rounded to the pixel a WheelEvent can actually carry.
    def wheel_target(selector = ".gerber-viewer")
      page.evaluate_script(<<~JS)
        (() => {
          const r = document.querySelector("#{selector} svg").getBoundingClientRect()
          return [ Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2) ]
        })()
      JS
    end

    # THE USER-SPACE POINT UNDER A CLIENT PIXEL, BY THE BROWSER'S OWN TRANSFORM. `getScreenCTM()`
    # on the root <svg> folds in the viewBox and preserveAspectRatio, so this is the answer the
    # module's `toUserSpace` must agree with, computed by something that is not the module.
    def user_point_at(cx, cy, selector = ".gerber-viewer")
      page.evaluate_script(<<~JS)
        (() => {
          const svg = document.querySelector("#{selector} svg")
          const pt = svg.createSVGPoint()
          pt.x = #{cx}
          pt.y = #{cy}
          const p = pt.matrixTransform(svg.getScreenCTM().inverse())
          return [ p.x, p.y ]
        })()
      JS
    end

    # pointerdown -> pointermove -> pointerup from the element's centre, the three events a drag is.
    # `pointerId: 1` with `isPrimary: true` is what the handler tracks in its pointer map, and
    # `button: 0` is what its mouse guard checks; ONE move is enough because the pan is computed
    # from the origin rather than accumulated per frame.
    def drag_on(selector = ".gerber-viewer", dx:, dy:)
      page.execute_script(<<~JS)
        (() => {
          const el = document.querySelector("#{selector} svg")
          const r = el.getBoundingClientRect()
          const x = r.left + r.width / 2, y = r.top + r.height / 2
          const opts = (cx, cy) => ({
            pointerId: 1, pointerType: "mouse", isPrimary: true, button: 0, buttons: 1,
            clientX: cx, clientY: cy, bubbles: true, cancelable: true
          })
          el.dispatchEvent(new PointerEvent("pointerdown", opts(x, y)))
          el.dispatchEvent(new PointerEvent("pointermove", opts(x + #{dx}, y + #{dy})))
          el.dispatchEvent(new PointerEvent("pointerup", opts(x + #{dx}, y + #{dy})))
        })()
      JS
    end
end
