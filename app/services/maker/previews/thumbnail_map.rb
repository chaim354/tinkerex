module Maker
  module Previews
    # Resolve the CURRENT-version thumbnail for a set of file-library node_ids, degrade-safe.
    #
    # A thumbnail is keyed by (node_id, content_token); the token comes from the FileLayer port.
    # If the backend is unreachable (FetchError), we return an empty map so callers show a spinner
    # /icon rather than 503-ing a page of maker data that does not depend on the file backend.
    class ThumbnailMap
      def self.for(user, node_ids)
        ids = node_ids.compact.uniq
        info =
          if ids.empty?
            {}
          else
            begin
              FileLayer.current.stat_all(user, node_ids: ids)
            rescue FileLayer::FetchError
              {}
            end
          end
        tokens = info.transform_values(&:content_token)
        previews =
          if tokens.values.compact.empty?
            {}
          else
            user.maker_previews
                .where(kind: "thumbnail", node_id: ids, version_id: tokens.values.compact)
                .index_by { |p| [ p.node_id, p.version_id ] }
          end
        new(tokens:, previews:)
      end

      def initialize(tokens:, previews:)
        @tokens = tokens
        @previews = previews
      end

      # The Maker::Preview for a node's current content, or nil (nil => spinner in _thumb).
      def thumb(node_id)
        token = @tokens[node_id]
        token && @previews[[ node_id, token ]]
      end
    end
  end
end
