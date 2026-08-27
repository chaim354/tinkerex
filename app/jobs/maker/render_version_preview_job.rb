module Maker
  # RENDERS ONE HISTORICAL VERSION, ON DEMAND. The job behind the greyed-or-not tiles in a project's
  # version list.
  #
  # IT NEVER TOUCHES `maker_previews`, AND THAT IS THE POINT OF THE WHOLE TASK. §14b collapsed
  # `Maker::Preview` to one row per (user, node, kind) because one-row-per-version leaked a row and a
  # blob on every save; `GeneratePreviewJob#commit_if_current` is what keeps the current row pointing
  # at the current content. This job writes to `maker_version_previews` and nothing else, so a slow
  # render of a 2019 version can never claim, repoint, or invalidate the row describing the file as
  # it is today. `version_preview_test.rb` mutation-checks exactly that.
  #
  # ON DEMAND MEANS ON DEMAND. The only sanctioned caller is the History view. Enqueuing this from
  # the save path, `Library::ScanJob` or `Maker::Git::ProjectCommit` would re-create §14b's leak with
  # a new table's name on it — the row and the blob per save are the same rows and blobs however
  # they are keyed.
  class RenderVersionPreviewJob < ApplicationJob
    queue_as :default

    Unsupported = Class.new(StandardError)

    # THIS CACHE RENDERS THUMBNAILS AND NOTHING ELSE. `Maker::Preview` has four kinds because the
    # Measure view needs a `geometry` payload from the CURRENT file; a version list needs a picture.
    # Written down as a constant rather than a bare string so the two `kind`-shaped call sites below
    # cannot drift, and so it is obvious what to change if history ever grows a second artifact.
    KIND = "thumbnail".freeze

    # THE ARGUMENT IS A PRIMARY-DATABASE ROW ID AND THIS JOB LIVES IN THE QUEUE DATABASE, so without
    # this `perform_later` is not covered by the caller's transaction: it commits to the queue DB on
    # its own connection, immediately, while the row is still uncommitted on primary. Solid Queue
    # runs IN THE PUMA PROCESS here (SOLID_QUEUE_IN_PUMA) polling sub-second, so the worker wins that
    # race, finds no row, and `discard_on` below swallows the job — no failure, no log, and a tile
    # that spins forever. Measured on `Maker::GeneratePreviewJob`, whose comment records the job id.
    self.enqueue_after_transaction_commit = true

    # The row can be swept by retention (or its project destroyed) between enqueue and run. Discard
    # cleanly rather than letting find's RecordNotFound read as a failure.
    discard_on ActiveRecord::RecordNotFound

    # A TRANSIENT BYTE-STORE FAILURE IS NOT "not kept", AND CONFLATING THEM IS THE ONE MISTAKE THIS
    # JOB CAN MAKE THAT LIES TO A USER ABOUT THEIR HISTORY. §14a: an unmounted share must never read
    # as "your file is permanently gone", which is why `FileLayer::Share#read` raises the RETRYABLE
    # `FetchError` when the library root looks unmounted and the TERMINAL `NotFound` when the library
    # is there and this one file is not. Only the second is `not_kept`; this retries the first and
    # leaves the row `pending`, so a creds blip or an unmounted NAS never paints a maker's whole
    # history grey.
    retry_on FileLayer::FetchError, wait: :polynomially_longer, attempts: 5

    def perform(version_preview_id:)
      # OUTSIDE the begin/rescue, so a missing row reaches `discard_on` while fetch and render
      # errors below still land on the row.
      row = Maker::VersionPreview.find(version_preview_id)

      begin
        renderer = Maker::Previews::Registry.for_filename(row.source_filename)
        ext = File.extname(row.source_filename.to_s).downcase.delete_prefix(".")
        raise Unsupported, "no preview renderer for .#{ext}" if renderer.nil?
        # `available?` AND NOT `available_for?`, WHICH IS CORRECT ONLY BECAUSE THIS CACHE RENDERS
        # ONE KIND. The split exists so a measurable .svg/.dxf/.lbrn2 is not marked unsupported on a
        # box without the rasterizer — and every implementation is `kind == "geometry" || available?`
        # (checked), so for KIND it reduces to exactly this. Give history a second artifact and this
        # line has to become `available_for?(renderer, KIND)`.
        raise Unsupported, "renderer toolchain unavailable for .#{ext}" unless renderer.available?

        bytes = read_bytes(row)
        # NIL IS THE HONEST, EXPECTED ANSWER — see `read_bytes`. It is a terminal state of its own
        # precisely so it is not reported as a failure.
        return mark_not_kept(row) if bytes.nil?

        raise Unsupported, oversized_message(bytes, ext) if bytes.bytesize > max_bytes

        result = render_with(renderer, bytes, ext:)
        attach!(row, result)
      rescue Unsupported => e
        # Deliberate terminal state, not an error: do NOT re-raise (retrying re-reads the same
        # bytes to reach the same verdict).
        row.update!(state: "unsupported", error: e.message)
      rescue FileLayer::FetchError => e
        # Transient. Stay NON-terminal and re-raise so `retry_on` schedules a backed-off retry.
        row.update!(error: "#{e.class}: #{e.message} (retrying)")
        raise
      rescue StandardError => e
        row.update!(state: "failed", error: "#{e.class}: #{e.message}")
      end
    end

    private

    # ONE CEILING FOR "what size of file is a thumbnail worth", NOT A SECOND COPY OF THE NUMBER.
    # `GeneratePreviewJob::MAX_PREVIEW_BYTES` already answers that question (operator-tunable via
    # PREVIEW_MAX_BYTES) and it is the same question here. A second literal is the drift §14d
    # records `FilesHelper::EXT_FAMILIES` being rewritten to end.
    #
    # JUDGED ON THE FETCHED BYTES, NOT ON `nodes.size`, and the difference is real: `nodes.size` is
    # the size of the file as it is NOW, which says nothing about the version being rendered. The
    # read itself is already bounded by `FileLayer::MAX_BYTES` on all three backends, so this bounds
    # the RENDER — three transient copies of the buffer in a worker that shares RSS and the GVL with
    # the web threads on self-host.
    def max_bytes = Maker::GeneratePreviewJob::MAX_PREVIEW_BYTES

    # THE BYTES FOR ONE PAST VERSION, OR nil IF THE STORE NO LONGER HAS THEM.
    #
    # nil is not a failure and not an edge case: it is the ORDINARY case on `share`, where the
    # maker's overwrite in Finder destroyed the previous bytes before this app ever saw them, and on
    # `s3` unless the user turned bucket versioning on. Only `chunk_remote` keeps every version
    # (§14a — share and s3 are current-state only, deliberately). `FileLayer::NotFound` is the port's
    # terminal "genuinely gone", so it is translated here rather than rescued as an error at the top;
    # `FetchError` is deliberately NOT caught, because "the share is unmounted" must reach the
    # retry above instead of being recorded as a permanent loss.
    def read_bytes(row)
      FileLayer.current.read(row.user, node_id: row.node_id, content_token: row.content_token)
    rescue FileLayer::NotFound
      nil
    end

    def mark_not_kept(row)
      # `error` is CLEARED, not filled in with an explanation. This is not an error condition, and a
      # populated `error` column is what an operator greps for when something is wrong.
      row.update!(state: "not_kept", error: nil)
    end

    def attach!(row, result)
      row.asset.attach(io: StringIO.new(result[:bytes]),
                       filename: "version-#{row.id}#{asset_ext(result[:content_type])}",
                       content_type: result[:content_type])
      row.update!(state: "ready", width: result[:width], height: result[:height],
                  renderer_revision: Maker::Previews::Enqueue.revision_for_name(row.source_filename,
                                                                                KIND),
                  error: nil)
    end

    # Renderers share `render(bytes, size:)`; some also accept `ext:` (to pick a loader) and `kind:`.
    # Pass each only when the signature declares it, exactly as `GeneratePreviewJob` does, so the
    # simpler renderers stay unchanged.
    def render_with(renderer, bytes, ext:)
      accepted = renderer.method(:render).parameters.select { |t, _| %i[key keyreq].include?(t) }.map(&:last)
      opts = { size: 512 }
      opts[:ext]  = ext  if accepted.include?(:ext)
      opts[:kind] = KIND if accepted.include?(:kind)
      renderer.render(bytes, **opts)
    end

    def oversized_message(bytes, ext)
      human = ->(n) { ActiveSupport::NumberHelper.number_to_human_size(n) }
      "#{ext.presence || 'file'} is #{human.call(bytes.bytesize)}, over the " \
        "#{human.call(max_bytes)} preview ceiling (raise PREVIEW_MAX_BYTES to render larger files)"
    end

    def asset_ext(content_type)
      case content_type
      when "image/svg+xml" then ".svg"
      when "image/png"     then ".png"
      when "image/jpeg"    then ".jpg"
      else ".bin"
      end
    end
  end
end
