module Maker
  class Readme
    module Live
      # `log [N]` (spec §4): Date / Entry over the newest N build-log entries (default 10, at most 50).
      # Entry is the body's plain text, squished and cut, with "Milestone:" ahead of a milestone's. NO
      # anchor links: the renderer rewrites `#fragment` into the README's own namespace, so a link to an
      # entry would not land.
      module LogTable
        HEADERS = %w[Date Entry].freeze
        DEFAULT = 10
        MAX = 50
        GIST = 120

        def self.call(args, context:, mode:)
          count = args.blank? ? DEFAULT : Integer(args, exception: false)
          raise BadArgs, "log takes a count" if count.nil? || count < 1

          entries = context.entries.first([ count, MAX ].min)
          return Live.note("No build log entries yet.") if entries.empty?

          Live.table(HEADERS, entries.map { |entry| [ entry.logged_at.in_time_zone.strftime("%Y-%m-%d"), gist(entry) ] })
        end

        def self.gist(entry)
          text = Live.cell(entry.body.to_plain_text.squish.truncate(GIST))
          entry.entry_type == "milestone" ? "**Milestone:** #{text}" : text
        end
      end
    end
  end
end
