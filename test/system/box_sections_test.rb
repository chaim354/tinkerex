require "application_system_test_case"
require_relative "../support/fake_boxes_sidecar"

# The Box Generator's collapsible sections, its table of contents, and the editor's self-starting
# preview. The Box Generator itself is now a runtime-loaded ESM bundle (chaim354/tinkerex-addons,
# addons/boxes/*.js), not server-rendered ERB + Stimulus — Tools::BoxesController and its five
# Stimulus controllers are gone. This file exercises a SNAPSHOT of that bundle, copied verbatim into
# test/fixtures/addons/boxes/ and served through the exact same host pipeline production uses
# (Tools::AddonsController#show/#asset, Maker::Addons::Source::Local reading ADDON_SOURCE_PATH off
# disk) with the sidecar itself stubbed at the Maker::Addons::ServiceProxy seam (FakeBoxesSidecar) —
# there is no real boxes.py here, same as there was no real one behind the old BoxesClient.stub.
#
# THE HERMETIC-SNAPSHOT TRADE-OFF, stated plainly: this fixture can drift from the real bundle in
# ~/Desktop/tinkerex-addons. Nothing in this repo's CI catches that drift automatically — a change
# to the real bundle's sections/filter/preview logic that isn't mirrored into the snapshot here
# would leave these tests green while the shipped addon broke. This is the SAME mechanism (and the
# same accepted risk) test/system/addon_bundle_test.rb already established for its own minimal
# fixture; the difference is that fixture was purpose-built as a minimal host-pipeline probe, while
# this one is a full copy of the real feature. The alternative — pointing these tests at the sibling
# tinkerex-addons checkout and skipping when it's absent — was rejected because it gives ZERO
# coverage on a fresh clone (this repo's CI runner has no reason to have that sibling repo checked
# out beside it), and a skip that always skips is indistinguishable from no test at all. A snapshot
# that sometimes goes stale beats a test that never runs.
#
# Every one of these behaviours is browser-only in the sense test/system/README.md asks for:
#
#   1. `<details>` open/closed is a DOM property the user toggles — a request test can assert the
#      SHIPPED state, never what happens after a click.
#   2. The layout the user leaves behind lives in localStorage, so "still collapsed next visit"
#      needs a real second page load in a real browser.
#   3. The editor's first render fires from `mount()`, with nothing clicked. There is no request to
#      assert and no attribute that proves it — only an <img> that acquires a src on its own.
#   4. Filtering must REVEAL a match hidden inside a collapsed section, and must then put the layout
#      back. That interaction is two modules (sections.js/filter.js) on one element agreeing about
#      who owns `open`, which is exactly the seam a server-side test cannot see.
#
# MUTATION-CHECKED (2026-08-03, against the snapshot in test/fixtures/addons/boxes/) — each reverted,
# watched go red, restored. Named per test below.
class BoxSectionsTest < ApplicationSystemTestCase
  # ABox has a sample photo in FakeBoxesSidecar; the other three don't, so the gallery's <img> 404s
  # on purpose (through the NEW service-proxy path, not the old /tools/boxes/thumb/:key route) and
  # the bundle's own onerror handler hides it. Chrome logs that at SEVERE. See
  # `assert_no_console_errors(ignoring:)`.
  SAMPLE_404 = %r{/tools/boxes/service/boxes/sample/\w+ - Failed to load resource.+404}

  # The refusal the last test in this file provokes on purpose. Chrome logs any failed fetch at
  # SEVERE, so without this the deliberate 422 would mask a genuine error logged beside it — the
  # same argument SAMPLE_404 above already makes for the gallery's missing sample photos.
  GENERATE_422 = %r{/tools/boxes/service/boxes/generate - Failed to load resource.+422}

  setup do
    # Hermetic fixture, not the real bundle — see the file header. Mirrors
    # test/system/addon_bundle_test.rb's own ADDON_SOURCE_PATH dance exactly (ADDON_SOURCE_PATH,
    # not ADDON_SOURCE_URL: pointing this at ourselves over HTTP would be a synchronous nested
    # request into the same small Puma pool this test's own request is running on — see
    # Maker::Addons::Source::Local's comment for the measured stall this caused).
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    @proxy = FakeBoxesSidecar.install!
    sign_in_as "sections@example.com"
  end

  teardown do
    FakeBoxesSidecar.uninstall!
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
  end

  # `wait_until` moved to WebHelpers when openscad_preview_test needed the same poll for the same
  # reason (an <img> src is a property, not a DOM node Capybara can wait on).

  # Capybara's `assert_no_selector` takes no failure message, and these negatives are the whole
  # point of most of these tests — "it was still open" needs to say WHICH claim broke.
  #
  # THE PLAIN `has_no_selector?("#{selector}[open]")` FORM IS A RACE, and it is a race this bundle's
  # own async mount introduces where the old server-rendered markup had none: `has_no_selector?`
  # returns true the instant nothing matches, and "the element doesn't exist YET because mount()
  # hasn't finished fetching/rendering" matches that just as well as "it exists and is closed" does.
  # The old ERB page had every `<details>` present in the FIRST response body, so that ambiguity
  # could not arise; this bundle builds the DOM after an async fetch, so a check made too early
  # would silently confirm "closed" for a section that is actually just not there yet. Waiting for
  # the plain selector to exist first collapses that race: only then does the negative check mean
  # what it says. Caught by mutation-checking this file — see the header note before assuming this
  # line is decorative.
  def assert_closed(selector, message)
    assert_selector selector
    assert page.has_no_selector?("#{selector}[open]"), message
  end

  def assert_open(selector, message)
    assert page.has_selector?("#{selector}[open]"), message
  end

  # Typed, never `set`. Selenium's `set` is clear()-then-send_keys, and clear() does not reliably
  # fire `input` — which is the event filter.js listens to. That makes `set("")` a no-op for the
  # filter, and "clearing the box puts the layout back" is precisely what this file has to prove.
  def search_for(text)
    field = find("input.box-search")
    field.click
    field.value.length.times { field.send_keys(:backspace) }
    field.send_keys(text) unless text.empty?
  end

  def open_generator(key)
    open_addon_card(key)
  end

  # Sample-photo responses that arrive LATE. Nothing else is slowed: the generators list still lands
  # at once, so the cards render and become clickable while their four thumbnails are still in
  # flight — the exact state the gallery is in on a loaded CI box, and the one that made the click
  # race reachable there and not here.
  #
  # NAMES ONLY THE ARGUMENT IT BRANCHES ON and forwards the rest with a bare `super`. Spelling the
  # whole signature out made this override an ArgumentError the moment ServiceProxy#call grew a
  # keyword (`read_timeout:` was the first), which fails as a broken gallery rather than as
  # anything naming a signature.
  class SlowSamples < FakeServiceProxy
    def call(path:, **rest)
      sleep 0.3 if path.to_s.start_with?("sample/")
      super
    end
  end

  # THE GALLERY MOVES UNDER THE POINTER, AND A MISSED CLICK IS SILENT. Each card's
  # `<img class="addon-thumb">` is a real request through the sidecar proxy, and
  # `.addon-thumb.is-missing { display: none }` removes a 120px box the moment one fails — so every
  # card below it jumps up ~126px. Measured for TrayLayout, the last of the four: 1002px -> 624px.
  # Chromedriver computes ONE click coordinate and then dispatches pointerMove/pointerDown at it, so
  # a thumbnail resolving in between drops the click into the dead space below the shrunken grid,
  # where nothing raises and nothing happens. `system-test` was red on main for exactly this (run
  # 31188332739), and its failure screenshot shows a perfectly healthy gallery.
  #
  # ASSERTED AS THE HELPER'S CONTRACT, NOT AS THE RACE'S OUTCOME, and that is deliberate: the real
  # window is sub-100ms, so a test that clicked and hoped would be a coin flip in both directions —
  # green with the bug present often enough to prove nothing. What IS deterministic is the property
  # that closes the window: by the time open_addon_card clicks, no thumbnail is still loading and
  # the collapse has already been applied, so nothing is left that could move the target.
  #
  # MUTATION-CHECKED (2026-08-10): dropped the `i.complete` clause from settle_addon_cards' probe —
  # red here on both assertions ("4 thumbnails were still loading"), restored, green again.
  test "the gallery is not clicked until its thumbnails have stopped moving" do
    FakeBoxesSidecar.install!(proxy: SlowSamples.new)
    visit tools_addon_path("boxes")

    settle_addon_cards

    still_loading = page.evaluate_script(
      'Array.prototype.slice.call(document.querySelectorAll("img.addon-thumb")).filter(function (i) { return !i.complete }).length'
    )
    assert_equal 0, still_loading, "#{still_loading} thumbnails were still loading — the cards can still collapse under the click"

    # And the collapse is not merely finished but APPLIED: re-asserting it must move nothing. This is
    # the half that would still catch a settle that waited on the requests but clicked before the
    # reflow those requests trigger.
    positions = 'Array.prototype.slice.call(document.querySelectorAll(".addon-card")).map(function (c) { return Math.round(c.getBoundingClientRect().top) }).join(",")'
    before = page.evaluate_script(positions)
    page.execute_script('document.querySelectorAll("img.addon-thumb").forEach(function (i) { i.classList.add("is-missing") })')
    assert_equal before, page.evaluate_script(positions), "the cards were still going to move after settle_addon_cards returned"

    # The click itself, through the real helper, on the card with the most travel to lose.
    open_generator("TrayLayout")
    assert_selector ".box-editor"
    assert_selector "[data-role=key]", text: "TrayLayout"
  end

  # MUTATION: made `jump` fall through to the browser's default #hash navigation (dropped the
  # preventDefault + `section.open = true` in sections.js) — red, the section stayed shut.
  test "a table-of-contents entry opens the section it points at, even when that section is shut" do
    visit tools_addon_path("boxes")
    find("#box-section-tray > summary").click
    assert_closed "#box-section-tray", "clicking the summary should have folded it"

    find("nav.box-toc a[href='#box-section-tray']").click
    assert_selector "#box-section-tray[open]"
    assert_selector "#box-section-tray .addon-title", text: "TypeTray"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # MUTATION: dropped the localStorage write in sections.js's `persist` — red, the section came
  # back open. This is the test with a known flake (see the plan/CLAUDE.md) — if it still flakes
  # after this rewrite, that is reported rather than hidden.
  test "what you fold away stays folded on the next visit" do
    visit tools_addon_path("boxes")
    assert_selector "#box-section-box[open]"
    find("#box-section-box > summary").click
    assert_closed "#box-section-box", "clicking the summary should have folded it"

    visit tools_addon_path("boxes")
    assert_closed "#box-section-box", "the collapsed section was not remembered"
    assert_open "#box-section-tray", "an untouched section must keep its shipped state"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # The whole reason persistence hangs off a summary CLICK rather than the `toggle` event: filtering
  # opens sections by assigning `.open`, which fires `toggle` too. Storing that would mean a search
  # silently rewrote the layout you had arranged.
  #
  # THE DEPARTURE MID-SEARCH IS THE LOAD-BEARING STEP. Persisting on `toggle` passes everything else,
  # because filter.js puts the prior state back when the query is cleared — so storage lands on the
  # right value anyway. The bug only exists for someone who LEAVES while a filter is still applied,
  # which is why the reload happens there.
  #
  # MUTATION: moved persistence onto the `toggle` event (sections.js's `onToggle` also calling
  # `persist`) — green against the first draft, RED here at "a search must not persist as a choice".
  test "a search reveals matches inside collapsed sections without rewriting your layout" do
    visit tools_addon_path("boxes")
    find("#box-section-tray > summary").click
    assert_closed "#box-section-tray", "clicking the summary should have folded it"

    search_for "typetray"
    assert_open "#box-section-tray", "a match inside a collapsed section is a match nobody can see"
    assert_no_selector "#box-section-box", visible: true
    assert_no_selector "nav.box-toc a[href='#box-section-box']", visible: true

    # Walk away with the filter still on: nothing the search opened may have been banked.
    visit tools_addon_path("boxes")
    assert_closed "#box-section-tray", "a search must not persist as a choice"

    # And clearing the box in place puts the borrowed layout back.
    search_for "typetray"
    search_for ""
    assert_selector "#box-section-box", visible: true
    assert_closed "#box-section-tray", "clearing the box must put the layout back"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # MUTATION: removed preview.js's self-invoking `preview()` call at the end of `mountPreview` —
  # red, the <img> never got a src.
  test "the editor renders the generator's defaults with nothing clicked, then follows an edit" do
    visit tools_addon_path("boxes")
    open_generator("ABox")

    img = find('[data-role="preview-image"]', visible: :all)
    wait_until(message: "the default box was never previewed") do
      img[:src].to_s.start_with?("data:image/svg+xml")
    end

    before = @proxy.calls.count { |c| c.path == "generate" }
    find('[data-param="x"]').set("222")
    # MUTATION: removed the debounced input/change listener in preview.js's `mountPreview` — red
    # here, no second call was ever recorded.
    #
    # Asserted via the RECORDED SIDECAR CALL, not a changed <img> src: FakeBoxesSidecar returns the
    # identical canned SVG on every call, so the src can't distinguish "re-rendered" from "never
    # re-rendered" on its own — asserting the actual params a fresh call carried is the direct proof
    # the debounced listener fired with the edited value (assert the wire format, CLAUDE.md §14e).
    wait_until(message: "editing a param did not trigger a fresh sidecar render") do
      @proxy.calls.count { |c| c.path == "generate" } > before
    end
    sent = @proxy.calls.select { |c| c.path == "generate" }.last.params
    assert_equal "222", sent.dig("params", "x")
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # MUTATION: reverted fields.js's basic groups to a plain, non-<details> wrapper — red, the summary
  # click found no element to fold.
  test "every param group folds, and collapse-all folds them together" do
    visit tools_addon_path("boxes")
    open_generator("ABox")

    assert_selector "#param-group-abox-settings[open]"
    assert_closed "#param-group-settings-for-finger-joints", "an advanced group starts folded"

    # A basic group folds too — that is the change; only the advanced ones could before.
    find("#param-group-abox-settings > summary").click
    assert_closed "#param-group-abox-settings", "a basic group must fold like any other"

    click_on "Expand all"
    assert_selector "#param-group-abox-settings[open]"
    assert_selector "#param-group-settings-for-finger-joints[open]"
    click_on "Collapse all"
    assert_closed "#param-group-abox-settings", "collapse-all left a basic group open"
    assert_closed "#param-group-settings-for-finger-joints", "collapse-all left an advanced group open"

    # Folded or not, the fields stay in the DOM, so they are still submitted.
    assert_selector '[data-param="FingerJoint_style"]', visible: :all
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # THE SIDECAR'S OWN SENTENCE, NOT A STATUS CODE — and nothing else in this suite asserted it.
  # boxes.py refuses with prose in its `error` key ("traylayout requires --layout, …"), which names
  # the param to fix; "Preview failed (422)" names nothing. §14c is the rule behind it: a sidecar's
  # error never runs through the host's error table, so the SDK hands back a `ServiceError` carrying
  # the response's RAW TEXT and the BUNDLE does the parsing, in the one place the sidecar's shape is
  # known (preview.js's `sidecarMessage`).
  #
  # WRITTEN WHEN generateSvg CAME OFF ITS RAW `fetch`, because that rewrite is invisible to every
  # other assertion here. The old code branched on the response's Content-Type header; the new one
  # parses the text ServiceError carried. Both spellings render an identical preview on the happy
  # path, so a suite with no failing-render test would have gone green over a bundle that had
  # silently started showing users a bare status code.
  #
  # `exact_text:` IS LOAD-BEARING AND `text:` IS A FALSE GREEN HERE — found by mutation-checking this
  # very test, not by reading it. Capybara's `text:` is a SUBSTRING match, and the unparsed body
  # `{"error":"traylayout requires …"}` CONTAINS the sentence, so a `sidecarMessage` that skipped the
  # JSON rung entirely and dumped the raw JSON into the panel passed the substring form. Do not
  # relax this back.
  #
  # MUTATION-CHECKED (2026-08-11): dropped the JSON rung from `sidecarMessage` (return
  # `error.message` straight away) — RED, the panel read the whole `{"error":"…"}` blob; restored,
  # green again.
  test "a sidecar's refusal reaches the user in the sidecar's own words" do
    complaint = "traylayout requires --layout, --input, or implementation of generate_layout"
    @proxy.ok("#{FakeBoxesSidecar::BASE_URL}/generate", status: 422,
              body: { error: complaint }.to_json, content_type: "application/json")

    visit tools_addon_path("boxes")
    open_generator("TrayLayout")

    # `.is-error`, not just the text: the panel has one status element for "Rendering…" too, and a
    # message shown without the error class is a refusal styled as ordinary progress.
    assert_selector '[data-role="status"].is-error', exact_text: complaint
    assert_no_console_errors ignoring: [ SAMPLE_404, GENERATE_422 ]
  end

  # AN EDGE PARAM'S CHOICES ARE SINGLE LETTERS ON THE WIRE AND MUST NOT BE SINGLE LETTERS ON THE
  # PAGE. boxes.py's own web UI has always rendered them as "{letter} {description}"
  # (`ArgparseEdgeType.html`, out of `edges.getDescriptions()`); this bundle rendered the raw value,
  # so `top_edge` offered "e / f / F / h / c / E / S / Š / i / k / v / L / t / G / y / Y" — sixteen
  # letters and no way to tell them apart. The sidecar now advertises the descriptions as
  # `choice_labels` and fields.js composes the option text from them.
  #
  # THE VALUE IS ASSERTED SEPARATELY FROM THE TEXT, AND THAT SPLIT IS THE POINT: the letter is what
  # boxes.py parses, so a fix that put the description into the option's VALUE would look correct on
  # screen and 422 every render. Proven on the wire (the recorded sidecar call), not just on
  # `select.value` — §14e's assert-the-wire-format rule.
  #
  # Browser-only in the sense test/system/README.md asks for: this form has no server-rendered
  # markup at all — fields.js builds every <option> in the page after an async fetch — so `<option>`
  # text exists nowhere a request test could look.
  #
  # It lives in this file rather than its own because it needs the identical fixture/proxy/sign-in
  # setup and one more `open_generator` call, and TypeTray is already fetched here.
  test "an edge dropdown says what each letter means, and still submits the letter" do
    visit tools_addon_path("boxes")
    open_generator("TypeTray")

    top = find('[data-param="top_edge"]')
    assert_equal FakeBoxesSidecar::TOP_EDGE_CHOICES, top.all("option", visible: :all).map(&:value),
                 "the sidecar's own choice set and order is what the letter must round-trip through"
    assert_equal [ "e — Straight Edge", "f — Finger Joint", "F — Finger Joint (opposing side)" ],
                 top.all("option", visible: :all).first(3).map(&:text)

    bottom = find('[data-param="bottom_edge"]')
    assert_equal "h — Edge (parallel Finger Joint Holes)",
                 bottom.find("option[value='h']", visible: :all).text
    assert_equal "h", bottom.value, "the label must not have displaced the value it explains"

    find('[data-param="sx"]').set("60*2")
    wait_until(message: "editing a param did not trigger a fresh sidecar render") do
      @proxy.calls.any? { |c| c.path == "generate" && c.params.dig("params", "sx") == "60*2" }
    end
    sent = @proxy.calls.select { |c| c.path == "generate" }.last.params
    assert_equal "e", sent.dig("params", "top_edge"), "boxes.py parses the LETTER, not the label"
    assert_equal "h", sent.dig("params", "bottom_edge")

    # An enum the sidecar has no descriptions for stays BARE — the same arm a sidecar older than
    # `choice_labels` puts EVERY enum down, so a bundle that assumed the key was always there would
    # render "rectangular — undefined" on every deployment mid-rollout. A fresh `visit`, because
    # opening a generator replaces the gallery `open_addon_card` needs.
    visit tools_addon_path("boxes")
    open_generator("ABox")
    style = find('[data-param="FingerJoint_style"]', visible: :all)
    # `text(:all)`, because this group ships FOLDED and Capybara's plain `#text` answers "" for a
    # node inside a closed <details> — which would have compared four empty strings against four
    # empty strings had the expectation been written the same way.
    assert_equal %w[rectangular springs barbs snap],
                 style.all("option", visible: :all).map { |o| o.text(:all) }
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end
end
