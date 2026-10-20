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
# WHAT IS COUNTED: elements inside the top bar or `main` whose computed background-color equals the
# resolved `--accent`, restricted to controls. The top bar joined in redesign slice 4, when Upload
# moved there and became the Library's and the project hub's one action — a guard still reading
# `main` alone would have seen those two pages lose their primary and reported it as `[]`. The
# restriction is deliberate, not tidiness — `.brand-mark`
# (the rail's 18px logo) is accent-filled and is not a control (the front door's low-stock dot was the
# second such element until the 2026-10-08 redesign moved it to `--warn`), so counting every
# element would fail this for things decision 3 does not govern. The accent is compared against a PROBE rather than a literal
# `rgb(240, 165, 58)`: the token has a different value in the light theme, and a literal would pin
# this guard to one of the three theme states.
#
# MUTATION-CHECKED (§15) — four, each run and each restored (re-measured in redesign slice 6, when
# Recent made the top bar's Upload its one action):
#   1. Putting `.upload-btn span` back into the `.btn.primary` group in components.css — every
#      route except /, /files (both rows) and /projects/desk-lamp gains an "Upload" at the head of
#      its list (/projects reports ["Upload", "New project"], /settings ["Upload"]): the top bar's
#      QUIET Upload, on every signed-in page, turns accent. The routes that stay green are the ones
#      where Upload opts IN either way. The build-log entries' "Upload & attach" no longer shows
#      here even under this mutation: they sit in each entry's action menu, where `.menu-item--host .upload-btn
#      span` resets the background — so the per-entry runaway the spec measured (seven on one page)
#      is now held by that rule, and the fixture's entries are what would show it coming back.
#   2. Deleting the `.btn.primary` background/border/color declarations: every route reports []
#      against its expectation, so the FLOOR half is not decoration.
#   3. Dropping `primary: true` from ProjectsController#show's `use_folder_destination`:
#      /projects/desk-lamp reports ["Save publishing"] alone — the opt-in-forgotten case, which a
#      ceiling could never have caught.
#   4. Deleting `upload_primary!` from HomeController#index: "/" reports [] — the same
#      opt-in-forgotten case on the one page whose Upload is its accent without a folder.
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
    # A 3D MODEL'S FOLDER (structural redesign §5.4, slice 5), so the Library's model strip is on a
    # page this guard measures. The strip carries Edit, Delete and "Log a print" and spends none of
    # them: the folder's one action is still the top bar's Upload.
    @model_folder = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "bracket")
    @user.maker_models.create!(title: "Wall Bracket", folder_node_id: @model_folder.node_id)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "every page spends the accent on exactly the action it exists for" do
    expected = {
      # RECENT'S ONE ACTION IS THE TOP BAR'S UPLOAD (slice 6, spec §4.2), although the page shows no
      # folder: FolderDestination's upload_primary! changes Upload's weight and leaves it asking with
      # the chooser. The head's "New project" went — New ▾ in the top bar already has Project. (The
      # front door's accent was "Files" until 2026-09-10, a rail destination rendered as the loudest
      # control on the page, §2.6; then "New project" until slice 6.)
      "/" => [ "Upload" ],
      # The top bar's, now the Library's one action (redesign slice 4).
      "/files" => [ "Upload" ],
      # The model strip above the files adds nothing (slice 5).
      "/files (a model folder)" => [ "Upload" ],
      # The Library's 3D models view (slice 5): its one action is Import model. No folder is on screen,
      # so the top bar's Upload stays quiet (FolderDestination is never set here).
      "/files/models" => [ "Import model" ],
      "/projects" => [ "New project" ],
      "/inventory" => [ "New item" ],
      # THE ONE PAGE DECISION 3 ALLOWS TWO, and these are the two it names: the folder this project
      # keeps its files in (now the top bar's Upload, into that folder) and the switch that makes the
      # whole thing public. It rendered SEVEN with this fixture and ten with six log entries.
      "/projects/desk-lamp" => [ "Upload", "Save publishing" ],
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
      "/settings/shelves" => [ "Add shelf" ],
      # K (2026-10-20): the library folder page, with a catalog to keep (the model folder above), spends
      # it on Switch; Start over is quiet behind its confirmation. Off share there is nothing to choose.
      "/settings/library" => FileLayer.current.is_a?(FileLayer::Share) ? [ "Switch to this folder" ] : []
    }
    paths = {
      "/" => root_path, "/files" => files_path, "/files/models" => files_models_path,
      "/files (a model folder)" => files_path(folder: @model_folder.node_id),
      "/projects" => projects_path, "/inventory" => inventory_items_path,
      "/projects/desk-lamp" => project_path(@project), "/settings" => settings_path,
      "/tools" => tools_path, "/search" => search_path,
      "/inventory/suppliers" => suppliers_path, "/inventory/locations" => locations_path,
      "/settings/shelves" => settings_shelves_path, "/settings/library" => settings_library_path
    }

    actual = paths.transform_values do |path|
      visit path
      # `main` is this assertion's own precondition. Without it a route that failed to render would
      # report NO accent controls and satisfy every `[]` expectation — §14e's "a guard that scans a
      # directory dies silently when the directory leaves", with a route in place of a glob.
      assert_selector "main", visible: :all
      # The model folder's row pins the strip spending nothing only while the strip is ON the page —
      # without it, a folder that stopped showing its model would report ["Upload"] just the same.
      assert_selector ".model-strip h2", text: "Wall Bracket" if path == paths["/files (a model folder)"]
      accent_controls
    end
    assert_equal expected, actual
  end

  # THE LANDING (2026-10-16): signed out on a demo deployment, its one action is Try the demo
  # (design-system.md rule 15). Its own test because every route above is signed in. The setup's
  # account doubles as the demo account -- the only account, so on share and s3 no other library
  # sharer closes the demo's door and the expectation is the same on every leg.
  test "the landing spends the accent on Try the demo" do
    prior = ENV["DEMO_ACCOUNT_EMAIL"]
    ENV["DEMO_ACCOUNT_EMAIL"] = @user.email
    Capybara.reset_sessions!
    visit "/"
    assert_selector ".landing-hero h1"
    assert_equal [ "Try the demo" ], accent_controls
  ensure
    prior.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = prior
  end

  private

    # The labels of every accent-filled control inside the top bar or `main`, in document order (the
    # bar comes first). Labels rather than a bare count so a failure says WHICH controls — a count
    # alone sends the next reader back to the browser to find out what it was talking about.
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
                      .reduce(function (all, s) { return all.concat(['header.topbar ' + s, 'main ' + s]) }, [])
                      .join(', ')

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
