require "application_system_test_case"
require_relative "../support/fake_boxes_sidecar"

# The tray top view: a plan of the compartments, drawn in the BROWSER from the params already on the
# form. Browser-only in the sense test/system/README.md asks for — there is no request to assert,
# because the whole point of this tier is that it costs no sidecar call:
#
#   1. It renders from `mount()`, with nothing clicked and nothing fetched.
#   2. "Removing a wall merges two compartments" is a DOM redraw in response to an `input` event.
#   3. Its self-gating (absent on a generator with no compartments) is a decision the module makes
#      about a form it is looking at, which a server-rendered assertion cannot see.
#
# THE BOX GENERATOR IS NOW A RUNTIME-LOADED ESM BUNDLE (chaim354/tinkerex-addons, addons/boxes/*.js),
# not server-rendered ERB + Stimulus (top_view.js replaces topview_controller.js). This file
# exercises a SNAPSHOT of that bundle copied verbatim into test/fixtures/addons/boxes/, through the
# real host pipeline, with the sidecar stubbed at the Maker::Addons::ServiceProxy seam
# (FakeBoxesSidecar). See box_sections_test.rb's header for the hermetic-snapshot trade-off this
# accepts.
class TrayTopViewTest < ApplicationSystemTestCase
  # FakeBoxesSidecar gives ABox a sample photo and the others none, so the gallery <img> 404s on
  # purpose (through the service-proxy path — see box_sections_test.rb's SAMPLE_404).
  SAMPLE_404 = %r{/tools/boxes/service/boxes/sample/\w+ - Failed to load resource.+404}

  # 3 columns x 2 rows, every wall present -> six compartments. Same shape FakeBoxesSidecar seeds.
  MERGED_LAYOUT = <<~ART
     ,> 50.0mm
     | ,> 50.0mm
     | | ,> 50.0mm
    +-+-+-+
    |   | | 50.0mm
    +-+-+-+
    | | | | 50.0mm
    +-+-+-+
  ART

  setup do
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    FakeBoxesSidecar.install!
    sign_in_as "topview@example.com"
  end

  teardown do
    FakeBoxesSidecar.uninstall!
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
  end

  def open_generator(key)
    visit tools_addon_path("boxes")
    find(".addon-card", text: key).click
  end

  def summary = find('[data-topview="summary"]')

  test "a tray generator draws its compartments without being asked" do
    open_generator("TrayLayout")

    assert_selector ".box-topview svg", wait: 5
    assert_equal "6 compartments", summary.text
    # One <g data-compartment> per compartment, tagged so this counts the drawing rather than the
    # caption.
    assert_selector ".box-topview [data-compartment]", count: 6
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # MUTATION-CHECKED (2026-08-03): made top_view.js's `redraw` a no-op (the input/change listeners
  # stayed wired but did nothing) — red here ("expected... 5 compartments... found 6 compartments,
  # which matched the selector but not all filters"), restored, confirmed green again.
  test "removing a wall from the layout merges the two compartments it separated" do
    open_generator("TrayLayout")
    assert_equal "6 compartments", summary.text

    # Typed, not assigned: `set` on a non-empty value sends real keystrokes, which is what fires the
    # `input` event top_view.js's redraw listens to. (Assigning .value fires nothing.)
    find('[data-param="layout"]').set(MERGED_LAYOUT)

    assert_selector '[data-topview="summary"]', text: "5 compartments"
    assert_equal "5 compartments · 1 merged", summary.text
    assert_selector ".box-topview [data-compartment]", count: 5
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  test "a generator with no compartments gets no top view at all" do
    open_generator("ABox")

    assert_selector ".box-preview" # the ordinary cut-sheet preview still belongs here
    assert page.has_no_selector?(".box-topview"),
           "ABox has no sx/sy and no layout — there are no compartments to plan"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  test "a layout that is not a TRAY layout gets no top view" do
    # FrontPanel has a `layout` too, but it is a different DSL entirely — outline/rect/circle/text.
    # "Has a layout param" is not the same question as "has compartments to plan", and getting that
    # wrong shows an empty, permanently blank Top view panel on a generator that can never fill it.
    open_generator("FrontPanel")

    assert_selector '[data-param="layout"]' # it really does have a multiline layout
    assert page.has_no_selector?(".box-topview"),
           "FrontPanel's layout describes a panel, not a grid of compartments"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  test "a tray with sizes but no layout draws its grid from sx and sy" do
    open_generator("TypeTray")

    assert_selector ".box-topview svg", wait: 5
    assert_equal "6 compartments", summary.text
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end
end
