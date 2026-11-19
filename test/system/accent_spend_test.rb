require "application_system_test_case"

# ONE PRIMARY PER SCREEN, AND IT IS INK; THE ACCENT FILLS NO CONTROL AT ALL (design-system.md rule 13,
# the Shop manual's proposal 1, 2026-11-19; decision 3 of
# `docs/superpowers/specs/2026-09-10-ui-cohesion-design.md` before it). This guard is the only thing
# that keeps both true, because nothing else in the suite can see them: the primary is drawn by a
# COMPONENT rule, not by the pages, so a page acquires another one by rendering a partial that
# already existed, with no diff on the page itself.
#
# WHY THE BROWSER TIER (this directory's README asks for the argument). The count that matters is of
# RESOLVED BACKGROUNDS, and the defect this was written for was invisible to the class list:
# `.upload-btn span` sat inside the `.btn.primary` group in components.css, so every uploader in the
# app painted itself in the primary's fill with no `primary` class anywhere in the markup. A request
# test asserting on classes would have counted ZERO on the page that had ten. §14e's rule for exactly
# this shape: only a browser knows.
#
# WHY AN EXACT TABLE RATHER THAN A CEILING. A ceiling ("at most one") is satisfied perfectly by an
# app with no primary at all, so deleting the `.btn.primary` rule outright would leave it green while
# the product lost its only strong signal. It also cannot see an uploader that silently LOSES its
# opt-in — a failure mode `primary:` defaulting to false introduced, since a call site can forget it.
# The table is floor, ceiling and the record of where each page spends its one primary, in one
# assertion. Updating it is meant to cost a deliberate edit: the accent's spend drifting silently
# across 49 PRs is why this file exists, and the table carried over unchanged when the fill moved
# from the accent to ink.
#
# WHAT IS COUNTED: controls inside the strip or `main` whose computed background-color equals the
# resolved `--fg`, the ink, LESS those that announce a state (`aria-pressed="true"`, `aria-current`,
# `aria-selected="true"`). Selection is ink too (a pressed toggle, a segmented control's lit part,
# the chosen tag), and a lit part that SAYS it is lit is a selection, not an action; one that says
# nothing is indistinguishable from a primary, which is why the Library's Grid/List links carry
# `aria-current`. The strip is in because Add lives there: an outlined button on every page (Shop
# manual slice 3), which a primary must never become. Only CONTROLS: an ink chip (`.badge`) is a label, not an action. The
# colours are compared against PROBES, never literals, so the guard holds in every theme state.
# AND THE ACCENT FILLS NOTHING: the same controls, compared against the resolved `--accent`, must be
# none on every page. Red marks (a figure number, a flag, the current row's square, focus); it never
# fills a control. The wordmark's red disc is not a control.
#
# MUTATION-CHECKED (§15), each run and restored (re-measured 2026-11-19 for the ink primary):
#   1. Putting `.btn.primary` back on the accent fill (`background: var(--accent)`): every route
#      reports [] in the ink table (the landing's too), the fill having left ink.
#   2. Deleting the `.btn.primary` background/border/color declarations: every route reports []
#      against its expectation, so the FLOOR half is not decoration.
#   3. Giving the strip's Add summary `primary`: every route reports "Add" first — the strip's
#      control is counted, so Add cannot quietly become every page's second primary.
#   4. Dropping the Library's Grid/List `aria-current`: /files reports ["List"] — a lit
#      segment that announces nothing reads as a second primary.
#   5. Filling `.btn[aria-pressed="true"]` with the accent: the ink table stays right (a pressed
#      button is a selection) and the accent table reports "/settings" => ["Light"], so the
#      "fills nothing" half is not decoration either.
class AccentSpendTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("accent@example.com")
    # THE HANDLE IS NOT DECORATION. `projects/_publish` renders "Claim handle" (quiet) until the
    # user has one and "Save publishing" (the primary) after — so a handle-less fixture would measure
    # the Publishing tab with NO primary and never reach the control it exists to spend it on. (Until
    # 2026-10-26 that was the project page's second primary, the one decision 3 allowed; the edit
    # area moved it to a tab of its own.)
    # An admin, so Settings → Users is on a page this guard measures (2026-10-21).
    @user.update!(handle: "bench", admin: true)
    @project = @user.maker_projects.create!(name: "Desk Lamp")
    # THE BUILD LOG IS THE POINT OF THIS FIXTURE. Each entry renders its own `upload_control`, so
    # the runaway the spec measured (ten on one page, seven of them the same "Upload & attach")
    # only reproduces on a project that has entries. One entry would prove the rule; three prove it
    # does not scale with the log.
    3.times { |i| @project.build_log_entries.create!(user: @user, body: "Bench note #{i}.") }
    # A 3D MODEL'S FOLDER (structural redesign §5.4, slice 5), so the Library's model strip is on a
    # page this guard measures. The strip carries Edit, Delete and "Log a print" and spends none of
    # them, and the folder page spends nothing either.
    @model_folder = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "bracket")
    @user.maker_models.create!(title: "Wall Bracket", folder_node_id: @model_folder.node_id)
    # A FILE, for its own page and for the Library with it selected (Shop manual slice 6): the page
    # spends its primary on Download, the selected panel on Open.
    @plate = create_node!(@user, node_id: SecureRandom.uuid, name: "plate.dxf", kind: "file",
                                 size: 5, mtime: 1_000_000_000, content_hash: "h-plate")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "every page fills exactly the action it exists for with ink, and nothing with the accent" do
    # A second account for the Users page's per-account page. HERE, NOT IN setup: the landing test
    # below needs the setup's account to be the only one, or the demo's door stays shut on share.
    @other_account = User.create!(email: "accent-other@example.com", confirmed_at: Time.current, omniauth_signup: true)
    expected = {
      # HOME SPENDS NOTHING (Shop manual slice 3). Its one action was the top bar's Upload until the
      # strip's Add replaced Upload and New ▾ as an outlined button on every page. (The front door's
      # primary was "Files" until 2026-09-10, then "New project" until slice 6, then Upload.)
      "/" => [],
      # The Library spends nothing: Add is outlined, and so are the head's Add files and New folder.
      "/files" => [],
      # A SELECTED FILE'S PANEL spends its one on Open (Shop manual slice 6), the screens' SELECTED panel.
      "/files (a file selected)" => [ "Open" ],
      # A FILE'S PAGE spends it on Download (slice 6): what the page is opened for.
      "/files/:id" => [ "Download" ],
      # The model strip above the files adds nothing (slice 5).
      "/files (a model folder)" => [],
      # The Library's 3D models view (slice 5): its one action is the Add model menu (UX audit E3:
      # a model comes from a file already in the library or from a Printables zip, so the primary
      # opens a menu). The strip's Add is outlined here as everywhere.
      "/files/models" => [ "Add model ▾" ],
      "/projects" => [ "New project" ],
      "/inventory" => [ "New item" ],
      # THE PROJECT PAGE SPENDS NOTHING (Shop manual slice 3): its one action was the top bar's Upload,
      # which the strip's outlined Add replaced. Decision 3 allowed it two, and the second — Save
      # publishing, the switch that makes the whole thing public — is the Publishing tab's one
      # primary now, below. It rendered SEVEN with this fixture and ten with six log entries.
      "/projects/desk-lamp" => [],
      # THE EDIT AREA'S THREE TABS, one primary each, and the strip's Add outlined on all three.
      "/projects/desk-lamp/edit" => [ "Save changes" ],
      "/projects/desk-lamp/publishing" => [ "Save publishing" ],
      "/projects/desk-lamp/layout" => [ "Save layout" ],
      # Pages with no action of their own spend none, and pinning [] is what keeps it that way —
      # /tools in particular is about to grow a first-run state (slice 3).
      "/settings" => [],
      "/tools" => [],
      "/search" => [],
      # THE THREE LIST-MANAGEMENT PAGES ARE HERE BECAUSE THE SPEC ASKED FOR THEM TO BE AUDITED
      # (slice 1, "Add supplier / Add location") AND THE AUDIT'S ANSWER WAS "already right".
      # Recording an answer of "no change" as a pinned expectation is the cheap half: without it
      # the next reader has to re-derive that these were looked at.
      "/inventory/suppliers" => [ "Add supplier" ],
      "/inventory/locations" => [ "Add location" ],
      # THE SHELVES PAGE (2026-10-20; it was Filing, and before that the model catalog's shelves
      # held this path) spends it once, on Add shelf at its foot. Each card's Add (an extension)
      # and Save (its view and group), and the page's Add group and each group's Rename, are quiet:
      # with a dozen cards a per-card primary would be a dozen.
      "/settings/shelves" => [ "Add shelf" ],
      # K (2026-10-20): the library folder page, with a catalog to keep (the model folder above), spends
      # it on Switch; Start over is quiet behind its confirmation. Off share there is nothing to choose.
      "/settings/library" => FileLayer.current.is_a?(FileLayer::Share) ? [ "Switch to this folder" ] : [],
      # Users (2026-10-21): the list spends it on Add user; one user's page on Set password, with
      # Make admin quiet and Delete the danger button behind a typed address.
      "/settings/users" => [ "Add user" ],
      "/settings/users/:id/edit" => [ "Set password" ],
      # Devices (pentest H1b, 2026-10-22): no one action; each row's Sign out is a danger link.
      "/settings/devices" => [],
      # THE ONBOARDING WIZARD (2026-11-09): Choose spends nothing, its two cards being equal; Tour spends
      # its Next, Project its Create, Files nothing (Add's Upload is aimed at the new project's folder), and
      # Done its Open.
      "/welcome" => [],
      "/welcome/files/tour" => [ "Next: your first project" ],
      "/welcome/models/project" => [ "Create project" ],
      "/welcome/files/files" => [],
      "/welcome/models/done" => [ "Open Desk Lamp" ]
    }
    paths = {
      "/" => root_path, "/files" => files_path, "/files/models" => files_models_path,
      "/files (a model folder)" => files_path(folder: @model_folder.node_id),
      "/files (a file selected)" => files_path(selected: @plate.node_id), "/files/:id" => file_path(@plate.node_id),
      "/projects" => projects_path, "/inventory" => inventory_items_path,
      "/projects/desk-lamp" => project_path(@project), "/settings" => settings_path,
      "/projects/desk-lamp/edit" => edit_project_path(@project),
      "/projects/desk-lamp/publishing" => publishing_project_path(@project),
      "/projects/desk-lamp/layout" => edit_layout_project_path(@project),
      "/tools" => tools_path, "/search" => search_path,
      "/inventory/suppliers" => suppliers_path, "/inventory/locations" => locations_path,
      "/settings/shelves" => settings_shelves_path, "/settings/library" => settings_library_path,
      "/settings/users" => settings_users_path, "/settings/users/:id/edit" => edit_settings_user_path(@other_account),
      "/settings/devices" => settings_devices_path,
      "/welcome" => welcome_path,
      "/welcome/files/tour" => welcome_tour_path(track: "files"),
      "/welcome/models/project" => welcome_project_path(track: "models"),
      "/welcome/files/files" => welcome_files_path(track: "files", project: @project.slug),
      "/welcome/models/done" => welcome_done_path(track: "models", project: @project.slug)
    }

    accent = {}
    actual = paths.to_h do |name, path|
      visit path
      # `main` is this assertion's own precondition. Without it a route that failed to render would
      # report NO filled controls and satisfy every `[]` expectation — §14e's "a guard that scans a
      # directory dies silently when the directory leaves", with a route in place of a glob.
      assert_selector "main", visible: :all
      # The model folder's row pins the strip spending nothing only while the strip is ON the page —
      # without it, a folder that stopped showing its model would report [] just the same.
      assert_selector ".model-strip h2", text: "Wall Bracket" if path == paths["/files (a model folder)"]
      # The panel loads into a frame after the page, so its Open is measured only once it is there.
      assert_selector ".inspector .inspector-name", text: "plate.dxf" if path == paths["/files (a file selected)"]
      filled = filled_controls
      accent[name] = filled["accent"]
      [ name, filled["ink"] ]
    end
    assert_equal expected, actual
    assert_equal paths.keys.index_with { [] }, accent, "the accent marks; it fills no control (rule 13)"
  end

  # THE LANDING (2026-10-16): signed out on a demo deployment, its one action is Try the demo
  # (design-system.md rule 15), an ink fill like every other primary. Its own test because every
  # route above is signed in. The setup's account doubles as the demo account -- the only account, so
  # on share and s3 no other library sharer closes the demo's door and the expectation is the same on
  # every leg. Install's state, with no demo account, is landing_test.rb's (both states, by class).
  test "the landing fills Try the demo with ink, and nothing with the accent" do
    prior = ENV["DEMO_ACCOUNT_EMAIL"]
    ENV["DEMO_ACCOUNT_EMAIL"] = @user.email
    Capybara.reset_sessions!
    visit "/"
    assert_selector ".landing-hero h1"
    filled = filled_controls
    assert_equal [ "Try the demo" ], filled["ink"]
    assert_equal [], filled["accent"], "the accent marks; it fills no control (rule 13)"
  ensure
    prior.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = prior
  end

  # THE PUBLIC PAGES (Shop manual slice 8). A published project spends its one primary on the bundle,
  # an ink fill: taking the project away is what a visitor comes for. Explore and a maker's page spend
  # nothing. Signed in, which is no weakening: a public page renders the visitor's view whatever the
  # session says (Public::BaseController), and its header is not the strip, so the header's outlined
  # Sign in is outside the count either way. Mutation-checked (2026-11-19): the bundle button back on
  # `btn small` reported "/u/bench/bench-lamp" => [].
  test "a published project fills its bundle with ink, the public lists spend nothing, and nothing takes the accent" do
    projects = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "Projects")
    folder = FileLayer.current.mkdir(@user, parent_node_id: projects.node_id, name: "bench-lamp")
    FileLayer.current.write(@user, parent_node_id: folder.node_id, name: "base.stl", io: StringIO.new("solid base\nendsolid base\n"))
    lamp = @user.maker_projects.create!(name: "Bench Lamp", visibility: "public", folder_node_id: folder.node_id)
    paths = { "/u/bench/bench-lamp" => public_project_path(@user.handle, lamp.slug),
              "/explore" => public_explore_path, "/u/bench" => public_user_path(@user.handle) }
    accent = {}
    actual = paths.to_h do |name, path|
      visit path
      assert_selector "main.public-main"
      assert_selector "header.public-header"
      filled = filled_controls
      accent[name] = filled["accent"]
      [ name, filled["ink"] ]
    end
    assert_equal({ "/u/bench/bench-lamp" => [ "Download bundle (1 file, 25 Bytes)" ], "/explore" => [], "/u/bench" => [] }, actual)
    assert_equal paths.keys.index_with { [] }, accent, "the accent marks; it fills no control (rule 13)"
  end

  private

    # { "ink" => [...], "accent" => [...] }: the labels of every control inside the strip or `main`
    # filled with ink (less those announcing a state, see the header) and with the accent, in document
    # order (the strip comes first). Labels rather than a bare count so a failure says WHICH controls —
    # a count alone sends the next reader back to the browser to find out what it was talking about.
    def filled_controls
      page.evaluate_script(<<~JS)
        (function () {
          var resolve = function (token) {
            var probe = document.createElement('span')
            probe.style.background = 'var(' + token + ')'
            document.body.appendChild(probe)
            var colour = getComputedStyle(probe).backgroundColor
            probe.remove()
            return colour
          }
          var ink = resolve('--fg'), accent = resolve('--accent')
          // A lit part that says it is lit is a selection, drawn in ink by rule 13, not an action.
          var announcesState = function (el) {
            return el.getAttribute('aria-pressed') === 'true' || el.getAttribute('aria-selected') === 'true' ||
                   (el.hasAttribute('aria-current') && el.getAttribute('aria-current') !== 'false')
          }

          var sel = ['a', 'button', 'input[type=submit]', 'input[type=button]', 'summary',
                     '.upload-btn > span']
                      .reduce(function (all, s) { return all.concat(['header.strip ' + s, 'main ' + s]) }, [])
                      .join(', ')

          // AN `<input type=submit>` CARRIES ITS LABEL IN `value`, NOT `textContent`, and the first
          // run of this guard reported three of them as "btn small primary" — a failure message
          // naming the class it already knew instead of the button a reader must find.
          var label = function (el) {
            var text = el.value || el.textContent || ''
            return text.replace(/\\s+/g, ' ').trim().slice(0, 40) ||
                   el.getAttribute('aria-label') || el.className
          }
          var controls = Array.prototype.slice.call(document.querySelectorAll(sel))
          var filled = function (colour) {
            return controls.filter(function (el) { return getComputedStyle(el).backgroundColor === colour })
          }
          return {
            ink: filled(ink).filter(function (el) { return !announcesState(el) }).map(label),
            accent: filled(accent).map(label)
          }
        })()
      JS
    end
end
