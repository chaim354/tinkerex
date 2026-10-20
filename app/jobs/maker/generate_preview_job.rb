module Maker
  # Orchestrates one preview: start (pending → processing; a `rebuilding` row keeps its picture) →
  # fetch bytes → pick a renderer → attach → ready.
  #
  # Terminal states:
  #   ready       — rendered + asset attached.
  #   unsupported — no permissive renderer for this file type (e.g. .sldprt), OR the
  #                 renderer's toolchain isn't installed on this box. A deliberate,
  #                 NON-error outcome: the job does NOT raise (no retry storm — the file
  #                 type simply isn't renderable here).
  #   failed      — a real error while fetching bytes or rendering (e.g. missing chunk).
  #
  # The renderer comes from Maker::Previews::Registry; adding a format changes the registry, never
  # this orchestrator.
  class GeneratePreviewJob < ApplicationJob
    queue_as :default

    Unsupported = Class.new(StandardError)

    # THIS JOB'S ARGUMENT IS A PRIMARY-DATABASE ROW ID, AND THE JOB ITSELF LIVES IN THE QUEUE
    # DATABASE — so without this, `perform_later` is NOT covered by the caller's transaction. It
    # commits to the queue DB on its own connection, immediately, while the `maker_previews` row is
    # still uncommitted on primary. `Maker::Previews::Enqueue` is called from inside a transaction
    # by every addon save (`Tools::AddonsController#create`), and Solid Queue runs IN THE PUMA
    # PROCESS here (SOLID_QUEUE_IN_PUMA) polling sub-second, so the worker won that race, found no
    # row, and `discard_on ActiveRecord::RecordNotFound` below swallowed the job — no failure, no
    # log, marked finished. The row then sat at `pending` forever, which is a permanent spinner.
    #
    # MEASURED, NOT REASONED: on the deployed share library, job 15583 was created and finished
    # within the same second (2026-08-13 23:09:20) while preview 1747 was never touched.
    #
    # SET PER JOB RATHER THAN GLOBALLY (it is an ActiveJob `class_attribute`, default false in
    # Rails 8.1) because this is a statement about THIS job's argument, and it belongs beside the
    # `discard_on` whose interaction makes the loss silent. `after_all_transactions_commit` runs
    # the block immediately when no transaction is open, so callers outside one are unaffected.
    self.enqueue_after_transaction_commit = true

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
    # After attempts are exhausted, ActiveJob re-raises; the preview stays non-terminal (in flight:
    # `processing`, or `rebuilding` with its old picture still up) so a later re-enqueue — the
    # STALLED_AFTER heal — can still succeed.
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
        # THE START, COMPARE-AND-SET LIKE EVERY OTHER WRITE HERE (F-S08-2). It was a bare `update!`
        # on the row as this job first read it, so a row that moved on in between was overwritten:
        # a renderer bump landing in that gap had its `rebuilding` flipped to `processing` by the
        # stale object, blanking a picture that was still correct, and the job went on to render
        # coordinates nobody had asked for. A row that moved is answered by the job enqueued for
        # it, so this one stops.
        #
        # AND IT MOVES `pending` AND NOTHING ELSE. `pending → processing` is the v1 wire's "a worker
        # has it" and restarts the stall clock; every other status already says something true
        # about what is on screen. Above all `rebuilding`, whose old picture must stay up through
        # the render: this line used to write `processing` unconditionally, which every surface
        # drew as a spinner over that picture for as long as the render took.
        started = commit_if_current(preview, target) do
          preview.update!(status: "processing", error: nil) if preview.status == "pending"
        end
        return unless started

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
        raise Unsupported, "renderer toolchain unavailable for .#{ext}" unless Maker::Previews::Registry.available_for?(renderer, preview.kind)
        refuse_if_oversized!(node, ext)

        bytes  = Maker::FileBytes.read(preview.user, node_id: preview.node_id, version_id: preview.version_id)
        result = Maker::Previews::Registry.render(renderer, bytes, ext:, kind: preview.kind)

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
        # Transient (auth/network/5xx). Do NOT mark terminal — leave its in-flight status alone
        # and re-raise so retry_on schedules a backed-off retry (or re-raises once exhausted).
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
    # is the old behaviour, not a new one — and that backstop is now true on ALL THREE backends,
    # which it was not when this sentence was written: share stats the file and s3 bounds a ranged
    # GET, and chunk_remote refuses on the summed length of the manifest it has already mirrored.
    # The shared adapter contract asks for it, so a fourth adapter cannot quietly omit it and leave
    # this justification false again.
    def refuse_if_oversized!(node, ext)
      size = node&.size
      return if size.nil? || size <= MAX_PREVIEW_BYTES

      raise Unsupported,
            "#{ext.presence || 'file'} is #{ActiveSupport::NumberHelper.number_to_human_size(size)}, " \
            "over the #{ActiveSupport::NumberHelper.number_to_human_size(MAX_PREVIEW_BYTES)} preview " \
            "ceiling (raise PREVIEW_MAX_BYTES to render larger files)"
    end

    # Write ONLY if the row still points at the content this run rendered; true when it did.
    #
    # EVERY write goes through here — the start and every terminal one, not just the successful
    # one — and that is the part most likely to be trimmed later: a stale `unsupported` or
    # `failed` is as wrong as a stale image. A v1 render that fails must not mark a row that has
    # already moved to v2 as failed — `Enqueue` treats `failed` as "retry me", so it would look
    # repaired while describing content nobody asked about, and the genuine v2 result would be
    # overwritten by an older verdict.
    #
    # Losing the write is the CORRECT outcome, not a dropped update: whoever repointed the row also
    # enqueued a job for the new content, so the newer render is already coming.
    def commit_if_current(preview, target)
      preview.reload
      return false if [ preview.version_id, preview.renderer_revision ] != target

      yield
      true
    rescue ActiveRecord::RecordNotFound
      false # the row was deleted mid-render; nothing to write and nothing wrong
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
