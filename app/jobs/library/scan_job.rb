module Library
  # Periodic reconcile of a SCANNED library — share-backed or s3-backed. Changes made outside the
  # app (someone drops files on the NAS in Finder, or runs `aws s3 mv`) surface within the interval
  # — inotify/FSEvents are unreliable to absent over SMB/NFS for changes made by OTHER machines,
  # and a bucket tells us nothing at all unless asked, so polling is the honest mechanism (spec
  # decision 5).
  #
  # ONE JOB, TWO OBSERVERS, ONE RECONCILER (see .observer_for). Library::Scanner walks a
  # filesystem, Library::S3Observer lists a bucket, and both hand Library::Observation to the same
  # Library::Reconciler — which is where every decision (move-pairing, revive-by-path, the
  # mass-deletion guard) actually lives. A second reconciler would be a second home for every bug
  # 2a found in the first.
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

    # `root:` NAMES A SHARE ROOT, and it is optional for one reason: an s3 library has no name
    # that may be written down here.
    #
    # ActiveJob SERIALIZES arguments into the queue's database, where they persist until the job
    # runs — and after it fails. A share's target is a path, which is safe to write there and
    # genuinely useful (an operator reading the failed-jobs table sees WHICH root refused). An s3
    # library's target is a bucket plus the credentials to reach it, which must never be written
    # there. So the s3 fan-out names only the user and this job resolves FileLayer.current, from
    # the same validated ENV the fan-out itself read a moment earlier.
    #
    # THIS IS NOT THE GATE, and the distinction is the whole of Phase 3's trap. `root:` given =
    # a caller named a share root and gets it scanned, whatever the deployment is (pinned by a
    # test). `root:` omitted = "this deployment's library", which resolves to a scannable adapter
    # or RAISES. Neither branch can silently do nothing, which is the property that matters:
    # `scan_all!` may decline to schedule, but `perform` always performs or says why.
    def perform(user_id:, root: nil)
      user = User.find(user_id)

      # `new` + `call` rather than `.call`, which returns the instance only on success: holding
      # the observer means #unreadable_dirs is still reachable, and that is the whole reason
      # Task 5 exposed it (and Task 7 gave S3Observer the same method for the same caller — here).
      observer = root ? Library::Scanner.new(user, root:) : observer_for(user)
      observer.call
      warn_unreadable(observer, user)
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
    #
    # THE PHASE 3 TRAP, DISARMED (2026-07-17, Task 8). This gate WAS `is_a?(FileLayer::Share)`.
    # That was correct — Share was the only scanned backend — and it went silently wrong the day
    # FileLayer::S3 landed: it answered false, scan_all! enqueued nothing, raised nothing, logged
    # nothing, and an s3 library was simply never indexed while every test stayed green. It was
    # reproduced in exactly that state before this line changed.
    #
    # THE LESSON, WHICH IS NOT "ADD S3": `is_a?(Share) || is_a?(S3)` would be the same bug with a
    # longer fuse — the third backend inherits the same false from a check it has never heard of.
    # The gate asks a CAPABILITY the adapter ANSWERS, so a new backend cannot be silently excluded
    # from the scan: it must state `scannable:` to construct its Capabilities at all (Data.define
    # requires every member), and whichever it states, this gate obeys it. The default is not
    # "false", it is "you must say".
    def self.scan_all!
      adapter = FileLayer.current
      return unless adapter.capabilities.scannable?

      # The s3 fan-out names NO target: a bucket + credentials must not be serialized into the
      # queue's database (see #perform). Share's root is a path, which is safe there and useful in
      # a failed-jobs row — and .to_s because ActiveJob cannot serialize a Pathname (it raises
      # SerializationError at enqueue).
      args = adapter.is_a?(FileLayer::Share) ? { root: adapter.root.to_s } : {}
      User.find_each { |user| perform_later(user_id: user.id, **args) }
    end

    # THE DISPATCH — deliberately NOT the gate, and the difference is why an is_a? is honest here
    # and was dishonest as a gate. The gate's failure mode was SILENCE: a backend it did not
    # recognize got SKIPPED, and skipping looks exactly like a library with nothing in it. Here an
    # unrecognized adapter yields nil and the caller raises. A future backend that answers
    # `scannable: true` and forgets to add itself here gets a failed job naming the class; it does
    # not get an empty library.
    #
    # IT ASKS NO CAPABILITY, and that is what makes it worth testing. `scannable` is a DECLARATION
    # ("poll me"); this is an independent FACT ("something exists that can"). The contract asserts
    # the two agree — a comparison with meaning only because neither side is derived from the
    # other. When the check lived inside this method the contract test was circular and a Chunk
    # mutated to `scannable: true` sailed straight through it (found by mutation, not by review).
    #
    # PUBLIC, and a class method, for that test. It stays in the job rather than becoming
    # `adapter.observer_for(user)` because the direction of that dependency matters: FileLayer is
    # the PORT and Library::* is a consumer of it, so an adapter that constructed an observer would
    # have the port reaching up into the catalog layer.
    def self.observer_for(user, adapter)
      case adapter
      when FileLayer::Share then Library::Scanner.new(user, root: adapter.root)
      when FileLayer::S3    then Library::S3Observer.new(user, adapter:)
      end
    end

    private

    def observer_for(user)
      adapter = FileLayer.current
      observer = self.class.observer_for(user, adapter)
      return observer if observer

      # Both messages, because they are different mistakes with different fixes — and neither may
      # be a silent no-op.
      raise ArgumentError,
            if adapter.capabilities.scannable?
              "#{adapter.class} says it is scannable but Library::ScanJob has no observer for " \
              "it — add one to .observer_for. (Refusing loudly rather than skipping: a scan " \
              "that silently does nothing is indistinguishable from an empty library, which is " \
              "the exact bug this job's gate shipped in Phase 3.)"
            else
              "#{adapter.class} is not a scanned backend (its catalog does not come from " \
              "polling a store), so there is nothing for a scan to do. Chunk-mode libraries " \
              "are maintained by the sync engine's changelog. Pass root: to scan a share " \
              "directory explicitly."
            end
    end

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
