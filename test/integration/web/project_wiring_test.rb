require "test_helper"

module Web
  # The wiring table (stage 3, S3-3): the project page's panel and its three write doors
  # (Projects::ConnectionsController -- create / update / destroy). Session-authed, like every
  # Projects::* controller. Plain forms + redirects, no turbo_stream -- Projects::BomLinesController's
  # own reasoning applies here too: a connection is added or edited far less often than a task is
  # toggled, so there is no full-panel repaint worth avoiding.
  class ProjectWiringTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "wiring-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    def other_user!
      User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                   confirmed_at: Time.current)
    end

    def connection!(**attrs)
      @project.connections.create!(user: @user, from_label: "A", to_label: "B",
                                   position: (@project.connections.maximum(:position) || -1) + 1,
                                   **attrs)
    end

    def fields_by_name(row)
      row.css("input").each_with_object({}) { |el, h| h[el["name"]] = el["value"] }
    end

    # --- the panel -----------------------------------------------------------------------------

    test "the panel lists connections in position order with their four cells" do
      connection!(from_label: "Driver", to_label: "Motor", wire: "22 AWG", note: "twisted pair")
      connection!(from_label: "PSU", to_label: "Driver", wire: "18 AWG")

      get project_path(@project)
      assert_response :success
      assert_select "section.panel.wiring-panel h2", text: "Wiring"
      assert_select ".wiring-panel .mono.muted", text: "2 connections"
      assert_select "table.table.wiring tbody tr.wiring-row", count: 2

      rows = css_select("table.table.wiring tbody tr.wiring-row")
      first = fields_by_name(rows[0])
      assert_equal "Driver", first["connection[from_label]"]
      assert_equal "Motor", first["connection[to_label]"]
      assert_equal "22 AWG", first["connection[wire]"]
      assert_equal "twisted pair", first["connection[note]"]

      second = fields_by_name(rows[1])
      assert_equal "PSU", second["connection[from_label]"]
    end

    test "the empty state" do
      # ABSENT, THEN OPENED (slice 6): no connection means no panel, and "+ Add panel" offers it.
      get project_path(@project)
      assert_select "section.wiring-panel", count: 0
      assert_select ".add-panel a.menu-item", text: "Wiring"
      get project_path(@project, add: "wiring")
      assert_response :success
      # QUIET AT ZERO (stage 4, S4-1): the panel says it is empty by being empty. The sentence and
      # the "0 connections" count span are both gone -- a zero beside a heading is not information
      # -- so their ABSENCE is what is pinned here, beside the class the partial sets on itself.
      assert_select "section.panel.wiring-panel.panel--quiet"
      assert_select "section.wiring-panel table.wiring", count: 0
      assert_select ".wiring-panel .panel-head .mono.muted", count: 0
      # The composer still renders with nothing to edit yet, in the panel's head (C4).
      assert_select ".wiring-panel .panel-head > details.composer.wiring-add summary", text: "Add…"
    end

    # ONE COMPOSER PATTERN (2026-11-02, the UX audit's C4): "Add…" opens it and the submit names the
    # thing, so the two never carry one label; the submit is a quiet `.btn` (the hub's accent is
    # the top bar's Upload).
    test "the composer's field names" do
      get project_path(@project, add: "wiring")
      assert_select "details.composer.wiring-add summary", text: "Add…"
      assert_select "details.composer.wiring-add input[type=submit][value=?]", "Add connection"
      assert_select "details.composer.wiring-add input[type=submit].primary", 0
      assert_select "form[action=?]", project_connections_path(@project)
      assert_select "input[name=?]", "connection[from_label]"
      assert_select "input[name=?]", "connection[to_label]"
      assert_select "input[name=?]", "connection[wire]"
      assert_select "input[name=?]", "connection[note]"
    end

    # --- create --------------------------------------------------------------------------------

    test "create appends with the next position and redirects back with a flash" do
      connection!(from_label: "PSU", to_label: "Driver")

      assert_difference "Maker::Connection.count", 1 do
        post project_connections_path(@project),
             params: { connection: { from_label: "Driver", to_label: "Motor", wire: "22 AWG" } }
      end
      created = Maker::Connection.order(:id).last
      assert_equal 1, created.position
      assert_equal "Driver", created.from_label
      assert_equal "Motor", created.to_label
      assert_redirected_to project_path(@project)
      assert_match(/Added/, flash[:notice])
      assert_match(/Driver/, flash[:notice])
      assert_match(/Motor/, flash[:notice])
    end

    # A REFUSAL KEEPS WHAT WAS TYPED (2026-11-02, the UX audit's B3): 422 and the composer again,
    # open, its error inside it and every field still holding the posted value — never a redirect
    # with an alert over an empty form. Without Turbo that is a page of its own.
    test "a blank to_label is refused with the message, and the composer keeps what was typed" do
      assert_no_difference "Maker::Connection.count" do
        post project_connections_path(@project),
             params: { connection: { from_label: "Driver", to_label: "", wire: "22 AWG", note: "twisted" } }
      end
      assert_response :unprocessable_entity
      assert_nil flash[:alert]
      assert_select "details.composer.wiring-add#wiring-composer[open]" do
        assert_select ".form-errors[role=alert]", text: /to label/i
        assert_select "input[name=?][value=?]", "connection[from_label]", "Driver"
        assert_select "input[name=?][value=?]", "connection[wire]", "22 AWG"
        assert_select "input[name=?][value=?]", "connection[note]", "twisted"
        assert_select "input[name=?]", "connection[to_label]"
      end
      assert_select ".breadcrumb a[href=?]", project_path(@project)
    end

    # UNDER TURBO THE COMPOSER ALONE IS REPLACED, so nothing else on the page — another panel's
    # draft included — is re-rendered by the refusal.
    test "a refused connection under Turbo replaces only the composer, open and holding the input" do
      post project_connections_path(@project), as: :turbo_stream,
           params: { connection: { from_label: "Driver", to_label: "" } }
      assert_response :unprocessable_entity
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert_select "turbo-stream[action=replace][target=wiring-composer]", 1
      assert_select "turbo-stream", 1
      assert_includes response.body, %(value="Driver")
      assert_includes response.body, "open"
    end

    test "a connection posted against another user's project slug 404s" do
      other = other_user!
      foreign = other.maker_projects.create!(name: "Theirs")
      post project_connections_path(foreign), params: { connection: { from_label: "A", to_label: "B" } }
      assert_response :not_found
    end

    # --- update --------------------------------------------------------------------------------

    # THE PER-ROW FORM WIRING ITSELF, not merely that the fields render: a <form> cannot span
    # table cells, so each row's <form> sits OUTSIDE the table and every field points back at it
    # by id via the HTML `form=` attribute (projects/_wiring.html.erb's own header comment).
    test "the row's fields are wired to their form by the HTML form attribute" do
      connection = connection!(from_label: "Driver", to_label: "Motor")

      get project_path(@project)
      form_id = "connection-#{connection.id}"
      assert_select "input[form=?]", form_id, minimum: 4
      assert_select "form##{form_id} input[name=?][value=?]", "_method", "patch"
    end

    test "update changes a row" do
      connection = connection!(from_label: "Driver", to_label: "Motor")

      patch connection_path(connection), params: { connection: { from_label: "Driver v2" } }
      assert_redirected_to project_path(@project)
      # Names what was saved, verb first (the UX audit's B7: "Saved." was one of two bare notices).
      assert_equal "Saved Driver v2 → Motor.", flash[:notice]
      assert_equal "Driver v2", connection.reload.from_label
    end

    # A REFUSED ROW KEEPS ITS EDIT (B3): the table comes back with that row still holding what was
    # typed and its sentence beside its Save, 422; the other rows show what is saved.
    test "a refused row edit comes back as typed, with its error, under Turbo and without" do
      connection = connection!(from_label: "Driver", to_label: "Motor")
      other = connection!(from_label: "PSU", to_label: "Driver")

      patch connection_path(connection), params: { connection: { from_label: "Driver v2", to_label: "" } }
      assert_response :unprocessable_entity
      assert_equal "Motor", connection.reload.to_label
      assert_select "tr.wiring-row--refused input[name=?][value=?]", "connection[from_label]", "Driver v2"
      assert_select "tr.wiring-row--refused .wiring-row-error[role=alert]", text: /to label/i
      assert_select "input#connection-#{other.id}-from_label[value=?]", "PSU"
      # THE REFUSED ROW IS STILL UNSAVED, AND SAYS SO: marked dirty for wiring_controller.js, so
      # leaving the page asks about it, with its "Unsaved" shown; the other row is not.
      assert_select "tr.wiring-row--refused[data-wiring-target=row][data-dirty=true] .wiring-unsaved:not([hidden])",
                    text: "Unsaved"
      assert_select "tr.wiring-row[data-dirty]", 1

      patch connection_path(connection), as: :turbo_stream, params: { connection: { to_label: "" } }
      assert_response :unprocessable_entity
      assert_select "turbo-stream[action=replace][target=project-wiring]", 1
    end

    # EVERY CELL'S FIELD HAS A NAME (the UX audit's §I: four unnamed inputs per row), and the table
    # mounts the unsaved-row warning (C10) — wiring_controller.js, which stimulus_hygiene_test.rb
    # holds to an existing file.
    test "each row's four fields carry a label, and the table mounts the unsaved warning" do
      connection = connection!(from_label: "Driver", to_label: "Motor")
      get project_path(@project)
      %w[from_label to_label wire note].each do |field|
        assert_select "label.label-hidden[for=?]", "connection-#{connection.id}-#{field}", 1
      end
      assert_select "section.wiring-panel[data-controller=wiring]"
      assert_select "tr.wiring-row[data-wiring-target=row] .wiring-unsaved[hidden]", text: "Unsaved"
      assert_select "form#connection-#{connection.id}[data-action=?]", "submit->wiring#save"
    end

    test "update on a foreign connection 404s" do
      other = other_user!
      other_project = other.maker_projects.create!(name: "Theirs")
      other_connection = other_project.connections.create!(user: other, from_label: "A", to_label: "B")

      patch connection_path(other_connection), params: { connection: { from_label: "X" } }
      assert_response :not_found
    end

    # --- destroy -------------------------------------------------------------------------------

    test "destroy removes one and renumbers nothing" do
      first = connection!(from_label: "A", to_label: "B")
      second = connection!(from_label: "C", to_label: "D")

      assert_difference "Maker::Connection.count", -1 do
        delete connection_path(first)
      end
      assert_redirected_to project_path(@project)
      assert_match(/Removed/, flash[:notice])
      # POSITIONS MAY GAP: the surviving row keeps its own position (1) rather than being
      # renumbered down to close the gap the deleted row (0) left behind.
      assert_equal 1, second.reload.position
    end

    test "destroy on a foreign connection 404s" do
      other = other_user!
      other_project = other.maker_projects.create!(name: "Theirs")
      other_connection = other_project.connections.create!(user: other, from_label: "A", to_label: "B")

      delete connection_path(other_connection)
      assert_response :not_found
    end

    # --- read-only ------------------------------------------------------------------------------

    # `editable: false` HAS NO PAGE YET -- S3-4's public project page is its first caller -- so the
    # partial is rendered directly. Pinned now rather than then because every test above drives
    # the project page, which always passes `editable: true`: inverting the branch would leave all
    # of them green while the public page grew Save buttons and a composer.
    test "editable: false renders plain cells with no form, input or composer" do
      connection!(from_label: "Driver", to_label: "Motor", wire: "22 AWG", note: "twisted pair")

      # `layout:` JOINED THE LOCALS ON 2026-09-09 (the page editor): the panel's heading is the
      # maker's own title now, and this partial is the ONE panel both pages render, so the layout
      # arrives as a local rather than off an ivar neither caller shares. A direct render is the
      # third caller and has no page to take it from — `Maker::Project#panel_layout` is the same
      # answer with no folders in the vocabulary, which is all a fixed key needs.
      html = ApplicationController.render(partial: "projects/wiring",
                                          locals: { project: @project, connections: @project.connections.to_a,
                                                    editable: false, layout: @project.panel_layout })
      doc = Nokogiri::HTML.fragment(html)
      assert_equal 0, doc.css("form, input, details.composer").size
      assert_equal [ "Driver", "Motor", "22 AWG", "twisted pair" ],
                   doc.css("tr.wiring-row td").map { |td| td.text.strip }
      assert_equal 4, doc.css("thead th").size, "no actions column in read-only mode"
    end
  end
end
