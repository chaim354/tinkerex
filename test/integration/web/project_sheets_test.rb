require "test_helper"

module Web
  class ProjectSheetsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # The project detail view reads file metadata + capabilities through FileLayer.current; pin a
    # real backend so the share CI leg (no LIBRARY_PATH) doesn't fail on backend construction.
    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "requires login" do
      user = User.create!(email: "x@example.com", password: PASSWORD, confirmed_at: Time.current)
      project = user.maker_projects.create!(name: "Lamp")
      post project_sheets_path(project)
      assert_redirected_to new_user_session_path
    end

    test "create makes a blank sheet and redirects to it" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")

      assert_difference "project.sheets.count", 1 do
        post project_sheets_path(project), params: { sheet: { name: "Cut list" } }
      end
      sheet = project.sheets.last
      assert_equal "Cut list", sheet.name
      assert_equal Maker::Sheet::DEFAULT_ROWS, sheet.cells.size
      assert_redirected_to sheet_path(sheet)
    end

    test "create falls back to a default name" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      post project_sheets_path(project), params: { sheet: { name: "" } }
      assert_equal "Sheet 1", project.sheets.last.name
    end

    test "show renders the grid page" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list", data: Maker::Sheet.blank_data)

      get sheet_path(sheet)
      assert_response :success
      assert_select "h1", "Cut list"
      assert_select "[data-controller=?]", "sheet"
    end

    test "update autosaves the data and answers JSON" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list", data: Maker::Sheet.blank_data)

      patch sheet_path(sheet), as: :json, params: { sheet: { data: {
        "columns" => [ { "title" => "Part" } ], "cells" => [ [ "M3 bolt" ] ]
      } } }

      assert_response :success
      assert_equal "ok", JSON.parse(response.body)["status"]
      assert_equal [ [ "M3 bolt" ] ], sheet.reload.cells
    end

    test "update renames and redirects for an HTML request" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list", data: Maker::Sheet.blank_data)

      patch sheet_path(sheet), params: { sheet: { name: "Costs" } }
      assert_redirected_to sheet_path(sheet)
      assert_equal "Costs", sheet.reload.name
    end

    test "csv export writes the column titles and cells" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Costs", data: {
        "columns" => [ { "title" => "Part" }, { "title" => "Qty" } ],
        "cells"   => [ [ "M3 bolt", "12" ] ]
      })

      get sheet_path(sheet, format: :csv)
      assert_response :success
      assert_equal "text/csv", response.media_type
      assert_equal "Part,Qty\nM3 bolt,12\n", response.body
    end

    test "destroy returns to the project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list")

      assert_difference "project.sheets.count", -1 do
        delete sheet_path(sheet)
      end
      assert_redirected_to project_path(project)
    end

    # `config.action_dispatch.show_exceptions = :rescuable` in the test env, so the RecordNotFound
    # from current_user scoping arrives as a 404 RESPONSE rather than a raised exception — which is
    # why every cross-user test in this suite asserts the status, not an exception.
    test "another user's sheet is not reachable" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs").sheets.create!(user: other, name: "Secret")

      get sheet_path(theirs)
      assert_response :not_found

      patch sheet_path(theirs), params: { sheet: { name: "x" } }
      assert_response :not_found

      delete sheet_path(theirs)
      assert_response :not_found
      assert_equal "Secret", theirs.reload.name
    end

    test "create cannot target another user's project" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")

      assert_no_difference "Maker::Sheet.count" do
        post project_sheets_path(theirs), params: { sheet: { name: "Sneaky" } }
      end
      assert_response :not_found
    end

    test "the grid page carries the data, the save URL and a breadcrumb back to the project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list", data: {
        "columns" => [ { "title" => "Part" } ], "cells" => [ [ "M3 bolt" ] ]
      })

      get sheet_path(sheet)
      assert_response :success
      assert_select ".breadcrumb a", text: "Lamp"
      assert_select "[data-sheet-url-value=?]", sheet_path(sheet)
      assert_select "[data-sheet-data-value*=?]", "M3 bolt"
      assert_select "a[href=?]", sheet_path(sheet, format: :csv)

      # Both targets must be INSIDE the controller element — Stimulus only resolves targets in its
      # own subtree, and a status span left outside would leave the indicator stuck on "Saved"
      # while every save failed. Asserting the nesting, not just the presence, is what catches it.
      assert_select "[data-controller=sheet] [data-sheet-target=status]"
      assert_select "[data-controller=sheet] [data-sheet-target=grid]"
    end

    test "the grid page loads the vendored library only on this page" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list", data: Maker::Sheet.blank_data)

      get sheet_path(sheet)
      assert_select "script[src*=?]", "jspreadsheet"

      get project_path(project)
      assert_select "script[src*=?]", "jspreadsheet", count: 0
    end

    # The formula engine only works if these four load in exactly this order: formula-parser must
    # set window.formulaParser before lib/formula_adapter reads it, and the adapter must set
    # window.formula before jspreadsheet.js's own top-level `if(!formula&&...)var
    # formula=require(...)` shim runs — a browser no-op, but whatever window.formula already is at
    # that point is what every cell formula calls for the rest of the page's life (see
    # vendor/javascript/JSPREADSHEET-LICENSES.md and app/javascript/lib/formula_adapter.js).
    # jsuites-before-jspreadsheet is the pre-existing requirement this test also re-covers. Classic
    # <script> tags execute in document order, so asserting DOM order here is asserting the actual
    # mechanism, not a proxy for it.
    test "the grid page loads jsuites, the formula engine, and the adapter before jspreadsheet" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list", data: Maker::Sheet.blank_data)

      get sheet_path(sheet)
      assert_response :success

      script_srcs = response.body.scan(/<script[^>]*\ssrc="([^"]+)"/).flatten
      keywords = %w[jsuites formula-parser lib/formula_adapter jspreadsheet]
      matched = script_srcs.filter_map { |src| keywords.find { |keyword| src.include?(keyword) } }

      assert_equal keywords, matched
    end

    test "the project page lists its sheets and offers a new-sheet form" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      project.sheets.create!(user:, name: "Cut list", data: Maker::Sheet.blank_data)
      project.sheets.create!(user:, name: "Costs", data: Maker::Sheet.blank_data)

      get project_path(project)
      assert_response :success
      assert_select ".sheets-panel .sheet-row", count: 2
      assert_select ".sheets-panel a", text: "Cut list"
      assert_select ".sheets-panel form[action=?]", project_sheets_path(project)
    end

    test "the project page shows an empty state with no sheets" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      get project_path(project)
      assert_select ".sheets-panel .sheet-row", count: 0
      assert_select ".sheets-panel .muted", text: /No sheets yet/
    end

    test "another user's sheets never appear on a project page" do
      user = sign_in("a@example.com")
      project = user.maker_projects.create!(name: "Mine")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.maker_projects.create!(name: "Theirs").sheets.create!(user: other, name: "Secret")

      get project_path(project)
      assert_select ".sheets-panel a", text: "Secret", count: 0
    end

    # The controller permits `data: {}` wide open, so a malformed blob can be stored. The page must
    # still render — the model's defensive readers are the guard, and this is the page they exist for.
    test "a malformed data blob renders an empty grid rather than breaking the page" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Odd", data: Maker::Sheet.blank_data)

      # Bypasses validation the same way a hostile or buggy client PATCH would.
      sheet.update_column(:data, { "columns" => [ nil, { "title" => "Z" } ], "cells" => "nope" })

      get sheet_path(sheet)
      assert_response :success
      assert_select "[data-controller=sheet]"
      # `cells` guards its OUTER shape (is data["cells"] an Array at all?) — "nope" is a String, so
      # it flattens to []. `columns` passes the SAME outer check (data["columns"] IS an Array), so
      # its malformed inner `nil` entry rides through unchanged: the model's readers are not an
      # element-by-element sanitizer, only an outer-shape guard. (Verified directly — bin/rails
      # runner against this exact hash returns `columns: [nil, {"title"=>"Z"}]`, `cells: []` — an
      # earlier draft of this assertion wrongly expected both to flatten to [].) The inner-element
      # case is what sheet_controller.js's own `.filter((c) => c && typeof c === "object")` guards;
      # a plain request-spec test can't drive that JS, so the real proof that a null column entry
      # can no longer crash the page is that this request still returns 200 at all.
      assert_select "[data-sheet-data-value=?]",
        { "columns" => [ nil, { "title" => "Z" } ], "cells" => [] }.to_json
    end
  end
end
