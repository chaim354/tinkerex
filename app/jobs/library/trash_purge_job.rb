module Library
  # Purge trash entries past the retention window. FileLayer::Share#delete renames a file to
  # .trash/<node_id>/<name> rather than unlinking it, so this is what actually reclaims the space —
  # without it a share library grows forever and the "delete" the user performed never lands.
  #
  # The ENTRY DIRECTORY's mtime is when it was trashed: Share#delete's mkdir_p stamps it, and
  # nothing touches it afterwards. That is why no `trashed_at` column exists — the filesystem
  # already records it, and a column would be a second copy to keep in sync (spec decision 3: share
  # libraries are current-state only; the disk is the truth).
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
    # BOTH arguments are required, and `trash_days` is required for exactly the reason ScanJob
    # gives for `root`: purge_all! always passes it (below, from the one ENV read), so a default
    # here would only ever serve a hand-rolled call — and would serve it a second, raw ENV read.
    # LIBRARY_TRASH_DAYS is read in ONE place, and this is not it.
    def perform(root:, trash_days:)
      # 0 (or negative) is the documented "keep forever" (spec §3.5), and this guard is the whole
      # test: `Time.current - 0.days` is NOW and `Time.current - (-1).days` is the FUTURE, so the
      # obvious implementation purges the ENTIRE trash on a config value that means the opposite —
      # a data-loss bug wearing a config knob. It runs FIRST, before any filesystem work.
      return if trash_days <= 0

      trash = Pathname.new(root).join(Library::Scanner::TRASH_PREFIX)
      # No trash yet (nothing has ever been deleted) is the normal state of a fresh library, not an
      # error. Dir.children raises ENOENT on a missing directory, so this guard is load-bearing.
      return unless trash.directory?

      cutoff = Time.current - trash_days.days
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

    # THE one reader of LIBRARY_TRASH_DAYS, and it reads PER CALL rather than into a constant at
    # class load. 2a hit exactly that: MAX_DELETE_PCT frozen at class load could not be varied by
    # tests, and a knob the real entry point cannot reach is a knob only ENV-mutation can use.
    #
    # PHASE 3 TRAP — ARMED AS OF TASK 3 (2026-07-17), the same one ScanJob.scan_all! carries (read
    # the comment there). No longer a prediction: FileLayer::S3 exists, so this is_a? answers false
    # and purge_all! SILENTLY NO-OPS — reproduced, returns nil and enqueues nothing under
    # LIBRARY_BACKEND=s3. The bytes an s3 user deletes are never reclaimed and they are never told.
    #
    # Note this gate is the QUIETER of the two, which is why it is named separately rather than
    # folded into ScanJob's: a library that is never indexed is at least visible as an empty
    # library, whereas a trash that is never purged looks exactly like a working one until the
    # storage bill arrives. An S3 trash is a key PREFIX, not a directory, and has no directory
    # mtime to age against — it needs its own reaper keyed on the objects' last_modified.
    # Task 8 decides here deliberately. DO NOT SHIP PHASE 3 WITH THIS GATE UNCHANGED.
    def self.purge_all!
      adapter = FileLayer.current
      return unless adapter.is_a?(FileLayer::Share)

      # .to_s: ActiveJob serializes arguments and Pathname is not a supported type — passing the
      # adapter's Pathname straight through raises SerializationError at enqueue.
      perform_later(root: adapter.root.to_s, trash_days: configured_trash_days)
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
