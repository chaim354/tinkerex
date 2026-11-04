# frozen_string_literal: true

module McpServer
  module Tools
    # THE BUILD LOG: read newest first, add a note or a milestone. The body crosses this wire as
    # PLAIN TEXT in both directions, as it does on v1 (BuildLogEntriesController#entry_json).
    module BuildLog
      def self.all = [ ListBuildLog, AddBuildLogEntry ]

      class ListBuildLog < McpServer::Tool
        DEFAULT = 20
        MAX = 100

        tool_name "list_build_log"
        description "A project's build-log entries, newest first, as plain text. limit defaults to " \
                    "#{DEFAULT} and may be up to #{MAX}."
        input_schema(
          properties: {
            project: { type: "string", description: "The project's slug." },
            limit: { type: "integer", minimum: 1, maximum: MAX }
          },
          required: %w[project], additionalProperties: false
        )
        reads!

        def self.perform(user, project:, limit: DEFAULT)
          p = project!(user, project)
          rows = p.build_log_entries.reorder(logged_at: :desc, id: :desc).limit(limit).includes(:rich_text_body).to_a
          { project: p.slug, entries: rows.map { |e| Render.entry(e) } }
        end
      end

      class AddBuildLogEntry < McpServer::Tool
        tool_name "add_build_log_entry"
        description "Add a note or a milestone to a project's build log. body is plain text; a blank " \
                    "line separates paragraphs. logged_at is ISO-8601 and defaults to now."
        input_schema(
          properties: {
            project: { type: "string", description: "The project's slug." },
            body: { type: "string", minLength: 1 },
            entry_type: { type: "string", enum: Maker::BuildLogEntry::ENTRY_TYPES },
            logged_at: { type: "string", description: "ISO-8601, e.g. 2026-11-04T10:00:00Z." }
          },
          required: %w[project body], additionalProperties: false
        )
        writes!

        def self.perform(user, project:, body:, entry_type: "note", logged_at: nil)
          p = project!(user, project)
          e = p.build_log_entries.create!(user: user, entry_type: entry_type, logged_at: parse_time!(logged_at),
                                          body: html_from_plain(body))
          { entry: Render.entry(e) }
        end

        # nil is "now"; anything Time.zone cannot read is refused in words. The rescue is the one
        # named case (Time.zone.parse raises ArgumentError on an out-of-range field) and never a
        # bare rescue_from.
        def self.parse_time!(value)
          return Time.current if value.nil?

          Time.zone.parse(value.to_s) || raise(Refused, "logged_at must be an ISO-8601 time, like 2026-11-04T10:00:00Z.")
        rescue ArgumentError
          raise Refused, "logged_at must be an ISO-8601 time, like 2026-11-04T10:00:00Z."
        end

        # Plain text in, the editor's paragraphs out: the text is ESCAPED first, so a "<" in a note
        # stays a "<", then each blank-line-separated block becomes a <p> and a single newline a
        # <br>. Maker::TextOnlyRichText then runs as on every door.
        def self.html_from_plain(text)
          ActionController::Base.helpers.simple_format(ERB::Util.html_escape(text.to_s), {}, sanitize: false)
        end
      end
    end
  end
end
