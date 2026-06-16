module Maker
  # Orchestrates one preview: processing → fetch bytes → pick a renderer → attach → ready.
  #
  # Terminal states:
  #   ready       — rendered + asset attached.
  #   unsupported — no permissive renderer for this file type (e.g. .sldprt), OR the
  #                 renderer's toolchain isn't installed on this box. A deliberate,
  #                 NON-error outcome: the job does NOT raise (no retry storm — the file
  #                 type simply isn't renderable here).
  #   failed      — a real error while fetching bytes or rendering (e.g. missing chunk).
  #
  # Phase 1 registers ONLY SVG (Maker::Previews::Registry). Later phases add renderers to
  # the registry; this orchestrator is unchanged.
  class GeneratePreviewJob < ApplicationJob
    queue_as :default

    Unsupported = Class.new(StandardError)

    def perform(preview_id, filename: nil)
      preview = Maker::Preview.find(preview_id)
      preview.update!(status: "processing", error: nil)

      name = filename.presence || preview.node_id
      renderer = Maker::Previews::Registry.for_filename(name)

      ext = File.extname(name.to_s).downcase.delete_prefix(".")
      raise Unsupported, "no preview renderer for .#{ext}" if renderer.nil?
      raise Unsupported, "renderer toolchain unavailable for .#{ext}" unless renderer.available?

      bytes  = Maker::FileBytes.read(preview.user, node_id: preview.node_id, version_id: preview.version_id)
      result = renderer.render(bytes, size: 512)

      preview.asset.attach(
        io: StringIO.new(result[:bytes]),
        filename: "#{preview.kind}-#{preview.id}#{asset_ext(result[:content_type])}",
        content_type: result[:content_type]
      )
      preview.update!(status: "ready", width: result[:width], height: result[:height], error: nil)
    rescue Unsupported => e
      # Not an error — a deliberate terminal state. Don't re-raise (no retries).
      preview&.update!(status: "unsupported", error: e.message)
    rescue StandardError => e
      preview&.update!(status: "failed", error: "#{e.class}: #{e.message}")
    end

    private

    def asset_ext(content_type)
      case content_type
      when "image/svg+xml" then ".svg"
      when "image/png"     then ".png"
      else ".bin"
      end
    end
  end
end
