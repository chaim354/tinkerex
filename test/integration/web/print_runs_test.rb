require "test_helper"

module Web
  class PrintRunsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
    end

    def sign_in(email = "maker@example.com")
      user = User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "the show page renders the log form and history" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon")
      m.print_runs.create!(printed_on: Date.new(2026, 7, 22), outcome: "success", printer: "MK4")
      get model_path(m)
      assert_select "form.print-form"
      assert_select ".print-run", text: /MK4/
    end

    test "logging a success print creates a run and flips status to printed" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon")
      assert_difference "Maker::PrintRun.count", 1 do
        post model_print_runs_path(m), params: { print_run: {
          printed_on: "2026-07-22", outcome: "success", printer: "MK4", material: "PLA",
          duration_hours: "6.5", filament_grams: "82", notes: "0.2mm"
        } }
      end
      assert_redirected_to model_path(m)
      assert_equal "printed", m.reload.print_status
    end

    test "deleting a run recomputes status and is scoped to the owner" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon")
      run = m.print_runs.create!(printed_on: Date.today, outcome: "failed")
      assert_equal "failed", m.reload.print_status
      assert_difference "Maker::PrintRun.count", -1 do
        delete print_run_path(run)
      end
      assert_redirected_to model_path(m)
      assert_equal "failed", m.reload.print_status # no runs left -> status left untouched
    end

    test "an invalid print (blank date) redirects with an alert and creates nothing" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon")
      assert_no_difference "Maker::PrintRun.count" do
        post model_print_runs_path(m), params: { print_run: { printed_on: "", outcome: "success" } }
      end
      assert_redirected_to model_path(m)
      follow_redirect!
      assert_select ".flash-alert"
    end

    # EVERY ANSWER GOES BACK WHERE IT CAME FROM (structural redesign §5.4, slice 5): the Library's
    # model strip logs and deletes prints from the model's folder, and must land there again. The
    # tests above send no referer, which is why they still land on the model page. The strip's own
    # create-with-referer case is in model_strip_test.rb; these are the other two answers.
    test "deleting a run, or a refused log, returns to the page that asked" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon")
      back = files_url(folder: "d-dragon")
      run = m.print_runs.create!(printed_on: Date.today, outcome: "failed")
      delete print_run_path(run), headers: { "HTTP_REFERER" => back }
      assert_redirected_to back

      post model_print_runs_path(m), params: { print_run: { printed_on: "", outcome: "success" } },
                                     headers: { "HTTP_REFERER" => back }
      assert_redirected_to back
    end

    test "cannot log a print on another user's model" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      m = other.maker_models.create!(title: "Theirs")
      # find_by!(slug:) on the current user's scope misses -> RecordNotFound, which this app
      # rescues to a 404 (same as the projects flow test), NOT a raised exception in the test.
      assert_no_difference "Maker::PrintRun.count" do
        post model_print_runs_path(m), params: { print_run: { printed_on: "2026-07-22", outcome: "success" } }
      end
      assert_response :not_found
    end
  end
end
