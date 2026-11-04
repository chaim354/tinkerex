# frozen_string_literal: true

module McpServer
  module Tools
    # THE LIBRARY TREE AND ITS TEXT (spec §4, §5): a folder's entries, one text file's bytes, and one
    # search across everything. The tree is read from the catalog alone (LibraryPath); the ONE port
    # read is the bytes of the one file the model asked for, bounded by the catalog's size first --
    # the same allowance Maker::MarkdownFile has on a GET, and the same cap (§2, §14a).
    module Library
      def self.all = [ ListFolder, ReadTextFile, Search ]

      FOLDER_CAP = 500
      READ_LIMIT = Maker::Readme::READ_LIMIT

      class ListFolder < McpServer::Tool
        tool_name "list_folder"
        description "The files and folders directly inside one folder of the library (the root when " \
                    "path is omitted), folders first. Hidden files, the .git marker and build output " \
                    "are left out, as on the Files page. Each entry carries the path the other tools " \
                    "take, and text: true where read_text_file can read it. At most #{FOLDER_CAP}."
        input_schema(properties: { path: { type: "string", maxLength: 2000 } }, required: [], additionalProperties: false)
        reads!

        def self.perform(user, path: "")
          node = LibraryPath.resolve!(user, path)
          raise Refused, "#{path.inspect} is a file; list its folder, or read it with read_text_file." if node && !node.dir?

          base = LibraryPath.normalize(path)
          scope = user.nodes.present.visible_entries(false).where(parent_node_id: node&.node_id)
                      .order(Arel.sql("CASE kind WHEN 'dir' THEN 0 ELSE 1 END"), :name)
          rows, truncated = capped(scope, FOLDER_CAP)
          { path: base, entries: rows.map { |n| Render.node(n, path: LibraryPath.join(base, n.name)) }, truncated: }
        end
      end

      class ReadTextFile < McpServer::Tool
        tool_name "read_text_file"
        description "The text of one file, by path: README and Markdown, source code, config, G-code, " \
                    "SCAD, CSV, logs -- anything the library classes as text. Refuses binary files " \
                    "(models, images, CAD) and files over #{READ_LIMIT} bytes."
        input_schema(properties: { path: { type: "string", maxLength: 2000 } }, required: %w[path], additionalProperties: false)
        reads!

        def self.perform(user, path:)
          node = LibraryPath.resolve!(user, path)
          raise Refused, "Give a file's path; the library root is a folder (list_folder)." if node.nil?
          raise Refused, "#{path.inspect} is a folder; list it with list_folder." if node.dir?
          unless Maker::FileAttachment.text?(node.name)
            label = Maker::FileAttachment::ROLE_LABELS.fetch(Maker::FileAttachment.role_for(node.name), "Other")
            raise Refused, "#{node.name} is not text (its kind is #{label}); read_text_file only reads text files."
          end
          raise Refused, too_large(node.name, node.size.to_i) if node.size.to_i > READ_LIMIT

          bytes = FileLayer.current.read(user, node_id: node.node_id)
          # THE CATALOG CAN LAG THE STORE (a share file grown since the last scan): measured again.
          raise Refused, too_large(node.name, bytes.bytesize) if bytes.bytesize > READ_LIMIT

          text = bytes.dup.force_encoding(Encoding::UTF_8).scrub
          { path: LibraryPath.normalize(path), node_id: node.node_id, size: bytes.bytesize, text: text }
        end

        def self.too_large(name, size)
          "#{name} is #{size} bytes; read_text_file reads files up to #{READ_LIMIT} bytes."
        end
      end

      class Search < McpServer::Tool
        PER_KIND = 5
        QUERY_MAX = 80

        tool_name "search"
        description "Search everything at once by a name substring: files, folders, projects and " \
                    "inventory items, up to #{PER_KIND} of each. Use list_folder, get_project or " \
                    "get_inventory_item to go deeper."
        input_schema(properties: { q: { type: "string", minLength: 1, maxLength: QUERY_MAX } }, required: %w[q], additionalProperties: false)
        reads!

        def self.perform(user, q:)
          q = q.to_s.strip.first(QUERY_MAX)
          raise Refused, "Give something to search for." if q.blank?

          tree = Maker::LibraryTree.new(user)
          pattern = like(Node, q)
          nodes = user.nodes.present.visible_entries(false).where("LOWER(name) LIKE ? ESCAPE '\\'", pattern).order(:name)
          files = nodes.where(kind: "file").limit(PER_KIND).to_a
          folders = nodes.where(kind: "dir").limit(PER_KIND).to_a
          projects = user.maker_projects
                         .where("LOWER(name) LIKE ? ESCAPE '\\' OR LOWER(slug) LIKE ? ESCAPE '\\'", pattern, pattern)
                         .order(:name).limit(PER_KIND).to_a
          items = user.maker_inventory_items.includes(:location, :supplier)
                      .where("LOWER(name) LIKE ? ESCAPE '\\' OR LOWER(COALESCE(part_number, '')) LIKE ? ESCAPE '\\'", pattern, pattern)
                      .order(:name).limit(PER_KIND).to_a
          { q: q,
            files: files.map { |n| Render.node(n, path: LibraryPath.of(tree, n)) },
            folders: folders.map { |n| Render.node(n, path: LibraryPath.of(tree, n)) },
            projects: projects.map { |p| Render.project(p, tree:) },
            inventory: items.map { |i| Render.item(i) } }
        end
      end
    end
  end
end
