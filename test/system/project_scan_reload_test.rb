require "application_system_test_case"

# THE "Scan folder" BUTTON'S ONE-SHOT RELOAD, WHICH ONLY A BROWSER CAN SEE.
#
# On share/s3 the scan is a background job — an unbounded NAS walk or bucket listing — so the
# request that starts it cannot show the result. `projects/_attachments.html.erb` therefore renders
#
#     <span data-controller="scanreload" data-scanreload-url-value="…the param-free project path…"
#           data-scanreload-status-url-value="/files/scan_status" data-scanreload-since-value="…">
#
# when `@scan_started && capabilities.scannable?`, and `scanreload_controller.js` POLLS
# `/files/scan_status` every 2000 ms until the answer differs from the stamp the page rendered with,
# then navigates to that param-FREE url. Both halves of that are invisible below the browser:
#
#   * `test/stimulus_hygiene_test.rb` proves the identifier RESOLVES TO A FILE, and nothing more.
#     A controller whose `connect()` throws, or is misspelled, or whose `static values` no longer
#     name `url`, resolves to a file just as well and does nothing at all.
#   * `test/integration/web/project_scan_button_test.rb` proves the ATTRIBUTE IS IN THE HTML
#     (`assert_select "[data-controller~=?]", "scanreload", 1`). An attribute on a page whose
#     JavaScript never runs is exactly the shape of §14d's nine-day outage: Stimulus neither throws
#     nor warns on an identifier it cannot resolve, so a dead controller renders a perfect page.
#
# That is CLAUDE.md §15's recorded dominant failure mode — a green suite over something that never
# runs — and it is what this file exists to close. It asserts the NAVIGATION, not the attribute.
#
# IT IS EXPENSIVE, AND MOST OF THAT IS NO_LOOP_WATCH: the only way to observe that a poll does NOT
# navigate is to outlive several of its intervals. The reload half is now as fast as the scan — the
# stamp is written in Ruby mid-test and the very next 2000 ms poll sees it — where the 6000 ms guess
# it replaced had to be waited out in full. Two tests, because "it fires when the scan finished" and
# "it does not fire when nothing finished" are two claims and the second is the one the guess could
# not make at all.
#
# NO LIBRARY FILES OF ITS OWN. The behaviour under test is a timer and a url; a project with no
# attachments renders the panel, the button and the flash exactly as one with fifty would. It still
# takes `use_fresh_share_library!` (addon_bundle_test.rb's pattern) for two reasons that are not
# about fixtures: `ProjectsController#show` calls `ensure_library_folder!`, which mkdirs
# `Projects/<slug>` THROUGH THE PORT — and the system gate shares ONE `LIBRARY_PATH` for the whole
# run while the database rolls back per test, so that directory outlives the row that named it and
# a second test wanting the same slug meets Share's clobber refusal (§14a). It also pins the
# adapter, so `capabilities.scannable?` is true because this test says so rather than because the
# gate happens to export `LIBRARY_BACKEND=share`.
#
# MUTATION-CHECKED — FOUR TIMES, THREE ON THE CODE AND ONE ON THE TEST ITSELF (README: "a test
# nobody has watched fail is a test nobody should trust"). Each was reverted with `git checkout --`
# and `git status --porcelain` confirmed empty before the next:
#
#   1. `connect()` renamed to `connectt()` in scanreload_controller.js — Stimulus registers the
#      controller and never calls it, so the element is present, the page is perfect, and nothing
#      navigates. RED: `expected "/projects/desk-lamp?scanning=1" to equal "/projects/desk-lamp"`,
#      at the `assert_current_path ..., wait: 15` below.
#   2. `window.location.replace(this.urlValue)` -> `window.location.reload()` — the reload carries
#      `?scanning=1` forward, the reloaded page renders a fresh scanreload element, and it loops
#      forever. RED with the IDENTICAL message, at the SAME assertion — not at the no-loop pair,
#      and that is a property of the defect rather than a gap here: a page that never leaves
#      `?scanning=1` fails "did it reach the param-free url" before it can fail "did it stay
#      there", and no assertion can observe a loop it never entered.
#   3. So the no-loop pair was mutation-checked on its own: dropping `@scan_started &&` from the
#      view's guard makes the param-free page render its own scanreload element, which hops to
#      itself forever. The path assertion stays GREEN through that (every hop lands on the same
#      url) and only the element-absence assertion sees it. RED: `expected not to find css
#      "[data-controller~='scanreload']", found 1 match: ""`.
#   4. AND `visible: :all` WAS MUTATION-CHECKED TOO, because a guard that cannot fail is worse than
#      none. With mutation 3 still applied, dropping `visible: :all` from the `assert_no_selector`
#      turned that RED back to a full GREEN run — Selenium reports the empty <span> as not
#      displayed, so the default `visible: :visible` makes the absence assertion true whether or
#      not the element is there. Do not "tidy" those two kwargs away.
#
# MUTATIONS 1, 3 AND 4 ARE INHERITED FROM THE 6000 ms VERSION AND WERE NOT RE-RUN AT S4-3; they are
# about `connect()`, the view's guard and the kwargs, none of which this change touched. MUTATION 2
# is likewise unchanged in kind. WHAT S4-3 ADDED ITS OWN MUTATION FOR is the COMPARISON, which is
# the whole difference from the guess: `if (stamp && stamp !== this.sinceValue)` -> `if (stamp ===
# undefined)` makes the poll never navigate, and the first test below goes RED with
# `expected "/projects/desk-lamp?scanning=1" to equal "/projects/desk-lamp"`. The second test
# ("no scan finishing means no reload") is the guard for the other direction and CANNOT be
# mutation-checked from the comparison: dropping `&& stamp !== this.sinceValue` leaves it green,
# because nothing is stamped there and `stamp` is null either way. It is the SECOND test that makes
# the first one's mid-test stamp load-bearing rather than decorative.
class ProjectScanReloadTest < ApplicationSystemTestCase
  # Comfortably past several of the controller's 2000 ms poll intervals, and the price of asserting
  # that NOTHING happens: the only way to observe a poll not navigating is to outlive the moments it
  # would have.
  NO_LOOP_WATCH = 9

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("scanreload@example.com")
    @project = @user.maker_projects.create!(name: "Desk Lamp")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "the scan button's reload fires once, to the url without the marker" do
    visit project_path(@project)
    assert_button "Scan folder"

    click_on "Scan folder"

    # The async branch: Library::ScanJob is enqueued and the page says so. Both of these are
    # request-level facts already pinned by project_scan_button_test.rb — they are here as the
    # PRECONDITION for what follows, so a failure further down can be read as "the reload did not
    # happen" rather than "the button did not work". Both are instant DOM/url reads, and nothing can
    # move the page under them: no scan has stamped anything yet, so every poll answers null.
    assert_current_path project_path(@project, scanning: 1)
    assert_selector ".flash-notice", text: /Scanning your library/i

    # `visible: :all` IS NOT OPTIONAL AND IS NOT TIDINESS — see mutation 4 in the header. The
    # element is an EMPTY <span>, which Selenium reports as not displayed, so the default
    # `visible: :visible` makes this assertion unsatisfiable here and — far worse — makes its
    # `assert_no_selector` twin below pass whether the element is there or not.
    assert_selector "[data-controller~='scanreload']", visible: :all

    # THE SCAN FINISHES — IN RUBY, BECAUSE ActiveJob's test adapter never runs what it queues.
    # A system test shares its database connection with the server thread, so this row is what the
    # browser's next poll reads. Stamping it is exactly what Library::ScanJob#perform's last line
    # does, and pinning that line's EFFECT here rather than re-running the job keeps this test about
    # the browser half.
    @user.update_column(:library_scanned_at, Time.current)

    # THE ASSERTION THIS FILE EXISTS FOR: nobody drives this navigation. No click, no `visit`, no
    # Turbo submission — the browser leaves `?scanning=1` on its own, which it can only do if the
    # controller was constructed, connect() started the poll, the poll read a stamp different from
    # the one this page rendered with, and urlValue named where to go.
    #
    # A STRING EXPECTATION IS COMPARED AGAINST `request_uri`, QUERY INCLUDED (Capybara defaults
    # `ignore_query: false`), which is the whole reason this can tell the two urls apart. Adding
    # `ignore_query: true` here would make it pass on the page it is meant to leave.
    assert_current_path project_path(@project), wait: 15

    # ONCE, NOT FOREVER — the property the param-free url exists to produce. Structurally first:
    # no element means no controller instance means no second timer, and it fails IMMEDIATELY on a
    # page that kept rendering the element, instead of waiting out the watch below to find out.
    assert_no_selector "[data-controller~='scanreload']", visible: :all

    # `sleep`, NOT A POLL LOOP. The claim is that nothing happens, so there is no condition to poll
    # for; a loop asserting inside it would also make this file's assertion count depend on how
    # fast the box is, which is noise in exactly the number §15 asks a human to read.
    sleep NO_LOOP_WATCH
    # `wait: 0` deliberately: the condition already holds, and if it does not, the page has
    # navigated away, so waiting 10 s for it to come back is 10 s spent confirming a failure.
    assert_current_path project_path(@project), wait: 0

    assert_no_console_errors
  end

  # THE POLL DOES NOT RELOAD ON A SCAN THAT NEVER FINISHED, which is the whole difference between
  # this and the 6-second guess it replaced: the old controller navigated whether or not anything
  # had happened. NO_LOOP_WATCH outlives several poll intervals, so this is a claim about the
  # comparison rather than about timing.
  test "no scan finishing means no reload" do
    visit project_path(@project)
    click_on "Scan folder"
    assert_current_path project_path(@project, scanning: 1)
    assert_selector "[data-controller~='scanreload']", visible: :all

    sleep NO_LOOP_WATCH

    assert_current_path project_path(@project, scanning: 1), wait: 0
    assert_no_console_errors
  end
end
