require "test_helper"
require "support/public_fixture"

module Web
  # SAVED CALCULATIONS (2026-10-21; plan 2026-10-21-calculator-modal.md): the calculator modal's Save
  # to project frame (CalculationsController#new/#create) and the project page's Calculations panel
  # (its rows, rename and delete). Session-authed, never the v1 API (§14d). The modal's own behaviour
  # in a browser is test/system/calculator_modal_test.rb's; the engine is calculator_engine_test.rb's.
  class CalculationsTest < ActionDispatch::IntegrationTest
    include PublicFixture

    setup do
      @user = make_owner!(handle: "calc-#{SecureRandom.hex(3)}")
      sign_in_as(@user)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    def calculation!(project = @project, **attrs)
      project.calculations.create!({ user: project.user, label: "Shelf depth", expression: "12.5mm + 1/4in",
                                     result: 18.85, unit: "mm" }.merge(attrs))
    end

    def save_params(**attrs)
      { calculation: { project_id: @project.id, label: "Arm length", expression: "3 ft to mm",
                       result: "914.4", unit: "mm", inch_fraction: "" }.merge(attrs) }
    end

    def other_user!
      make_owner!(handle: "other-#{SecureRandom.hex(3)}")
    end

    # --- the save frame ------------------------------------------------------------------------

    test "the save form posts calculation[...] names, which create requires (the scope: bug class, §14d)" do
      get new_calculation_path(project_id: @project.id)
      assert_response :success
      assert_select "turbo-frame#calculator-save form#calculator-save-form[action=?][method=post]", calculations_path
      %w[project_id label].each do |field|
        assert_select "#calculator-save-form [name=?]", "calculation[#{field}]", 1
      end
      %w[expression result unit inch_fraction].each do |field|
        assert_select "#calculator-save-form input[type=hidden][name=?]", "calculation[#{field}]", 1
      end
      # The submit carries no name, so `commit` never rides along.
      assert_select "#calculator-save-form input[type=submit][name]", 0
      # The frame is a fragment: no layout, so no second rail or second modal inside the modal.
      assert_select "aside.rail", 0
      assert_select "dialog.calculator", 0
    end

    test "the page's own project is preselected; a foreign or junk id preselects nothing" do
      @user.maker_projects.create!(name: "Bench")
      get new_calculation_path(project_id: @project.id)
      assert_select "select[name='calculation[project_id]'] option[selected][value=?]", @project.id.to_s, 1

      theirs = other_user!.maker_projects.create!(name: "Theirs")
      get new_calculation_path(project_id: theirs.id)
      assert_select "select[name='calculation[project_id]'] option[selected]", 0
      assert_select "select[name='calculation[project_id]'] option", text: "Theirs", count: 0

      get new_calculation_path(project_id: "1 OR 1=1")
      assert_response :success
      assert_select "select[name='calculation[project_id]'] option[selected]", 0
    end

    test "archived projects are left out of the choice, except the one whose page this is" do
      archived = @user.maker_projects.create!(name: "Old rig", status: "archived")
      get new_calculation_path
      assert_select "select option", text: "Old rig", count: 0
      assert_select "select option", text: "Desk Lamp", count: 1

      get new_calculation_path(project_id: archived.id)
      assert_select "select option[selected]", text: "Old rig", count: 1
    end

    test "with no projects the frame says so and offers to make one, with no form to submit" do
      @project.destroy!
      get new_calculation_path
      assert_select "#calculator-save-form a[href=?]", new_project_path
      assert_select "#calculator-save-form select", 0
      assert_select "#calculator-save-form input[type=submit]", 0
    end

    # --- create --------------------------------------------------------------------------------

    test "a turbo_stream save stores the row and replaces the form and that project's rows" do
      assert_difference -> { @project.calculations.count }, 1 do
        post calculations_path, params: save_params, as: :turbo_stream
      end
      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      saved = @project.calculations.last
      assert_equal [ @user.id, "Arm length", "3 ft to mm", 914.4, "mm", nil ],
                   [ saved.user_id, saved.label, saved.expression, saved.result, saved.unit, saved.inch_fraction ]
      assert_select "turbo-stream[action=replace][target=calculator-save-form]", 1
      assert_select "turbo-stream[action=replace][target=?]", "calculation-rows-#{@project.id}", 1
      # The fresh form says what was saved and where, and keeps the project chosen for the next one.
      assert_select "turbo-stream[target=calculator-save-form] .calculator-saved", text: /Saved “Arm length” to\s+Desk Lamp/
      assert_select "turbo-stream[target=calculator-save-form] select option[selected][value=?]", @project.id.to_s
      assert_select "turbo-stream[target=calculator-save-form] input[name='calculation[label]']:not([value])"
      assert_select "turbo-stream[target=?] .calculation-row .calculation-label", "calculation-rows-#{@project.id}",
                    text: "Arm length"
    end

    test "an inch result keeps the fraction it was shown at" do
      post calculations_path, params: save_params(expression: "3 3/16in", result: "3.1875", unit: "in",
                                                  inch_fraction: "16"), as: :turbo_stream
      assert_response :success
      assert_equal 16, @project.calculations.last.inch_fraction
    end

    test "a refused save answers 422 with the reason, keeps the maker's choice and label, and blanks the hidden four" do
      assert_no_difference -> { Maker::Calculation.count } do
        post calculations_path, params: save_params(label: "Arm", unit: "kg"), as: :turbo_stream
      end
      assert_response :unprocessable_entity
      assert_select "turbo-stream[target=calculator-save-form] .calculator-save-error", text: /Unit/
      assert_select "turbo-stream[target=calculator-save-form] input[name='calculation[label]'][value=?]", "Arm"
      assert_select "turbo-stream[target=calculator-save-form] select option[selected][value=?]", @project.id.to_s
      # THE FORM-WITH-SCOPE TRAP: a scoped form falls back to the model for a value, so without
      # `value: nil` the refused expression would ride into the next save (calculator_controller.js
      # fills these at submit; nothing else may).
      %w[expression result unit inch_fraction].each do |field|
        assert_select "turbo-stream[target=calculator-save-form] input[type=hidden][name=?]:not([value])",
                      "calculation[#{field}]", 1
      end
      assert_select "turbo-stream[target^=calculation-rows]", 0
    end

    test "a blank label is refused with how to name one" do
      post calculations_path, params: save_params(label: " "), as: :turbo_stream
      assert_response :unprocessable_entity
      assert_select ".calculator-save-error", text: /Shelf depth/
    end

    test "another user's project cannot be saved to" do
      theirs = other_user!.maker_projects.create!(name: "Theirs")
      assert_no_difference -> { Maker::Calculation.count } do
        post calculations_path, params: save_params(project_id: theirs.id), as: :turbo_stream
      end
      assert_response :unprocessable_entity
      assert_select ".calculator-save-error", text: /your own project/
    end

    test "without JavaScript a save redirects to the project's panel" do
      post calculations_path, params: save_params
      assert_redirected_to project_path(@project, anchor: "project-calculations")
      assert_equal "Saved “Arm length” to Desk Lamp.", flash[:notice]
    end

    test "signed out, every door goes to sign-in and nothing is saved" do
      delete destroy_user_session_path
      get new_calculation_path
      assert_redirected_to new_user_session_path
      assert_no_difference -> { Maker::Calculation.count } do
        post calculations_path, params: save_params
      end
      assert_redirected_to new_user_session_path
    end

    # --- the panel -----------------------------------------------------------------------------

    test "the panel lists saved calculations oldest first with label, answer and expression" do
      travel_to(2.days.ago) { calculation!(label: "Zed first", expression: "3 ft to mm", result: 914.4, unit: "mm") }
      calculation!(label: "Alpha second", expression: "3 3/16in", result: 3.1875, unit: "in", inch_fraction: 16)
      calculation!(label: "Angle", expression: "atan(1) to deg", result: 45, unit: "°")

      get project_path(@project)
      assert_response :success
      assert_select "section.panel.calculations-panel#project-calculations h2", text: "Calculations"
      labels = css_select(".calculations-panel .calculation-row .calculation-label").map { |el| el.text.strip }
      assert_equal [ "Zed first", "Alpha second", "Angle" ], labels
      results = css_select(".calculations-panel .calculation-result").map { |el| el.text.strip }
      assert_equal [ "914.4 mm", "3 3/16 in", "45°" ], results
      assert_select ".calculations-panel code.calculation-expression", text: "3 3/16in"
      # Open in calculator carries the expression and the display it was saved at.
      assert_select ".calculations-panel button.calculation-open[data-calculator-open][data-calculator-expression=?][data-calculator-fraction=?]",
                    "3 3/16in", "16"
      assert_select ".calculations-panel button.calculation-open[data-calculator-expression=?][data-calculator-fraction='']",
                    "3 ft to mm"
      assert_select ".calculations-panel .panel-head button[data-calculator-open]", text: "Open calculator"
    end

    test "a rounded inch fraction says so, and a whole number of inches has no fraction" do
      calculation!(label: "Rounded", expression: "1in + 1mm", result: 1.03937007874, unit: "in", inch_fraction: 32)
      calculation!(label: "Whole", expression: "2in + 2in", result: 4, unit: "in", inch_fraction: 16)
      get project_path(@project)
      results = css_select(".calculations-panel .calculation-result").map { |el| el.text.strip }
      assert_equal [ "≈ 1 1/32 in", "4 in" ], results
    end

    test "the rename form posts calculation[label] with its own value, and only the owner's row" do
      calc = calculation!
      get project_path(@project)
      assert_select "form.calculation-rename-form[action=?] input[name='calculation[label]'][value=?]",
                    calculation_path(calc), "Shelf depth"

      patch calculation_path(calc), params: { calculation: { label: "Shelf depth (front)", expression: "1", result: "1" } }
      assert_redirected_to project_path(@project, anchor: "project-calculations")
      calc.reload
      assert_equal "Shelf depth (front)", calc.label
      assert_equal "12.5mm + 1/4in", calc.expression, "only the label is editable"
      assert_in_delta 18.85, calc.result

      patch calculation_path(calc), params: { calculation: { label: "" } }
      assert_match(/Label can't be blank/, flash[:alert])
      assert_equal "Shelf depth (front)", calc.reload.label
    end

    test "delete removes the row and comes back to the panel" do
      calc = calculation!
      calculation!(label: "Keep")
      delete calculation_path(calc)
      assert_redirected_to project_path(@project, anchor: "project-calculations")
      assert_equal [ "Keep" ], @project.calculations.pluck(:label)
    end

    test "another user's calculation is a 404 to rename or delete" do
      other = other_user!
      theirs = other.maker_projects.create!(name: "Theirs")
      calc = calculation!(theirs)
      patch calculation_path(calc), params: { calculation: { label: "mine now" } }
      assert_response :not_found
      delete calculation_path(calc)
      assert_response :not_found
      assert_equal "Shelf depth", calc.reload.label
    end

    test "an empty Calculations panel is absent, offered by + Add panel, and quiet when opened" do
      get project_path(@project)
      assert_select "section.calculations-panel", 0
      assert_select ".add-panel a.menu-item[href=?]",
                    project_path(@project, add: "calculations", anchor: "project-calculations"), text: "Calculations"

      get project_path(@project, add: "calculations")
      assert_select "section.calculations-panel.panel--quiet#project-calculations"
      assert_select "section.calculations-panel .panel-head button[data-calculator-open]"
      # THE STREAM'S TARGET IS ON THE PAGE, so a save from the modal lands in the open panel.
      assert_select "#calculation-rows-#{@project.id}", 1
    end

    test "a hidden Calculations panel is not rendered and its rows are not loaded" do
      calculation!
      @project.update!(panels: { "hidden" => %w[calculations] })
      get project_path(@project)
      assert_select "section.calculations-panel", 0
      assert_select ".add-panel a.menu-item", text: "Calculations", count: 0
    end

    # --- never public --------------------------------------------------------------------------

    test "calculations never reach the visitor's page or the owner's preview of it" do
      @root = use_fresh_share_library!
      @project.destroy! # the fixture makes its own "Desk Lamp", and slugs are per user
      f = seed_public_project!(@user, visibility: "public")
      project = f[:project]
      calculation!(project, label: "Secret margin", expression: "1234.5mm - 10%")

      get public_project_path(@user.handle, project.slug)
      assert_response :success
      assert_select ".calculations-panel", 0
      refute_includes response.body, "Secret margin"
      refute_includes response.body, "1234.5mm"

      get preview_project_path(project)
      assert_response :success
      assert_select ".calculations-panel", 0
      refute_includes response.body, "Secret margin"

      # The owner's own page does show it, so the two refusals above are about the surface.
      get project_path(project)
      assert_select ".calculations-panel .calculation-label", text: "Secret margin"
    end
  end
end
