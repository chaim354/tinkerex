module Maker
  class Task < ApplicationRecord
    self.table_name = "maker_tasks"

    belongs_to :user
    belongs_to :taskable, polymorphic: true, optional: true

    STATUSES = %w[todo doing done].freeze

    # ONE MAP, AND `TASKABLE_TYPES` IS DERIVED FROM ITS KEYS — because these were two independent
    # enumerations of one set (an array here, a `case` in the validation 17 lines below) with
    # nothing linking them, and the split failed **OPEN**: `taskable_belongs_to_owner` resolved its
    # owner class from that `case` and then `return unless owner_class`, so a type the `case` did
    # not name got **NO TENANT CHECK AT ALL**. Probed directly: `Maker::Project` ran the check and
    # a third type ran nothing, i.e. A could point a task at B's row. **The edit that opens it is
    # adding one string to `TASKABLE_TYPES`** — and nothing would have gone red, because the
    # `inclusion:` validation below held the hole shut for exactly as long as the two lists agreed.
    # Derived from the keys, a split is no longer expressible.
    #
    # A MAP, NOT `taskable_type.constantize`: the string is allowlisted before it is resolved, so
    # `constantize` would not be a *security* hazard here — but it turns a typo in a constant name
    # into a runtime `NameError` on a user request, whereas a map cannot be extended without
    # supplying a class.
    #
    # **DECLARATION ORDER IS LOAD-BEARING.** `inclusion: { in: TASKABLE_TYPES }` captures the ARRAY
    # OBJECT at declaration time — verified by `const_set`-ing a replacement at runtime and watching
    # the validator go on reading the old one — so this must stay ABOVE the validation.
    #
    # Naming the classes in the class body forces their autoload here; `bin/rails zeitwerk:check`
    # is the thing that proves that is safe.
    TASKABLE_OWNERS = {
      "Maker::Item"    => Maker::Item,
      "Maker::Project" => Maker::Project
    }.freeze
    TASKABLE_TYPES = TASKABLE_OWNERS.keys.freeze

    validates :title, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :taskable_type, inclusion: { in: TASKABLE_TYPES }, allow_nil: true
    validate  :taskable_belongs_to_owner, if: -> { taskable_id.present? }

    scope :open, -> { where.not(status: "done") }

    # THE ORDER THE TASKS PANEL SHOWS, STATED ONCE. projects/_tasks groups a project's tasks by
    # STATUSES (Todo, then Doing, then Done) and keeps this order inside each group. `id` is the
    # tie-break: two tasks on one position with one `created_at` (a v1 or MCP create sends no
    # position, so every such task sits at 0) otherwise come back in whatever order the adapter
    # likes, and SQLite and Postgres need not agree. `.next_steps_for` ranks inside each status in
    # exactly this order, so of two Todos the panel draws first, the first is the next step.
    PANEL_ORDER = %i[position created_at id].freeze
    scope :in_panel_order, -> { order(*PANEL_ORDER) }

    # A project's tasks, for a SET of projects. `user_id` rides along beside the owner pair: the
    # validation below already keeps a task's user and its project's user equal, and saying it again
    # here costs nothing and uses the (user_id, taskable_type, taskable_id) index as written.
    scope :for_projects, lambda { |projects|
      where(user_id: projects.map(&:user_id).uniq, taskable_type: "Maker::Project",
            taskable_id: projects.map(&:id))
    }

    # "1 of 4 done" beside a project's next step.
    Progress = Data.define(:done, :total)

    # WHICH OPEN STATUS IS THE NEXT STEP FIRST: a task already under way, then one not started.
    # NOT THE PANEL'S GROUP ORDER (STATUSES draws Todo above Doing), and on purpose: the panel files
    # tasks by status, it does not rank them, and the step a maker carries on with is the one they
    # have started, while a Todo above it is waiting its turn. Home's "Carry on" asks exactly that.
    # Every status but done, so no open task can fall outside the rank (pinned by the test file).
    NEXT_STEP_STATUSES = %w[doing todo].freeze

    # THE NEXT STEP OF EACH PROJECT IN ONE QUERY: { project_id => the task to carry on with }. A
    # project with no tasks, or whose tasks are all done, is an ABSENT key, never nil
    # (Maker::Task.progress_for tells those two apart). Whatever projects the caller passes are
    # answered; which ones a screen shows is the screen's choice (Maker::Project.open for Home).
    #
    # "FIRST" IS A DOING BEFORE A TODO (NEXT_STEP_STATUSES), then PANEL_ORDER inside the status: the
    # first task under way in the panel's order, and with none under way the first Todo it draws.
    #
    # ONE STATEMENT, NOT ONE PER PROJECT: ROW_NUMBER over each project's open tasks, keeping rank 1.
    # SQLite has had window functions since 3.25 and Postgres since 8.4; Maker::ProjectFolderListing
    # ranks the same way. The rank's CASE is built from NEXT_STEP_STATUSES, so the order is stated
    # once. Constancy in N is pinned by test/models/maker/task_next_steps_test.rb.
    def self.next_steps_for(projects)
      projects = projects.to_a
      return {} if projects.empty?

      ranked = for_projects(projects).open
        .select("maker_tasks.*, ROW_NUMBER() OVER (PARTITION BY maker_tasks.taskable_id " \
                "ORDER BY #{next_step_rank_sql}) AS step_rank")
      from(ranked, :maker_tasks).where(arel_table[:step_rank].eq(1)).index_by(&:taskable_id)
    end

    # { project_id => Progress(done:, total:) } for the same set, in ONE grouped query. A project
    # with no tasks at all is an absent key; one whose tasks are all done reads total of total.
    # "Done" is the one status `open` leaves out, so the two scopes cannot disagree about a task.
    def self.progress_for(projects)
      projects = projects.to_a
      return {} if projects.empty?

      for_projects(projects).group(:taskable_id)
        .pluck(:taskable_id, Arel.sql("COUNT(*)"),
               Arel.sql("SUM(CASE WHEN maker_tasks.status = 'done' THEN 1 ELSE 0 END)"))
        .to_h { |id, total, done| [ id, Progress.new(done: done.to_i, total: total.to_i) ] }
    end

    # The rank as SQL: the status's place in NEXT_STEP_STATUSES, then PANEL_ORDER's columns.
    def self.next_step_rank_sql
      whens = NEXT_STEP_STATUSES.each_with_index.map { |s, i| sanitize_sql_array([ "WHEN ? THEN ?", s, i ]) }
      [ "CASE maker_tasks.status #{whens.join(" ")} END", *PANEL_ORDER.map { |c| "maker_tasks.#{c}" } ].join(", ")
    end
    private_class_method :next_step_rank_sql

    # `completed_at` IS DERIVED FROM `status`, HERE AND NOWHERE ELSE: a done task carries the moment
    # it became done (kept through later saves, and kept as handed in by a caller that knows it),
    # and any other status carries none. Every writer gets the pair right by setting the status
    # alone. Four doors each spelled this themselves in two meanings (stamp once, stamp again), two
    # bugs shipped from the copies, and a plain `update!(status: "done")` stamped nothing. Do not
    # derive the stamp in a controller or a tool again; a row from before this rule mends itself the
    # next time it is saved.
    before_save { self.completed_at = (status == "done" ? completed_at || Time.current : nil) }

    def complete!
      update!(status: "done")
    end

    private

    # FAILS CLOSED ONLY FOR A TYPE THAT IS **PRESENT**, and the exemption is not a softening — the
    # naive "fail closed on anything unresolvable" walks straight into §14d's dangling-id lock. A
    # row carrying a `taskable_id` with a NULL `taskable_type` is reachable through the v1 API
    # today (probed: `POST /v1/maker/tasks {title, taskable_id}` answers **201** with
    # `taskable_type: null`, and the follow-up PATCH answers **200**) because `taskable_type` is
    # `allow_nil: true`, this check is guarded on `taskable_id.present?`, and `task_params` permits
    # the two columns independently. Refuse it and every such row becomes **permanently
    # unsaveable** — its owner cannot even rename it. A blank type means `taskable` is nil: there is
    # no owner to check and nothing to leak, so there is nothing for a refusal to protect.
    #
    # Do not chase the half-orphan state itself from here; this method's job is only to not lock it.
    def taskable_belongs_to_owner
      owner_class = TASKABLE_OWNERS[taskable_type]
      if owner_class.nil?
        return if taskable_type.blank?

        return errors.add(:taskable_type, "is not a valid task owner")
      end

      unless owner_class.exists?(id: taskable_id, user_id: user_id)
        errors.add(:taskable_id, "must reference your own #{owner_class.model_name.element}")
      end
    end
  end
end
