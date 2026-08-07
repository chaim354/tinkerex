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

    # THE CEILING A PREVIEW IS WORTH, WHICH IS NOT THE CEILING A FILE IS ALLOWED TO BE.
    #
    # Rendering buffers the WHOLE file (Maker::FileBytes.read returns a String), and the only bound
    # on that was FileLayer::MAX_BYTES — 256 MiB, which exists to cap an UPLOAD, not a thumbnail.
    # Three consequences, worst first:
    #   - On S3 the first index of a large library enqueues one of these per renderable object and
    #     each one is a FULL BILLED DOWNLOAD. §14a's identity ladder explicitly refused to pay that
    #     cost for hashing ("a full billed egress to index a library the user already has is the
    #     cost the on-ramp exists to avoid") — previews were paying it silently, for the same bytes.
    #   - Worst case ~3 x 256 MB transient in the worker process, which on self-host shares RSS and
    #     the GVL with the web threads (SOLID_QUEUE_IN_PUMA).
    #   - A 200 MB STL does not produce a better thumbnail than a 20 MB one; it produces the same
    #     512px image after far more work.
    #
    # 32 MB comfortably covers the formats with real thumbnails (STL/3MF/SVG/DXF/LightBurn, images,
    # PDF) while excluding the outliers that cost the most and gain the least. Operator-tunable,
    # following PROJECT_ORGANIZE_EAGER_MAX_MOVES' precedent, because the right number depends on the
    # library: raise it on a fast local share, lower it on metered object storage.
    #
    # SKIPPED, NOT FAILED. It resolves to `unsupported`, which is already this job's word for "no
    # preview for this file here" — a deliberate terminal state that does NOT retry. `failed` would
    # be wrong twice: nothing failed, and it would invite a retry that re-reads the same bytes.
    MAX_PREVIEW_BYTES = ENV.fetch("PREVIEW_MAX_BYTES", 32.megabytes).to_i

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
      #
      # BOTH COORDINATES, not just the content: a row is equally repointed when the RENDERER's
      # revision moves, and a run that started under the old build must not stamp its output onto
      # a row now claiming the new one. Same race, second axis.
      target = [ preview.version_id, preview.renderer_revision ]

      begin
        preview.update!(status: "processing", error: nil)

        # An explicit filename arg wins (e.g. the UI passes it). Otherwise resolve the
        # file's real name from the synced Node row (tenant-scoped) — the enqueue API may
        # omit filename, and preview.node_id is a UUID with no extension, so renderer
        # selection would wrongly land on "unsupported" without this. Falls back to the
        # raw node_id when there's no matching node row (still correctly unsupported).
        # ONE lookup, TWO answers. This used to resolve only the name, and to skip the row entirely
        # when an explicit `filename:` was passed; the row is now always read because `size` is what
        # the ceiling below judges. It is effectively free — an indexed find the job already made in
        # the common case.
        node = preview.user.nodes.find_by(node_id: preview.node_id)
        name = filename.presence || node&.name || preview.node_id
        renderer = Maker::Previews::Registry.for_filename(name)

        ext = File.extname(name.to_s).downcase.delete_prefix(".")
        raise Unsupported, "no preview renderer for .#{ext}" if renderer.nil?
        raise Unsupported, "renderer toolchain unavailable for .#{ext}" unless available_for?(renderer, preview.kind)
        refuse_if_oversized!(node, ext)

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

    # Decline to render a file too big to be worth rendering — see MAX_PREVIEW_BYTES.
    #
    # JUDGED ON THE CATALOG ROW, WHICH IS THE ONLY PLACE IT IS FREE. `nodes.size` is populated by
    # all three backends (it is the catalog the scan and the sync engine both maintain), so this
    # costs nothing beyond the find already made. Asking the PORT for the size instead would mean a
    # HEAD per object on S3 — paying a per-object request to avoid a per-object download, on every
    # preview, which is the trade §14a's LIBRARY_S3_HEAD_FOR_CHECKSUM note already rejected.
    #
    # AN UNKNOWN SIZE PROCEEDS. A missing node row or a null size means the catalog cannot answer,
    # and refusing on "I don't know" would silently stop previewing files whose row is merely
    # incomplete. FileLayer::MAX_BYTES still backstops the read, so the failure mode of proceeding
    # is the old behaviour, not a new one.
    def refuse_if_oversized!(node, ext)
      size = node&.size
      return if size.nil? || size <= MAX_PREVIEW_BYTES

      raise Unsupported,
            "#{ext.presence || 'file'} is #{ActiveSupport::NumberHelper.number_to_human_size(size)}, " \
            "over the #{ActiveSupport::NumberHelper.number_to_human_size(MAX_PREVIEW_BYTES)} preview " \
            "ceiling (raise PREVIEW_MAX_BYTES to render larger files)"
    end

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
      return if [ preview.version_id, preview.renderer_revision ] != target

      yield
    rescue ActiveRecord::RecordNotFound
      nil # the row was deleted mid-render; nothing to write and nothing wrong
    end

    # IS THIS RENDERER ABLE TO BUILD **THIS KIND** ON THIS BOX?
    #
    # `available?` asks about the TOOLCHAIN, and for the 2D vector formats that toolchain is resvg
    # — because their THUMBNAIL is a rasterized SVG. The Measure payload from the same renderers is
    # Nokogiri and arithmetic and needs nothing external, so a single `available?` gate marks a
    # perfectly measurable .svg/.dxf/.lbrn2 `unsupported` on any box without the rasterizer. That
    # reads to a user as "we cannot handle this file", which is false, and it would have made the
    # measure feature silently backend-dependent: `Mage.available?` is unconditionally true, so
    # .mage would measure on such a box while the other three did not.
    #
    # `respond_to?` WITH A FALLBACK TO `available?`, the same shape `Enqueue.revision_for` already
    # uses for `payload_revision` — so the ten renderers that produce only a thumbnail are
    # untouched and the registry's published contract (available?/render/EXTENSIONS) still holds.
    def available_for?(renderer, kind)
      return renderer.available_for?(kind) if renderer.respond_to?(:available_for?)

      renderer.available?
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
      when "application/json"  then ".json"
      else ".bin"
      end
    end
  end
end
