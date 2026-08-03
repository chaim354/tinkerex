require "application_system_test_case"
require_relative "../support/fake_boxes_sidecar"

# The first system test in this repo, and it earns a real browser rather than an integration test for
# one reason: the two things TrayLayout's editor depends on are BROWSER behaviours that Rack::Test and
# Nokogiri do not model.
#
#   1. An <input type="text"> silently STRIPS line breaks (HTML's value sanitization algorithm). That
#      is what broke this generator originally — boxes.py answered "traylayout requires --layout,
#      --input, or implementation of generate_layout" because the ASCII art arrived as one line. Only
#      a real browser proves a <textarea> carries the newlines through.
#   2. `layout` OVERRIDES sx/sy — boxes.py reads the compartment sizes back out of the art — so the
#      size fields are dead controls unless JavaScript keeps the art in step with them.
#
# THE BOX GENERATOR IS NOW A RUNTIME-LOADED ESM BUNDLE (chaim354/tinkerex-addons, addons/boxes/*.js),
# not server-rendered ERB + Stimulus. This file exercises a SNAPSHOT of that bundle copied verbatim
# into test/fixtures/addons/boxes/, through the real host pipeline, with the sidecar stubbed at the
# Maker::Addons::ServiceProxy seam (FakeBoxesSidecar) instead of the deleted BoxesClient/FakeBoxes.
# See box_sections_test.rb's header for the hermetic-snapshot trade-off this accepts.
#
# ONE GENUINE SIMPLIFICATION THE BUNDLE BUYS FOR FREE, not just a port: the old #1 above was a form
# SUBMISSION concern (a real POST re-encodes a textarea's value as CRLF per RFC 2388, and this repo's
# own BoxesController had to `.delete("\r")` to compare it back). The bundle never submits a form —
# it reads `textarea.value` (which the DOM always normalizes to bare "\n", never "\r\n") and
# JSON-encodes it directly — so there is no CRLF step to reintroduce at all, not merely one that's
# already handled. The multi-line-textarea behaviour itself (#1 above) still needs a real browser and
# is still exercised below; only the CRLF half of the old worry is now structurally impossible.
#
# The generator here is FakeBoxesSidecar's TrayLayout (sx "50*3", sy "50*2"); the real sidecar is
# exercised by sidecar/boxes/tests/test_api.py against actual boxes.py.
class TrayLayoutTest < ApplicationSystemTestCase
  setup do
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    @proxy = FakeBoxesSidecar.install!
    sign_in_as "tray@example.com"
    visit tools_addon_path("boxes")
    find(".addon-card", text: "TrayLayout").click
  end

  teardown do
    FakeBoxesSidecar.uninstall!
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
  end

  def layout_field = find('[data-param="layout"]')

  test "the layout arrives as editable multi-line art, not a one-line text field" do
    assert_equal FakeBoxesSidecar::TRAY_LAYOUT, layout_field.value
    assert_operator layout_field.value.lines.size, :>, 4, "the art collapsed onto one line"
    # The distinguishing check: a text input would have eaten every one of these.
    assert_equal 8, layout_field.value.lines.size
  end

  # The sync fires on "change" (value committed), not per keystroke — see tray_sync.js for why.
  # Typed via `.set`, not assigned: Selenium's `set` sends real keystrokes (firing `input` on each),
  # and `:tab` moves focus away to fire the trailing `change` — assigning `.value` directly fires
  # neither event.
  def set_size(param, value)
    field = find(%([data-param="#{param}"]))
    field.set(value)
    field.send_keys(:tab)
  end

  # MUTATION-CHECKED (2026-08-03): disabled tray_sync.js's regeneration (an early `return` at the
  # top of `update`) — red here (the layout stayed at its 50mm default) AND errored the hand-edit
  # test below with "Unable to find modal dialog" (no `confirm()` is ever reached once regeneration
  # never runs) — restored, confirmed green again.
  test "changing the compartment sizes regenerates the art, so sx/sy are not dead controls" do
    set_size "sx", "40*4"

    expected = <<~ART
       ,> 40.0mm
       | ,> 40.0mm
       | | ,> 40.0mm
       | | | ,> 40.0mm
      +-+-+-+-+
      | | | | | 50.0mm
      +-+-+-+-+
      | | | | | 50.0mm
      +-+-+-+-+
    ART
    assert_equal expected, layout_field.value
  end

  test "a hand-edited layout is never silently overwritten when the sizes change" do
    mine = FakeBoxesSidecar::TRAY_LAYOUT.sub("| | | | 50.0mm", "| |   | 50.0mm") # a wall removed by hand
    layout_field.set(mine)

    # Exactly ONE prompt for the whole edit. Per-keystroke syncing asked once per character, which
    # is what pushed tray_sync.js onto "change".
    dismiss_confirm { set_size "sx", "40*4" }
    assert_equal mine, layout_field.value,
                 "declining the prompt must leave the hand-removed wall in place"

    accept_confirm { set_size "sy", "60*2" }
    assert_includes layout_field.value, "60.0mm"
  end

  # The end of the path the original bug lived on: browser control -> real fetch -> what the sidecar
  # (here, FakeBoxesSidecar via the service proxy) is handed. Everything upstream of here can look
  # right while the value still arrives flattened.
  test "the layout reaches the sidecar with its lines intact after a real save" do
    find('[data-role="name"]').set("Bench tray")
    click_on "Save to library"
    assert_selector '[data-role="save-status"]', text: "Saved."

    # editor.js's save handler always makes a FRESH generate call (not whatever the debounced
    # preview last drew) immediately before saving — the last recorded "generate" call is that one.
    sent = @proxy.calls.select { |c| c.path == "generate" }.last.params.dig("params", "layout")
    assert_operator sent.lines.size, :>, 4, "the layout arrived flattened onto one line"
    assert_equal FakeBoxesSidecar::TRAY_LAYOUT, sent
  end

  test "an unreadable size leaves the art alone rather than writing junk" do
    set_size "sx", "40*"
    assert_equal FakeBoxesSidecar::TRAY_LAYOUT, layout_field.value
    set_size "sx", "not a size"
    assert_equal FakeBoxesSidecar::TRAY_LAYOUT, layout_field.value
  end
end
