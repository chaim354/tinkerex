require "test_helper"

module Web
  # NEXT STEP ON HOME AND PROJECTS (Shop manual spec §9): Home's Carry on and its Active projects'
  # "N of M steps done", and the Projects index's Next column. Which task is the next step is
  # Maker::Task.next_steps_for's (test/models/maker/task_next_steps_test.rb); what is asserted here is
  # which projects each page asks about, what each row says, and that nothing is drawn for nothing.
  # Their query cost is page_query_budget_test.rb's. Catalog rows only, no port: every backend leg
  # runs these the same way.
  class NextStepsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "next-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    # --- Home: Carry on -------------------------------------------------------------------------

    # The fixture covers every way a project can fail to have a row: no tasks, every task done, a
    # done project and an archived one that still carry an open task. The two with a step are in
    # Active projects' order (newest first), which is not their creation order, and the lamp's step
    # is its Doing though a Todo sits above it in its panel (Maker::Task::NEXT_STEP_STATUSES).
    test "Carry on gives each open project's next step and progress, in Active projects' order" do
      bench = project!("Workbench", status: "planning", updated_at: 2.hours.ago)
      task!(bench, "Cut the short stretchers")
      lamp = project!("Desk Lamp", updated_at: 1.hour.ago)
      task!(lamp, "Order the LEDs", status: "done", position: 0)
      task!(lamp, "Print the base", position: 1)
      task!(lamp, "Check the flicker", status: "doing", position: 2)
      project!("Empty", status: "paused")
      finished = project!("All done")
      task!(finished, "Only step", status: "done")
      task!(project!("Shipped", status: "done"), "Left over")
      task!(project!("Shelved", status: "archived"), "Left over too")

      get root_path
      assert_response :success

      rows = css_select(".home-carry-on .carry-on-row").map do |row|
        %w[.carry-on-project .carry-on-step .carry-on-facts].map { |sel| row.at_css(sel).text.squish }
      end
      assert_equal [ [ "Desk Lamp", "Check the flicker", "1 of 3 done" ],
                     [ "Workbench", "Cut the short stretchers", "0 of 1 done" ] ], rows
      assert_select ".home-carry-on .panel-head .panel-note", text: "the next step of each project"
      # Open lands on the project's tasks, and says which project, since every row's word is the same.
      assert_select ".home-carry-on a.carry-on-open[href=?][aria-label=?]",
                    project_path(lamp, anchor: "project-tasks"), "Open Desk Lamp", text: "Open"
      assert_select ".home-carry-on a.carry-on-open[href=?][aria-label=?]",
                    project_path(bench, anchor: "project-tasks"), "Open Workbench", text: "Open"
      # The screen's checkbox is not drawn (home/index says why).
      assert_select ".home-carry-on input", count: 0
    end

    test "with no open task on any open project, Carry on and its column row are absent" do
      project!("Empty")
      task!(project!("Finished"), "Only step", status: "done")
      task!(project!("Shipped", status: "done"), "Left over")

      get root_path

      assert_select ".home-carry-on", count: 0
      assert_select ".home-projects", count: 1
      assert_select "aside.column a.column-row[href='#home-carry-on']", count: 0
      assert_equal "1 Active projects", css_select(".home-projects .panel-head h2").first.text.squish
    end

    test "Active projects' rows say how many steps are done, and a project with no task says nothing" do
      lamp = project!("Desk Lamp", updated_at: 1.hour.ago)
      task!(lamp, "Order the LEDs", status: "done")
      task!(lamp, "Print the base")
      bench = project!("Workbench", updated_at: 2.hours.ago)
      task!(bench, "Cut the stretchers")
      project!("Empty", updated_at: 3.hours.ago)

      get root_path

      steps = css_select(".home-projects .project-tile").map { |t| [ t.at_css(".project-name").text, t.at_css(".project-steps")&.text ] }
      assert_equal [ [ "Desk Lamp", "1 of 2 steps done" ], [ "Workbench", "0 of 1 step done" ], [ "Empty", nil ] ], steps
      # Home's rows are the compact kind: the step itself is Carry on's, never repeated on the row.
      assert_select ".home-projects .project-next", count: 0
    end

    # --- The Projects index -----------------------------------------------------------------------

    test "each row on the Projects index shows its next step and progress" do
      lamp = project!("Desk Lamp")
      task!(lamp, "Order the LEDs", status: "done", position: 0)
      task!(lamp, "Check the flicker", position: 1)
      finished = project!("Laser test cards", status: "done")
      2.times { |i| task!(finished, "Card #{i}", status: "done") }
      shipped = project!("Shipped", status: "done")
      task!(shipped, "Left over")
      project!("No tasks")

      get projects_path
      assert_response :success

      assert_select ".projects-rows.projects-rows--steps", count: 1
      by_name = css_select(".projects-rows .project-tile").to_h do |tile|
        nxt = tile.at_css(".project-next")
        [ tile.at_css(".project-name").text,
          nxt && [ nxt.at_css(".project-next-label")&.text, nxt.at_css(".project-next-step")&.text, nxt.at_css(".project-steps").text ] ]
      end
      assert_equal [ "Next", "Check the flicker", "1 of 2 steps done" ], by_name.fetch("Desk Lamp")
      # Every step done: the progress alone, with no Next.
      assert_equal [ nil, nil, "2 of 2 steps done" ], by_name.fetch("Laser test cards")
      # A done project's leftover task is not what comes next: progress, no Next.
      assert_equal [ nil, nil, "0 of 1 step done" ], by_name.fetch("Shipped")
      assert_nil by_name.fetch("No tasks")
      # The index's rows carry the step in their own column, never in the facts.
      assert_select ".projects-rows .project-facts .project-steps", count: 0
    end

    test "a list where no project has a task draws no steps column" do
      project!("Desk Lamp")
      project!("Workbench")

      get projects_path

      assert_select ".projects-rows .project-tile", count: 2
      assert_select ".projects-rows--steps", count: 0
      assert_select ".project-next", count: 0
    end

    test "the archived list shows an archived project's progress and no next step" do
      shelved = project!("Shelved", status: "archived")
      task!(shelved, "Left over")
      task!(shelved, "Finished", status: "done")

      get projects_path(archived: 1)

      assert_select ".projects-rows .project-next .project-steps", text: "1 of 2 steps done"
      assert_select ".projects-rows .project-next-label", count: 0
    end

    private

    def project!(name, status: "active", updated_at: nil)
      attrs = { name:, status: }
      attrs[:updated_at] = updated_at if updated_at
      @user.maker_projects.create!(attrs)
    end

    def task!(project, title, status: "todo", position: 0)
      @user.maker_tasks.create!(title:, taskable: project, status:, position:)
    end
  end
end
