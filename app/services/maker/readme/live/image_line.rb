module Maker
  class Readme
    module Live
      # `image <node_id> [caption]` (spec §4): one project file BY IDENTITY, so a rename follows. The
      # caption defaults to the file's name.
      #
      # THE ONE PLACE THE FILE AND THE PAGE DIFFER. A picture (Live.picture?: the inline-image list plus
      # SVG) is an image in both. Any other file is a LINK in the file — an image tag whose source is an STL is a
      # broken picture on GitHub — and an image on the page once its thumbnail is ready, which the
      # maker's node-aware image arm (ProjectsHelper#maker_image_link) resolves to that thumbnail. With
      # no thumbnail ready yet the page gets the link form too; the next load, after the render job,
      # shows the picture.
      module ImageLine
        def self.call(args, context:, mode:)
          node_id, caption = args.to_s.split(/\s+/, 2)
          raise BadArgs, "image needs a node id" if node_id.blank?

          row = context.row(node_id)
          return Live.note("This file is no longer in the project.") if row.nil?

          text = caption.presence || row.node.name
          path = context.relative_path(row)
          picture = Live.picture?(row.node.name) || (mode == :page && context.thumb_ready?(node_id))
          picture ? Live.image(text, path) : Live.link(text, path)
        end
      end
    end
  end
end
