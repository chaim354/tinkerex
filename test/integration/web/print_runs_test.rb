require "test_helper"

module Web
  class PrintRunsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
    end

    def sign_in(email = "maker@example.com")
      user = User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(user, password: PASSWORD)
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

    # A REFUSED LOG RE-RENDERS THE MODEL PAGE (UX audit 2026-11-01, B3): 422, the composer open with
    # its error, and every field still holding what was typed. It redirected with an alert, which
    # emptied the form. Field NAMES asserted on the rendered page, never the posted hash (§14d).
    test "an invalid print (blank date) re-renders the page with the error and keeps the input" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon")
      assert_no_difference "Maker::PrintRun.count" do
        post model_print_runs_path(m), params: { print_run: {
          printed_on: "", outcome: "failed", printer: "MK4", material: "PETG", duration_hours: "2.5",
          filament_grams: "40", notes: "warped corner"
        } }
      end
      assert_response :unprocessable_entity
      assert_select ".print-log details.composer[open] .form-errors.flash-alert", text: /Date can't be blank/
      assert_select ".print-log form.print-form[action=?]", model_print_runs_path(m) do
        assert_select "input[name='print_run[printed_on]'][value]", 0
        assert_select "select[name='print_run[outcome]'] option[selected][value='failed']"
        assert_select "input[name='print_run[printer]'][value='MK4']"
        assert_select "input[name='print_run[material]'][value='PETG']"
        assert_select "input[name='print_run[duration_hours]'][value='2.5']"
        assert_select "input[name='print_run[filament_grams]'][value='40']"
        assert_select "input[name='print_run[notes]'][value='warped corner']"
      end
      # The whole page, not a fragment: the list on the left and the Details pane both render.
      assert_select ".model-index .model-files"
      assert_select "turbo-frame#model_stage .model-details"
    end

    # EVERY ANSWER GOES BACK WHERE IT CAME FROM (structural redesign §5.4, slice 5): the Library's
    # model strip logs and deletes prints from the model's folder, and must land there again. The
    # tests above send no referer, which is why they still land on the model page. The strip's own
    # create-with-referer case is in model_strip_test.rb; these are the other two answers.
    # A refused log is the one answer that does NOT go back: from the strip it lands on the model's own
    # page, the one page that can show the form with its error (the test above).
    test "deleting a run returns to the page that asked, and says what it did" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon")
      back = files_url(folder: "d-dragon")
      run = m.print_runs.create!(printed_on: Date.today, outcome: "failed")
      delete print_run_path(run), headers: { "HTTP_REFERER" => back }
      assert_redirected_to back
      # B7: the button says Delete, so the notice does too.
      assert_equal "Deleted the print.", flash[:notice]

      post model_print_runs_path(m), params: { print_run: { printed_on: "", outcome: "success" } },
                                     headers: { "HTTP_REFERER" => back }
      assert_response :unprocessable_entity
    end

    # A RUN'S OUTCOME CARRIES ITS WORD (design-system rule 13), and its Delete confirm names the print.
    test "a logged run shows its outcome as a word and confirms its delete by date" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon")
      m.print_runs.create!(printed_on: Date.new(2026, 7, 22), outcome: "success")
      m.print_runs.create!(printed_on: Date.new(2026, 7, 23), outcome: "failed")
      get model_path(m, file: "details")
      assert_select ".print-run .badge.mstatus-printed", text: "Printed"
      assert_select ".print-run .badge.mstatus-failed", text: "Failed"
      assert_select ".print-run form[data-turbo-confirm=?]", "Delete the print from 2026-07-22?"
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
