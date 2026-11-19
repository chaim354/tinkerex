module Maker
  class Readme
    module Live
      # `files <path>` (spec §4): the files directly under one folder of the project, as File / Kind /
      # Size / Modified, sorted by name. Kind is the role label the Files panel groups by; backups are
      # left out as the panel leaves them out; subfolders are not descended — the directive names one
      # folder and lists its own files.
      #
      # ON THE PAGE, A FIRST "Fig." COLUMN CITES EACH FILE'S FIGURE NUMBER (the Shop manual spec §9), where
      # the page numbers figures (Context#figures?). NEVER IN THE FILE: `:file` mode is what the editor's
      # Save writes, and a positional number written into a README would be wrong the moment a file is
      # added (§11.3).
      module FilesTable
        HEADERS = %w[File Kind Size Modified].freeze

        def self.call(args, context:, mode:)
          raise BadArgs, "files needs a folder path" if args.blank?

          rows = context.files_at(args)
          return Live.note("No folder “#{Live.cell(args)}” in this project.") if rows.nil?

          rows = rows.reject(&:backup?).sort_by { |r| r.node.name.downcase }
          return Live.note("No files in “#{Live.cell(args)}” yet.") if rows.empty?

          cited = mode == :page && context.figures?
          Live.table((cited ? [ "Fig." ] : []) + HEADERS, rows.map do |row|
            (cited ? [ context.figure(row.node_id).to_s ] : []) +
              [ Live.link(row.node.name, context.relative_path(row)),
                Maker::FileAttachment::ROLE_LABELS.fetch(row.role, "Other"),
                Live.size(row.node.size),
                Live.date(row.node.mtime) ]
          end)
        end
      end
    end
  end
end
