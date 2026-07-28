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
  end
end
