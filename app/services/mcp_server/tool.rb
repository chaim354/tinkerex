# frozen_string_literal: true

module McpServer
  # THE BASE OF EVERY TOOL (spec docs/superpowers/specs/2026-11-04-mcp-server-design.md §3, §7).
  #
  # A subclass declares `tool_name`, `description`, `input_schema` (ALWAYS with
  # `additionalProperties: false`, so a misspelt argument is refused by the SDK as an isError result
  # instead of reaching `perform` as an unknown keyword), one of `reads!` / `writes!`, and
  # `self.perform(user, **args)`. `call` below is the SDK's entry and the one door: it reads the
  # user off the server context McpController built, runs `perform`, and maps what a tool can raise
  # to isError results (§7). Everything else propagates to the SDK, which answers a JSON-RPC internal
  # error and reports the exception (config/initializers/mcp.rb). NOTHING HERE RESCUES
  # NotImplementedError (§14a): it is a ScriptError and the rescue list below never names it.
  #
  # ANNOTATIONS ARE STATED IN FULL because the SDK's defaults are `destructive_hint: true` and
  # `open_world_hint: true` (MCP::Tool::Annotations): a read tool that forgot `reads!` would be
  # presented to the client as destructive. `open_world_hint` is false everywhere: every tool acts
  # on this one user's closed dataset.
  class Tool < MCP::Tool
    UNREACHABLE = "The library is unreachable right now. Try again in a moment."
    LIST_CAP = 100

    class << self
      def reads!
        annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      end

      def writes!(idempotent: false)
        annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: idempotent, open_world_hint: false)
      end

      def call(server_context:, **args)
        ok(perform(server_context[:user], **args))
      rescue NotFound, Refused, FileLayer::UnsupportedOperation => e
        refuse(e.message)
      rescue ActiveRecord::RecordNotFound
        refuse("Not found.")
      rescue ActiveRecord::RecordInvalid => e
        refuse("#{e.record.errors.full_messages.join(". ")}.")
      rescue FileLayer::NotFound => e
        refuse(e.message.presence || "Not found.")
      rescue FileLayer::FetchError
        refuse(UNREACHABLE)
      end

      def perform(_user, **)
        raise NotImplementedError, "#{name} must define self.perform(user, **args)"
      end

      # One text block of compact JSON for the model to read, and the same hash as structuredContent
      # for a client that parses.
      def ok(payload)
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ], structured_content: payload)
      end

      def refuse(message)
        MCP::Tool::Response.new([ { type: "text", text: message } ], error: true)
      end

      # --- Finders. EVERY ONE STARTS FROM THE USER (§8): a foreign slug or id is NotFound here, and
      # a bare `Maker::Project.find` must never appear in a tool (isolation_test.rb).
      def project!(user, slug)
        user.maker_projects.find_by(slug: slug.to_s) || raise(NotFound, "No project #{slug.to_s.inspect}.")
      end

      def task!(user, id)
        user.maker_tasks.find_by(id: id) || raise(NotFound, "No task with id #{id}.")
      end

      def item!(user, id)
        user.maker_inventory_items.find_by(id: id) || raise(NotFound, "No inventory item with id #{id}.")
      end

      def bom_line!(user, id)
        user.maker_bom_lines.find_by(id: id) || raise(NotFound, "No BOM line with id #{id}.")
      end

      # The Files page's case-insensitive LIKE pattern (SearchController): the caller's clause must
      # carry `ESCAPE '\'`, which is what makes sanitize_sql_like do anything on SQLite.
      def like(model, q)
        "%#{model.sanitize_sql_like(q.to_s.downcase)}%"
      end

      # `cap + 1` rows, then the cap: one query answers both the page and whether it was cut.
      def capped(scope, cap = LIST_CAP)
        rows = scope.limit(cap + 1).to_a
        [ rows.first(cap), rows.size > cap ]
      end
    end
  end
end
