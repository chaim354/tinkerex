module Maker
  module Previews
    # THE ONE idempotent entry point the "bytes landed" seams call (web upload, API commit, scan).
    # Finds-or-creates the (node, kind: thumbnail) Preview and enqueues GeneratePreviewJob when
    # `needs_job?` says the row needs one: it is new, its content or its renderer has MOVED, it
    # previously `failed`, or it claims a job that has STALLED. Returns the Preview, or
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
      # Those two statuses (`Maker::Preview::IN_FLIGHT`) are ASSERTIONS about work that exists
      # elsewhere, and nothing verified them. When the assertion was false the row became
      # unrecoverable: every branch of the guard in `call` returned early, so a lost job wedged its
      # row while the grid spun until its poll gave up. `failed` re-enqueues, `ready` is done and
      # `unsupported` is terminal by design — these two were the only statuses with no way back.
      # Three rows were wedged this way on the live share library, the oldest for over a week (the
      # record, CLAUDE.md §11).
      #
      # THE HEAL IS REACHED ONLY THROUGH `needs_job?`, AND UNTIL 2026-10-19 ALMOST NOTHING A USER
      # OPENS REACHED IT. This comment said the 15-minute scan, the Files page's backfill, `#show`
      # and the addon door all got here; none did. Each door asked "is this row CURRENT?" first
      # (`current_preview`, status-blind on purpose) and never called `call` for a row that was,
      # and the scan reaches `call` only for a file it creates, revives or sees change — an
      # unchanged file is skipped before anything is enqueued. The API's preview POST was the one
      # door that healed a stalled row. Every door that already holds a row now asks `needs_job?`
      # itself: `ThumbnailMap`'s backfill (every Files, Models and Projects render),
      # `FilesController#current_thumbnail` (the file page and the inspector), `#geometry`'s poll
      # and `MissingBackfill`; `Public::FilesController#enqueue_geometry` (a visitor's render) asks
      # through `call`. The scan still does not, and does not need to.
      #
      # A WINDOW, NOT A BARE "in flight → re-enqueue", because `ThumbnailMap`'s backfill asks this of
      # every row on every Files page render: without one, every spinner on screen would enqueue a
      # duplicate job on every load. 15 minutes is far beyond any render (the deployed box runs one
      # in ~70-90 ms) plus any realistic queue wait, so a wedged row heals on the first render that
      # shows it after the window, or the next `rake previews:backfill_missing`.
      #
      # A DUPLICATE ENQUEUE IS SAFE, WHICH IS WHY A WINDOW CAN BE A HEURISTIC HERE: the job is
      # idempotent and `commit_if_current` compares both staleness axes before writing anything.
      # Erring toward one extra render is the right direction when the alternative is a spinner
      # nothing in the system will ever resolve.
      STALLED_AFTER = 15.minutes

      # BOTH POLICY KWARGS DEFAULT SO EVERY EAGER CALLER IS BYTE-IDENTICAL, and there are ten callers:
      # three in `FilesController` (`#current_thumbnail`, `#geometry`, `#enqueue_preview`),
      # `Projects::UploadsController`, `Library::Reconciler`, `Addons::LibraryOutput`, `ThumbnailMap`
      # and `MissingBackfill` pass neither; `Public::FilesController#enqueue_geometry` passes
      # `retry_failed: false` (a read door holding no row); `V1::Maker::PreviewsController#create`
      # passes `skip_unrenderable: false`.
      #
      # `skip_unrenderable:` is the ONE branch the comment above calls a deliberately different
      # policy from `V1::Maker::PreviewsController#create`: an API client polls, so it needs a row
      # to poll even for a name no renderer handles. Everything BELOW this line is shared, which is
      # the point — the four staleness axes had drifted into a second, two-axis copy in that
      # controller.
      #
      # `retry_failed:` is the read doors' policy, `needs_job?`'s own parameter passed through: an
      # eager seam retries a `failed` render (the bytes just landed, so a retry can succeed), a door
      # a user opens again and again never does (files-preview.md: the S4-5 asymmetry).
      #
      # WITH A NIL RENDERER THE ROW IS STILL COHERENT: `revision_for(nil, kind)` answers
      # BASE_REVISION (nil does not respond to `payload_revision`), which is exactly the column
      # default, so nothing is stamped that a later reader could judge stale. The job is still
      # enqueued and writes the terminal `unsupported` itself — the only place that can tell "no
      # renderer for this type" from "toolchain missing on this box".
      def call(user:, node_id:, name:, version_id:, kind: "thumbnail", skip_unrenderable: true,
               retry_failed: true)
        renderer = Maker::Previews::Registry.for_filename(name)
        return nil if renderer.nil? && skip_unrenderable

        revision = revision_for(renderer, kind)
        preview  = user.maker_previews.find_or_initialize_by(node_id:, kind:)
        return preview unless needs_job?(preview, version_id:, revision:, retry_failed:)

        content_moved = preview.version_id != version_id
        stalled       = stalled?(preview)
        preview.version_id = version_id
        preview.renderer_revision = revision
        # BLANKED ONLY WHEN THE CONTENT MOVED — the two staleness axes deserve different answers.
        #
        # `pending` exists so a user never sees an artifact of the PREVIOUS CONTENT labelled as the
        # current file; that is a lie and the spinner is the honest replacement. A RENDERER bump is
        # not that case: the stored artifact still depicts exactly this file, it was merely built by
        # older code. Blanking it replaces a correct picture with a spinner for as long as the job
        # takes. Since stage 4, S4-3 the detail page polls a `pending` row and reloads when it lands,
        # so the spinner is no longer permanent — but it is still a spinner over a picture that was
        # correct, for the whole render, on every renderer bump. Shipped that way briefly (before the
        # poll existed) and it read as "generating preview is broken", which is fair.
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

      # DOES THIS ROW NEED A JOB? THE ONE TRANSITION TABLE — `call` answers by it, and so does every
      # door that already holds a row (`ThumbnailMap`'s backfill, `MissingBackfill`,
      # `FilesController#current_thumbnail` and `#geometry`), instead of the coordinates-only copy
      # each used to keep and the stalled arm each lost with it:
      #
      #   no row, or one never saved                       -> true  (there is nothing to show)
      #   CONTENT or RENDERER moved since it was built     -> true  (whatever its status says)
      #   `failed` at current coordinates                  -> `retry_failed`
      #   in flight (`IN_FLIGHT`) for over STALLED_AFTER   -> true  (its job is not coming)
      #   anything else                                    -> false
      #
      # THE TWO COORDINATES ARE INDEPENDENT REASONS A STORED ARTIFACT IS OUT OF DATE. `version_id`
      # asks "was this made from the file's CURRENT CONTENT?", `renderer_revision` "was it made by
      # the CURRENT CODE?". Only the first was checked until a thinning fix shipped for the .lbrn2
      # Measure view and every already-measured file kept serving the old algorithm's output,
      # because its content had not changed and nothing else was being compared.
      #
      # `retry_failed:` IS REQUIRED HERE, NOT DEFAULTED, because the two answers are both right for
      # someone and both silent when wrong: an eager seam must retry (`call`'s default), and a door a
      # user opens again and again must not, or a broken render is re-queued on every view. A door
      # that forgets to choose raises instead of picking one by accident.
      #
      # NOT `current_preview?` WITH A STATUS FOLDED IN: that predicate answers WHICH ROW IS CURRENT
      # and stays status-blind (the comment above it says why, and §14h forbids the fold). This one
      # answers what a caller holding a row must DO about it, which is a different question that
      # happens to start with the same two coordinates.
      def needs_job?(preview, version_id:, revision:, retry_failed:)
        return true if preview.nil? || preview.new_record?
        return true if preview.version_id != version_id || preview.renderer_revision != revision
        return retry_failed if preview.status == "failed"

        stalled?(preview)
      end

      # A saved row that has claimed a job for longer than STALLED_AFTER. `persisted?` first: an
      # unsaved row has no `updated_at` to compare.
      def stalled?(preview)
        preview.persisted? && Maker::Preview::IN_FLIGHT.include?(preview.status) &&
          preview.updated_at < STALLED_AFTER.ago
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

      # WHICH STORED ROW COUNTS AS CURRENT FOR A FILE — the read-path counterpart of `call`'s own
      # staleness test, in the two shapes its callers need: a QUERY (`current_preview`, for a
      # caller holding one node) and a PREDICATE (`current_preview?`, for a caller that has
      # already loaded a page of rows in one query and must filter them in Ruby).
      #
      # BOTH AXES, ONE DEFINITION. `version_id` asks "was this artifact made from the file's
      # CURRENT CONTENT?" and `renderer_revision` asks "was it made by the CURRENT CODE?" — the
      # same two independent questions `call` compares above, and the same pair every reader has
      # to get right. They were spelled out three times: twice in `FilesController` (330 lines
      # apart, byte-identical but for the `kind` string) and once in `ThumbnailMap`, which is this
      # repo's recorded failure shape — §14h's "172 of 174 LightBurn thumbnails" bug WAS one of
      # these copies missing the revision half, and the fix landed in one door and not the others.
      #
      # `kind` IS NAMED ONCE. In `FilesController` it was written twice per site — once to pick the
      # revision, once in the `find_by` — with nothing coupling them, so mis-spelling either half
      # made the lookup silently never match (an endless re-enqueue) or match on the wrong kind's
      # revision. A single parameter cannot be half wrong.
      #
      # ONE OF THOSE TWO ARMS WAS COMPLETELY SILENT, AND IT IS SILENT ONLY BY COINCIDENCE — probed
      # at review, on the old two-spelling code. Getting the FIND_BY half wrong reddened 5 tests and
      # 1 error. Getting the REVISION half wrong — `revision_for_name(node.name, "thumbnail")` sitting
      # beside `kind: "geometry"` — reddened NOTHING: 2444 runs, 0 failures. It is silent because
      # `Lbrn2.payload_revision("thumbnail")` and `payload_revision("geometry")` both happen to be 4
      # today. But the entire REASON revisions are per-kind is that those two numbers are MEANT to
      # diverge — §14h: "bumping geometry must not rebuild ~1400 thumbnails as a side effect of an
      # unrelated fix" — so that defect would go live the first time somebody does the thing the
      # mechanism exists for, and the suite would still be green. That is a better argument for
      # naming `kind` once than the one this comment originally made, and it was not available
      # without running the mutation.
      #
      # DO NOT FOLD `status` INTO EITHER OF THESE. It is the obvious next thought — "current" sounds
      # like it should mean servable — and it is wrong in both directions at once: `#current_thumbnail`
      # deliberately serves a `ready` artifact straight through a renderer rebuild (the picture is
      # still of this file), while `#geometry` deliberately never reads `status` here at all and
      # answers `pending` on any miss (an older build's payload is DATA that is wrong, not merely
      # old). §14h states the rule outright — "Same mechanism, opposite right answers; do not unify
      # them." What is shared is only WHICH ROW IS CURRENT; what each door does with the answer is
      # each door's own business and must stay there.
      def current_preview(user:, node_id:, name:, version_id:, kind:)
        return nil if name.blank? || version_id.blank?

        user.maker_previews.find_by(node_id:, kind:, version_id:,
                                    renderer_revision: revision_for_name(name, kind))
      end

      # The same rule against a row already in memory. `kind` comes off the row itself, which is
      # what keeps the two members from being able to disagree about it.
      #
      # BOTH BLANK GUARDS ARE LOAD-BEARING AND NEITHER IS DECORATION:
      #
      # `version_id.blank?` — `maker_previews.version_id` is NULLABLE and `Enqueue.call` really
      # writes a nil one (`V1::Maker::PreviewsController#create` permits the parameter, and
      # `refuse_stale_version!` returns false on a blank one and falls through). The port answers
      # `content_token: nil` for a node with no content, which the page renders as "No content
      # yet." Without this line `nil == nil` is true and that row is served as the file's current
      # thumbnail — a coincidence of representation dressed up as an answer about content.
      #
      # `name.blank?` — `revision_for_name(nil, kind)` walks Registry -> nil -> BASE_REVISION,
      # which is exactly the column's own default (`renderer_revision default: 1, null: false`),
      # so a row at revision 1 would be judged CURRENT for a file whose name is unknown. It is not
      # reachable from either of today's callers (`ThumbnailMap` scopes its query to the nodes the
      # port answered for; `Node` validates `name` for presence), WHICH IS PRECISELY WHY it can be
      # deleted without a test going red. Leave it.
      def current_preview?(preview, name:, version_id:)
        return false if name.blank? || version_id.blank?

        preview.version_id == version_id &&
          preview.renderer_revision == revision_for_name(name, preview.kind)
      end
    end
  end
end
