require "test_helper"

module Web
  class ProjectsFlowTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # Maker data is backend-neutral, but the detail/list views READ file metadata + capabilities
    # through FileLayer.current. Pin a real backend so a `LIBRARY_BACKEND=share` CI leg (which has
    # no LIBRARY_PATH) doesn't fail these on backend construction — they aren't share tests.
    setup do
      # A hermetic library for this suite. It pinned embedded chunk until Arc D Part 2; with that
      # backend retired it would otherwise run on the AMBIENT one, which on the s3 leg means real
      # Aws calls (the stub is opt-in per file) and on chunk_remote means a live sync server.
      # What these tests are about is the web layer, not which backend holds the bytes.
      @root = use_fresh_share_library!
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "requires login" do
      get projects_path
      assert_redirected_to new_user_session_path
    end

    test "index lists live projects in one flat list, empty state otherwise" do
      user = sign_in
      get projects_path
      assert_response :success
      assert_select "h1", "Projects"
      assert_select ".projects-empty"

      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      user.maker_projects.create!(name: "Bench Jig", status: "paused")
      user.maker_projects.create!(name: "Old Rig", status: "archived")
      get projects_path

      # One grid, no per-status sections.
      assert_select ".projects-grid", count: 1
      # A non-archived status is no longer a heading and no longer a badge.
      assert_select ".project-card .badge", count: 0
      assert_select ".project-card .project-name", text: "Desk Lamp"
      assert_select ".project-card .project-name", text: "Bench Jig"
      # Archived projects stay out of the default listing.
      assert_select ".project-card .project-name", text: "Old Rig", count: 0
    end

    test "index shows only the current user's projects" do
      sign_in("a@example.com").maker_projects.create!(name: "Mine")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.maker_projects.create!(name: "Theirs")
      get projects_path
      assert_select ".project-name", text: "Mine"
      assert_select ".project-name", text: "Theirs", count: 0
    end

    # --- create ----------------------------------------------------------------

    test "create a project with valid params" do
      sign_in
      get new_project_path
      assert_response :success
      assert_select "form"

      assert_difference "Maker::Project.count", 1 do
        post projects_path, params: { project: { name: "Smart Lamp", status: "active", description: "RGB" } }
      end
      project = Maker::Project.order(:created_at).last
      assert_redirected_to project_path(project)
      assert_equal "smart-lamp", project.slug
      follow_redirect!
      assert_select "h1", text: /Smart Lamp/
    end

    test "the new-project form submits params under the key the controller requires" do
      # Regression: form_with model: @project on a NAMESPACED model (Maker::Project) scopes fields
      # to `maker_project[...]`, but ProjectsController#create does params.require(:project). The
      # rendered form and the controller must agree, or every create/edit through the UI fails.
      # (The other create test POSTs `project:` directly, so it never exercised the real form.)
      sign_in
      get new_project_path
      assert_response :success
      assert_select "form input[name=?]", "project[name]"
      assert_select "form input[name=?]", "maker_project[name]", count: 0
    end

    test "creating through the actual rendered form params succeeds" do
      sign_in
      # Mirror what the browser sends: exactly the fields the form renders, by name.
      assert_difference "Maker::Project.count", 1 do
        post projects_path, params: { "project" => { "name" => "Via Form", "status" => "planning", "description" => "" } }
      end
    end

    test "creating a project ensures a Projects/<slug> library folder and stores its node_id" do
      user = sign_in
      post projects_path, params: { project: { name: "Desk Lamp", status: "planning" } }
      project = user.maker_projects.order(:created_at).last
      assert project.folder_node_id.present?, "the project's folder node_id must be stored"
      folder = user.nodes.present.find_by!(node_id: project.folder_node_id)
      assert_equal "dir", folder.kind
      assert_equal "desk-lamp", folder.name
      assert_equal "Projects", user.nodes.find_by!(node_id: folder.parent_node_id).name
    end

    test "project create still succeeds if the library backend can't make the folder" do
      user = sign_in
      broken = Object.new
      def broken.capabilities = Object.new.tap { |c| def c.port_writable? = true }
      def broken.mkdir(*) = raise(FileLayer::FetchError, "down")
      FileLayer.current = broken
      assert_difference "Maker::Project.count", 1 do
        post projects_path, params: { project: { name: "Lamp", status: "planning" } }
      end
      assert_nil user.maker_projects.order(:created_at).last.folder_node_id
    ensure
      FileLayer.reset!
    end

    test "create with a blank name re-renders the form with an error" do
      sign_in
      assert_no_difference "Maker::Project.count" do
        post projects_path, params: { project: { name: "" } }
      end
      assert_response :unprocessable_entity
      assert_select "form"
    end

    # --- detail + lifecycle ----------------------------------------------------

    test "show renders the project header and description" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp", status: "active",
                                            description: "A nice lamp")
      get project_path(project)
      assert_response :success
      assert_select "h1", text: /Desk Lamp/
      assert_select ".project-description", text: /A nice lamp/
    end

    test "show 404s for another user's project" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      p = other.maker_projects.create!(name: "Theirs")
      get project_path(p)   # slug-based path; a's scope has no such slug
      assert_response :not_found
    end

    # STAGE 4, S4-2 (story 4.3): the per-project sweep switch. ASSERTED AS RENDERED (§14d's
    # twice-shipped `scope:` bug) — and the hidden "0" beside it is the half that makes UNCHECKING
    # reach the controller at all: without it an unchecked box sends nothing and `autofile` could
    # never be turned off through the form.
    test "the form offers the sweep switch and the controller reads it" do
      user = sign_in
      project = user.maker_projects.create!(name: "Sweepable")
      get edit_project_path(project)
      assert_select "form.project-form input[name=?][type=checkbox]", "project[autofile]"
      assert_select "form.project-form input[name=?][type=hidden][value=?]", "project[autofile]", "0"

      patch project_path(project), params: { project: { name: project.name, autofile: "0" } }
      refute project.reload.autofile?
    end

    test "edit + update changes fields" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old", status: "planning")
      get edit_project_path(project)
      assert_response :success
      patch project_path(project), params: { project: { name: "New", status: "paused" } }
      project.reload
      assert_equal "New", project.name
      assert_equal "paused", project.status
      assert_redirected_to project_path(project)
    end

    test "destroy archives (soft) rather than deleting" do
      user = sign_in
      project = user.maker_projects.create!(name: "Done Build", status: "active")
      assert_no_difference "Maker::Project.count" do
        delete project_path(project)
      end
      assert_equal "archived", project.reload.status
      assert_redirected_to projects_path
    end

    # --- cover thumbnails ------------------------------------------------------

    test "cover_node_id prefers image, then model, then first attachment, else nil" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      assert_nil project.cover_node_id

      project.file_attachments.create!(user:, node_id: "m1", role: "model", position: 0)
      project.file_attachments.create!(user:, node_id: "i1", role: "image", position: 1)
      assert_equal "i1", project.reload.cover_node_id, "an image cover wins over a model"

      project.file_attachments.destroy_all
      project.file_attachments.create!(user:, node_id: "src", role: "source_archive", position: 0)
      project.file_attachments.create!(user:, node_id: "m2", role: "model", position: 1)
      assert_equal "m2", project.reload.cover_node_id, "a model wins over a non-image/non-model"
    end

    test "a project card shows a cover cell when it has an attachment" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp", status: "active")
      user.nodes.create!(node_id: "c1", name: "cover.png", kind: "file")
      project.file_attachments.create!(user:, node_id: "c1", role: "image")

      get projects_path
      assert_select ".project-card .file-cell[data-node-id=?]", "c1"
    end

    # --- archived view + unarchive ----------------------------------------------

    test "the archived view lists archived projects and links back" do
      user = sign_in
      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      user.maker_projects.create!(name: "Old Rig", status: "archived")

      get projects_path(archived: 1)
      assert_response :success
      assert_select "h1", "Archived projects"
      assert_select ".project-card .project-name", text: "Old Rig"
      assert_select ".project-card .project-name", text: "Desk Lamp", count: 0
    end

    # The Unarchive button must live INSIDE its own card's container, never as a bare sibling of
    # the card. `.projects-grid` is `display: grid`, and every DIRECT child of a grid container
    # becomes its own independent grid item — a bare sibling button is a SECOND grid item per
    # archived project, so auto-placement has no idea it belongs with the card next to it. With
    # 2+ archived projects the button can visually land next to a different project entirely
    # (most visibly once the grid wraps a row). Text-content assertions like the ones above can't
    # see this; only checking the actual container structure can.
    test "each archived card owns its own unarchive button" do
      user = sign_in
      old_rig = user.maker_projects.create!(name: "Old Rig", status: "archived")
      older_rig = user.maker_projects.create!(name: "Older Rig", status: "archived")

      get projects_path(archived: 1)

      # One grid item per project, each a `.project-tile` — never a bare card or a bare button
      # sitting loose as its own grid item.
      tiles = css_select(".projects-grid > .project-tile")
      assert_equal 2, tiles.size, "expected one .project-tile per archived project"
      assert_select ".projects-grid > form", count: 0
      assert_select ".projects-grid > a.project-card", count: 0

      [ old_rig, older_rig ].each do |project|
        tile = tiles.find { |t| t.at_css(".project-name")&.text&.strip == project.name }
        assert tile, "no .project-tile found for #{project.name}"
        # Scoped to THIS tile: the unarchive form for THIS project must be nested inside the same
        # container as its own card, not merely present somewhere on the page.
        assert_select tile, "form[action=?] button", unarchive_project_path(project), text: "Unarchive"
      end
    end

    test "the default index links to the archived view when there are archived projects" do
      user = sign_in
      user.maker_projects.create!(name: "Old Rig", status: "archived")
      get projects_path
      assert_select ".archived-note a", text: "1 archived project"

      user.maker_projects.create!(name: "Older Rig", status: "archived")
      get projects_path
      assert_select ".archived-note a", text: "2 archived projects"
    end

    # Step 0(b): with nothing archived there is nothing to say, so the note must not render at all.
    test "the archived note is absent when nothing is archived" do
      user = sign_in
      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      get projects_path
      assert_select ".archived-note", count: 0
    end

    # Step 0(a): `.present?` would have made "0" truthy and served the ARCHIVED view here.
    test "archived=0 shows the live list, not the archive" do
      user = sign_in
      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      user.maker_projects.create!(name: "Old Rig", status: "archived")

      get projects_path(archived: 0)
      assert_select "h1", "Projects"
      assert_select ".project-card .project-name", text: "Desk Lamp"
      assert_select ".project-card .project-name", text: "Old Rig", count: 0
    end

    test "unarchive returns a project to the live list" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old Rig", status: "archived",
                                            archived_at: Time.current)

      patch unarchive_project_path(project)
      assert_redirected_to projects_path

      project.reload
      assert_equal "active", project.status
      assert_nil project.archived_at

      get projects_path
      assert_select ".project-card .project-name", text: "Old Rig"
    end

    # `config.action_dispatch.show_exceptions = :rescuable` in the test env, so a RecordNotFound
    # from the current_user scoping arrives as a 404 RESPONSE rather than a raised exception —
    # which is why every cross-user test in this suite asserts the status, not an exception.
    test "unarchive cannot reach another user's project" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs", status: "archived")

      patch unarchive_project_path(theirs)
      assert_response :not_found
      assert_equal "archived", theirs.reload.status
    end

    # --- status badge/select removal --------------------------------------------

    # STAGE 4, S4-6: `planning` (the column default) is still badged nowhere — badging a default is
    # noise. The fixture was `paused` and asserted only the ABSENCE of `.status-archived`, which now
    # passes over a page that badges: the assertion has to be about this page's whole badge set, on
    # the one status that carries no badge at all.
    test "the detail page shows no status badge for a project in the default status" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp", status: "planning")
      get project_path(project)
      assert_response :success
      assert_select "h1", "Desk Lamp"
      assert_select ".badge.status-archived", count: 0
      assert_select ".page-title .badge", count: 0
    end

    test "the detail page badges an archived project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old Rig", status: "archived")
      get project_path(project)
      assert_select ".badge.status-archived", text: "Archived"
    end

    # STORY 1.2 / 1.6: "no status field on the form, so planning/active/paused/done are
    # unreachable — share: all 9 projects read planning". ASSERT THE RENDERED FIELD NAME, which is
    # §14d's twice-shipped `scope:` bug: a nested-hash POST bypasses the form entirely and cannot
    # see `maker_project[status]`.
    test "the project form offers a status select carrying the four live statuses" do
      sign_in
      get new_project_path
      assert_response :success
      assert_select "form.project-form select[name=?]", "project[status]"
      assert_select "form.project-form select[name='project[status]'] option[value=?]", "done"
      assert_select "form.project-form select[name='project[status]'] option[value=?]", "archived",
                    count: 0
      assert_select "select[name=?]", "maker_project[status]", count: 0
    end

    # ARCHIVING IS A BUTTON, AND THE SELECT MUST NOT BECOME A SECOND WAY OUT OF IT. With `archived`
    # absent from the options, a rendered select on an archived project would show nothing selected,
    # the browser would pick the first option, and saving any other field would silently unarchive
    # the project while leaving archived_at set.
    test "an archived project's form has no status select, and saving it leaves the status alone" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old Rig", status: "archived",
                                            archived_at: Time.current)

      get edit_project_path(project)
      assert_select "select[name=?]", "project[status]", count: 0

      patch project_path(project), params: { project: { name: "Old Rig II" } }
      assert_equal "archived", project.reload.status
      assert_not_nil project.archived_at
    end

    # A hand-posted `archived` would set the column WITHOUT archived_at, so the archived list would
    # show a project the unarchive flow cannot reason about. The form never offers it; this closes
    # the door behind it.
    test "a hand-posted archived status is dropped rather than applied" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp", status: "active")

      patch project_path(project), params: { project: { name: "Desk Lamp", status: "archived" } }

      assert_equal "active", project.reload.status
    end

    # STORY 1.2: "Does not set current." The box is on `new` only — the edit page already has a
    # "Set as current" button, and an edit submit that silently switched the current project would
    # be a side effect nobody asked for.
    test "the new form offers make-current, checked, and the edit form does not" do
      user = sign_in
      get new_project_path
      assert_select "form.project-form input[type=checkbox][name=?][checked=?]",
                    "project[make_current]", "checked"

      get edit_project_path(user.maker_projects.create!(name: "Desk Lamp"))
      assert_select "input[name=?]", "project[make_current]", count: 0
    end

    test "creating with make-current sets it, and the flash names the folder and the destination" do
      sign_in
      post projects_path, params: { project: { name: "Smart Lamp", status: "active",
                                               make_current: "1" } }

      project = Maker::Project.find_by!(slug: "smart-lamp")
      assert_equal project.id, session[:current_project_id]
      assert_match(%r{Its folder is Projects/smart-lamp\.}, flash[:notice].to_s)
      assert_match(/Current project: Smart Lamp/, flash[:notice].to_s)
    end

    # `check_box_tag` emits NO hidden "0" companion, so an unchecked box sends nothing at all —
    # which is the right meaning here (absent = no) and is why this needs no hidden field.
    test "creating without make-current leaves the current project alone" do
      sign_in
      post projects_path, params: { project: { name: "Quiet Build", status: "planning" } }
      assert_nil session[:current_project_id]
      refute_match(/Current project/, flash[:notice].to_s)
    end

    # STORY 1.2: "A failed mkdir still says 'Project created.'" — the one flash a maker cannot act
    # on, over a project whose folder does not exist. The error CLASS is named because
    # FileLayer::FetchError (an unmounted NAS) and FileLayer::UnsupportedOperation (a refused name)
    # are different problems with different answers. The broken-port fixture is the one "project
    # create still succeeds if the library backend can't make the folder" already uses, above —
    # a second mechanism (define_method on the model) would prove the same thing twice.
    # THE CROSSING (found in review): "make current" ticked AND the mkdir failed. The flash used to
    # read the failure sentence and then "uploads and tool output land there" — false in exactly the
    # case the first sentence describes, since uploads fall back to the library root.
    test "a current project whose folder could not be made does not promise uploads will land there" do
      sign_in
      broken = Object.new
      def broken.capabilities = Object.new.tap { |c| def c.port_writable? = true }
      def broken.mkdir(*) = raise(FileLayer::FetchError, "down")
      FileLayer.current = broken

      post projects_path, params: { project: { name: "No Folder Yet", make_current: "1" } }

      created = Maker::Project.find_by!(slug: "no-folder-yet")
      assert_equal created.id, session[:current_project_id]
      assert_match(/could not be made/, flash[:notice].to_s)
      assert_match(/until its folder exists, uploads go to the library root/, flash[:notice].to_s)
      assert_no_match(/land there/, flash[:notice].to_s)
    ensure
      FileLayer.reset!
    end

    test "a project whose folder could not be made says so, and names the error class" do
      sign_in
      broken = Object.new
      def broken.capabilities = Object.new.tap { |c| def c.port_writable? = true }
      def broken.mkdir(*) = raise(FileLayer::FetchError, "down")
      FileLayer.current = broken

      post projects_path, params: { project: { name: "No Folder" } }

      assert_predicate Maker::Project.find_by(slug: "no-folder"), :present?
      assert_match(/could not be made \(FileLayer::FetchError\)/, flash[:notice].to_s)
    ensure
      FileLayer.reset!
    end

    # --- the detail page's action bar tracks the archived state ---

    test "an archived project's detail page offers unarchive, not archive" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old Rig", status: "archived")

      get project_path(project)
      assert_response :success
      assert_select "form[action=?]", unarchive_project_path(project)
      # The Archive button posts DELETE to the project itself; it must not render here.
      assert_select "form[action=?][method=?]", project_path(project), "post", count: 0
    end

    test "a live project's detail page offers archive, not unarchive" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp", status: "active")

      get project_path(project)
      assert_select "form[action=?]", project_path(project)
      assert_select "form[action=?]", unarchive_project_path(project), count: 0
    end

    test "an archived project cannot be set as the current project from its detail page" do
      user = sign_in
      archived = user.maker_projects.create!(name: "Old Rig", status: "archived")
      live = user.maker_projects.create!(name: "Desk Lamp", status: "active")

      # Scoped to `.head-actions` (the detail page's own action bar): the top bar in
      # app/views/layouts/application.html.erb also renders a `form_with url: current_project_path`
      # whenever the user has ANY live project (`current_project_choices.any?`) — which `live` makes
      # true here regardless of which project's page we're on. An unscoped selector would find that
      # unrelated form and fail for the wrong reason.
      get project_path(archived)
      assert_select ".head-actions form[action=?]", current_project_path, count: 0

      # The control is offered for a live project — proving the assertion above discriminates on
      # status rather than passing because the selector never matches anything.
      get project_path(live)
      assert_select ".head-actions form[action=?]", current_project_path
    end

    # --- the New badge, first open, and "Not a project" (stage 4, S4-6) ----------

    # STORY 1.1: "no 'new' marker". The badge is the surface on every backend, including for the
    # unattended sweep, which is the only way discovery runs on share/s3.
    test "an auto-created project wears a New badge until its owner opens it" do
      user = sign_in
      auto = user.maker_projects.create!(name: "Tray")
      auto.update_columns(discovered_at: 1.hour.ago)
      user.maker_projects.create!(name: "By Hand")

      get projects_path
      assert_select ".project-tile .badge.project-new", count: 1

      get project_path(auto)
      assert_not_nil auto.reload.opened_at

      get projects_path
      assert_select ".badge.project-new", count: 0
    end

    # `update_column`, so opening a project must NOT reorder the lists that sort by updated_at.
    # Compared with a three-day gap rather than at second resolution: §15 records that a timestamp
    # asserted at `.to_i` was written in the same second as the thing it feared, so the mutation
    # stayed green.
    test "opening a project does not touch updated_at" do
      user = sign_in
      project = travel_to(3.days.ago) { user.maker_projects.create!(name: "Tray") }
      before = project.reload.updated_at

      get project_path(project)

      assert_equal before.to_f, project.reload.updated_at.to_f
      assert_not_nil project.opened_at
    end

    test "the status is badged on the page unless it is the default" do
      user = sign_in
      get project_path(user.maker_projects.create!(name: "A", status: "planning"))
      assert_select ".page-title .badge", text: "Planning", count: 0

      get project_path(user.maker_projects.create!(name: "B", status: "done"))
      assert_select ".page-title .badge.status-done", text: "Done"
    end

    # STORY 1.6: "Archive doubles as the undocumented 'not a project' dismissal."
    test "a discovered project offers Not a project, and it archives with its own sentence" do
      user = sign_in
      auto = user.maker_projects.create!(name: "Tray")
      auto.update_columns(discovered_at: 1.hour.ago)

      get project_path(auto)
      assert_select ".head-actions form[action=?] button", project_path(auto, dismiss: 1),
                    text: "Not a project"
      assert_select ".head-actions form[data-turbo-confirm*=?]", "won't adopt it as a project again"

      delete project_path(auto, dismiss: 1)
      assert_equal "archived", auto.reload.status
      assert_match(/is not a project/i, flash[:notice].to_s)
      assert_match(/folder stays in your library/i, flash[:notice].to_s)
    end

    test "a hand-made project offers Archive only, with the plain confirm" do
      user = sign_in
      project = user.maker_projects.create!(name: "By Hand")

      get project_path(project)
      assert_select "form[action=?]", project_path(project, dismiss: 1), count: 0
      assert_select ".head-actions form[data-turbo-confirm=?]", "Archive By Hand?"

      delete project_path(project)
      assert_match(/\AArchived By Hand\./, flash[:notice].to_s)
    end

    # --- a folder that is in the trash is never re-minted (stage 4, S4-6; decision 2) -----------
    #
    # ONE TEST PER DOOR that calls Maker::Project#ensure_library_folder!, because "it returns nil
    # now" is a claim about the model and each of these is a claim about a REQUEST (§15: drive the
    # real request). Deleting a project's folder in Finder is the maker's own act; a new empty
    # `Projects/<slug>` appearing behind their back on the next page view was the surprise, and
    # since S4-6 a project's folder can be a folder ANYWHERE, so re-minting would put a second one
    # in a place they never chose.
    #
    # THE FIXTURE IS A REAL SHARE, NOT `project_folder_rows!`, AND THAT IS WHAT MAKES THESE GUARDS
    # WORK. Measured: with rows alone, restoring the old re-minting branch left the page and attach
    # tests GREEN — `Projects/` has no storage_path in a rows-only fixture, so the re-mint raised
    # FileLayer::NotFound and each caller's rescue swallowed it, and the mutation was masked by the
    # fixture rather than caught by the assertion (§15's "a green suite over something that never
    # worked"). Here `Projects/` is a real directory, so a re-mint would SUCCEED — which is the only
    # state in which "it minted nothing" is a claim with weight.

    # A project whose folder the maker deleted in Finder: the bytes are gone from the share and the
    # scan has tombstoned the row, while `Projects/` itself is untouched and writable.
    def folder_in_the_trash!(user, project)
      projects = create_node!(user, node_id: "d-projects", name: Maker::ProjectFolders::ROOT,
                              kind: "dir", mtime: 1, size: 0)
      folder = create_node!(user, node_id: "d-folder", name: project.slug, kind: "dir",
                            parent_node_id: projects.node_id, mtime: 1, size: 0)
      project.update_column(:folder_node_id, folder.node_id)
      FileUtils.remove_entry(@root.join(folder.storage_path))
      folder.update!(deleted: true)
      folder
    end

    test "the project page says the folder is in the trash, and mints nothing" do
      user = sign_in
      project = user.maker_projects.create!(name: "Tray")
      folder = folder_in_the_trash!(user, project)
      before = user.nodes.count

      get project_path(project)

      assert_response :success
      assert_equal before, user.nodes.count, "looking at a project must not re-mint its folder"
      assert_equal folder.node_id, project.reload.folder_node_id, "and must not repoint it"
      assert_select ".attachments-panel .folder-missing", text: /in the trash or was removed/
      assert_select ".attachments-panel .folder-missing a[href=?]", trash_index_path
    end

    test "an upload to that project lands at the library root rather than minting a folder" do
      user = sign_in
      project = user.maker_projects.create!(name: "Tray")
      folder_in_the_trash!(user, project)
      before = user.nodes.count
      file = Rack::Test::UploadedFile.new(StringIO.new("solid cube".b),
                                          "application/octet-stream", original_filename: "cube.stl")

      post project_uploads_path(project), params: { file: }

      assert_response :redirect
      node = user.nodes.present.find_by!(name: "cube.stl")
      assert_nil node.parent_node_id, "the fallback destination is the library root"
      assert_equal before + 1, user.nodes.count, "the upload must add its own node and nothing else"
    end

    test "an attach into that project attaches the row and leaves the bytes where they are" do
      user = sign_in
      project = user.maker_projects.create!(name: "Tray")
      folder_in_the_trash!(user, project)
      node = create_node!(user, node_id: "n-loose", name: "loose.stl", kind: "file",
                          mtime: 1_000_000_000, size: 10)
      before = user.nodes.count

      post project_attachments_path(project), params: { node_id: node.node_id }

      assert_response :redirect
      assert_equal 1, project.file_attachments.count, "the ROW is the attachment; the move is separate"
      assert_nil node.reload.parent_node_id, "nothing moved"
      assert_equal before, user.nodes.count, "and no folder was minted to move it into"
    end

    test "unarchiving from the detail page restores the project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old Rig", status: "archived",
                                            archived_at: Time.current)

      get project_path(project)
      patch unarchive_project_path(project)
      assert_redirected_to projects_path
      assert_equal "active", project.reload.status
    end

    # STAGE 4, S4-7 (story 6.5): the type is chosen here, and ASSERTED ON THE RENDERED FIELD NAME
    # (§14d) rather than through a nested-hash POST, which would pass whatever the form emitted.
    test "the edit form offers the project type under the name the controller permits" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp")

      get edit_project_path(project)

      assert_select "form.project-form select[name=?]", "project[kind]"
      assert_select "form.project-form select[name='project[kind]'] option[value=laser]",
                    text: "Laser cutting"
      assert_select "form.project-form select[name='project[kind]'] option[selected=selected][value=other]"
    end

    test "saving the type changes the page's panels" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp")

      patch project_path(project), params: { project: { name: "Desk Lamp", kind: "laser" } }

      assert_equal "laser", project.reload.kind
      get project_path(project)
      assert_select "section.bom-panel", count: 0
    end

    # THE CHIPS ARE DERIVED FROM WHAT THE USER HAS, and `other` is dropped because it is the column
    # default — a chip for "everything nobody typed" filters nothing.
    test "the index filters by kind, with chips for the kinds this user actually has" do
      user = sign_in
      user.maker_projects.create!(name: "Cut Box", kind: "laser")
      user.maker_projects.create!(name: "Bracket", kind: "print")
      user.maker_projects.create!(name: "Untyped")

      get projects_path
      assert_select ".projects-toolbar a.chip", text: "Laser cutting"
      assert_select ".projects-toolbar a.chip", text: "3D printing"
      assert_select ".projects-toolbar a.chip", text: "Other", count: 0

      get projects_path(kind: "laser")
      assert_select ".project-card .project-name", text: "Cut Box"
      assert_select ".project-card .project-name", text: "Bracket", count: 0
      assert_select ".projects-toolbar a.chip.active", text: "Laser cutting"
    end

    # A FILTER WITH NO SURVIVORS STILL OFFERS ITS WAY OUT (found in review): the type row used to
    # render only when the maker HAD typed projects, so a stale `?kind=` — a bookmark, Back after
    # retyping the last laser project — showed the empty state with no "All types" chip.
    test "a kind filter with no matching project still renders the chip that clears it" do
      @user.maker_projects.create!(name: "Untyped")

      get projects_path(kind: "laser")

      assert_response :success
      assert_select ".filter.chip", text: "All types"
    end

    test "an unknown kind filters nothing rather than emptying the page" do
      user = sign_in
      user.maker_projects.create!(name: "Cut Box", kind: "laser")

      get projects_path(kind: "wormhole")

      assert_select ".project-card .project-name", text: "Cut Box"
    end

    # BADGE A NON-DEFAULT KIND ONLY (S4-6's own rule: a field you can set and never see is worse
    # than no field, and badging a default is noise).
    test "a card badges its kind, and an untyped project's card carries none" do
      user = sign_in
      user.maker_projects.create!(name: "Cut Box", kind: "laser")
      user.maker_projects.create!(name: "Untyped")

      get projects_path

      assert_select ".project-tile .badge.project-kind", 1
      assert_select ".project-tile .badge.project-kind", text: "Laser cutting"
    end
  end
end
