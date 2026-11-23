require "application_system_test_case"

# AN ADDON'S PERMISSIONS ARE ITS CARD'S RIGHT-CLICK MENU'S "Permissions…", WHICH OPENS A MODAL
# (2026-11-23; tools/home/_permissions_dialog, toolmenu_controller.js#showPermissions). They were a
# footer on every card. The request tests (home_controller_test.rb) read what each dialog says and
# which card names it; only a browser can see that the entry opens it as a MODAL — the page behind
# inert, the dialog in the top layer — that each way of closing it works, and that closing it hands
# focus back to the tool rather than to <body>, since the menu item that opened it has gone.
class ToolPermissionsSystemTest < ApplicationSystemTestCase
  ENVS = %w[ADDON_SOURCE_PATH BOXES_SIDECAR_URL FIXTURE_SVC_SIDECAR_URL].freeze

  setup do
    @prior = ENV.to_h.slice(*ENVS)
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    ENV["BOXES_SIDECAR_URL"] = "http://boxes.invalid"
    # Fixture Addon names this service and declares no permissions; with a URL for it, it is the
    # runnable tool that asks for nothing.
    ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://fixture-svc.invalid"
    sign_in_as("tool-permissions@example.com")
  end

  teardown do
    ENVS.each do |key|
      @prior.key?(key) ? ENV[key] = @prior[key] : ENV.delete(key)
    end
  end

  def card = find(".addon-card", text: "Box Generator")

  def open_permissions
    card.right_click
    find(".file-menu button[role=menuitem]", text: "Permissions…").click
  end

  # What the fixture's boxes manifest declares (test/fixtures/addons/manifests.json), by label.
  def dialog = find("dialog.tool-permissions[open]")

  # A WAITING ASSERTION, NOT A ONE-SHOT READ: the `open` attribute drops the moment the dialog shuts,
  # but its `close` event, which moves focus, is a task queued after that — a read taken as soon as
  # `dialog[open]` is gone can land between the two.
  def assert_focus_back_on_the_tool(how)
    assert_selector ".addon-card-link:focus", text: "Box Generator", wait: 2
  rescue Minitest::Assertion
    flunk "#{how} left focus off the tool (on #{page.evaluate_script("document.activeElement?.outerHTML")&.[](0, 120)})"
  end

  test "Permissions… opens a modal listing what the tool asks to do, with its reasons" do
    visit tools_path
    assert_no_selector ".addon-card", text: /This tool can/
    assert_no_selector "dialog[open]"

    open_permissions
    assert_no_selector ".file-menu"
    within(dialog) do
      assert_selector "h2", text: "Box Generator permissions"
      assert_equal [ "Write files to your library", "Call the boxes service" ],
                   all(".tool-permission-name").map(&:text)
      assert_selector ".tool-permission-reason", text: /Saves the box it draws/
    end
    # MODAL, NOT MERELY OPEN: showModal() is what puts it in the top layer and makes the page inert.
    # A dialog given the `open` attribute instead would show the same words and pass every check above.
    assert page.evaluate_script(%(document.querySelector("dialog.tool-permissions[open]").matches(":modal"))),
           "the dialog is open but not modal"
    # The ×, the first control, takes focus inside the dialog.
    assert page.evaluate_script(%(document.activeElement?.matches("dialog[open] .modal-close"))),
           "focus did not move into the dialog"
    assert_no_console_errors
  end

  test "Esc, the × and the backdrop each close it, and focus goes back to the tool" do
    visit tools_path

    open_permissions
    # To the focused control, the × inside the dialog: the page behind is inert.
    dialog.find("button.modal-close").send_keys(:escape)
    assert_no_selector "dialog[open]"
    assert_focus_back_on_the_tool("Esc")

    open_permissions
    dialog.find("button.modal-close").click
    assert_no_selector "dialog[open]"
    assert_focus_back_on_the_tool("the ×")
    # Closing is the dialog's own form, never a navigation.
    assert_current_path tools_path

    open_permissions
    # The page's top-left corner is the backdrop: the dialog is centred and narrower than the window.
    page.driver.browser.action.move_to_location(5, 5).click.perform
    assert_no_selector "dialog[open]"
    assert_focus_back_on_the_tool("the backdrop")

    # A click INSIDE the box is not the backdrop and leaves it open.
    open_permissions
    dialog.find(".modal-body").click
    assert_selector "dialog[open]"
    assert_no_console_errors
  end

  # The rail's pinned link has no dialog on most pages, so its menu is the pin alone; and a tool
  # declaring nothing still answers, rather than leaving its menu without the entry.
  test "the rail's menu has no Permissions…, and a tool declaring nothing says so" do
    visit tools_path
    card.right_click
    find(".file-menu button", text: "Pin to sidebar").click
    find("aside.rail a.rail-tool-pin", text: "Box Generator").right_click
    assert_equal [ "Unpin from sidebar" ], all(".file-menu button[role=menuitem]").map(&:text)
    find("body").send_keys(:escape)

    find(".addon-card", text: "Fixture Addon").right_click
    find(".file-menu button", text: "Permissions…").click
    within(dialog) { assert_text "This tool does not ask for any permissions." }
    assert_no_console_errors
  end
end
