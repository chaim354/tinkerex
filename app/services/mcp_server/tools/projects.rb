# frozen_string_literal: true

module McpServer
  module Tools
    # PROJECTS: list, read, create, update. Never delete (spec §4): archiving is a status.
    module Projects
      def self.all = [ ListProjects, GetProject, CreateProject, UpdateProject ]

      class ListProjects < McpServer::Tool
        tool_name "list_projects"
        description "List this user's projects, newest change first: slug, name, status, kind, " \
                    "library folder path, open task count. Filter by status " \
                    "(#{Maker::Project::STATUSES.join(", ")}) and/or a name substring. " \
                    "At most #{LIST_CAP} rows; truncated is true when there were more."
        input_schema(
          properties: {
            status: { type: "string", enum: Maker::Project::STATUSES },
            q: { type: "string", maxLength: 80, description: "A substring of the name, case-insensitive." }
          },
          required: [], additionalProperties: false
        )
        reads!

        def self.perform(user, status: nil, q: nil)
          scope = user.maker_projects.by_status(status).order(updated_at: :desc, id: :desc)
          scope = scope.where("LOWER(name) LIKE ? ESCAPE '\\'", like(Maker::Project, q)) if q.present?
          rows, truncated = capped(scope)
          tree = Maker::LibraryTree.new(user)
          open = user.maker_tasks.open.where(taskable_type: "Maker::Project", taskable_id: rows.map(&:id))
                     .group(:taskable_id).count
          { projects: rows.map { |p| Render.project(p, tree:, open_tasks: open.fetch(p.id, 0)) }, truncated: }
        end
      end

      class GetProject < McpServer::Tool
        ENTRIES = 20

        tool_name "get_project"
        description "One project in full: description, status, kind, visibility, folder path, its " \
                    "tasks (open first), the last #{ENTRIES} build-log entries newest first, its BOMs " \
                    "with line counts, and the files attached to it with their paths."
        input_schema(properties: { slug: { type: "string" } }, required: %w[slug], additionalProperties: false)
        reads!

        def self.perform(user, slug:)
          p = project!(user, slug)
          tree = Maker::LibraryTree.new(user)
          tasks = p.tasks.reorder(Arel.sql("CASE status WHEN 'done' THEN 1 ELSE 0 END"), :position, :id).to_a
          entries = p.build_log_entries.reorder(logged_at: :desc, id: :desc).limit(ENTRIES)
                     .includes(:rich_text_body).to_a
          boms = p.boms.order(:id).to_a
          counts = Maker::BomLine.where(bom_id: boms.map(&:id)).group(:bom_id).count
          attachments = p.file_attachments.to_a
          nodes = user.nodes.present.where(node_id: attachments.map(&:node_id)).index_by(&:node_id)
          Render.project(p, tree:, open_tasks: tasks.count { |t| t.status != "done" }).merge(
            description: p.description,
            archived_at: Render.time(p.archived_at),
            tasks: tasks.map { |t| Render.task(t, project: p) },
            build_log: entries.map { |e| Render.entry(e) },
            boms: boms.map { |b| Render.bom(b, lines: counts.fetch(b.id, 0)) },
            files: attachments.filter_map do |a|
              node = nodes[a.node_id] or next
              { path: LibraryPath.of(tree, node), name: node.name, role: a.role, label: a.label, node_id: node.node_id }
            end
          )
        end
      end

      class CreateProject < McpServer::Tool
        tool_name "create_project"
        description "Create a project. The slug is derived from the name. Its library folder " \
                    "Projects/<slug> is made too; if the library cannot be reached the project still " \
                    "exists and the answer carries a note."
        input_schema(
          properties: {
            name: { type: "string", minLength: 1, maxLength: 200 },
            description: { type: "string" },
            status: { type: "string", enum: Maker::Project::STATUSES },
            kind: { type: "string", enum: Maker::Project::KINDS }
          },
          required: %w[name], additionalProperties: false
        )
        writes!

        def self.perform(user, name:, description: nil, status: nil, kind: nil)
          p = user.maker_projects.create!({ name:, description:, status:, kind: }.compact)
          note = ensure_folder(user, p)
          Render.project(p, tree: Maker::LibraryTree.new(user), open_tasks: 0)
                .merge(description: p.description, note: note).compact
        end

        # ProjectsController#ensure_project_folder's best effort, for its reason: the project exists
        # whether or not the library answered, and the folder is tried again on the next project
        # view. Only the two port failures are swallowed; anything else propagates.
        def self.ensure_folder(user, p)
          p.ensure_library_folder!(user)
          nil
        rescue FileLayer::FetchError
          "The library could not be reached, so the project folder was not created yet. It is made " \
            "the next time the project is opened while the library is available."
        rescue FileLayer::UnsupportedOperation
          "The project folder could not be made in the library; a file or folder there may already " \
            "have its name. It is tried again each time the project is opened."
        end
      end

      class UpdateProject < McpServer::Tool
        tool_name "update_project"
        description "Change a project's name, description, status or kind; only the fields given " \
                    "change. A status of \"archived\" archives it (stamping archived_at); any other " \
                    "status unarchives it. There is no delete."
        input_schema(
          properties: {
            slug: { type: "string" },
            name: { type: "string", minLength: 1, maxLength: 200 },
            description: { type: "string" },
            status: { type: "string", enum: Maker::Project::STATUSES },
            kind: { type: "string", enum: Maker::Project::KINDS }
          },
          required: %w[slug], additionalProperties: false
        )
        writes!(idempotent: true)

        def self.perform(user, slug:, name: nil, description: nil, status: nil, kind: nil)
          p = project!(user, slug)
          p.assign_attributes({ name:, description:, kind:, status: }.compact)
          # Maker::Project#archive! / #unarchive! in one save: the stamp follows the status.
          p.archived_at = (status == "archived" ? (p.archived_at || Time.current) : nil) if status
          p.save!
          Render.project(p, tree: Maker::LibraryTree.new(user))
                .merge(description: p.description, archived_at: Render.time(p.archived_at))
        end
      end
    end
  end
end
