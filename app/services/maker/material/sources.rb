module Maker
  module Material
    # WHERE THE MATERIAL ESTIMATE'S PARTS COME FROM (2026-11-22; spec
    # docs/superpowers/specs/2026-11-22-material-estimate-design.md, "Adding parts, three ways").
    #
    # UPLOADS ARE MEASURED AND THROWN AWAY. Their bytes reach `Dimensions.measure` and nothing else:
    # not the port, not the library, not Active Storage, not a preview row. That is a deliberate,
    # scoped departure from §15's "bytes out of Rails", chosen by the owner; Rack's multipart tempfile
    # is the only copy and it dies with the request.
    #
    # A LIBRARY FILE READS ITS STORED SIZE when its thumbnail row is a current build of its current
    # content — a measurement is data, and §14h says a consumer that measures asks `current_build?` —
    # and otherwise reads its bytes through the port and measures them with the same function the
    # thumbnail job uses. Nothing is enqueued from here.
    #
    # Every lookup starts from the user, so another user's project, folder or file answers exactly
    # like a missing one.
    module Sources
      module_function

      MAX_UPLOADS = 20
      MAX_FOLDER_FILES = 200
      GONE = "no longer in the library".freeze
      UNREACHABLE = "library unreachable, try again".freeze
      UNREADABLE = "could not be read".freeze

      Added = Data.define(:parts, :notes)

      def max_bytes = Maker::GeneratePreviewJob::MAX_PREVIEW_BYTES

      def max_folder_files = MAX_FOLDER_FILES

      def uploads(files)
        files = Array(files).select { |f| f.respond_to?(:original_filename) && f.respond_to?(:read) }
        notes = []
        if files.size > MAX_UPLOADS
          left = files.size - MAX_UPLOADS
          notes << "Left out #{left} #{'file'.pluralize(left)}: one upload measures at most #{MAX_UPLOADS}."
          files = files.first(MAX_UPLOADS)
        end
        Added.new(parts: files.flat_map { |file| upload_parts(file) }, notes:)
      end

      def project(user, project_id)
        project = user.maker_projects.find_by(id: project_id)
        return missing("project") if project.nil?

        nodes = measurable(user.nodes.present.where(kind: "file", node_id: project.file_attachments.pluck(:node_id)))
        notes = nodes.empty? ? [ "Found no SVG, LightBurn, DXF or MillMage files attached to #{project.name}." ] : []
        Added.new(parts: library_parts(user, nodes), notes:)
      end

      def folder(user, folder_id)
        folder = user.nodes.present.find_by(node_id: folder_id.to_s, kind: "dir")
        return missing("folder") if folder.nil?

        ids = FileLayer::Subtree.node_ids(user, folder.node_id)
        nodes = measurable(user.nodes.present.where(kind: "file", node_id: ids))
        notes = []
        if nodes.empty?
          notes << "Found no SVG, LightBurn, DXF or MillMage files in #{folder.name}."
        elsif nodes.size > max_folder_files
          notes << "Added the first #{max_folder_files} of #{nodes.size} files from #{folder.name}."
          nodes = nodes.first(max_folder_files)
        end
        Added.new(parts: library_parts(user, nodes), notes:)
      end

      def file(user, node_id)
        node = user.nodes.present.find_by(node_id: node_id.to_s, kind: "file")
        return missing("file") if node.nil?
        unless Maker::Previews::Dimensions.measurable_name?(node.name)
          return Added.new(parts: [ Part.refused(name: node.name, node_id: node.node_id, reason: Maker::Previews::Dimensions::UNSUPPORTED) ],
                           notes: [])
        end

        Added.new(parts: library_parts(user, [ node ]), notes: [])
      end

      # `SystemStackError` IS NAMED in this rescue and in `library_part`'s because it is not a
      # `StandardError`. `SvgGeometry.walk` recurses once per nested `<g>`, so a deeply nested SVG
      # overflows a Puma request thread's stack. Unnamed, it would escape both rescues and 500 the
      # page. Rescuing it is safe, because the stack has unwound by the time it arrives here.
      def upload_parts(file)
        name = File.basename(file.original_filename.to_s).first(255).presence || "upload"
        return [ Part.refused(name:, reason: Maker::Previews::Dimensions::UNSUPPORTED) ] unless Maker::Previews::Dimensions.measurable_name?(name)
        return [ Part.refused(name:, reason: too_big) ] if file.size.to_i > max_bytes

        parts_for(name, Maker::Previews::Dimensions.measure(name, file.read))
      rescue Maker::Previews::Dimensions::Unmeasurable => e
        [ Part.refused(name:, reason: e.message) ]
      rescue StandardError, SystemStackError => e
        Rails.logger.warn("material upload #{name.inspect}: #{e.class}: #{e.message}")
        [ Part.refused(name:, reason: UNREADABLE) ]
      end

      def library_parts(user, nodes)
        return [] if nodes.empty?

        ids = nodes.map(&:node_id)
        infos = FileLayer.current.stat_all(user, node_ids: ids)
        rows = user.maker_previews.where(kind: "thumbnail", node_id: ids).with_attached_asset.index_by(&:node_id)
        nodes.flat_map { |node| library_part(user, node, infos[node.node_id], rows[node.node_id]) }
      end

      def library_part(user, node, info, row)
        return [ Part.refused(name: node.name, node_id: node.node_id, reason: GONE) ] if info.nil?

        parts_for(node.name, stored(row, node, info) || read(user, node, info), node_id: node.node_id)
      rescue Maker::Previews::Dimensions::Unmeasurable => e
        [ Part.refused(name: node.name, node_id: node.node_id, reason: e.message) ]
      rescue FileLayer::FetchError
        [ Part.refused(name: node.name, node_id: node.node_id, reason: UNREACHABLE) ]
      rescue FileLayer::NotFound
        [ Part.refused(name: node.name, node_id: node.node_id, reason: GONE) ]
      rescue StandardError, SystemStackError => e
        Rails.logger.warn("material library #{node.node_id}: #{e.class}: #{e.message}")
        [ Part.refused(name: node.name, node_id: node.node_id, reason: UNREADABLE) ]
      end

      # The row's size, when the row is THIS build of THIS content; else nil, and the bytes decide.
      def stored(row, node, info)
        return nil unless row&.current_build?
        return nil unless Maker::Previews::Enqueue.current_preview?(row, name: node.name, version_id: info.content_token)

        row.metadata if Maker::Previews::Dimensions.from_metadata(row.metadata)
      end

      def read(user, node, info)
        raise Maker::Previews::Dimensions::Unmeasurable, too_big if info.size.to_i > max_bytes

        Maker::Previews::Dimensions.measure(node.name,
                                            Maker::FileBytes.read(user, node_id: node.node_id, version_id: info.content_token))
      end

      # A one-page file is one part; a multi-page file one part per page with something on it,
      # since its pages are cut as separate jobs.
      def parts_for(name, metadata, node_id: nil)
        facts = Maker::Previews::Dimensions.from_metadata(metadata)
        return [ Part.refused(name:, node_id:, reason: Maker::Previews::Dimensions::NO_SHAPES) ] if facts.nil?

        pages = facts.multi_page? ? facts.sized_pages : facts.pages
        pages.map do |page|
          Part.measured(name:, node_id:, page: (page.name if facts.multi_page?), width: page.width, height: page.height)
        end
      end

      def measurable(scope)
        scope.select(:node_id, :name).to_a
             .select { |node| Maker::Previews::Dimensions.measurable_name?(node.name) }
             .sort_by { |node| [ node.name.downcase, node.node_id ] }
      end

      def missing(what) = Added.new(parts: [], notes: [ "Found no such #{what}." ])

      def too_big = "over the #{ActiveSupport::NumberHelper.number_to_human_size(max_bytes)} limit"
    end
  end
end
