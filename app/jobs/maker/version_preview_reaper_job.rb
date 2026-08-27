module Maker
  # Periodic eviction for the HISTORICAL RENDER CACHE — `Maker::VersionPreview` rows and the Active
  # Storage blobs hanging off them. Scheduled from config/recurring.yml.
  #
  # DESTROYING A ROW HERE LOSES NOTHING, AND THAT HAS TO BE THE FIRST SENTENCE, because a reader
  # meeting "destroy" beside "preview" will reasonably read this as §14b's leak made in the opposite
  # direction — the sweep that throws away a maker's history. It is not, and the difference is
  # structural rather than a promise: the COMMIT is in the project's repository, the version still
  # names its `content_token`, and `Projects::HistoryController#mint_missing` — the one sanctioned
  # minting site — re-creates the row and re-enqueues `Maker::RenderVersionPreviewJob` the next time
  # anyone opens that file's History. A reaped row costs one re-render.
  #
  # THAT IS EXACTLY WHAT `Maker::AttachmentReaper` CANNOT SAY, which is why the two windows below
  # are not its window. Both existing reapers share `Maker::DeadNodes::GRACE` (30 days) and that
  # number is a SAFETY FLOOR: a tombstone is one undo away from returning with the same node_id, and
  # reaping inside the window destroys the user's own filing permanently. Nothing here is
  # unrecoverable, so 30 days gives this sweep no floor to inherit — and copying it anyway would be
  # copying a number whose entire justification is absent, the mistake this repo keeps naming about
  # `scannable`/`port_writable` agreeing on three backends by coincidence.
  #
  # WHAT THE WINDOW ACTUALLY TRADES is a cache hit against bytes on a Kamal volume (tinkerex#160 —
  # `Maker::VersionPreview`'s header records that this cache makes that volume grow with BROWSING
  # rather than with saves). Both ends are soft, so the choice comes from the direction of the
  # error: too long costs bytes a later sweep still reclaims, while too short costs a re-render the
  # maker watches — and on `chunk_remote`, the base deployment (§7), that re-render is a WAN fetch
  # of the version's bytes before any pixels are drawn. Err long.
  #
  # THE TWO WINDOWS SPLIT ON TERMINAL vs NON-TERMINAL, which is the line `Maker::VersionPreview`'s
  # own STATES comment already draws ("pending — the only non-terminal state"). A terminal row is a
  # finished answer and ages out as a cache entry. A `pending` row is an unfinished question, and
  # `mint_missing` enqueues only `if row.previously_new_record?` — so a row whose render never
  # resolved is NEVER re-enqueued by any number of page views, and destroying it is the only thing
  # that restores that tile. See PENDING_RETENTION.
  #
  # NO SERVICE MODULE BESIDE IT, unlike `Maker::Previews::DeadNodeReaper` and
  # `Maker::AttachmentReaper`. Those split because their real work is a per-USER `reap!(user)` — a
  # `Maker::DeadNodes.index` lookup scoped to one user's nodes — with a `reap_all!` loop over it and
  # a second caller in `lib/tasks/previews.rake`. This table is not user-scoped (tenancy comes
  # through `project_id`, see the migration) and the retention key is a column on the row itself, so
  # there is no per-user half to extract and no second caller: a service here would be a file whose
  # only content is what this job already is.
  #
  # Backend-neutral, like both siblings: a cached render is a cached render on chunk_remote, share
  # and s3 alike, so there is no capability to gate on and no `command:` entry needed.
  class VersionPreviewReaperJob < ApplicationJob
    queue_as :background

    # A TERMINAL ROW'S CACHE LIFETIME, measured from `COALESCE(last_viewed_at, created_at)` —
    # `Maker::VersionPreview.stale_before` owns that fallback and is the only place it is written.
    #
    # 90 DAYS, AND NOT BECAUSE IT IS THREE TIMES THIRTY. It is one working season: long enough that
    # a maker coming back to a project across the whole of a build never watches a tile re-render,
    # short enough that a file browsed once and abandoned does not hold a blob for a year. The
    # asymmetry above (bytes vs a watched re-render, WAN-fetched on the base deployment) is what
    # puts it on this side of the reapers' 30 rather than below it.
    #
    # NOTHING WRITES `last_viewed_at` TODAY — checked, not assumed: `mint_missing` is the only site
    # that touches these rows and it sets no view timestamp, so every live row currently ages from
    # `created_at`. That makes the fallback the ONLY path this window runs through, which is why the
    # nil case in the tests is the mainline rather than an edge case, and why the column stops being
    # decoration the moment a view-side touch is added rather than needing this job changed.
    RETENTION = 90.days

    # A `pending` ROW'S LIFETIME, AND IT IS A REPAIR RATHER THAN A RECLAIM. A pending row holds no
    # attachment, so the volume argument that sets RETENTION says nothing about it. What it holds is
    # a tile that spins forever: `mint_missing` gates its enqueue on `previously_new_record?`, so
    # reopening History finds the stuck row and starts no new job. Destroying it is the whole repair
    # — the next open mints a fresh row and a fresh render.
    #
    # ONE DAY, and the lower bound is what fixes it rather than taste. The longest LEGITIMATE
    # pending lifetime is `Maker::RenderVersionPreviewJob`'s `retry_on FileLayer::FetchError,
    # wait: :polynomially_longer, attempts: 5` — minutes, not hours. A day clears that by three
    # orders of magnitude, the same margin §15 demands of a guard whose two events would otherwise
    # land in the same second. Nothing pulls the number UP: reaping frees no bytes, and racing a
    # genuinely in-flight job is safe BY CONSTRUCTION rather than by luck — that job carries
    # `discard_on ActiveRecord::RecordNotFound` and its comment names this sweep as the reason.
    #
    # THE ONE COST, stated rather than left to be found: on a deeply backed-up queue a legitimately
    # queued render can sit past a day, get reaped, and be re-minted on the next History open. That
    # costs a discarded job and a second enqueue, it needs a human opening the page to happen at
    # all, and the tile they were looking at was pending either way.
    PENDING_RETENTION = 1.day

    def perform(retention: RETENTION, pending_retention: PENDING_RETENTION, dry_run: false)
      # THE TWO SCOPES PARTITION THE TABLE EXACTLY — `state` is NOT NULL with a default, so every
      # row is in one arm or the other and none can fall through both windows. A third state added
      # to STATES lands in the terminal arm automatically, which is the safe direction: it ages out
      # on the long window rather than being immortal.
      finished = Maker::VersionPreview.where.not(state: "pending").stale_before(retention.ago)
      stuck    = Maker::VersionPreview.where(state: "pending").stale_before(pending_retention.ago)

      reaped = reap(finished, dry_run:) + reap(stuck, dry_run:)
      Rails.logger.info("VersionPreviewReaperJob #{dry_run ? '[dry-run] would reap' : 'reaped'} " \
                        "#{reaped} cached historical render(s)")
      reaped
    end

    private

    def reap(scope, dry_run:)
      return scope.count if dry_run

      reaped = 0
      # `with_attached_asset` because the pending arm is mostly rows with NO attachment, and without
      # the preload `attached?` is one query per row to learn that. The loop unit is the ROW, not a
      # user, because there is no user fan-out here to isolate on.
      scope.with_attached_asset.find_each do |row|
        # PURGED EXPLICITLY, NOT LEFT TO `dependent: :purge_later`. Deleting the row without its
        # blob trades a database leak for a stored-file one on the very volume this sweep exists to
        # bound — `Maker::Previews::DeadNodeReaper` makes the same call for the same reason, and
        # doing it synchronously means the bytes are gone when this job returns rather than when
        # some other queue drains.
        row.asset.purge if row.asset.attached?
        row.destroy!
        reaped += 1
      rescue StandardError => e
        # ONE ROW'S FAILURE MUST NOT STALL THE SWEEP — both siblings' rule at their own loop unit
        # (theirs is the user). A purge against a briefly unreachable storage service is ordinary,
        # and a raise here would leave every row after it in this batch unswept with nothing
        # anywhere saying why. The row is retried on the next run.
        Rails.logger.error("VersionPreviewReaperJob: row #{row.id} failed: #{e.class}: #{e.message}")
      end
      reaped
    end
  end
end
