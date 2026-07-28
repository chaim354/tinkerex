require "application_system_test_case"
require_relative "../support/fake_boxes"

# The first system test in this repo, and it earns a real browser rather than an integration test for
# one reason: the two things TrayLayout's editor depends on are BROWSER behaviours that Rack::Test and
# Nokogiri do not model.
#
#   1. An <input type="text"> silently STRIPS line breaks (HTML's value sanitization algorithm). That
#      is what broke this generator — boxes.py answered "traylayout requires --layout, --input, or
#      implementation of generate_layout" because the ASCII art arrived as one line. Only a real
#      browser proves a <textarea> carries the newlines through an actual submit.
#   2. `layout` OVERRIDES sx/sy — boxes.py reads the compartment sizes back out of the art — so the
#      size fields are dead controls unless JavaScript keeps the art in step with them.
#
# The generator here is FakeBoxes' TrayLayout (sx "50*3", sy "50*2"); the real sidecar is exercised by
# sidecar/boxes/tests/test_api.py against actual boxes.py.
class TrayLayoutTest < ApplicationSystemTestCase
  PASSWORD = "correct horse battery staple".freeze

  setup do
    @user = User.create!(email: "tray@example.com", password: PASSWORD, confirmed_at: Time.current)
    @boxes = FakeBoxes.new
    BoxesClient.stub = @boxes
    visit new_user_session_path
    fill_in "user[email]", with: @user.email
    fill_in "user[password]", with: PASSWORD
    click_on "Log in"
    # Wait for Turbo to actually FOLLOW the login redirect before navigating. Without this the next
    # `visit` races the redirect, arrives before the session cookie is set, and 401s into the login
    # page — which reads exactly like the editor failing to render.
    assert_current_path "/files"
  end

  teardown { BoxesClient.reset! }

  test "the layout arrives as editable multi-line art, not a one-line text field" do
    visit new_tools_box_path(generator: "TrayLayout")
    layout = find("textarea[name='params[layout]']")

    assert_equal FakeBoxes::TRAY_LAYOUT, layout.value
    assert_operator layout.value.lines.size, :>, 4, "the art collapsed onto one line"
    # The distinguishing check: a text input would have eaten every one of these.
    assert_equal 8, layout.value.lines.size
  end

  # The sync fires on "change" (value committed), not per keystroke — so a size only takes effect once
  # the field is left. See the controller for why.
  def set_size(field, value)
    fill_in field, with: value
    find_field(field).send_keys(:tab)
  end

  test "changing the compartment sizes regenerates the art, so sx/sy are not dead controls" do
    visit new_tools_box_path(generator: "TrayLayout")
    set_size "params[sx]", "40*4"

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
    assert_equal expected, find("textarea[name='params[layout]']").value
  end

  test "a hand-edited layout is never silently overwritten when the sizes change" do
    visit new_tools_box_path(generator: "TrayLayout")
    mine = FakeBoxes::TRAY_LAYOUT.sub("| | | | 50.0mm", "| |   | 50.0mm") # a wall removed by hand
    layout = find("textarea[name='params[layout]']")
    layout.fill_in with: mine

    # Exactly ONE prompt for the whole edit. Per-keystroke syncing asked once per character, which
    # is what pushed this onto "change".
    dismiss_confirm { set_size "params[sx]", "40*4" }
    assert_equal mine, find("textarea[name='params[layout]']").value,
                 "declining the prompt must leave the hand-removed wall in place"

    accept_confirm { set_size "params[sy]", "60*2" }
    assert_includes find("textarea[name='params[layout]']").value, "60.0mm"
  end

  # The end of the path the bug lived on: browser control -> real submit -> what BoxesClient hands the
  # sidecar. Everything upstream of here can look right while the value still arrives flattened.
  test "the layout reaches the client with its lines intact after a real submit" do
    visit new_tools_box_path(generator: "TrayLayout")
    fill_in "name", with: "Bench tray"
    click_on "Save to library"
    assert_text "Bench tray"

    sent = @boxes.last_generate.fetch(:params).fetch("layout")
    assert_operator sent.lines.size, :>, 4, "the layout arrived flattened onto one line"
    # A browser submits textarea content CRLF-delimited; boxes.py splits on "\n" and its trailing
    # \s* absorbs the stray \r, so both forms render identically (verified against real boxes.py).
    assert_equal FakeBoxes::TRAY_LAYOUT, sent.delete("\r")
  end

  test "an unreadable size leaves the art alone rather than writing junk" do
    visit new_tools_box_path(generator: "TrayLayout")
    set_size "params[sx]", "40*"
    assert_equal FakeBoxes::TRAY_LAYOUT, find("textarea[name='params[layout]']").value
    set_size "params[sx]", "not a size"
    assert_equal FakeBoxes::TRAY_LAYOUT, find("textarea[name='params[layout]']").value
  end
end
