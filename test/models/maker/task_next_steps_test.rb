require "test_helper"

module Maker
  # Maker::Task.next_steps_for and .progress_for: a project's next step and its "1 of 4 done", for a
  # SET of projects, in a constant number of queries (spec 2026-11-18 §9 and §10's query budget).
  # "First" is a task under way before one not started, and the tasks panel's order inside each, so
  # the last test here reads the panel's own order and checks the two agree, rather than trusting
  # that they were written alike.
  class TaskNextStepsTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "next-steps-#{SecureRandom.hex(4)}@example.com")
    end

    test "the next step is the first open task by position, and done tasks are skipped" do
      lamp = project!("Lamp")
      task!(lamp, "Order parts", position: 0, status: "done")
      second = task!(lamp, "Print the base", position: 1)
      task!(lamp, "Wire the driver", position: 2)

      assert_equal({ lamp.id => second }, Maker::Task.next_steps_for([ lamp ]))
    end

    # CARRY ON MEANS THE STEP UNDER WAY (Maker::Task::NEXT_STEP_STATUSES). The Todo sits at the
    # LOWER position, so a rank that followed the panel's groups, or position alone, picks it.
    test "a Doing comes before a Todo whatever their positions" do
      lamp = project!("Lamp")
      task!(lamp, "Not started", position: 0)
      doing = task!(lamp, "In progress", position: 5, status: "doing")

      assert_equal doing, Maker::Task.next_steps_for([ lamp ])[lamp.id]
    end

    test "a Todo is the next step once nothing is under way" do
      lamp = project!("Lamp")
      task!(lamp, "Finished", position: 0, status: "done")
      task!(lamp, "Later", position: 2)
      todo = task!(lamp, "Sooner", position: 1)

      assert_equal todo, Maker::Task.next_steps_for([ lamp ])[lamp.id]
    end

    # A STATUS THE RANK DOES NOT NAME WOULD SORT AS NULL, first on SQLite and last on Postgres, so a
    # fourth open status added to STATUSES alone would rank differently per adapter. Every status
    # but done is ranked, and done never is.
    test "the rank names every open status and no other" do
      assert_equal (Maker::Task::STATUSES - [ "done" ]).sort, Maker::Task::NEXT_STEP_STATUSES.sort
    end

    test "a project with no tasks, and one whose tasks are all done, are absent keys" do
      empty = project!("Empty")
      finished = project!("Finished")
      task!(finished, "One", status: "done")
      task!(finished, "Two", status: "done")

      steps = Maker::Task.next_steps_for([ empty, finished ])

      assert_equal({}, steps)
    end

    # The fixtures DISAGREE with insertion order on purpose: created first is the one that must
    # lose, so an order that fell back to id alone would pick the wrong task.
    test "a tie on position goes to the earlier created_at, and a tie on both to the lower id" do
      lamp = project!("Lamp")
      later = task!(lamp, "Later", position: 0, created_at: 1.hour.ago)
      earlier = task!(lamp, "Earlier", position: 0, created_at: 2.hours.ago)
      assert_equal earlier, Maker::Task.next_steps_for([ lamp ])[lamp.id]
      assert_operator later.id, :<, earlier.id

      bench = project!("Bench")
      at = 3.hours.ago.change(usec: 0)
      first = task!(bench, "First row", position: 0, created_at: at)
      task!(bench, "Second row", position: 0, created_at: at)
      assert_equal first, Maker::Task.next_steps_for([ bench ])[bench.id]
    end

    # THE TIE-BREAK IS A UNIQUE COLUMN, so the panel's order is total. Pinned as a fact about the
    # constant rather than by two tied rows, because SQLite hands tied rows back in rowid order
    # (= id order) with or without the tie-break, so no fixture here could tell; Postgres is where
    # the order would wander without it.
    test "the panel order ends on id, so no two tasks tie" do
      assert_equal :id, Maker::Task::PANEL_ORDER.last
    end

    test "each project gets its own next step, and a task elsewhere never answers for it" do
      lamp = project!("Lamp")
      bench = project!("Bench")
      not_asked = project!("Not asked")
      lamp_step = task!(lamp, "Lamp step", position: 3)
      bench_step = task!(bench, "Bench step", position: 0)
      task!(not_asked, "Elsewhere", position: 0)
      # An item's task pointed at the SAME id as a project asked about, and a task on no owner at
      # all, on the same user: only the owner TYPE tells the first apart.
      item = @user.maker_items.create!(title: "Widget")
      @user.maker_tasks.create!(title: "Item task", taskable: item, position: -1).update_columns(taskable_id: lamp.id)
      @user.maker_tasks.create!(title: "Loose task", position: -1)

      assert_equal({ lamp.id => lamp_step, bench.id => bench_step },
                   Maker::Task.next_steps_for([ lamp, bench ]))
    end

    test "another user's tasks never answer, even pointed at the same id" do
      lamp = project!("Lamp")
      mine = task!(lamp, "Mine", position: 5)
      other = User.create!(email: "next-steps-other-#{SecureRandom.hex(4)}@example.com")
      theirs = other.maker_projects.create!(name: "Theirs")
      other.maker_tasks.create!(title: "Theirs", taskable: theirs, position: 0)
      # A row planted past the validation: their task, naming MY project's id.
      planted = other.maker_tasks.create!(title: "Planted", taskable: theirs, position: 0)
      planted.update_columns(taskable_id: lamp.id)

      assert_equal({ lamp.id => mine }, Maker::Task.next_steps_for([ lamp ]))
      assert_equal({ lamp.id => Maker::Task::Progress.new(done: 0, total: 1) }, Maker::Task.progress_for([ lamp ]))
    end

    test "progress counts done and total per project, and a project with no tasks is absent" do
      lamp = project!("Lamp")
      finished = project!("Finished")
      empty = project!("Empty")
      task!(lamp, "a", status: "done")
      task!(lamp, "b", status: "doing")
      task!(lamp, "c")
      task!(lamp, "d")
      3.times { |i| task!(finished, "f#{i}", status: "done") }

      progress = Maker::Task.progress_for([ lamp, finished, empty ])

      assert_equal({ lamp.id => Maker::Task::Progress.new(done: 1, total: 4),
                     finished.id => Maker::Task::Progress.new(done: 3, total: 3) }, progress)
      assert_not progress.key?(empty.id)
    end

    test "no projects asks nothing" do
      assert_equal 0, count_queries { Maker::Task.next_steps_for([]) }
      assert_equal 0, count_queries { Maker::Task.progress_for([]) }
      assert_equal({}, Maker::Task.next_steps_for([]))
      assert_equal({}, Maker::Task.progress_for([]))
    end

    # The open set is the caller's choice; Home asks Maker::Project.open, which leaves done and
    # archived projects out however many open tasks they still carry.
    test "over Maker::Project.open, archived and done projects have no next step" do
      planning = project!("Planning", status: "planning")
      paused = project!("Paused", status: "paused")
      done = project!("Done", status: "done")
      archived = project!("Archived", status: "archived")
      [ planning, paused, done, archived ].each { |p| task!(p, "Step for #{p.name}") }

      steps = Maker::Task.next_steps_for(@user.maker_projects.open)

      assert_equal [ planning.id, paused.id ].sort, steps.keys.sort
    end

    # THE QUERY BUDGET (spec §10): one statement each, whether one project is asked about or five,
    # and however many tasks each holds. Constancy, not a literal (page_query_budget_test.rb).
    test "neither method grows with the number of projects or their tasks" do
      small = Array.new(1) { |i| seeded_project!("Small #{i}") }
      large = Array.new(5) { |i| seeded_project!("Large #{i}") }

      Maker::Task.next_steps_for(small) # warm up the statement
      steps_small = count_queries { Maker::Task.next_steps_for(small) }
      steps_large = count_queries { Maker::Task.next_steps_for(large) }
      assert_equal steps_small, steps_large,
                   "next_steps_for issued #{steps_small} queries for 1 project and #{steps_large} for 5"

      Maker::Task.progress_for(small)
      progress_small = count_queries { Maker::Task.progress_for(small) }
      progress_large = count_queries { Maker::Task.progress_for(large) }
      assert_equal progress_small, progress_large,
                   "progress_for issued #{progress_small} queries for 1 project and #{progress_large} for 5"

      assert_equal 5, Maker::Task.next_steps_for(large).size
      assert_equal 5, Maker::Task.progress_for(large).size
    end

    # "FIRST" READ OFF THE PANEL: projects/_tasks loops over STATUSES and keeps `in_panel_order`
    # inside each group, so the first Doing it draws is the next step, for a shuffled set of
    # positions, statuses and timestamps. Two Doings tie on nothing and the panel's first one is the
    # later-created, so an order that ignored position or created_at picks the wrong one; and the
    # first open task the panel draws is a Todo, so the panel's group order picks the wrong one too.
    test "the next step is the first Doing the panel draws" do
      lamp = project!("Lamp")
      [ [ 2, "doing" ], [ 0, "done" ], [ 1, "todo" ], [ 0, "doing" ], [ 3, "todo" ], [ 1, "todo" ] ].each_with_index do |(pos, status), i|
        task!(lamp, "t#{i}", position: pos, status:, created_at: (10 - i).minutes.ago)
      end

      tasks = lamp.tasks.in_panel_order.to_a
      panel = Maker::Task::STATUSES.flat_map { |s| tasks.select { |t| t.status == s } }
      first_doing = panel.find { |t| t.status == "doing" }

      assert_equal first_doing, Maker::Task.next_steps_for([ lamp ])[lamp.id]
      assert_not_equal panel.find { |t| t.status != "done" }, first_doing
    end

    private

    def project!(name, status: "active")
      @user.maker_projects.create!(name:, status:)
    end

    def task!(project, title, position: 0, status: "todo", created_at: nil)
      attrs = { title:, taskable: project, position:, status: }
      attrs[:created_at] = created_at if created_at
      @user.maker_tasks.create!(attrs)
    end

    def seeded_project!(name)
      project = project!(name)
      task!(project, "#{name} done", position: 0, status: "done")
      task!(project, "#{name} next", position: 1)
      task!(project, "#{name} later", position: 2, status: "doing")
      project
    end

    def count_queries(&block)
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:sql].start_with?("PRAGMA") }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      n
    end
  end
end
