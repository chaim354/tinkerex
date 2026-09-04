# Shared setup for the browser tier. Extracted because sheet_grid_test and tray_layout_test both
# hand-rolled the same six lines, including the same non-obvious wait, and both explained it in a
# comment — the third copy is the one to avoid writing.
module WebHelpers
  PASSWORD = "correct horse battery staple".freeze

  # See settle_addon_cards. Deliberately larger than Capybara.default_max_wait_time: this one wait
  # covers a whole ESM bundle's load, not a single DOM mutation.
  SETTLE_TIMEOUT = 10

  # Creates a confirmed user and signs in THROUGH THE FORM, then waits for Turbo to actually follow
  # the redirect.
  #
  # THE `assert_current_path` IS NOT DECORATION — do not delete it as a redundant assertion. Without
  # it the next `visit` races the login redirect, arrives before the session cookie is set, and 401s
  # into the login page, which reads exactly like the page under test failing to render. Both
  # existing system tests hit this and both documented it.
  #
  # Signs in through the form rather than via a Warden test helper on purpose: a system test that
  # bypasses the real session path can pass while login itself is broken.
  def sign_in_as(email = "maker@example.com")
    user = User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
    visit new_user_session_path
    fill_in "user[email]",    with: email
    fill_in "user[password]", with: PASSWORD
    click_on "Log in"
    assert_current_path "/"
    user
  end

  # A project plus a library folder to upload into — the shape most of these tests need. Returns
  # [Maker::Project, Node], the folder being the leaf DIR NODE (not an id).
  #
  # Goes through Maker::LibraryFolder rather than creating a Node row directly, so the fixture uses
  # the same door the app does and cannot drift from it. That service is described in its own header
  # as "THE ONE PLACE the cross-backend folder-creation branch lives" — hand-rolling a node here
  # would bypass the port_writable? decision it exists to own, and would then behave differently
  # under `bin/ci test-share`.
  def project_with_folder(user, name: "Lamp", folder: "parts")
    project = user.maker_projects.create!(name:)
    # ensure_path! takes an ARRAY OF SEGMENTS and returns the leaf dir Node. There is no `mkdir`
    # class method on this service — verified against app/services/maker/library_folder.rb.
    folder_node = Maker::LibraryFolder.ensure_path!(user, [ folder ])
    [ project, folder_node ]
  end

  # Clicks a Box Generator gallery card. SIX call sites hand-rolled `find(".addon-card", text: key)
  # .click` before this existed, so this is the fourth copy's worth of duplication the file header
  # already warns about — but it is here for correctness, not tidiness.
  #
  # THE `settle_addon_cards` IS NOT DECORATION — do not collapse this back to a bare click. Every
  # card carries an `<img class="addon-thumb">` asking the sidecar proxy for a sample photo, and a
  # failed one used to remove a 120px-tall box (plus its 6px flex gap) via
  # `.addon-thumb.is-missing { display: none }`, so every card below it jumped up ~126px. Measured
  # for TrayLayout, the last of the four: 1002px -> 624px, a 378px shift arriving whenever four real
  # HTTP round-trips happened to land.
  #
  # Chromedriver's click computes ONE coordinate and then dispatches pointerMove/pointerDown at it.
  # A thumb resolving inside that window moved the card out from under the pointer, the click landed
  # in dead space, and NOTHING RAISED — a silent no-op, after which the test waited out its whole
  # timeout on a gallery page that looked perfectly healthy. That is what had `system-test` red on
  # main (run 31188332739): the failure screenshot shows the gallery, not the editor, and the tests
  # that failed are exactly the ones opening the LAST card.
  #
  # THE SHIFT IS GONE AS OF 2026-08-25 — a sample-less generator keeps its frame, so a 404 changes
  # a card's contents and never its size. TWO THINGS IN THE OLD VERSION OF THIS COMMENT WERE ALSO
  # FALSE BY THEN and are corrected here rather than left as folklore: FakeBoxesSidecar's ABox
  # sample was "deliberately truncated JPEG bytes" that Chrome could not decode, so all four thumbs
  # fired `error` and the fixture contained zero photos — it is a real 1x1 JPEG now, and exactly one
  # card has a photo.
  #
  # THE CALL STAYS, for the race the structural fix does NOT close: the bundle renders this gallery
  # after two async fetches, so `find(".addon-card")` can outrun it, and the helper waits for the
  # cards to exist before anything clicks. It is also the cheap insurance that keeps the old failure
  # from returning silently if the frame ever stops being reserved.
  def open_addon_card(key)
    settle_addon_cards
    find(".addon-card", text: key).click
  end

  # Waits until the gallery has stopped moving: every thumbnail request has ENDED (`complete` is
  # true for a 404 and for a decode failure, not just for a successful load, which is the whole
  # point) and two consecutive reads of every card's position agree. Polling a condition, not
  # sleeping a guessed interval — the shift is caused by network responses whose timing is exactly
  # what nobody can guess.
  #
  # Requiring the cards to exist also absorbs the other flake this page produces on a loaded box:
  # `find(".addon-card")` racing the bundle's own `await`ed generators fetch. That is why the budget
  # is SETTLE_TIMEOUT and not Capybara's 2s default — reaching this gallery means ~20 ESM modules
  # plus two fetches through a 4-thread Puma pool, which on a loaded runner honestly takes longer
  # than 2s (observed: "Unable to find css '.addon-card'" in PlanExportTest). It costs nothing on a
  # quiet box, where the loop returns on its second poll.
  def settle_addon_cards(timeout: SETTLE_TIMEOUT)
    probe = <<~JS
      (function () {
        var thumbs = Array.prototype.slice.call(document.querySelectorAll("img.addon-thumb"))
        if (!thumbs.every(function (i) { return i.complete })) return null
        var cards = Array.prototype.slice.call(document.querySelectorAll(".addon-card"))
        if (!cards.length) return null
        return cards.map(function (c) { return Math.round(c.getBoundingClientRect().top) }).join(",")
      })()
    JS

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    previous = nil
    loop do
      current = page.evaluate_script(probe)
      return current if current && current == previous

      previous = current
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise Capybara::ExpectationNotMet,
              "the gallery cards were still moving after #{timeout}s (last positions: #{current.inspect})"
      end
      sleep 0.05
    end
  end

  # Capybara's matchers wait on the DOM; an <img> swapping its `src` is a PROPERTY read, which no
  # Capybara matcher can wait on — so poll it. Lived privately in box_sections_test until
  # openscad_preview_test needed the same wait for the same reason (a self-starting preview filling
  # an <img>), which by this file's own header is the point at which it moves here.
  def wait_until(timeout: 5, message: "condition never became true")
    deadline = Time.now + timeout
    sleep 0.05 until yield || Time.now > deadline
    assert yield, message
  end

  # Fails the test if the browser logged an error. Cheap, and it catches the whole class of bug
  # where a Stimulus controller throws, the DOM is left half-built, and the assertion below happens
  # to still pass — how the jspreadsheet async-factory bug rendered a permanently empty grid with no
  # error surfaced anywhere.
  #
  # VERIFIED NON-VACUOUS (2026-07-29), which is the only reason it is worth having. Rails' default
  # `driven_by :selenium, using: :headless_chrome` does not obviously enable browser logging, and a
  # helper that always reads [] is a FAKE GUARD in every test that calls it. Probed by provoking a
  # real uncaught error in the page: logs.get(:browser) returned one entry, level "SEVERE", message
  # "Uncaught ReferenceError: nonExistentFunctionCall is not defined". No extra `goog:loggingPrefs`
  # capability is needed.
  # `ignoring:` takes Regexps for failures the page is DESIGNED to produce, and is meant to stay
  # rare — every pattern added here is a hole in the guard. The one real case so far: the generator
  # gallery asks the sidecar proxy for a sample photo that most generators don't have, and the 404
  # is what triggers the thumbfallback controller. Chrome logs a failed subresource at SEVERE, so
  # without this the expected 404 masks any genuine error logged alongside it.
  def assert_no_console_errors(ignoring: [])
    logs = page.driver.browser.logs.get(:browser).select { |l| l.level == "SEVERE" }
    messages = logs.map(&:message).reject { |m| ignoring.any? { |pattern| m.match?(pattern) } }
    assert_empty messages, "the browser logged errors"
  end
end
