module Library
  # Periodic reconcile of a share-backed library. Changes made outside the app (someone drops
  # files on the NAS in Finder) surface within the interval — inotify/FSEvents are unreliable to
  # absent over SMB/NFS for changes made by OTHER machines, which is the actual use case, so
  # polling is the honest mechanism (spec decision 5).
  #
  # WHY THE BACKEND GATE IS ON .scan_all! AND NOT ON #perform. They are different kinds of thing:
  # `scan_all!` is a SCHEDULE — recurring.yml fires it in every deployment including chunk-mode
  # ones, so no-opping there is the answer to a question nobody asked. `#perform` is a COMMAND: a
  # caller named a user and a root. A `return unless backend == "share"` there would make an
  # operator's explicit scan silently do nothing, which is the exact failure mode this port
  # refuses everywhere else (FileLayer.build raises on s3 rather than quietly serving an empty
  # library). If you are here because a scan "did nothing", that is why it is not written that way.
  class ScanJob < ApplicationJob
    # Matches RetentionJob / ChunkReaperJob: a periodic all-users sweep is background work, not
    # something a user is waiting on.
    queue_as :background

    # The user can be deleted between scan_all!'s fan-out and this running. Nothing to scan and
    # nothing wrong — discard rather than record a failure (GeneratePreviewJob sets the precedent).
    discard_on ActiveRecord::RecordNotFound

    # DELIBERATELY NO `retry_on Library::Scanner::UnsafeScan`, and no discard_on for it either.
    #
    # UnsafeScan is a REFUSAL, not a crash: the root is missing, or the pass would tombstone an
    # implausible share of the library. Retrying in 30s cannot remount a NAS or fix a typo'd
    # LIBRARY_PATH, so retry_on would turn one honest refusal into five identical ones and delay
    # nothing. And discard_on would reduce "we refused to reconcile your library" to a log line on
    # a self-hosted box nobody tails — the guard would be doing its job invisibly.
    #
    # So it propagates: Solid Queue records ONE failed execution per scheduled run, carrying the
    # message (which Task 7 made name the counts and the unreadable dirs). That is what "reported"
    # means operationally here — an entry in the failed-jobs table an operator can actually see.
    # The 15-minute schedule is itself the retry, and it is a better one than any backoff: it
    # re-observes the world instead of replaying a stale verdict.

    # `root` is REQUIRED rather than defaulting to ENV["LIBRARY_PATH"]. scan_all! always passes it
    # (from the validated adapter, below), so a default would only serve a hand-rolled call — and
    # it would serve it a raw, unvalidated ENV read that is nil in every non-share deployment,
    # making `Pathname.new(nil)` the operator's error message. Requiring it means the caller's
    # mistake is named at the call site.
    def perform(user_id:, root:)
      user = User.find(user_id)

      # `new` + `call` rather than `Scanner.call`, which returns the instance only on success:
      # holding the scanner means #unreadable_dirs is still reachable, and that is the whole
      # reason Task 5 exposed it.
      scanner = Library::Scanner.new(user, root:)
      scanner.call
      warn_unreadable(scanner, user)
    end

    # recurring.yml has no per-user fan-out pattern (every existing entry is an all-users sweep),
    # so the schedule calls this and it fans out internally. Tenant = user, and a share-backed
    # deployment is single-user in practice, so this stays small.
    #
    # The gate asks the FACTORY, not ENV. Task 8 established ENV.fetch("LIBRARY_BACKEND", "chunk")
    # as the reader and had LibraryBackendCheck mirror its defaults deliberately rather than invent
    # a second one; a literal third copy here would be the one that drifts. Asking FileLayer.current
    # also hands us a root that check! has already validated (exists, is a directory, is readable)
    # instead of a raw ENV string — one fewer way for the two to disagree.
    # PHASE 3 TRAP — ARMED AS OF TASK 3 (2026-07-17). This comment used to say "the moment
    # FileLayer::S3 exists"; it exists, so the trap is no longer a prediction. FileLayer.current
    # now RETURNS a FileLayer::S3 for an s3 deployment instead of raising NotImplementedError, so
    # this is_a? quietly answers false and scan_all! SILENTLY NO-OPS: an s3 library is never
    # indexed, nothing raises, nothing logs, and the whole suite stays green. Reproduced, not
    # reasoned — scan_all! returns nil and enqueues zero jobs under LIBRARY_BACKEND=s3.
    #
    # This is the exact silent-no-op this job's own design argues against two paragraphs up, and
    # it is left live DELIBERATELY for one task only: Task 8 wires the s3 scan and must decide
    # here on purpose rather than inherit this false. An S3 library needs its own indexer (it has
    # no walkable Pathname root, and `adapter.root` below does not exist on S3).
    # DO NOT SHIP PHASE 3 WITH THIS GATE UNCHANGED.
    def self.scan_all!
      adapter = FileLayer.current
      return unless adapter.is_a?(FileLayer::Share)

      # .to_s: ActiveJob serializes arguments and Pathname is not a supported type — passing the
      # adapter's Pathname straight through raises SerializationError at enqueue.
      root = adapter.root.to_s
      User.find_each { |user| perform_later(user_id: user.id, root:) }
    end

    private

    # The operator signal for a half-mounted NAS. This matters precisely when the mass-deletion
    # guard does NOT trip: a small unreadable subtree stays under the threshold, so the scan
    # succeeds and those files are simply excluded from the library, with nothing but a per-dir
    # line in the Scanner's log to say why. (On the UnsafeScan path this is not needed — the
    # refusal message already names them.)
    def warn_unreadable(scanner, user)
      dirs = scanner.unreadable_dirs
      return if dirs.empty?

      Rails.logger.warn(
        "Library::ScanJob: #{dirs.size} directories were unreadable for user #{user.id} and " \
        "their contents are EXCLUDED from the library " \
        "(#{dirs.first(3).map(&:inspect).join(', ')}#{'...' if dirs.size > 3}). " \
        "Is the share fully mounted?"
      )
    end
  end
end
