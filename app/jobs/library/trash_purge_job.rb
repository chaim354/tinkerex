module Library
  # Purge trash entries past the retention window. `delete` on a scanned backend does not unlink —
  # it MOVES the bytes to `.trash/<node_id>/<name>` (Share#delete renames; S3#delete copies then
  # deletes the original), so this job is what actually reclaims the space. Without it the library
  # grows forever and the "delete" the user performed never lands.
  #
  # TWO REAPERS, ONE JOB, because the age lives somewhere different on each and there is no shared
  # mechanism to factor out — only a shared RULE (see #purge_share! and #purge_s3!):
  #
  #   share: the ENTRY DIRECTORY's mtime is when it was trashed. Share#delete's mkdir_p stamps it
  #          and nothing touches it afterwards.
  #   s3:    there IS no entry directory — `.trash/<node_id>/` is a key prefix with no existence
  #          apart from its objects, and so no mtime of its own. The age comes from the OBJECTS'
  #          last_modified, and an entry is purged only when EVERY object under it is past the
  #          window.
  #
  # That is why no `trashed_at` column exists on either: the store already records it, and a column
  # would be a second copy to keep in sync (spec decision 3 — these libraries are current-state
  # only; the store is the truth).
  #
  # The node row is NEVER destroyed, only its bytes. The row is what makes a project say "file
  # missing" rather than an attachment silently vanishing, and it costs a few hundred bytes.
  class TrashPurgeJob < ApplicationJob
    # Matches ScanJob / RetentionJob / ChunkReaperJob: a periodic sweep is background work, not
    # something a user is waiting on.
    queue_as :background

    # Consistent with ScanJob. This job never looks a node up (see #perform — it purges by AGE,
    # not by row), so this is inert today; it is here so that stays a deliberate property rather
    # than an accident of the current implementation.
    discard_on ActiveRecord::RecordNotFound

    DEFAULT_TRASH_DAYS = 30

    # Same division as ScanJob's, for the same reason: `purge_all!` is a SCHEDULE (recurring.yml
    # fires it in chunk deployments too, where no-opping is the answer to a question nobody asked);
    # `#perform` is a COMMAND, and a caller who named a root deserves the operation, not a silent
    # no-op. So the backend gate lives on purge_all! and NOT here.
    #
    # `trash_days` is required for the reason ScanJob gives for `root`: purge_all! always passes it
    # (below, from the one ENV read), so a default here would only ever serve a hand-rolled call —
    # and would serve it a second, raw ENV read. LIBRARY_TRASH_DAYS is read in ONE place, and this
    # is not it.
    #
    # `root:` is optional for ScanJob's reason, in its words: a share's target is a path, which is
    # safe to serialize into the queue's database and useful to read back out of a failed job; an
    # s3 library's target is a bucket plus the credentials to reach it, which must never be written
    # there. Omitted means "this deployment's library", resolved from FileLayer.current.
    def perform(root: nil, trash_days:)
      # 0 (or negative) is the documented "keep forever" (spec §3.5), and this guard is the whole
      # test: `Time.current - 0.days` is NOW and `Time.current - (-1).days` is the FUTURE, so the
      # obvious implementation purges the ENTIRE trash on a config value that means the opposite —
      # a data-loss bug wearing a config knob. It runs FIRST, before ANY store work: on a "keep
      # forever" library this job must not even list.
      return if trash_days <= 0

      cutoff = Time.current - trash_days.days
      return purge_share!(Pathname.new(root), cutoff) if root

      # Same shape as ScanJob#observer_for and the same argument for it: an adapter this job has no
      # reaper for RAISES rather than being skipped. A gate that skips silently is what Phase 3
      # shipped; a dispatch that raises is a failed job naming the class.
      adapter = FileLayer.current
      case adapter
      when FileLayer::Share then purge_share!(adapter.root, cutoff)
      when FileLayer::S3    then purge_s3!(adapter, cutoff)
      else
        raise ArgumentError,
              "#{adapter.class} has no trash for this job to purge. Chunk-mode deletes are " \
              "tombstones, and their bytes are reclaimed by the refcount GC (Sync::Gc) and " \
              "Sync::ChunkReaper, not by this job."
      end
    end

    private

    def purge_share!(root, cutoff)
      trash = root.join(Library::Scanner::TRASH_PREFIX)
      # No trash yet (nothing has ever been deleted) is the normal state of a fresh library, not an
      # error. Dir.children raises ENOENT on a missing directory, so this guard is load-bearing.
      return unless trash.directory?

      purged = 0
      # Only ENTRY dirs are removed — never `trash` itself. That is load-bearing, not laziness:
      # Share#library_present? uses root EMPTINESS as its "is the NAS mounted?" signal, so purging
      # the last entry out of a library whose only content is trash would make the root read as
      # UNMOUNTED — turning undelete's terminal "your file is gone" (NotFound) into a retryable
      # "your NAS is down" (FetchError). Leaving the empty directory costs nothing and keeps that
      # answer honest.
      Dir.children(trash.to_s).each do |entry|
        dir = trash.join(entry)
        begin
          # `<` cutoff: OLDER than the window. Inverting this purges everything EXCEPT what should
          # go — verified by mutation, and it kills both halves of the age test.
          #
          # `dir.directory?` also skips a stray file (a .DS_Store, an operator's scratch note)
          # rather than letting it derail the sweep of the real entries beside it.
          next unless dir.directory? && dir.mtime < cutoff
          # By AGE, never by row: an entry whose node was hard-deleted, or belongs to another user,
          # is just an aged directory. Looking the node up would turn that into a crash — or, with
          # discard_on above, a silently skipped purge leaking the bytes forever.
          FileUtils.remove_entry(dir)
          purged += 1
        rescue SystemCallError => e
          # One unreadable entry must not abort the sweep, and must never be retried into a
          # failure: the next run picks it up. Same posture as the Scanner's per-entry rescues.
          Rails.logger.warn("Library::TrashPurgeJob: cannot purge #{entry.inspect}: " \
                            "#{e.class} (#{e.message})")
        end
      end
      purged
    end

    # THE S3 REAPER. Not a port of the share's — the share's mechanism is ABSENT here, not merely
    # different. `.trash/<node_id>/` is a key PREFIX, not a directory: it has no existence apart
    # from the objects under it and therefore no mtime of its own to age against. The age can only
    # come from the OBJECTS' `last_modified`, which the listing already carries (so this costs no
    # extra request).
    #
    # AN ENTRY IS PURGED ONLY IF **EVERY** OBJECT UNDER IT IS PAST THE WINDOW. An entry is one
    # user-visible file, and the operator configured a window in which their deletes are still
    # recoverable; purging on the strength of the oldest object would delete bytes inside that
    # window, with no version to restore (spec decision 3). When the objects disagree the entry
    # waits for the next run, which costs a few KB and a week.
    #
    # LIST TO COMPLETION FIRST, DELETE ONLY AFTER — the sharper cousin of Landmine 4, not a copy of
    # it. A partial listing there was a mass-deletion lookalike; here it is worse in kind: it can
    # show an entry's aged object while the page carrying its FRESH sibling never arrives, making
    # "every object is past the window" true of an entry for which it is false. So a failed page
    # aborts before anything is deleted, and no partial credit is taken. Note this deliberately
    # does NOT depend on keys arriving sorted — real S3 lists lexicographically, but this backend
    # points at whatever the user runs (SeaweedFS/MinIO/Ceph), and "group as they stream, an entry
    # is done when the node_id changes" would silently split entries on a store that doesn't.
    def purge_s3!(adapter, cutoff)
      prefix = "#{adapter.listing_prefix}#{Library::Scanner::TRASH_PREFIX}/"
      entries = Hash.new { |h, k| h[k] = [] }

      list_trash(adapter, prefix) do |obj|
        # The key relative to `.trash/` — its first segment is the node_id the entry is keyed by
        # (2b's layout, which is what makes two same-named deletes unable to collide).
        rest = obj.key.delete_prefix(prefix)
        node_id, sep, _name = rest.partition("/")
        # No separator = no entry: this is a key AT `.trash/` itself, which in practice means a
        # directory-marker object (`library/.trash/`) that the console or a sync tool created.
        # Landmine 6's phantom in its other costume — and the entry it would otherwise mint here
        # is one named "", whose "every object is aged" would be vacuously true.
        next if sep.empty? || node_id.empty?

        entries[node_id] << obj
      end

      purged = 0
      entries.each do |node_id, objects|
        # `<` cutoff: OLDER than the window. `all?` is the rule stated above — and note it is
        # vacuously true for an empty list, which is why an entry can only be created above by a
        # real object.
        next unless objects.all? { |o| o.last_modified < cutoff }

        begin
          # By AGE, never by row — an entry whose node was hard-deleted is just an aged prefix
          # (the share reaper's argument, verbatim, and the same discard_on makes the alternative
          # a silently skipped purge that leaks the bytes forever).
          objects.each { |o| adapter.client.delete_object(bucket: adapter.bucket, key: o.key) }
          purged += 1
        rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError => e
          # One entry that will not delete must not abort the sweep of the others, and must not be
          # retried into a failure: the next run picks it up. Same posture as the share reaper's
          # per-entry rescue and the Scanner's. A half-deleted entry is safe to leave — the next
          # run re-lists it, and the remaining objects are still aged.
          Rails.logger.warn("Library::TrashPurgeJob: cannot purge #{node_id.inspect}: " \
                            "#{e.class} (#{e.message})")
        end
      end
      purged
    end

    # Complete or nothing. FetchError (transient, "ask again") rather than Scanner::UnsafeScan: the
    # scan's refusal means "I will not reconcile this", which is a statement about the catalog and
    # has no meaning for a reaper. Nothing was purged and the weekly schedule is the retry.
    #
    # e.class is in the message for Library::S3Observer's reason: a stubbed or real SDK error's
    # `message` does not name the code, so the CLASS is the only place an operator learns WHICH
    # failure this was.
    def list_trash(adapter, prefix)
      token = nil
      loop do
        resp = adapter.client.list_objects_v2(bucket: adapter.bucket, prefix:,
                                              continuation_token: token)
        resp.contents.each { |obj| yield obj }
        break unless resp.is_truncated

        token = resp.next_continuation_token
        # Truncated with no token: the store says there is more and gives us no way to ask for it.
        # RAISE, do not break — a `break` here IS the partial listing this method exists to refuse,
        # wearing the costume of an ordinary loop exit. (Written as a break first; caught on the
        # reread.) Library::S3Observer refuses on the same signal for the same reason: real S3
        # cannot do this, but an S3-COMPATIBLE store is not bound by that, and this backend points
        # at whatever the user runs.
        if token.blank?
          raise FileLayer::FetchError,
                "the S3 trash listing reports more results but returned no continuation token — " \
                "the listing is incomplete, so nothing was purged."
        end
      end
    rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError, ArgumentError,
           EncodingError => e
      # ArgumentError/EncodingError is the non-UTF-8 key arriving as a CRASH rather than as data —
      # verified against aws-sdk-s3 in Task 7: one invalid byte anywhere in the response body and
      # `list_objects_v2` itself raises, before the parser runs. A trash key is one WE composed
      # from a node_id and a name, so an invalid byte can only get in via the name — which came
      # from the user's own bucket. It is reachable.
      raise FileLayer::FetchError,
            "the S3 trash listing failed partway through (#{e.class}: #{e.message}) — a partial " \
            "listing can hide an entry's freshest object and make it look purgeable, so nothing " \
            "was purged."
    end

    # THE one reader of LIBRARY_TRASH_DAYS, and it reads PER CALL rather than into a constant at
    # class load. 2a hit exactly that: MAX_DELETE_PCT frozen at class load could not be varied by
    # tests, and a knob the real entry point cannot reach is a knob only ENV-mutation can use.
    #
    # THE PHASE 3 TRAP'S QUIETER HALF, DISARMED (2026-07-17, Task 8). This gate was
    # `is_a?(FileLayer::Share)`, the same one ScanJob.scan_all! carried, and it answered false for
    # s3 the day FileLayer::S3 landed: purge_all! enqueued nothing, said nothing, and an s3 user's
    # deleted bytes were never reclaimed. Reproduced in that state before this line changed.
    #
    # It is the QUIETER of the two, which is why it is gated separately rather than folded into
    # ScanJob's: a library that is never indexed is at least visible as an empty library, whereas a
    # trash that is never purged looks exactly like a working one until the storage bill arrives.
    #
    # WHY `scannable?` GATES A TRASH PURGE, since the name is about scanning. It is one fact, not
    # two: a backend is scanned precisely because its bytes live in storage the USER also writes to
    # and we do not own — and that is the same reason its delete has to be a move to a `.trash`
    # region within that storage (there is nowhere else to put the bytes, and no version to keep
    # them as), which in turn is why something has to come along and reclaim them. Chunk mode
    # answers false to all of it: its delete is a tombstone, and its bytes are reclaimed by the
    # refcount GC. The residual risk — a future backend that is scannable but has no trash — is
    # covered where it can be caught rather than by a second capability nobody could pin: #perform
    # RAISES on an adapter it has no reaper for.
    def self.purge_all!
      adapter = FileLayer.current
      return unless adapter.capabilities.scannable?
      # NOT WHILE THE LIBRARY FOLDER IS UNCONFIRMED (K §3), the pause Library::ScanJob.scan_all!
      # takes: nothing has been chosen, so there is no library whose trash this would be.
      return if Tinkerex::LibraryRoot.pending?

      # Share names its root (a path is safe in the queue's database and useful in a failed-jobs
      # row; .to_s because ActiveJob cannot serialize a Pathname). S3 names nothing — its target is
      # a bucket plus credentials. Same split as ScanJob.enqueue_for, same reason.
      #
      # NOT fanned out per user, on either backend: `.trash` is ONE region per library and its
      # entries are keyed by node_id, so one job purges the whole thing. (S3 does not change this —
      # a bucket has one `<prefix>/.trash/` exactly as a root has one `.trash`. The reason it is
      # one job and ScanJob is N is the storage's shape, not the user count.)
      args = adapter.is_a?(FileLayer::Share) ? { root: adapter.root.to_s } : {}
      perform_later(trash_days: configured_trash_days, **args)
    end

    # RAISES on a typo rather than defaulting. Falling back to 30 on a value the operator clearly
    # meant as something else is how a "0 = keep forever" config quietly starts deleting files
    # after 30 days — the failure this job exists to not have. The message names the VARIABLE and
    # its value, because `Integer("thirty")`'s own error ("invalid value for Integer(): \"thirty\"")
    # is true, useless, and reaches an operator with no hint of where to go look.
    def self.configured_trash_days
      raw = ENV.fetch("LIBRARY_TRASH_DAYS", DEFAULT_TRASH_DAYS.to_s)
      Integer(raw)
    rescue ArgumentError, TypeError
      raise ArgumentError, "LIBRARY_TRASH_DAYS must be a whole number of days " \
                           "(#{DEFAULT_TRASH_DAYS} by default, 0 = never purge), got #{raw.inspect}"
    end
    private_class_method :configured_trash_days
  end
end
