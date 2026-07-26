module Maker
  module Previews
    # One-time backfill: re-render LightBurn thumbnail previews created before the `metadata`
    # column existed, so they gain the laser-settings panel without the user re-saving the file.
    # Idempotent (re-render is deterministic) and safe to run repeatedly.
    module LbrnBackfill
      module_function

      LBRN_EXTS = %w[.lbrn .lbrn2].freeze

      def call
        scope = Maker::Preview.where(kind: "thumbnail", status: "ready", metadata: nil)
        count = 0
        scope.find_each do |preview|
          name = preview.user.nodes.find_by(node_id: preview.node_id)&.name.to_s
          next unless LBRN_EXTS.include?(File.extname(name).downcase)

          Maker::GeneratePreviewJob.perform_later(preview.id)
          count += 1
        end
        count
      end
    end
  end
end
