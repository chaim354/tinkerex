require "application_system_test_case"
require_relative "../support/fake_boxes"

# The tray top view: a plan of the compartments, drawn in the BROWSER from the params already on the
# form. Browser-only in the sense test/system/README.md asks for — there is no request to assert,
# because the whole point of this tier is that it costs no sidecar call:
#
#   1. It renders from `connect()`, with nothing clicked and nothing fetched.
#   2. "Removing a wall merges two compartments" is a DOM redraw in response to an `input` event.
#   3. Its self-gating (absent on a generator with no compartments) is a decision the controller
#      makes about a form it is looking at, which a server-rendered assertion cannot see.
class TrayTopViewTest < ApplicationSystemTestCase
  # FakeBoxes gives ABox a sample photo and the others none, so the gallery <img> 404s on purpose.
  SAMPLE_404 = %r{/tools/boxes/thumb/\w+ - Failed to load resource.+404}

  # 3 columns x 2 rows, every wall present -> six compartments. Same shape FakeBoxes seeds.
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
    Tools::BoxesClient.stub = FakeBoxes.new
    sign_in_as "topview@example.com"
  end

  teardown { Tools::BoxesClient.reset! }

  def summary = find("[data-topview-target='summary']")

  test "a tray generator draws its compartments without being asked" do
    visit new_tools_box_path(generator: "TrayLayout")

    assert_selector ".box-topview svg", wait: 5
    assert_equal "6 compartments", summary.text
    # One <rect> per compartment, tagged so this counts the drawing rather than the caption.
    assert_selector ".box-topview [data-compartment]", count: 6
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  test "removing a wall from the layout merges the two compartments it separated" do
    visit new_tools_box_path(generator: "TrayLayout")
    assert_equal "6 compartments", summary.text

    # Typed, not assigned: `set` on a non-empty value sends real keystrokes, which is what fires the
    # `input` event the redraw listens to. (Assigning .value fires nothing — see traylayout_controller.)
    find("textarea[name='params[layout]']").set(MERGED_LAYOUT)

    assert_selector "[data-topview-target='summary']", text: "5 compartments"
    assert_equal "5 compartments · 1 merged", summary.text
    assert_selector ".box-topview [data-compartment]", count: 5
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  test "a generator with no compartments gets no top view at all" do
    visit new_tools_box_path(generator: "ABox")

    assert_selector ".box-preview" # the ordinary cut-sheet preview still belongs here
    assert page.has_no_selector?(".box-topview"),
           "ABox has no sx/sy and no layout — there are no compartments to plan"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  test "a layout that is not a TRAY layout gets no top view" do
    # FrontPanel has a `layout` too, but it is a different DSL entirely — outline/rect/circle/text.
    # "Has a layout param" is not the same question as "has compartments to plan", and getting that
    # wrong shows an empty, permanently blank Top view panel on a generator that can never fill it.
    visit new_tools_box_path(generator: "FrontPanel")

    assert_selector "textarea[name='params[layout]']" # it really does have a multiline layout
    assert page.has_no_selector?(".box-topview"),
           "FrontPanel's layout describes a panel, not a grid of compartments"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  test "a tray with sizes but no layout draws its grid from sx and sy" do
    visit new_tools_box_path(generator: "TypeTray")

    assert_selector ".box-topview svg", wait: 5
    assert_equal "6 compartments", summary.text
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end
end
