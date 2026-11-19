require "application_system_test_case"

# THE CALCULATOR MODAL IN A BROWSER (2026-10-21; plan 2026-10-21-calculator-modal.md). What only a
# browser can see (test/system/README.md): that the delegated `data-calculator-open` door actually
# opens the native <dialog> from the Tools card, the pinned rail link and a saved row; that Enter
# evaluates through lib/calc.js and Esc closes with focus handed back; that history and the inch
# display survive a reload through localStorage; that the lazy Save frame loads, preselects the
# page's project, fills its four hidden fields from the answer on screen and lands its stream in an
# open panel; and that the dialog fits a 375px screen and paints the theme's surface, not the UA's.
# The arithmetic itself is calculator_engine_test.rb's; the doors' authorisation and field names
# are calculations_test.rb's and calculator_shell_test.rb's.
#
# MUTATION-CHECKED (2026-10-21), then restored:
#   * `event.preventDefault()` deleted from calculator_controller.js#submit — RED: the form
#     submitted and reloaded the page, so "Enter evaluates" lost its input (a stale element).
#   * #open's `focus()` AND `select()` deleted — RED: "focus lands in the input". Deleting `focus()`
#     alone stays green, because `select()` focuses the input too.
#   * #prepareSave no longer copying the expression — RED: the save was refused (blank expression)
#     and "Saved … to Desk Lamp" never appeared.
#   * `writeStorage(HISTORY_KEY, …)` deleted from #remember — RED: Recent was empty after the reload.
#   * #prepareSave's recalculation of an edited expression deleted — RED: the stale 914.4 was
#     saved under the old expression while the box read "2 ft to mm".
#   * the frame's `turbo:frame-missing->calculator#saveMissing` action deleted — RED: the ended
#     session's frame said "Content missing" and nothing else.
#   * #closed's focus hand-back deleted — GREEN, because Chrome's <dialog> restores focus to the
#     element focused before showModal() on its own. Kept anyway: Safari does not focus a button on
#     click, so there the opener is not "the element focused before", and only #closed returns to it.
#   * `.calculator-host { display: contents }` deleted from shell.css — GREEN: the host's grid cell
#     is empty and zero-height, so nothing here can see it. The rule is argued in its comment.
#
# THE KEYBOARD SHORTCUT AND THE DIALOG'S OWN KEYS, MUTATION-CHECKED 2026-10-22, then restored:
#   * the dialog's `keydown/paste/copy/cut->calculator#contain` actions deleted — RED: the grid's
#     Backspace emptied A1 ("Also found \"\""). It went red only once the keys were sent through the
#     action API with Backspace first; see the test.
#   * #takesTyping answering false — RED on the search field; its isContentEditable line deleted —
#     RED on the contenteditable probe; `textarea` dropped from its selector — RED on the textarea.
#   * #contain no longer offering the shortcut — RED: focus stayed on the × ("calculator-close").
#   * the `event.code === "KeyC"` fallback deleted — RED: "a Mac's ⌥C, which arrives as ç, opens it";
#     the letter test replaced by `event.code === "KeyC"` alone — RED: Alt+J on that key opened it.
#   * #open setting returnFocus even when already open — GREEN, for #closed's reason above: Chrome's
#     <dialog> puts focus back where it was before showModal() whatever returnFocus says.
class CalculatorModalTest < ApplicationSystemTestCase
  setup do
    use_fresh_share_library!
    @user = sign_in_as("calculator-modal@example.com")
    @project = @user.maker_projects.create!(name: "Desk Lamp")
  end

  def dialog_open? = page.evaluate_script("document.querySelector('dialog.calculator').open")
  def focused = page.evaluate_script("document.activeElement && (document.activeElement.id || document.activeElement.className)")

  def calculate(expression)
    input = find("#calculator-input")
    input.set(expression)
    input.send_keys(:enter)
  end

  # The shortcut, pressed on whatever has focus — the way a maker presses it, not aimed at an element.
  def press_alt_c = page.driver.browser.action.key_down(:alt).send_keys("c").key_up(:alt).perform

  def focus(selector) = page.execute_script("document.querySelector(arguments[0]).focus()", selector)

  test "the Tools card opens the modal; Enter evaluates; Esc closes and focus goes back to the card" do
    visit tools_path
    refute dialog_open?
    find("#calculator .calculator-card-open").click

    assert_selector "dialog.calculator[open]"
    assert_equal "calculator-input", focused, "focus lands in the input"
    calculate("12.5mm + 1/4in")
    assert_selector "dialog.calculator .calculator-result", text: "18.85 mm"
    assert_current_path tools_path

    find("#calculator-input").send_keys(:escape)
    assert_no_selector "dialog.calculator[open]"
    assert_includes focused.to_s, "calculator-card-open", "focus goes back to the control that opened it"
    assert_no_console_errors
  end

  # THE KEYBOARD SHORTCUT (2026-10-22, calculator#shortcut). Pressed from a button on the page it opens
  # the modal with focus in the input; pressed again from a button INSIDE the modal it brings focus
  # back to the input rather than doing nothing; and Esc still hands focus back to where it began.
  test "Alt+C opens the modal from the page, and pressed inside it puts focus back in the input" do
    visit tools_path
    focus("aside.rail .rail-help")
    press_alt_c
    assert_selector "dialog.calculator[open]"
    assert_equal "calculator-input", focused, "focus lands in the input"
    calculate("5' 6 to mm")
    assert_selector "dialog.calculator .calculator-result", text: "1676.4 mm"

    focus("dialog.calculator .calculator-close")
    press_alt_c
    assert dialog_open?, "the shortcut must not close or reopen an open modal"
    assert_equal "calculator-input", focused, "the shortcut inside the modal returns focus to the input"
    assert_equal "5' 6 to mm", find("#calculator-input").value, "and keeps what was typed"

    find("#calculator-input").send_keys(:escape)
    refute dialog_open?
    assert_includes focused.to_s, "rail-help", "focus goes back to where the shortcut was pressed"

    # A REAL MAC'S ⌥C ARRIVES AS key "ç" with code "KeyC", which no driver here synthesises (both send
    # "c"), so that event is dispatched by hand. The letter wins over the key's position wherever the
    # layout gives a letter: Alt on Dvorak's physical C key is Alt+J, not the shortcut.
    alt_key_c = ->(key) do
      page.execute_script(<<~JS, key)
        document.activeElement.dispatchEvent(new KeyboardEvent("keydown",
          { key: arguments[0], code: "KeyC", altKey: true, bubbles: true, cancelable: true }))
      JS
    end
    alt_key_c.("j")
    refute dialog_open?, "Alt+J on the physical C key is not the shortcut"
    alt_key_c.("ç")
    assert dialog_open?, "a Mac's ⌥C, which arrives as ç, opens it"
    find("#calculator-input").send_keys(:escape)

    visit project_path(@project) # and on any other signed-in page
    press_alt_c
    assert_selector "dialog.calculator[open]"
    assert_no_console_errors
  end

  # NEVER WHILE TYPING: in each of these, Alt+C belongs to the field (on a Mac ⌥C types ç). The last
  # press, from outside any field on the same page, shows the shortcut was live the whole time, so
  # the refusals are not a dead shortcut passing.
  test "Alt+C does nothing in a text field, a textarea or a contenteditable editor" do
    visit tools_path
    page.execute_script(<<~JS)
      const main = document.querySelector("main")
      const area = document.createElement("textarea"); area.id = "probe-textarea"
      const rich = document.createElement("div"); rich.id = "probe-editable"; rich.contentEditable = "true"
      rich.textContent = "notes"
      main.prepend(area, rich)
    JS
    [ ".topbar-search input[type=search]", "#probe-textarea", "#probe-editable" ].each do |field|
      find(field).click
      press_alt_c
      refute dialog_open?, "#{field}: the shortcut fired while typing"
    end

    focus("aside.rail .rail-help")
    press_alt_c
    assert_selector "dialog.calculator[open]"
  end

  # KEYS TYPED INTO THE CALCULATOR STOP AT THE DIALOG (calculator#contain). jspreadsheet listens for
  # keys on `document`, and a calculator opened by keyboard leaves the grid's cell selected (a click
  # elsewhere would have deselected it), so without the stop the grid took Enter, opened its own
  # editor on a digit, and Backspace CLEARED THE CELL.
  test "keys typed into a calculator opened over a sheet never reach the grid" do
    data = Maker::Sheet.blank_data
    data["cells"][0][0] = "keep me"
    sheet = @project.sheets.create!(user: @user, name: "Cut list", position: 0, data: data)
    visit sheet_path(sheet)
    a1 = "[data-sheet-target='grid'] td[data-x='0'][data-y='0']"
    assert_selector a1, text: "keep me", wait: 10
    find(a1).click # selects A1

    press_alt_c
    assert_selector "dialog.calculator[open]"
    # BACKSPACE FIRST, the way a maker clears the last expression, and every key sent to whatever has
    # focus (the action API), as a person types. Both matter to the mutation check: with the stop
    # removed, a digit first makes the grid open its own cell editor, which the closing Esc cancels,
    # restoring the cell, so the test passed; and keys aimed at the input with Capybara's element
    # `send_keys` never reproduced the cleared cell at all.
    page.driver.browser.action.send_keys(:backspace, "3 ftt", :backspace, " to mm", :enter).perform
    assert_selector ".calculator-result", text: "914.4 mm"
    assert_equal "3 ft to mm", find("#calculator-input").value
    assert_selector a1, exact_text: "keep me" # the grid's own Backspace empties the cell at once
    page.driver.browser.action.send_keys(:escape).perform
    refute dialog_open?, "Esc closes the calculator, not an editor the grid opened"
    assert_selector a1, exact_text: "keep me"
    assert_no_console_errors
  end

  test "a bad expression says what is wrong and shows no answer, and the × closes" do
    visit tools_path
    find("#calculator .calculator-card-open").click
    calculate("12mm + 1")
    assert_selector "dialog.calculator .calculator-error", text: "Can't add a plain number to a length. Give the 1 a unit, like 1mm."
    assert_equal "", find("dialog.calculator .calculator-result", visible: :all).text

    calculate("3 ft to mm")
    assert_no_selector "dialog.calculator .calculator-error"
    assert_selector "dialog.calculator .calculator-result", text: "914.4 mm"

    find("dialog.calculator .calculator-close").click
    refute dialog_open?
  end

  test "a click on the backdrop closes the modal, a click inside it does not" do
    visit tools_path
    find("#calculator .calculator-card-open").click
    find("dialog.calculator .calculator-head h2").click
    assert dialog_open?, "a click inside the dialog must not close it"
    page.driver.browser.action.move_to_location(5, 5).click.perform
    assert_no_selector "dialog.calculator[open]"
  end

  test "recent results survive a reload, and a recent one runs again" do
    visit tools_path
    find("#calculator .calculator-card-open").click
    calculate("2.5in in mm")
    assert_selector ".calculator-result", text: "63.5 mm"
    calculate("sqrt(9in*4in)")
    assert_selector ".calculator-result", text: "6 in"

    visit projects_path # another page, then back: a fresh controller reads the history from storage
    visit tools_path
    find("#calculator .calculator-card-open").click
    find("details.calculator-recent > summary").click
    items = all(".calculator-history .calculator-history-item code").map(&:text)
    assert_equal [ "sqrt(9in*4in)", "2.5in in mm" ], items, "newest first"

    find(".calculator-history .calculator-history-item", text: "2.5in in mm").click
    assert_equal "2.5in in mm", find("#calculator-input").value
    assert_selector ".calculator-result", text: "63.5 mm"
  end

  test "inches as 1/16 shows the nearest sixteenth, and the choice is remembered" do
    visit tools_path
    find("#calculator .calculator-card-open").click
    calculate("12.5mm + 1/4in")
    assert_selector ".calculator-fraction[hidden]", visible: :all # not an inch answer

    calculate("3.2in")
    assert_selector ".calculator-fraction:not([hidden])"
    find(".calculator-fraction button", text: "1/16").click
    assert_selector ".calculator-result", text: "≈ 3 3/16 in"
    assert_selector ".calculator-result-alt", text: "3.2 in"
    assert_selector ".calculator-fraction button[aria-pressed=true]", text: "1/16"

    visit tools_path
    find("#calculator .calculator-card-open").click
    calculate("1/4in + 1/32in")
    # 9/32 is between two sixteenths, so the remembered 1/16 rounds it and says so.
    assert_selector ".calculator-result", text: /\A≈ 5\/16 in\z/
    assert_selector ".calculator-fraction button[aria-pressed=true]", text: "1/16"
    find(".calculator-fraction button", text: "1/32").click
    assert_selector ".calculator-result", text: /\A9\/32 in\z/
  end

  test "Save to project from a project page picks that project and lands in its open panel" do
    visit project_path(@project, add: "calculations")
    within("section.calculations-panel") { click_on "Open calculator" }
    calculate("3 ft to mm")
    assert_selector ".calculator-result", text: "914.4 mm"

    find("details.calculator-save > summary").click
    within("turbo-frame#calculator-save") do
      assert_selector "select[name='calculation[project_id]'] option:checked", text: "Desk Lamp"
      assert_selector ".calculator-save-what", text: "Saves 914.4 mm"
      fill_in "calculation[label]", with: "Arm length"
      click_on "Save"
      assert_selector ".calculator-saved", text: "Saved “Arm length” to Desk Lamp."
      assert_equal "", find_field("calculation[label]").value, "the form clears for the next one"
    end
    saved = @project.calculations.sole
    assert_equal [ "Arm length", "3 ft to mm", 914.4, "mm", nil ],
                 [ saved.label, saved.expression, saved.result, saved.unit, saved.inch_fraction ]

    find("#calculator-input").send_keys(:escape)
    within("section.calculations-panel") do
      assert_selector ".calculation-row .calculation-label", text: "Arm length"
      assert_selector ".calculation-row .calculation-result", text: "914.4 mm"
    end
    assert_no_console_errors
  end

  test "an inch answer saves with the fraction it was shown at" do
    visit tools_path
    find("#calculator .calculator-card-open").click
    calculate("3 1/2in - 5mm")
    find(".calculator-fraction button", text: "1/32").click
    find("details.calculator-save > summary").click
    within("turbo-frame#calculator-save") do
      find("select[name='calculation[project_id]']").select("Desk Lamp")
      fill_in "calculation[label]", with: "Leg"
      click_on "Save"
      assert_selector ".calculator-saved", text: "Saved “Leg” to Desk Lamp."
    end
    saved = @project.calculations.sole
    assert_equal [ "in", 32 ], [ saved.unit, saved.inch_fraction ]
    assert_in_delta 3.5 - 5 / 25.4, saved.result, 1e-9
  end

  test "an expression edited after Enter is calculated by Save, so the saved answer matches the box" do
    visit project_path(@project, add: "calculations")
    within("section.calculations-panel") { click_on "Open calculator" }
    calculate("3 ft to mm")
    assert_selector ".calculator-result", text: "914.4 mm"
    find("#calculator-input").set("2 ft to mm") # no Enter: the 914.4 still on screen is stale
    find("details.calculator-save > summary").click
    within("turbo-frame#calculator-save") do
      fill_in "calculation[label]", with: "Short arm"
      click_on "Save"
      assert_selector ".calculator-saved", text: "Saved “Short arm” to Desk Lamp."
    end
    assert_selector ".calculator-result", text: "609.6 mm"
    saved = @project.calculations.sole
    assert_equal [ "2 ft to mm", 609.6 ], [ saved.expression, saved.result ]
  end

  test "saving before calculating says to calculate first and saves nothing" do
    visit project_path(@project, add: "calculations")
    within("section.calculations-panel") { click_on "Open calculator" }
    find("details.calculator-save > summary").click
    within("turbo-frame#calculator-save") do
      fill_in "calculation[label]", with: "Nothing yet"
      click_on "Save"
    end
    assert_selector ".calculator-save-hint", text: "Press Enter to calculate first"
    assert_equal 0, Maker::Calculation.count
  end

  # A SESSION THAT ENDED SINCE THE PAGE LOADED answers the frame with the sign-in page, and Turbo's
  # own answer to a frame response without its frame is the words "Content missing" (#saveMissing).
  test "if the session has ended, Save to project says to reload rather than Content missing" do
    visit tools_path
    find("#calculator .calculator-card-open").click
    calculate("3 ft to mm")
    page.driver.browser.manage.delete_all_cookies
    find("details.calculator-save > summary").click
    assert_selector "turbo-frame#calculator-save .calculator-save-error", text: "Couldn't load your projects. Reload the page"
    assert_no_text "Content missing"
  end

  test "Open in calculator puts a saved expression back, at the display it was saved with" do
    @project.calculations.create!(user: @user, label: "Leg", expression: "3 3/16in", result: 3.1875,
                                  unit: "in", inch_fraction: 16)
    visit project_path(@project)
    within("section.calculations-panel") { click_on "Open in calculator" }
    assert_selector "dialog.calculator[open]"
    assert_equal "3 3/16in", find("#calculator-input").value
    assert_selector ".calculator-result", text: /\A3 3\/16 in\z/
    assert_selector ".calculator-fraction button[aria-pressed=true]", text: "1/16"
  end

  test "pinned, the rail link opens the modal over any page without navigating" do
    visit tools_path
    # A RIGHT CLICK ON THE CARD, not a button (2026-10-22; toolmenu_controller.js).
    find("#calculator").right_click
    find(".file-menu button", text: "Pin to sidebar").click
    assert_selector "aside.rail a.rail-calculator"
    find("#calculator").right_click
    assert_selector ".file-menu button", text: "Unpin from sidebar"
    find(".file-menu button").send_keys(:escape)

    [ files_path, project_path(@project) ].each do |path|
      visit path
      find("aside.rail a.rail-calculator").click
      assert_selector "dialog.calculator[open]"
      assert_current_path path
      calculate("2 * pi")
      assert_selector ".calculator-result", text: "6.283185307"
      find("#calculator-input").send_keys(:escape)
      assert_includes focused.to_s, "rail-calculator"
    end
  end

  test "at phone width the Tools tab's card opens the modal and it fits the screen" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    begin
      visit root_path
      assert_equal 4, all("nav.tabbar a.tabbar-link").size
      find("nav.tabbar a.tabbar-link", text: "Tools").click
      find("#calculator .calculator-card-open").click
      assert_selector "dialog.calculator[open]"
      calculate("12.5mm + 1/4in")
      assert_selector ".calculator-result", text: "18.85 mm"
      find("details.calculator-save > summary").click
      assert_selector "turbo-frame#calculator-save select"
      left, right, client_width, scroll_width = page.evaluate_script(<<~JS)
        (function () {
          var r = document.querySelector('dialog.calculator').getBoundingClientRect()
          return [r.left, r.right, document.documentElement.clientWidth, document.documentElement.scrollWidth]
        })()
      JS
      assert_operator left, :>=, 0
      assert_operator right, :<=, client_width, "the dialog runs off a 375px screen (right #{right}, clientWidth #{client_width})"
      assert_operator scroll_width, :<=, client_width, "the page scrolls sideways with the modal open"
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end

  test "the dialog paints the theme's surface in dark and light, never the browser's white" do
    visit tools_path
    [ "dark", "light" ].each do |theme|
      page.execute_script("document.cookie = 'theme=#{theme}; path=/; max-age=31536000; samesite=lax'")
      visit tools_path
      find("#calculator .calculator-card-open").click
      dialog_bg, surface, fg, dialog_fg = page.evaluate_script(<<~JS)
        (function () {
          var d = document.querySelector('dialog.calculator')
          var probe = document.createElement('div')
          probe.style.background = 'var(--surface)'; probe.style.color = 'var(--fg)'
          document.body.appendChild(probe)
          var p = getComputedStyle(probe), s = getComputedStyle(d)
          var out = [s.backgroundColor, p.backgroundColor, p.color, s.color]
          probe.remove()
          return out
        })()
      JS
      assert_equal surface, dialog_bg, "#{theme}: the dialog is not on --surface"
      assert_equal fg, dialog_fg, "#{theme}: the dialog's text is not --fg"
      refute_equal "rgb(255, 255, 255)", dialog_bg if theme == "dark"
    end
  ensure
    page.execute_script("document.cookie = 'theme=; path=/; max-age=0'")
  end
end
