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
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
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
      # The composer still renders with nothing to edit yet.
      assert_select "details.composer.wiring-add summary", text: "Add connection"
    end

    test "the composer's field names" do
      get project_path(@project, add: "wiring")
      assert_select "details.composer.wiring-add summary", text: "Add connection"
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

    test "a blank to_label is refused with the message" do
      assert_no_difference "Maker::Connection.count" do
        post project_connections_path(@project), params: { connection: { from_label: "Driver", to_label: "" } }
      end
      assert_redirected_to project_path(@project)
      assert_match(/to label/i, flash[:alert])
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
      assert_equal "Saved.", flash[:notice]
      assert_equal "Driver v2", connection.reload.from_label
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
