require "test_helper"

module Projects
  class SheetsControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "sc-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      assert_response :redirect, "sign-in did not take — every test below would be meaningless"
      @project = @user.maker_projects.create!(name: "Lamp")
      @sheet = @project.sheets.create!(user: @user, name: "Cut list", position: 0,
                                       data: Maker::Sheet.blank_data)
    end

    test "an ordinary autosave persists and answers 200" do
      payload = { "columns" => [ { "title" => "A", "width" => 120 } ], "cells" => [ [ "7" ] ] }
      patch sheet_path(@sheet), params: { sheet: { data: payload } }, as: :json
      assert_response :success
      assert_equal [ [ "7" ] ], @sheet.reload.data["cells"]
    end

    # The point of the task: an over-limit autosave must be REJECTED VISIBLY, not 500, and must not
    # partially write.
    test "an over-limit autosave answers 422 and leaves the stored blob untouched" do
      original = @sheet.data
      filler = "x" * (Maker::Sheet::MAX_DATA_BYTES + 1000)
      payload = { "columns" => [ { "title" => "A", "width" => 120 } ], "cells" => [ [ filler ] ] }

      patch sheet_path(@sheet), params: { sheet: { data: payload } }, as: :json

      assert_response :unprocessable_entity
      # NOT REDUNDANT with the 422 above: Rails' own ActionDispatch::ExceptionWrapper already maps an
      # UNRESCUED ActiveRecord::RecordInvalid to a 422 (config/environments/test.rb sets
      # show_exceptions = :rescuable), and the row is untouched either way because update! raises
      # before any UPDATE is issued. Both assertions below this line would hold with the controller's
      # `rescue` deleted outright — only the media type pins it to OUR json branch actually having
      # run, rather than Rails' default HTML error page that happens to share the same status code.
      assert_equal "application/json", response.media_type
      assert_equal original, @sheet.reload.data
    end

    # The indicator shows whatever the server says, so the server has to say something useful.
    test "the over-limit response carries a human error message" do
      filler = "x" * (Maker::Sheet::MAX_DATA_BYTES + 1000)
      patch sheet_path(@sheet), params: { sheet: { data: { "cells" => [ [ filler ] ] } } }, as: :json

      body = JSON.parse(response.body)
      assert body["error"].present?, "expected an error message in #{response.body.first(200)}"
      assert_match(/too large/i, body["error"])
    end

    # The rename form shares the action; a rescue that swallowed HTML would break it silently.
    test "the HTML rename path still redirects" do
      patch sheet_path(@sheet), params: { sheet: { name: "Renamed" } }
      assert_redirected_to sheet_path(@sheet)
      assert_equal "Renamed", @sheet.reload.name
    end
  end
end
