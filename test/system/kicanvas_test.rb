require "application_system_test_case"
require "support/kicad_fixture"

# KiCanvas actually rendering a KiCad schematic in a real browser (stage 3, S3-2). Everything else
# about the :kicanvas branch — which extensions reach it, the data attributes, the Schematics
# panel's membership rule — is request-level (test/integration/web/kicanvas_preview_test.rb, cheap
# and already covers the backend-neutral parts). What only a browser can see is this file's whole
# subject: does the vendored module actually load, does it actually parse a real .kicad_sch, and
# does the CSP (report-only, but this is the check that matters per test/system/README.md) let the
# module, its fonts and its fetch of the blob URL through without an error.
#
# PROBED, NOT GUESSED: the plan's own first-guess skeleton
# (`(kicad_sch (version 20231120) (generator "tinkerex") (uuid "…") (paper "A4") (lib_symbols)
# (symbol_instances))`) loaded and even reached `data-kicanvas-state="ready"`, but the vendored
# module logged `[SEVERE] "No vaild root schematic was found."` [sic, upstream's own typo] and then
# `Uncaught Error: Unable to find undefined` — it never actually rendered anything, just its own
# `background-color: aqua` placeholder. Swapping in KiCanvas's OWN `test/kicad/files/empty.kicad_sch`
# fixture byte-for-byte (test/support/kicad_fixture.rb) did NOT fix it either, which is what
# actually pointed at the real cause: it was never about the SCHEMATIC CONTENT.
#
# THE REAL CAUSE, AND WHY THE ROUTE CHANGED (config/routes.rb, files/show.html.erb,
# projects/_schematics.html.erb, kicanvas_controller.js): KiCanvas's FetchFileSystem names a
# fetched file from the URL'S OWN TRAILING EXTENSION, never from its bytes or a Content-Disposition
# header — confirmed by reading vendor/javascript/kicanvas.js directly (`FetchFileSystem#load_file`
# takes the basename of the resolved URL; `Project` only calls a fetched thing a "schematic" when
# its name ends in ".kicad_sch"). The plain `blob_file_path` this used at first has NO extension in
# its path at all, so KiCanvas could never have recognised ANY content served from it — the
# skeleton was never the problem. `named_blob_file_path(id, filename: node.name)` fixed it with the
# ORIGINAL minimal content restored: zero console output, `kicanvas-embed.loaded === true`, and a
# real `<canvas>` found inside its shadow DOM (see below for why that needs its own probe).
#
# A PLAIN CSS SELECTOR CANNOT SEE THE CANVAS. `kicanvas-embed` renders its whole UI into an OPEN
# shadow root, several custom elements deep (kicanvas-embed -> kc-schematic-app -> ... ->
# kc-schematic-viewer's own canvas), and Capybara's Selenium-backed `:css` finder does not pierce
# shadow boundaries. `wait_for_kicanvas_canvas` below recurses through `shadowRoot` in JS instead —
# proven necessary, not decorative: `assert_selector "kicanvas-embed canvas"` reliably finds ZERO
# matches even once the canvas genuinely exists (tried first).
class KicanvasTest < ApplicationSystemTestCase
  include KicadFixture

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("kicanvas@example.com")
    @node = write_kicad_schematic!(name: "wiring.kicad_sch")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # data-kicanvas-state="ready" fires as soon as the controller has imported the module and
  # inserted <kicanvas-embed> — BEFORE KiCanvas's own async project load finishes, which is why the
  # canvas check below is a genuine poll rather than a one-shot assertion made right after this one.
  FIND_CANVAS_JS = <<~JS
    (function() {
      function findCanvas(root, depth) {
        if (!root || depth > 8) return false;
        if (root.querySelector && root.querySelector("canvas")) return true;
        const all = root.querySelectorAll ? root.querySelectorAll("*") : [];
        for (const el of all) if (el.shadowRoot && findCanvas(el.shadowRoot, depth + 1)) return true;
        return false;
      }
      const embed = document.querySelector("kicanvas-embed");
      return !!(embed && embed.shadowRoot && findCanvas(embed.shadowRoot, 0));
    })()
  JS

  def wait_for_kicanvas_canvas(timeout: Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if page.evaluate_script(FIND_CANVAS_JS)
      flunk "kicanvas-embed never rendered a <canvas> inside its shadow DOM" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.2
    end
  end

  # MUTATION (§15, test/system/README.md; run for real, verbatim below, then reverted):
  # kicanvas_controller.js's `await import("kicanvas")` changed to `await import("kicanvas-x")` —
  # a module specifier the importmap has no pin for — reds this test with:
  #
  #   KicanvasTest#test_a_real_KiCad_schematic_renders_in_the_browser:
  #   Minitest::Assertion: expected to find css ".kicanvas-stage[data-kicanvas-state='ready']"
  #   but there were no matches
  #
  # i.e. the controller's catch block runs and sets data-kicanvas-state="failed" instead, proving
  # this test would actually catch a broken import.
  test "a real KiCad schematic renders in the browser" do
    visit file_path(@node.node_id)

    assert_selector ".kicanvas-stage[data-kicanvas-state='ready']"
    assert_selector "kicanvas-embed[src='#{named_blob_file_path(@node.node_id, filename: @node.name)}']"
    wait_for_kicanvas_canvas
    assert_no_console_errors
  end

  # THE SCHEMATIC IS PAINTED IN KICANVAS' THEME FOR THE APP'S THEME (2026-10-21): "kicad", KiCad's
  # own paper, under Paper, and "witchhazel" under Graphite. Before, it was Witch Hazel in both. Read
  # off the PAINTED canvas, not the stored preference: a schematic draws through Canvas 2D, so its
  # corner pixel is the theme's background, and a preference written under the wrong key or after
  # the import would leave the key right and the picture wrong.
  #
  # MUTATION-CHECKED (§15; output in the PR, then reverted): deleting `choosePreference()` from
  # kicanvas_controller.js reddens the Paper arm with `[19, 18, 24]`, the Witch Hazel ground.
  CANVAS_CORNER_JS = <<~JS.freeze
    (function() {
      function findCanvas(root, depth) {
        if (!root || depth > 8) return null;
        const c = root.querySelector && root.querySelector("canvas");
        if (c) return c;
        for (const el of (root.querySelectorAll ? root.querySelectorAll("*") : [])) {
          const found = el.shadowRoot && findCanvas(el.shadowRoot, depth + 1);
          if (found) return found;
        }
        return null;
      }
      const canvas = findCanvas(document.querySelector("kicanvas-embed")?.shadowRoot, 0);
      const ctx = canvas && canvas.getContext("2d");
      return ctx ? Array.from(ctx.getImageData(3, 3, 1, 1).data).slice(0, 3) : null;
    })()
  JS

  # A KICANVAS PAGE CALLS NO THIRD PARTY AND RAISES NO CSP VIOLATION (2026-10-22). Upstream's bundle
  # appended a Google Fonts <link> (Material Symbols for the icons, Nunito for the labels), so every
  # viewer page fetched from fonts.googleapis.com and fonts.gstatic.com and broke style-src-elem and
  # font-src: 15 reports from this file's two tests, 22 from one phone sweep in shell_test.rb, enough
  # on the CI runners to pass CspReportsController's 30-a-minute cap and fail that sweep's console
  # check on the 429s. bin/build-kicanvas now deletes the <link> and points the labels at the page's
  # font, and application.css serves the icon font from our origin. The fix is NOT a wider CSP or a
  # higher report cap; either would hide this from the very log the CSP plan reads.
  #
  # THE RECORDER IS INSTALLED BEFORE THE PAGE EXISTS, through CDP, because the <link> went in at
  # module evaluation, a moment after connect(): a listener added after `visit` would race it and
  # could pass by arriving late. A violation is what makes Chrome send a report, report-only or not,
  # so an empty list here is "no CSP report", with no wait on the report's own delivery.
  #
  # AND THE POSITIVE HALF IS ASSERTED, so the test cannot pass on a viewer that drew no icons: the
  # icon font is LOADED, every icon is ONE glyph wide, and the embed's type is the page's. A Material
  # Symbol is exactly 1em (measured); without the font its NAME is drawn instead, "download" at 3.94em
  # and the shortest, "list", at 1.22em, which is why the bound is 1em +/- 0.05 and not "under 1.5".
  #
  # MUTATION-CHECKED (§15; each run red, then restored): appending upstream's <link> to the bundle
  # reddens the violation list (style-src-elem and font-src for Google's hosts); restoring the
  # "Nunito" stack reddens the type assertion; deleting the @font-face reddens the icon width.
  CSP_RECORDER_JS = <<~JS.freeze
    window.__cspViolations = [];
    document.addEventListener("securitypolicyviolation", (e) => {
      window.__cspViolations.push(e.effectiveDirective + " " + e.blockedURI);
    }, true);
  JS

  # Every <kc-ui-icon> drawn from the FONT (an "svg:" icon is a sprite, not a ligature), with its
  # rendered width in ems. Shadow roots are walked as FIND_CANVAS_JS does, for the same reason.
  FONT_ICONS_JS = <<~JS.freeze
    (function() {
      const out = [];
      (function walk(root, depth) {
        if (!root || depth > 10) return;
        for (const el of root.querySelectorAll("*")) {
          if (el.localName === "kc-ui-icon" && !(el.textContent || "").trim().startsWith("svg:")) {
            const width = el.getBoundingClientRect().width;
            if (width > 0) out.push([el.textContent.trim(), width / parseFloat(getComputedStyle(el).fontSize)]);
          }
          if (el.shadowRoot) walk(el.shadowRoot, depth + 1);
        }
      })(document.querySelector("kicanvas-embed")?.shadowRoot, 0);
      return out;
    })()
  JS

  test "a KiCanvas page loads no third-party font and raises no CSP violation" do
    browser = page.driver.browser
    recorder = browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: CSP_RECORDER_JS)
    visit file_path(@node.node_id)
    assert_selector ".kicanvas-stage[data-kicanvas-state='ready']"
    wait_for_kicanvas_canvas
    assert page.evaluate_script("Array.isArray(window.__cspViolations)"), "the CSP recorder never ran on this page"

    # Icons drawn means their font was fetched, which is when a font-src violation would fire: the
    # page has settled, so the absence assertions below are not read too early.
    icons = nil
    begin
      wait_until { (icons = page.evaluate_script(FONT_ICONS_JS)).any? && icons.all? { |_name, ems| (ems - 1).abs < 0.05 } }
    rescue Minitest::Assertion
      flunk "KiCanvas's icons never rendered as single glyphs; [name, width in ems]: #{icons.inspect}"
    end

    assert_empty page.evaluate_script("window.__cspViolations"), "a KiCanvas page raised CSP violations"
    # Not redundant with the line above: a policy widened to admit Google's hosts would empty the
    # violation list and leave the visitor's browser calling Google. This one still fails then.
    requested = page.evaluate_script("performance.getEntriesByType('resource').map((e) => e.name)")
    origin = page.evaluate_script("location.origin")
    assert_empty requested.reject { |u| u.start_with?(origin) }, "a KiCanvas page fetched from a third party"

    # The glyph check alone passes on a machine with Material Symbols INSTALLED, @font-face or not:
    # Chrome then resolves the family to the local copy. This asks for the app's own file.
    assert requested.any? { |u| u.match?(%r{/assets/material-symbols-outlined-\h+\.woff2\z}) },
           "the icon font was not fetched from this app: #{requested.inspect}"
    assert_equal page.evaluate_script("getComputedStyle(document.body).fontFamily"),
                 page.evaluate_script("getComputedStyle(document.querySelector('kicanvas-embed')).fontFamily"),
                 "KiCanvas's labels are not in the page's own font"
    assert_no_console_errors
  ensure
    browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: recorder["identifier"]) if recorder
  end

  test "the schematic follows the app's theme" do
    { "light" => [ 245, 244, 239 ], "dark" => [ 19, 18, 24 ] }.each do |theme, ground|
      page.execute_script("document.cookie = 'theme=#{theme}; path=/; max-age=31536000; samesite=lax'")
      visit file_path(@node.node_id)
      assert_selector ".kicanvas-stage[data-kicanvas-state='ready']"
      wait_for_kicanvas_canvas
      wait_until(message: "the #{theme} schematic never painted KiCanvas' #{theme} ground") do
        page.evaluate_script(CANVAS_CORNER_JS) == ground
      end
    end
    assert_no_console_errors
  ensure
    page.execute_script("document.cookie = 'theme=light; path=/; max-age=31536000; samesite=lax'")
  end
end
