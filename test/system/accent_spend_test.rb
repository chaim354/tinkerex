require "application_system_test_case"

# THE ACCENT MEANS "THE ONE ACTION THIS PAGE EXISTS FOR" (decision 3 of
# `docs/superpowers/specs/2026-09-10-ui-cohesion-design.md`). This guard is the only thing that
# keeps that true, because nothing else in the suite can see it: the accent is spent by a COMPONENT
# rule, not by the pages, so a page acquires another accent button by rendering a partial that
# already existed, with no diff on the page itself.
#
# WHY THE BROWSER TIER (this directory's README asks for the argument). The count that matters is of
# RESOLVED BACKGROUNDS, and the defect this was written for was invisible to the class list:
# `.upload-btn span` sat inside the `.btn.primary` group in components.css, so every uploader in the
# app painted itself accent with no `primary` class anywhere in the markup. A request test asserting
# on classes would have counted ZERO on the page that had ten. §14e's rule for exactly this shape:
# only a browser knows.
#
# WHY AN EXACT TABLE RATHER THAN A CEILING. A ceiling ("at most two") is satisfied perfectly by an
# app with no accent at all, so deleting the `.btn.primary` rule outright would leave it green while
# the product lost its only strong signal. It also cannot see an uploader that silently LOSES its
# opt-in — which is a new failure mode this slice introduced, since `primary:` now defaults to false
# and a call site can forget it. The table is floor, ceiling and the record of what decision 3
# resolved to, in one assertion. Updating it is meant to cost a deliberate edit: accent spend
# drifting silently across 49 PRs is why this file exists.
#
# WHAT IS COUNTED: elements inside `main` whose computed background-color equals the resolved
# `--accent`, restricted to controls. The restriction is deliberate, not tidiness — `.brand-mark`
# (the rail's 18px logo) and `.attention-row--warn .attention-mark` (a dot on Home) are both
# accent-filled and neither is a control, so counting every element would fail this for two things
# decision 3 does not govern. The accent is compared against a PROBE rather than a literal
# `rgb(240, 165, 58)`: the token has a different value in the light theme, and a literal would pin
# this guard to one of the three theme states.
#
# MUTATION-CHECKED (§15) — three, each run and each restored:
#   1. Putting `.upload-btn span` back into the `.btn.primary` group in components.css —
#      /projects/desk-lamp renders ["Upload & attach", "Upload & attach", "Upload & attach",
#      "Upload & attach", "Save publishing"] against the two expected. ONLY that route reddens, and
#      the reason is worth knowing rather than guessing at: /files draws an uploader that opts IN
#      either way, and Home's hero renders only when a current project is set, which this fixture
#      does not do until its last three lines. The runaway is per-BUILD-LOG-ENTRY, so the project
#      page is the only page that can show it.
#   2. Deleting the `.btn.primary` background/border/color declarations: every route reports []
#      against its expectation, so the FLOOR half is not decoration.
#   3. Dropping `primary: true` from the `projects/upload_control` render in
#      projects/_attachments.html.erb: /projects/desk-lamp reports ["Save publishing"] alone — the
#      opt-in-forgotten case, which a ceiling could never have caught.
class AccentSpendTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("accent@example.com")
    # THE HANDLE IS NOT DECORATION. `projects/_publish` renders "Claim handle" (quiet) until the
    # user has one and "Save publishing" (accent) after — so a handle-less fixture would test the
    # project page at ONE accent control where decision 3 allows it TWO, and the interesting
    # boundary would never be reached. With the handle the page sits exactly ON its cap, which is
    # the only state where a regression of one has anywhere to show.
    @user.update!(handle: "bench")
    @project = @user.maker_projects.create!(name: "Desk Lamp")
    # THE BUILD LOG IS THE POINT OF THIS FIXTURE. Each entry renders its own `upload_control`, so
    # the runaway the spec measured (ten on one page, seven of them the same "Upload & attach")
    # only reproduces on a project that has entries. One entry would prove the rule; three prove it
    # does not scale with the log.
    3.times { |i| @project.build_log_entries.create!(user: @user, body: "Bench note #{i}.") }
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "every page spends the accent on exactly the action it exists for" do
    expected = {
      # Home's was "Files" until 2026-09-10 — a rail destination rendered as the loudest control on
      # the front door, 200px from the rail's own Files link (§2.6).
      "/" => [ "New project" ],
      "/files" => [ "Upload a file" ],
      "/models" => [ "Import model" ],
      "/projects" => [ "New project" ],
      "/inventory" => [ "New item" ],
      # THE ONE PAGE DECISION 3 ALLOWS TWO, and these are the two it names: the folder this project
      # keeps its files in, and the switch that makes the whole thing public. It rendered SEVEN with
      # this fixture and ten with six log entries.
      "/projects/desk-lamp" => [ "Upload & attach", "Save publishing" ],
      # Pages with no action of their own spend none, and pinning [] is what keeps it that way —
      # /tools in particular is about to grow a first-run state (slice 3).
      "/settings" => [],
      "/tools" => [],
      "/search" => [],
      # THE THREE LIST-MANAGEMENT PAGES ARE HERE BECAUSE THE SPEC ASKED FOR THEM TO BE AUDITED
      # (slice 1, "Add supplier / Add location") AND THE AUDIT'S ANSWER WAS "already right".
      # Recording an answer of "no change" as a pinned expectation is the cheap half: without it
      # the next reader has to re-derive that these were looked at.
      "/settings/suppliers" => [ "Add supplier" ],
      "/settings/locations" => [ "Add location" ],
      "/settings/shelves" => [ "Add shelf" ]
    }
    paths = {
      "/" => root_path, "/files" => files_path, "/models" => models_path,
      "/projects" => projects_path, "/inventory" => inventory_items_path,
      "/projects/desk-lamp" => project_path(@project), "/settings" => settings_path,
      "/tools" => tools_path, "/search" => search_path,
      "/settings/suppliers" => suppliers_path, "/settings/locations" => locations_path,
      "/settings/shelves" => shelves_path
    }

    actual = paths.transform_values do |path|
      visit path
      # `main` is this assertion's own precondition. Without it a route that failed to render would
      # report NO accent controls and satisfy every `[]` expectation — §14e's "a guard that scans a
      # directory dies silently when the directory leaves", with a route in place of a glob.
      assert_selector "main", visible: :all
      accent_controls
    end
    assert_equal expected, actual

    # THE FILES PAGE HAS TWO UPLOADERS AND ONLY ONE RENDERS AT A TIME. With no current project it
    # draws its own inline form; with one it renders `projects/upload_control` instead — a separate
    # call site with its own `primary:` to forget, so it needs its own visit. `current_project_id`
    # is the column slice 0 introduced, which `CurrentProject` reads whenever
    # `remember_current_project?` — this user's default.
    @user.update!(current_project_id: @project.id)
    visit files_path
    assert_selector "main", visible: :all
    assert_equal [ "Upload & attach" ], accent_controls,
                 "the Files page's current-project uploader"
  end

  private

    # The labels of every accent-filled control inside `main`, in document order. Labels rather than
    # a bare count so a failure says WHICH controls — a count alone sends the next reader back to
    # the browser to find out what it was talking about.
    def accent_controls
      page.evaluate_script(<<~JS)
        (function () {
          var probe = document.createElement('span')
          probe.style.background = 'var(--accent)'
          document.body.appendChild(probe)
          var accent = getComputedStyle(probe).backgroundColor
          probe.remove()

          var sel = ['a', 'button', 'input[type=submit]', 'input[type=button]', 'summary',
                     'label.upload-btn > span']
                      .map(function (s) { return 'main ' + s }).join(', ')

          return Array.prototype.slice.call(document.querySelectorAll(sel))
            .filter(function (el) { return getComputedStyle(el).backgroundColor === accent })
            .map(function (el) {
              // AN `<input type=submit>` CARRIES ITS LABEL IN `value`, NOT `textContent`, and the
              // first run of this guard reported three of them as "btn small primary" — a failure
              // message naming the class it already knew instead of the button a reader must find.
              var text = el.value || el.textContent || ''
              return text.replace(/\\s+/g, ' ').trim().slice(0, 40) ||
                     el.getAttribute('aria-label') || el.className
            })
        })()
      JS
    end
end
