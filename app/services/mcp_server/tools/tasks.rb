# frozen_string_literal: true

module McpServer
  module Tools
    # TASKS: across every project or one, open first. A task's owner here is always a project
    # (Maker::Task's other taskable, an Item, is the catalog layer the MCP leaves out; spec §4).
    module Tasks
      def self.all = [ ListTasks, CreateTask, UpdateTask ]

      # Open first, then the maker's own order.
      ORDER = [ Arel.sql("CASE status WHEN 'done' THEN 1 ELSE 0 END"), :position, :id ].freeze

      class ListTasks < McpServer::Tool
        tool_name "list_tasks"
        description "Tasks across every project, or one project's (give its slug), open tasks first. " \
                    "Filter by status (#{Maker::Task::STATUSES.join(", ")}). At most #{LIST_CAP}."
        input_schema(
          properties: {
            project: { type: "string", description: "A project slug." },
            status: { type: "string", enum: Maker::Task::STATUSES }
          },
          required: [], additionalProperties: false
        )
        reads!

        def self.perform(user, project: nil, status: nil)
          scope = user.maker_tasks.includes(:taskable).order(*ORDER)
          scope = scope.where(taskable: project!(user, project)) if project
          scope = scope.where(status: status) if status
          rows, truncated = capped(scope)
          { tasks: rows.map { |t| Render.task(t) }, truncated: }
        end
      end

      class CreateTask < McpServer::Tool
        tool_name "create_task"
        description "Add a task to a project. status defaults to todo; done stamps completed_at."
        input_schema(
          properties: {
            project: { type: "string", description: "The project's slug." },
            title: { type: "string", minLength: 1, maxLength: 200 },
            notes: { type: "string" },
            status: { type: "string", enum: Maker::Task::STATUSES }
          },
          required: %w[project title], additionalProperties: false
        )
        writes!

        def self.perform(user, project:, title:, notes: nil, status: nil)
          p = project!(user, project)
          t = user.maker_tasks.create!(taskable: p, title: title, notes: notes, status: status || "todo",
                                       completed_at: (Time.current if status == "done"))
          { task: Render.task(t, project: p) }
        end
      end

      class UpdateTask < McpServer::Tool
        tool_name "update_task"
        description "Change a task's title, notes or status; only the fields given change. " \
                    "done stamps completed_at once; any other status clears it."
        input_schema(
          properties: {
            id: { type: "integer" },
            title: { type: "string", minLength: 1, maxLength: 200 },
            notes: { type: "string" },
            status: { type: "string", enum: Maker::Task::STATUSES }
          },
          required: %w[id], additionalProperties: false
        )
        writes!(idempotent: true)

        def self.perform(user, id:, title: nil, notes: nil, status: nil)
          t = task!(user, id)
          attrs = { title:, notes:, status: }.compact
          # V1::Maker::TasksController#update's rule, kept identical so the two doors agree.
          if status == "done"
            attrs[:completed_at] = t.completed_at || Time.current
          elsif status
            attrs[:completed_at] = nil
          end
          t.update!(attrs)
          { task: Render.task(t) }
        end
      end
    end
  end
end
