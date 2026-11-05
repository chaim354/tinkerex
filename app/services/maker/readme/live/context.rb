module Maker
  class Readme
    module Live
      # WHAT THE EMITTERS READ (spec §5). Wraps what the page already loaded and fills the gaps lazily,
      # one query each, memoised — so a README holding every directive costs a constant number of
      # queries whatever the project holds (page_query_budget_test.rb). The project page passes its own
      # ivars; a hidden BOM panel means it passes nothing and the lines are loaded here, once.
      #
      # `thumbs` is the page's ThumbnailMap (or anything answering `thumb(id)` with something answering
      # `showable?`), nil for a caller that built none; then no non-photo picture is ever "ready" and
      # ImageLine writes its link form. PATHS ARE STRING ARITHMETIC OVER THE LISTING'S TREE — the disk
      # is never touched, so `..` climbs to nothing rather than out of the folder.
      class Context
        attr_reader :user, :project, :listing

        def initialize(user:, project:, listing:, bom_lines: nil, tasks: nil, entries: nil, thumbs: nil)
          @user = user
          @project = project
          @listing = listing
          @bom_lines = bom_lines
          @tasks = tasks
          @entries = entries
          @thumbs = thumbs
        end

        def bom_lines
          @bom_lines ||= (bom = project.current_bom) ? bom.lines.includes(:inventory_item, :supplier).to_a : []
        end

        def tasks = @tasks ||= project.tasks.order(:position, :created_at).to_a

        def entries
          @entries ||= project.build_log_entries.includes(:rich_text_body).reorder(logged_at: :desc).to_a
        end

        # The listing's row for a node id, or nil when the node is not live inside this project's folder.
        def row(node_id) = listing.available? ? listing.row_for(node_id) : nil

        # A row's path relative to the project folder: "laser/box.lbrn2", or "README.md" at the root.
        # `listing.path_for` is the FULL library path of the row's directory, and the listing's own
        # path is the folder's.
        def relative_path(row)
          dir = listing.path_for(row.node)
          dir == listing.path ? row.node.name : "#{dir.delete_prefix("#{listing.path}/")}/#{row.node.name}"
        end

        # The rows a `files` argument names: the root's loose rows for ".", one nested Dir's own files
        # for "a/b", nil when nothing matches. The README's own row leaves the root listing — a table
        # of files that lists the file it sits in reads as a bug.
        def files_at(arg)
          return nil unless listing.available?

          rel = Pathname.new(arg.to_s).cleanpath.to_s
          return listing.loose.reject { |r| Maker::Readme::NAMES.include?(r.node.name) } if rel == "."
          return nil if rel.start_with?("/", "..")

          dirs = listing.tree
          found = nil
          rel.split("/").each do |segment|
            found = dirs.find { |d| d.name == segment } or return nil
            dirs = found.children
          end
          found.files
        end

        def thumb_ready?(node_id) = !!@thumbs&.thumb(node_id)&.showable?

        # THE NAME OF A NODE A BOM LINE POINTS AT OUTSIDE THIS PROJECT'S FOLDER, or nil when it is not
        # live anywhere. ONE batched query over every design-file line the listing does not hold,
        # memoised — a 200-line BOM costs one lookup, never a find per line (the rule
        # page_query_budget_test.rb enforces on the page that renders this).
        def node_name(node_id)
          @node_names ||= begin
            ids = bom_lines.filter_map(&:node_id).uniq.reject { |id| row(id) }
            ids.empty? ? {} : user.nodes.present.where(node_id: ids).pluck(:node_id, :name).to_h
          end
          @node_names[node_id]
        end
      end
    end
  end
end
