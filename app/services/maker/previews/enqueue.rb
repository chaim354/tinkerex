module Maker
  module Previews
    # THE ONE idempotent entry point the "bytes landed" seams call (web upload, API commit, scan).
    # Finds-or-creates the (node, kind: thumbnail) Preview and enqueues GeneratePreviewJob when it
    # is new, when the content has MOVED, or when it previously `failed`. Returns the Preview, or
    # nil when nothing to do (no renderer for this name -> don't litter the table with rows that
    # will only ever be `unsupported`; that judgement is cheap and local here, and keeps the grid's
    # preview map clean).
    #
    # ONE ROW PER (node, kind), REPOINTED — not one row per version. The old key included
    # `version_id`, so every save minted a row and stranded its predecessor: nothing reads a
    # superseded preview (every surface resolves by the node's CURRENT content_token) and nothing
    # deleted one either. 160 of 1334 rows on the deployed share library were orphans that way,
    # growing ~17.6/day with editing. Repointing removes the leak at its source instead of adding
    # a reaper to chase it, and ActiveStorage purges the replaced blob by itself.
    #
    # `status = "pending"` ON A CONTENT REPOINT is deliberate and is what keeps the page honest: the
    # row still holds the PREVIOUS render until the job finishes, and `_thumb.html.erb` shows an
    # image only when `ready`, so the user sees a spinner rather than the old picture labelled as
    # the new content. Same thing they saw before, when the superseded row simply was not found.
    #
    # A RENDERER REPOINT DELIBERATELY DOES NOT — see the branch in `call`. The artifact still
    # depicts this exact file; only the code that built it moved on.
    #
    # THE NON-RENDERABLE BRANCH IS THE ONLY POLICY V1::Maker::PreviewsController#create DOES NOT
    # SHARE, and it is now a `skip_unrenderable:` kwarg rather than a second implementation. That
    # controller DOES create a row for a non-renderable name, so an API client can poll and observe
    # the terminal `unsupported` state; here the trigger is automatic/eager, so skipping is right
    # and stays the default. Everything else — all four staleness axes — is shared. One branch
    # differing is a parameter; four axes differing was a second, stale writer of the same
    # two-coordinate invariant.
    #
    # NOT a controller concern and NOT sync-coupled: it reads a filename + content id and enqueues a
    # job. Callable from a controller, a service, or a scan loop (§10 tripwire stays intact).
    module Enqueue
      module_function

      # What a renderer that declares no revision of its own is taken to be. Every artifact that
      # existed before `renderer_revision` was introduced is stamped 1 by the migration, so a
      # renderer only invalidates its cache by bumping PAST this — silence changes nothing.
      BASE_REVISION = 1

      # HOW LONG A `pending`/`processing` ROW IS BELIEVED WHEN IT CLAIMS A JOB IS COMING.
      #
      # Those two statuses are ASSERTIONS about work that exists elsewhere, and nothing verified
      # them. When the assertion was false the row became unrecoverable: every branch of the guard
      # in `call` returned early, so the 15-minute scan, `backfill_thumbnails`, `#show` and the
      # addon door all no-op'd on it forever while the grid spun until its poll gave up. `failed`
      # re-enqueues, `ready` is done and `unsupported` is terminal by design — these two were the
      # only statuses with no way back. Three rows were wedged this way on the live share library,
      # the oldest for over a week (docs/STATUS.md).
      #
      # A WINDOW, NOT A BARE "pending → re-enqueue", because `backfill_thumbnails` calls this once
      # per row on every Files page render: without one, every spinner on screen would enqueue a
      # duplicate job on every load. 15 minutes is far beyond any render (the deployed box runs one
      # in ~70-90 ms) plus any realistic queue wait, and it matches `library_scan`'s interval, so a
      # wedged row self-heals on the next scan at the latest.
      #
      # A DUPLICATE ENQUEUE IS SAFE, WHICH IS WHY A WINDOW CAN BE A HEURISTIC HERE: the job is
      # idempotent and `commit_if_current` compares both staleness axes before writing anything.
      # Erring toward one extra render is the right direction when the alternative is a spinner
      # nothing in the system will ever resolve.
      STALLED_AFTER = 15.minutes

      # `skip_unrenderable:` DEFAULTS TRUE SO EVERY EAGER CALLER IS BYTE-IDENTICAL — nine of them
      # (three in `FilesController`, `V1::CommitsController`, `Projects::UploadsController`,
      # `Library::Reconciler`, `Addons::LibraryOutput`, `ThumbnailMap`, `MissingBackfill`) and none
      # passes it. It is the ONE branch the comment above calls a deliberately different policy from
      # `V1::Maker::PreviewsController#create`, which is now the one caller that passes `false`: an
      # API client polls, so it needs a row to poll even for a name no renderer handles. Everything
      # BELOW this line is shared, which is the point — the four staleness axes had drifted into a
      # second, two-axis copy in that controller.
      #
      # WITH A NIL RENDERER THE ROW IS STILL COHERENT: `revision_for(nil, kind)` answers
      # BASE_REVISION (nil does not respond to `payload_revision`), which is exactly the column
      # default, so nothing is stamped that a later reader could judge stale. The job is still
      # enqueued and writes the terminal `unsupported` itself — the only place that can tell "no
      # renderer for this type" from "toolchain missing on this box".
      def call(user:, node_id:, name:, version_id:, kind: "thumbnail", skip_unrenderable: true)
        renderer = Maker::Previews::Registry.for_filename(name)
        return nil if renderer.nil? && skip_unrenderable

        revision = revision_for(renderer, kind)
        preview  = user.maker_previews.find_or_initialize_by(node_id:, kind:)
        # TWO INDEPENDENT REASONS A STORED ARTIFACT IS OUT OF DATE, and they are not the same
        # question. `version_id` asks "was this made from the file's CURRENT CONTENT?";
        # `renderer_revision` asks "was it made by the CURRENT CODE?". Only the first was checked
        # until a thinning fix shipped for the .lbrn2 Measure view and every already-measured file
        # kept serving output from the old algorithm, because its content had not changed and
        # nothing else was being compared.
        content_moved = preview.version_id != version_id
        rebuilt       = preview.renderer_revision != revision
        # THE FOURTH REASON, and the only one that is not about the artifact being out of date: the
        # row says work is in flight and it no longer is. See STALLED_AFTER.
        stalled = preview.persisted? && %w[pending processing].include?(preview.status) &&
                  preview.updated_at < STALLED_AFTER.ago
        return preview unless preview.new_record? || content_moved || rebuilt ||
                              preview.status == "failed" || stalled

        preview.version_id = version_id
        preview.renderer_revision = revision
        # BLANKED ONLY WHEN THE CONTENT MOVED — the two staleness axes deserve different answers.
        #
        # `pending` exists so a user never sees an artifact of the PREVIOUS CONTENT labelled as the
        # current file; that is a lie and the spinner is the honest replacement. A RENDERER bump is
        # not that case: the stored artifact still depicts exactly this file, it was merely built by
        # older code. Blanking it replaces a correct picture with a spinner for as long as the job
        # takes — and the detail page does not poll, so it stays a spinner until someone reloads.
        # Shipped that way briefly and it read as "generating preview is broken", which is fair.
        #
        # Leaving `ready` alone means the old artifact stays visible until the job swaps it. The
        # job is safe either way: `commit_if_current` compares BOTH axes against what it captured,
        # and both are written here before it is enqueued, so a run that started under an older
        # revision still cannot stamp its output onto this row.
        preview.status = "pending" if preview.new_record? || content_moved || preview.status == "failed"
        # RESTAMP A HEALED ROW, OR THE HEAL REPEATS ON EVERY CALLER FOREVER. Re-enqueueing a
        # stalled row changes no other attribute, and `save!` on an unchanged record is a NO-OP
        # that leaves `updated_at` where it was — so the row would still read as stalled to the
        # next scan, the next page load, and every one after that, each adding another duplicate
        # job. Assigning the column explicitly is what makes the write happen AND fixes its value
        # (ActiveRecord only auto-stamps `updated_at` when it has not been changed by hand).
        preview.updated_at = Time.current if stalled
        preview.save!
        Maker::GeneratePreviewJob.perform_later(preview.id, filename: name)
        preview
      end

      # The revision a renderer claims for one kind, or BASE_REVISION when it claims none.
      #
      # ASKED OF THE RENDERER RATHER THAN HELD IN A TABLE HERE, so the number lives beside the code
      # whose output it describes — someone changing a payload sees the constant they need to bump
      # in the file they are already editing, which is the entire point of having it.
      #
      # PER KIND, NOT PER RENDERER: Lbrn2 produces both a thumbnail and a geometry payload, and
      # bumping one must not re-render the other. A geometry change that also rebuilt every
      # LightBurn thumbnail would be a silent full-library rebuild attached to an unrelated fix.
      def revision_for(renderer, kind)
        return BASE_REVISION unless renderer.respond_to?(:payload_revision)

        renderer.payload_revision(kind) || BASE_REVISION
      end

      # The same answer, for a caller that holds a filename rather than a renderer — the shape a
      # controller has when deciding whether a row it already found is worth serving.
      def revision_for_name(name, kind)
        renderer = Maker::Previews::Registry.for_filename(name)
        renderer.nil? ? BASE_REVISION : revision_for(renderer, kind)
      end
    end
  end
end
