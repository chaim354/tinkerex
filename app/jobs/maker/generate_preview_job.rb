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

    # A preview can be destroyed (e.g. file deleted) before this enqueued job runs;
    # discard cleanly rather than letting find's RecordNotFound be swallowed as a "failure".
    discard_on ActiveRecord::RecordNotFound

    # A transient byte-store failure (403 creds blip, 5xx, network) is RETRYABLE — the
    # chunk likely exists, we just couldn't read it this instant. Retry with backoff
    # instead of burning the preview to a terminal "failed" (the prod creds-outage bug).
    # After attempts are exhausted, ActiveJob re-raises; the preview stays non-terminal
    # ("processing") so a later manual/scheduled re-enqueue can still succeed.
    retry_on Maker::FileBytes::FetchError, wait: :polynomially_longer, attempts: 5

    def perform(preview_id, filename: nil)
      # find OUTSIDE the begin/rescue so a missing record propagates to discard_on,
      # while fetch/render errors below still mark the preview "failed".
      preview = Maker::Preview.find(preview_id)

      # WHAT THIS RUN IS RENDERING, captured before any work. A preview row is now ONE PER
      # (node, kind) and is REPOINTED as the file's content moves, so the row can change under a
      # job that is already rendering — a slow render of v1 finishing after a fast render of v2
      # would otherwise attach v1's bytes to a row that says v2 and mark it ready: a wrong image
      # shown as current, silently. Under the old row-per-version key that was impossible by
      # construction, and this guard is what buys the same immunity back.
      target = preview.version_id

      begin
        preview.update!(status: "processing", error: nil)

        # An explicit filename arg wins (e.g. the UI passes it). Otherwise resolve the
        # file's real name from the synced Node row (tenant-scoped) — the enqueue API may
        # omit filename, and preview.node_id is a UUID with no extension, so renderer
        # selection would wrongly land on "unsupported" without this. Falls back to the
        # raw node_id when there's no matching node row (still correctly unsupported).
        name = filename.presence ||
               preview.user.nodes.find_by(node_id: preview.node_id)&.name ||
               preview.node_id
        renderer = Maker::Previews::Registry.for_filename(name)

        ext = File.extname(name.to_s).downcase.delete_prefix(".")
        raise Unsupported, "no preview renderer for .#{ext}" if renderer.nil?
        raise Unsupported, "renderer toolchain unavailable for .#{ext}" unless renderer.available?

        bytes  = Maker::FileBytes.read(preview.user, node_id: preview.node_id, version_id: preview.version_id)
        result = render_with(renderer, bytes, ext:, kind: preview.kind)

        commit_if_current(preview, target) do
          preview.asset.attach(
            io: StringIO.new(result[:bytes]),
            filename: "#{preview.kind}-#{preview.id}#{asset_ext(result[:content_type])}",
            content_type: result[:content_type]
          )
          preview.update!(status: "ready", width: result[:width], height: result[:height],
                          metadata: result[:metadata], error: nil)
        end
      rescue Unsupported => e
        # Not an error — a deliberate terminal state. Don't re-raise (no retries).
        commit_if_current(preview, target) { preview.update!(status: "unsupported", error: e.message) }
      rescue Maker::FileBytes::FetchError => e
        # Transient (auth/network/5xx). Do NOT mark terminal — leave it "processing" and
        # re-raise so retry_on schedules a backed-off retry (or re-raises once exhausted).
        commit_if_current(preview, target) { preview.update!(error: "#{e.class}: #{e.message} (retrying)") }
        raise
      rescue StandardError => e
        commit_if_current(preview, target) { preview.update!(status: "failed", error: "#{e.class}: #{e.message}") }
      end
    end

    private

    # Write the outcome ONLY if the row still points at the content this run rendered.
    #
    # EVERY terminal write goes through here, not just the successful one, and that is the part
    # most likely to be trimmed later: a stale `unsupported` or `failed` is as wrong as a stale
    # image. A v1 render that fails must not mark a row that has already moved to v2 as failed —
    # `Enqueue` treats `failed` as "retry me", so it would look repaired while describing content
    # nobody asked about, and the genuine v2 result would be overwritten by an older verdict.
    #
    # Losing the write is the CORRECT outcome, not a dropped update: whoever repointed the row also
    # enqueued a job for the new content, so the newer render is already coming.
    def commit_if_current(preview, target)
      preview.reload
      return if preview.version_id != target

      yield
    rescue ActiveRecord::RecordNotFound
      nil # the row was deleted mid-render; nothing to write and nothing wrong
    end

    # Renderers share a `render(bytes, size:)` contract; some (e.g. Mesh/F3D) also accept
    # `ext:` (to pick the loader) and `kind:`. Accepting `kind:` is not a promise to produce
    # every kind — Mesh takes it only to REFUSE `model_glb` (f3d renders rasters and cannot
    # export GLB), raising Unsupported, which the rescue above maps to that terminal status.
    # Pass each kwarg only when the renderer's signature declares it, so the simpler
    # renderers stay unchanged.
    def render_with(renderer, bytes, ext:, kind:)
      accepted = renderer.method(:render).parameters.select { |t, _| %i[key keyreq].include?(t) }.map(&:last)
      opts = { size: 512 }
      opts[:ext]  = ext  if accepted.include?(:ext)
      opts[:kind] = kind if accepted.include?(:kind)
      renderer.render(bytes, **opts)
    end

    def asset_ext(content_type)
      case content_type
      when "image/svg+xml"     then ".svg"
      when "image/png"         then ".png"
      when "image/jpeg"        then ".jpg"
      when "model/gltf-binary" then ".glb"
      else ".bin"
      end
    end
  end
end
