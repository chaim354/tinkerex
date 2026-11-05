module Maker
  class Readme
    # LIVE REGIONS IN A README (2026-11-05; docs/superpowers/specs/2026-11-05-readme-panel-live-regions-design.md).
    #
    # A region is two HTML comments on their own lines around a GENERATED body:
    #
    #   <!-- tinkerex:files laser -->
    #
    #   | File | Kind | Size | Modified |
    #   ...
    #
    #   <!-- /tinkerex -->
    #
    # The body is regenerated on every render (`:page` mode, markers stripped, body alone) and every
    # Save from the project page (`:file` mode, marker / blank / body / blank / marker), so the file
    # holds a plain-markdown snapshot of what the page shows live — which is what the owner chose over
    # an app that rewrites the file on every scan, BOM edit or task change (spec §6). THE BLANK LINES
    # ARE LOAD-BEARING: kramdown swallows a table that starts directly under a comment into one
    # paragraph (probed while writing the spec).
    #
    # WHAT IS GENERATED IS PLAIN GFM, and it goes through Maker::Markdown's sanitiser like prose does,
    # so nothing an emitter writes can reach the page as markup. ONE emitter per directive answers for
    # the file and the page alike; `ImageLine` is the one place the two differ, and it says so.
    #
    # THE GRAMMAR, written once here and mirrored by readme_controller.js's collapse: an opener line,
    # then — if a closer appears before the next opener or the end — a closed region whose body is the
    # lines between; otherwise an UNCLOSED region that is the opener line alone, with the lines after it
    # ordinary prose. A closer with no open region is prose. Regions never nest. An unrecognised
    # directive, a directive whose arguments do not parse (`BadArgs`), and every region past
    # MAX_REGIONS are left as written in the file and lose only their markers on the page — a typo
    # never destroys what someone wrote.
    module Live
      DIRECTIVES = %w[files bom tasks log image].freeze
      MAX_REGIONS = 20
      MAX_ROWS = 200
      MODES = %i[page file].freeze
      # `\r?` on both: a README written on Windows arrives with CRLF, and a marker that fails to match
      # for its carriage return would silently demote a region to prose.
      OPEN_RE  = /\A[ \t]*<!--[ \t]*tinkerex:([a-z]+)(?:[ \t]+(.*?))?[ \t]*-->[ \t]*\r?\z/
      CLOSE_RE = %r{\A[ \t]*<!--[ \t]*/tinkerex[ \t]*-->[ \t]*\r?\z}
      CLOSER = "<!-- /tinkerex -->".freeze

      # An emitter raises this for arguments it cannot read; `expand` then treats the region as
      # unrecognised rather than guessing.
      class BadArgs < StandardError; end

      Region = Data.define(:directive, :args, :open_line, :close_line) do
        def closed? = !close_line.nil?
        def recognised? = DIRECTIVES.include?(directive)
        # The node id an `image` region names — what the page folds into its one thumbnail query
        # (spec §5) — and nil for every other directive.
        def node_id = directive == "image" ? args.to_s.split(/\s+/, 2).first : nil
      end

      def self.regions(text)
        lines = text.to_s.split("\n", -1)
        found = []
        i = 0
        while i < lines.size
          if (m = OPEN_RE.match(lines[i]))
            j = i + 1
            j += 1 while j < lines.size && !OPEN_RE.match?(lines[j]) && !CLOSE_RE.match?(lines[j])
            closed = j < lines.size && CLOSE_RE.match?(lines[j])
            found << Region.new(directive: m[1], args: m[2].to_s.strip, open_line: i, close_line: closed ? j : nil)
            i = closed ? j + 1 : i + 1
          else
            i += 1
          end
        end
        found
      end

      # `context` nil is a caller with nothing to expand against (a nested repository's card, the
      # file page): every region is then "unrecognised" — verbatim in the file, markers off on the page.
      def self.expand(text, context:, mode:)
        raise ArgumentError, "mode must be :page or :file, got #{mode.inspect}" unless MODES.include?(mode)

        lines = text.to_s.split("\n", -1)
        out = []
        cursor = 0
        regions(text).each_with_index do |region, index|
          out.concat(lines[cursor...region.open_line])
          last = region.closed? ? region.close_line : region.open_line
          body = context && index < MAX_REGIONS && region.recognised? ? emit(region, context:, mode:) : nil
          if body.nil?
            kept = lines[region.open_line..last]
            if mode == :page
              kept = kept.drop(1)                       # the opener
              kept = kept[0...-1] if region.closed?     # and the closer
            end
            out.concat(kept)
          elsif mode == :file
            out << lines[region.open_line].chomp("\r") << "" << body << "" << CLOSER
          else
            out << "" << body << ""
          end
          cursor = last + 1
        end
        out.concat(lines[cursor..] || [])
        out.join("\n")
      end

      def self.emit(region, context:, mode:)
        emitter_for(region.directive).call(region.args, context:, mode:)
      rescue BadArgs
        nil
      end

      def self.emitter_for(directive)
        case directive
        when "files" then FilesTable
        when "bom"   then BomTable
        when "tasks" then TaskList
        when "log"   then LogTable
        when "image" then ImageLine
        end
      end

      # --- what the emitters write with -----------------------------------------------------------

      # Text that is safe inside a table cell, a list item and a link's text: a pipe would end the
      # cell, a bracket the link, and `*`/`_`/backtick would start emphasis or code mid-name. A row
      # is one line, so whitespace is squished. (Probed against kramdown: `\|` and `\]` render as the
      # bare character.) The link DESTINATION is left as the catalog spells it except for a pipe,
      # escaped `\|` so it cannot end the cell — kramdown accepts spaces and parentheses there and
      # hands the pipe back bare (probed), and the folder resolver indexes RAW paths, so a
      # percent-encoded destination would resolve to nothing.
      def self.cell(text) = text.to_s.gsub(/\s+/, " ").strip.gsub(/[\\`*_\[\]|]/) { |c| "\\#{c}" }
      def self.link(text, path) = "[#{cell(text)}](#{path.to_s.gsub('|', '\\|')})"
      def self.note(text) = "*#{text}*"
      def self.size(bytes) = bytes ? ActiveSupport::NumberHelper.number_to_human_size(bytes) : "—"
      # The catalog's mtime is nanoseconds; the date is in the app's zone like every other timestamp.
      def self.date(nanos) = nanos ? Time.zone.at(nanos / 1_000_000_000).strftime("%Y-%m-%d") : "—"

      # A GFM table over pre-escaped cells, cut at MAX_ROWS with a count — a 2000-file folder must not
      # turn a README into a 2000-row file on Save.
      def self.table(headers, rows)
        lines = [ "| #{headers.join(' | ')} |", "|#{'---|' * headers.size}" ]
        rows.first(MAX_ROWS).each { |cells| lines << "| #{cells.join(' | ')} |" }
        lines << "" << note("… and #{rows.size - MAX_ROWS} more") if rows.size > MAX_ROWS
        lines.join("\n")
      end
    end
  end
end
