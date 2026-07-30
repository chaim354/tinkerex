# Shared setup for the browser tier. Extracted because sheet_grid_test and tray_layout_test both
# hand-rolled the same six lines, including the same non-obvious wait, and both explained it in a
# comment — the third copy is the one to avoid writing.
module WebHelpers
  PASSWORD = "correct horse battery staple".freeze

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
    assert_current_path "/files"
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
  def assert_no_console_errors
    logs = page.driver.browser.logs.get(:browser).select { |l| l.level == "SEVERE" }
    assert_empty logs.map(&:message), "the browser logged errors"
  end
end
