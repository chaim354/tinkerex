require "application_system_test_case"

# THE TOASTS (UX audit A5). The stack was fixed at the top right, over the top bar's New and Upload, so
# the notice after a delete covered the two controls a maker reaches for next; a notice left after 6 s
# however long it was, with no pause and no Escape. Now the stack sits at the bottom right (above the
# tab bar on a phone), a notice's countdown waits while the pointer is over it or focus is inside it,
# Escape dismisses the focused toast, and an alert still stays until dismissed (shell_test.rb).
#
# Boxes and timing, which only a browser has. The waits are real: a notice lives NOTICE_MS (6 s,
# toast_controller.js), so "it waited" means "it was still there after 7 s".
#
# MUTATION-CHECKED (2026-11-02; each reverted, and the file re-run green after):
#   1. `.flash-stack` back to `top: 12px` (and no `bottom`) in shell.css: the placement test red, the
#      toast over New and Upload at 1400px.
#   2. Deleting the phone block's `body.app-shell .flash-stack` rule: the placement test red at 375px,
#      the toast under the tab bar.
#   3. Deleting the `mouseenter` listener in toast_controller.js#itemTargetConnected: the hover test
#      red, the notice gone while the pointer was on it.
#   4. Deleting the `focusin` listener: the focus test red, the notice gone while its close button
#      held focus.
#   5. Deleting `data-action="keydown.esc->toast#escape"` from layouts/_flash: the Escape assertions red.
#   6. Making itemTargetConnected start no timer (`return` first): the appended-notice test red.
class ShellToastTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    # sign_in_as lands on / with Devise's sign-in notice in the stack.
    @user = sign_in_as("shell-toast@example.com")
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "a toast never covers New, Upload or the tab bar, at desktop or phone width" do
    assert_selector ".flash-stack .flash-notice"
    assert_empty overlaps(".flash-stack .flash", [ "header.topbar .topbar-new > summary", "header.topbar .topbar-upload .upload-btn" ]),
                 "a toast covers a top-bar control at 1400px"

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    visit root_path
    append_toast("flash-notice", "Deleted plate.dxf. It is in Trash.")
    assert_empty overlaps(".flash-stack .flash", [ "header.topbar", "nav.tabbar" ]),
                 "a toast covers the top bar or the tab bar at 375px"
    box, client = page.evaluate_script(
      "[(() => { const r = document.querySelector('.flash-stack .flash').getBoundingClientRect(); return [r.left, r.right]; })(), document.documentElement.clientWidth]")
    assert_operator box[0], :>=, 0
    assert_operator box[1], :<=, client, "the toast runs off the right of the phone"
  end

  test "a notice waits while the pointer is over it, and leaves once it is not" do
    notice = find(".flash-stack .flash-notice")
    notice.hover
    sleep 7
    assert_selector ".flash-stack .flash-notice", wait: 0
    find("main h1").hover
    assert_no_selector ".flash-stack .flash-notice", wait: 8
  end

  test "a notice waits while focus is inside it, and Escape dismisses the focused one" do
    find(".flash-stack .flash-notice .flash-close").execute_script("this.focus()")
    sleep 7
    assert_selector ".flash-stack .flash-notice", wait: 0
    page.driver.browser.action.send_keys(:escape).perform
    assert_no_selector ".flash-stack .flash-notice", wait: 1
    assert_no_console_errors
  end

  test "Escape dismisses a focused alert, which otherwise stays" do
    append_toast("flash-alert", "That name is taken here.")
    sleep 7
    assert_selector ".flash-stack .flash-alert", wait: 0
    find(".flash-stack .flash-alert .flash-close").execute_script("this.focus()")
    page.driver.browser.action.send_keys(:escape).perform
    assert_no_selector ".flash-stack .flash-alert", wait: 1
  end

  # A NOTICE A SCRIPT APPENDS LATER IS TIMED TOO (the page-layout editor's toasts): Stimulus hands every
  # `data-toast-target="item"` to itemTargetConnected, so a caller adds the element and the shell does
  # the rest.
  test "a notice appended after the page loads leaves on its own" do
    find(".flash-stack .flash-notice .flash-close").click
    assert_no_selector ".flash-stack .flash"
    # The pointer off the stack, or the new toast lands under it and (rightly) waits.
    find("main h1").hover
    append_toast("flash-notice", "Saved the layout.")
    assert_selector ".flash-stack .flash-notice", text: "Saved the layout."
    assert_no_selector ".flash-stack .flash-notice", wait: 8
  end

  private

    # The markup layouts/_flash renders, appended the way a script would.
    def append_toast(kind, text)
      page.execute_script(<<~JS, kind, text)
        const [kind, text] = arguments
        const item = document.createElement("div")
        item.className = `flash ${kind}`
        item.setAttribute("role", kind === "flash-alert" ? "alert" : "status")
        item.dataset.toastTarget = "item"
        item.innerHTML = '<span class="flash-text"></span><button type="button" class="flash-close" aria-label="Dismiss" data-action="toast#dismiss">&times;</button>'
        item.querySelector(".flash-text").textContent = text
        document.querySelector(".flash-stack").appendChild(item)
      JS
      assert_selector ".flash-stack .#{kind}", text:
    end

    # The selectors among `others` whose visible box meets any box matching `toasts`.
    def overlaps(toasts, others)
      page.evaluate_script(<<~JS, toasts, others)
        ((toasts, others) => {
          const meet = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
          const boxes = Array.from(document.querySelectorAll(toasts)).map((t) => t.getBoundingClientRect())
          return others.filter((sel) => {
            const el = document.querySelector(sel)
            const r = el ? el.getBoundingClientRect() : null
            return r && r.width > 0 && r.height > 0 && boxes.some((b) => meet(b, r))
          })
        })(arguments[0], arguments[1])
      JS
    end
end
