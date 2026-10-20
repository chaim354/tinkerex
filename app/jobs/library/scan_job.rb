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

    # ONE SCAN PER USER AT A TIME. Library::Reconciler's crash-repair design argues about
    # SEQUENTIAL passes (see its header) and nothing enforced that: library_scan fires every 15
    # minutes, and a first pass over a big NAS spends longer than that just hashing, so run N+1
    # started while run N was still walking. Two concurrent passes over one library interleave
    # observations with tombstones — precisely the state whose absence the pairing logic assumes.
    #
    # PER USER, NOT GLOBAL: two users' libraries share nothing, and a global key would serialize a
    # multi-user deployment's whole scan behind its slowest library.
    #
    # on_conflict: :discard, NOT the default :block. A blocked scan queues up behind the running
    # one, so a library that takes 20 minutes to walk accumulates a permanent backlog of scans
    # that each re-do the work of the one before. Dropping the tick is the right answer and this
    # job already says why in its retry commentary: the 15-minute schedule IS the retry, and it is
    # a better one than a replay because it re-observes the world instead of a stale verdict.
    #
    # duration is the semaphore's SAFETY VALVE for a worker that dies mid-scan, not an expected
    # runtime — it has to exceed a realistic slow pass or it lets exactly the overlap this
    # prevents back in. 1 hour comfortably covers the ~1–3 min/100k-file walk this repo measured
    # over SMB/NFS with headroom; the cost of that choice, stated plainly, is that a hard worker
    # crash skips this user's scans for up to an hour before the semaphore expires.
    #
    # NOTE FOR THE INTAKE CALL BELOW: concurrency controls are applied when a job is ENQUEUED, so
    # #intake_project_folders' `perform_now` is unaffected by ProjectIntakeJob's own limit. That
    # matters — §14f requires the intake to run inline, in this job, strictly after the reconcile,
    # and a limit that could discard it would break that guarantee rather than protect it.
    limits_concurrency to: 1, key: ->(args) { args[:user_id] },
                       duration: 1.hour, on_conflict: :discard

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
    # `scan_all!` may decline to schedule, but `perform` always performs or says why. (The one
    # decline is a QUEUED scan of a root the library folder has since left, and it logs which:
    # #stale_root?.)
    def perform(user_id:, root: nil)
      user = User.find(user_id)
      # ONE SCAN, ONE LIBRARY FOLDER (K; found in review). The walk below uses `root:`, fixed when the
      # job was queued, while the intake after it writes through FileLayer.current, whose share root
      # is read per job (FileLayer::Share#root). Reading the setting HERE, first, pins that answer for
      # the whole job: a folder chosen in the web process mid-walk is this process's NEXT job's, never
      # this job's intake -- which otherwise minted the old library's project folders inside the new
      # one. Library::RootChangeJob queues behind this job and scans the new folder. `if root`: only a
      # share scan names a root, and off share there is no setting to pin.
      Tinkerex::LibraryRoot.relative if root
      return if stale_root?(root)

      # `new` + `call` rather than `.call`, which returns the instance only on success: holding
      # the observer means #unreadable_dirs is still reachable, and that is the whole reason
      # Task 5 exposed it (and Task 7 gave S3Observer the same method for the same caller — here).
      observer = root ? Library::Scanner.new(user, root:) : observer_for(user)
      begin
        observer.call
      rescue Library::Scanner::UnsafeScan => e
        # THE REFUSAL IS RECORDED AND STILL RAISED (K §5): /settings/library shows it with its next
        # step, and the failed-jobs row stays the operator's report.
        user.update_column(:library_scan_refusal, e.message)
        raise
      end
      warn_unreadable(observer, user)
      discover_projects(user)
      intake_project_folders(user)
      intake_models(user)
      # A SCAN FINISHED, AND THIS IS THE ONLY PLACE THAT SAYS SO (stage 4, S4-3). Read by
      # FilesController#scan_status, polled by scanreload_controller.js, which reloads the page when
      # it moves — replacing a fixed 6-second guess.
      #
      # LAST, NOT AFTER observer.call, AND THAT IS THE POINT OF THE POSITION: the three steps above
      # are what a maker expects the reloaded page to SHOW (a discovered project, a filed file, a
      # catalogued model). All three are rescued, so a bug in one still stamps — correct, because
      # the reconcile above it committed and that is what "the scan finished" claims.
      #
      # NOT IN AN `ensure`. Library::Scanner::UnsafeScan propagates from observer.call (this job
      # deliberately has no retry_on for it), and a stamp on that path would tell every watching
      # page the scan succeeded while the catalog was never touched.
      #
      # update_columns: a bookkeeping stamp, not a user edit — no validations, no callbacks, and
      # `updated_at` left alone so a scan does not look like a profile change. It also clears a
      # refusal recorded above: the folder scanned.
      user.update_columns(library_scanned_at: Time.current, library_scan_refusal: nil)
    end

    # THE ONE PLACE THAT DECIDES WHAT MAY BE SERIALIZED INTO THE QUEUE. #perform's header states
    # the rule: a Share root is a PATH, safe to persist in the queue's database and genuinely
    # useful in a failed-jobs row (an operator sees WHICH root refused); an s3 library's target is
    # a bucket PLUS THE CREDENTIALS to reach it, which must never be written there, so the s3
    # fan-out names only the user and #perform re-resolves FileLayer.current.
    #
    # EXTRACTED WHEN Projects::ScansController BECAME A SECOND CALLER. A second copy of this branch
    # is the drift CLAUDE.md's §14d names a service to end — and the failure mode of getting it
    # wrong is a bucket's secret access key sitting in solid_queue_jobs.arguments forever.
    def self.enqueue_for(user)
      adapter = FileLayer.current
      # .to_s because ActiveJob cannot serialize a Pathname (SerializationError at enqueue).
      args = adapter.is_a?(FileLayer::Share) ? { root: adapter.root.to_s } : {}
      perform_later(user_id: user.id, **args)
    end

    # THE FIRST ACCOUNT TRIGGERS THE FIRST SCAN (J, 2026-10-15) -- ON SHARE, ONCE THE FOLDER IS
    # CONFIRMED (K, 2026-10-20). Scans are enqueued PER USER, so the boot-time hook in config/puma.rb
    # has no one to scan for on a fresh install -- measured: it ran, enqueued nothing, and a folder
    # full of files sat unindexed until Rescan while the guide said "indexed on start". The two doors
    # that create an account on a fresh server -- the sign-up form (Users::RegistrationsController)
    # and `bin/rails tinkerex:owner` -- call this for the FIRST account only, and the first-run
    # confirmation on /settings/library calls it once the folder is written. On a fresh share install
    # the sign-up's call meets the pending gate below and scans nothing; tinkerex:owner confirms the
    # whole mount first, so the console path still scans with no browser. Deliberately NOT a User
    # callback: 241 test files create users, and a callback dragged FileLayer.current and a real scan
    # into every one of them (red on all three legs, including an S3 listing against stub
    # credentials). The gates are the same two scan_all! obeys.
    def self.enqueue_first_for(user)
      return unless FileLayer.current.capabilities.scannable?
      # NOT WHILE THE LIBRARY FOLDER IS UNCONFIRMED (K §3). A fresh share install scans nothing until
      # its owner has said which folder is the library -- the boot hook, the schedule and the sign-up
      # form all reach this method or scan_all!. `.enqueue_for` stays a command and is not gated.
      return if Tinkerex::LibraryRoot.pending?

      enqueue_for(user)
    end

    # recurring.yml has no per-user fan-out pattern (every existing entry is an all-users sweep),
    # so the schedule calls this and it fans out internally. Tenant = user, and a share-backed
    # deployment is single-user in practice, so this stays small.
    #
    # The gate asks the FACTORY, not ENV. Task 8 established ENV.fetch("LIBRARY_BACKEND", "chunk")
    # as the reader and had LibraryBackendCheck mirror its defaults deliberately rather than invent
    # a second one; a literal third copy here would be the one that drifts. Asking FileLayer.current
    # also hands .enqueue_for a root that check! has already validated (exists, is a directory, is
    # readable) instead of a raw ENV string — one fewer way for the two to disagree.
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
      return unless FileLayer.current.capabilities.scannable?
      # The same pause as .enqueue_first_for's, and for the same reason (K §3).
      return if Tinkerex::LibraryRoot.pending?

      User.find_each { |user| enqueue_for(user) }
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

    # A SCAN QUEUED BEFORE THE LIBRARY FOLDER CHANGED MUST NOT RUN ON THE OLD ONE (K §5). The
    # semaphore Library::RootChangeJob shares stops one running DURING a change; this stops one queued
    # before it from running AFTER. Only a QUEUED job is judged: `enqueued_at` is nil for perform_now,
    # so a command still scans the root it names (this job's header), and a job queued after the
    # change names the new root anyway. A job queued before a write that left the root where it was
    # (the same folder confirmed twice) names the current root and runs.
    def stale_root?(root)
      return false if root.nil? || enqueued_at.nil?

      changed = Tinkerex::LibraryRoot.changed_at
      return false if changed.nil? || enqueued_at >= changed

      current = FileLayer.current
      return false unless current.is_a?(FileLayer::Share) && current.root.to_s != root

      Rails.logger.warn("Library::ScanJob: discarding a scan of #{root} queued before the library " \
                        "folder changed to #{current.root}")
      true
    end

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

    # STRICTLY AFTER THE RECONCILE AND STRICTLY BEFORE THE PROJECT INTAKE. The first ordering
    # changes the ANSWER; since F-S07-1 (2026-10-19) the second changes only the TIMING.
    #
    # After the RECONCILE because discovery reads names and parentage, and a folder the Scanner has
    # not settled is a wrong answer — the same reason the two methods below give.
    #
    # Before the PROJECT INTAKE so a discovered project's loose files are filed in the SAME pass, not
    # the next. This used to change the answer as well: left at `Projects/new-thing/`, the seeded `*`
    # shelf makes `Projects` the nearest shelf above them, so a catalog that reached the folder
    # before it was adopted made the whole `new-thing` FOLDER one model, permanently. Ordering never
    # closed that and could not: this call is CAPPED (Maker::ProjectDiscovery::MAX_PROJECTS), so a
    # folder past the cap reached #intake_models unadopted inside this very sequence, and on
    # chunk_remote the three sweeps are independent schedules. The catalog closes it instead, by
    # counting every folder discovery owns BY POSITION as claimed (Maker::ModelIntake
    # .claimed_folders). Pinned by DiscoveryOrderTest: RED on the swap as a file left unfiled, and a
    # capped run must leave no model behind.
    #
    # CALLS THE JOB, NOT Maker::ProjectDiscovery DIRECTLY, for the reason #intake_project_folders
    # records as a finding rather than a preference: the SERVICE logs nothing, so the JOB is the
    # only place a run's created count is ever written down. Calling the service here would give a
    # share/s3 deployment LESS operator visibility than chunk_remote gets from its schedule.
    # Concurrency controls apply at ENQUEUE, so ProjectDiscoveryJob's own limit cannot discard this
    # perform_now — and its #chain_intake declines on a scannable backend, so this call cannot
    # enqueue a second, unsequenced filer.
    #
    # RESCUED AND NARROWLY SCOPED, like its two siblings: the reconcile above is already committed,
    # so a discovery bug must not tell an operator reading the failed-jobs table that the library
    # did not index.
    def discover_projects(user)
      Maker::ProjectDiscoveryJob.perform_now(user_id: user.id)
    rescue StandardError => e
      Rails.logger.error("Library::ScanJob: the reconcile SUCCEEDED but project discovery " \
                         "failed for user #{user.id}: #{e.class}: #{e.message}")
    end

    # THE PROJECT-FOLDER INTAKE RUNS HERE, INLINE AND STRICTLY AFTER THE RECONCILE, and the
    # placement is a correctness constraint rather than a convenience.
    #
    # If the intake moves a file after the Scanner has captured its observations, the Reconciler
    # sees the node at its NEW path unobserved and the observation at the OLD path unclaimed, pairs
    # them by (content_hash, size) — best_pairing working exactly as designed — and re-points the
    # node BACK to the old path while the bytes sit at the new one. It self-heals on the next pass,
    # but in the window the node's storage_path has no bytes behind it — and a download of it does
    # NOT get the retryable 503: library_present? still reads true (the share root itself is fine),
    # so Share#download's ENOENT maps to NotFound, and FilesController renders that as 404, "File
    # not found." That is the TERMINAL answer, the one Share's own comments say must never be said
    # about a file that is not actually gone (the same reasoning that makes undelete raise
    # FetchError rather than NotFound on an unmounted share). It is that terminal reading — not
    # merely an extra retry — that makes this ordering worth GUARANTEEING rather than merely
    # preferring. Running here, in the same job, after observer.call, makes the overlap impossible
    # instead of merely unlikely. Maker::ProjectIntakeJob's own schedule declines on scannable
    # backends for the other half of this reason.
    #
    # A JOB ORCHESTRATING A MAKER SERVICE IS NOT the inversion .observer_for refuses. That objection
    # is about a FileLayer ADAPTER reaching up into the catalog layer; a job is the top level, and
    # this one already owns "what happens on a scan".
    #
    # CALLS THE JOB, NOT Maker::ProjectIntake DIRECTLY — Maker::ProjectIntakeJob.perform_now(user_id:)
    # rather than Maker::ProjectIntake.for_user(user:) — so a share/s3 deployment gets the SAME
    # operator-visible reporting a chunk deployment gets from the scheduled sweep, not less of it.
    # An earlier version of this method called the service directly and threw its RunResult away:
    # reproduced by forcing PROJECT_ORGANIZE_MAX_MOVES=1 against two loose files and finding NO
    # match for /cap/i, /refus/i or /attached/i anywhere in the log, while the identical trip on a
    # chunk deployment logs a WARN naming the count and `rake projects:organize`
    # (ProjectIntakeJob#report — its own header calls this "THE ENTIRE AUDIT TRAIL", since nothing
    # persists a marker of what a sweep did). So the deployment this integration exists for was
    # getting LESS visibility than the one it was not primarily built for. #perform is deliberately
    # ungated (the job's own header explains why), so calling it here costs one extra User.find and
    # ActiveJob's own Performing/Performed log lines — cheaper than a second copy of #report's
    # wording, which is the whole point of going through the job instead.
    #
    # RESCUED, AND NARROWLY SCOPED TO THIS CALL. The reconcile above is already committed — there is
    # no transaction (see Library::Reconciler's header) — so letting an intake bug fail this job
    # would tell an operator reading the failed-jobs table that the library did not index, when it
    # did. The rescue must NOT wrap observer.call: Scanner::UnsafeScan is the reconcile refusing, and
    # that failed-jobs row is the only way the refusal reaches anyone. perform_now still raises
    # through to here for anything ProjectIntakeJob does not itself swallow (only its own
    # discard_on ActiveRecord::RecordNotFound does), so this rescue is exercised exactly as it was
    # when this method called the service directly.
    def intake_project_folders(user)
      Maker::ProjectIntakeJob.perform_now(user_id: user.id)
    rescue StandardError => e
      Rails.logger.error("Library::ScanJob: the reconcile SUCCEEDED but the project-folder " \
                         "intake failed for user #{user.id}: #{e.class}: #{e.message}")
    end

    # STRICTLY AFTER THE PROJECT INTAKE, IN THIS JOB, AND THE ORDER IS LOAD-BEARING TWICE OVER.
    #
    # After the RECONCILE for the reason §14f already gives, and the one #intake_project_folders
    # spells out above: the catalog reads PATHS, and a path the Scanner has not settled is a wrong
    # answer.
    #
    # After the PROJECT INTAKE because that step MOVES files, and the model a file belongs to is
    # decided by the nearest SHELF above it — so a move can change the answer rather than merely the
    # location. Measured 2026-10-19 on a project adopted at a TOP-LEVEL folder with filing on: its
    # root is itself a shelf (the seeded `*`), so a loose `lid.stl` there is its own one-file model.
    # Catalogue first and that row makes the intake refuse to move the file (`:model_bundle`, a file
    # a model holds stays put), so it sits at the root for good; in this order it is filed into
    # `models/` and joins that folder's model. UNDER `Projects/` THE SAME SWAP NOW COSTS ONLY A SCAN:
    # a file loose at a project's root keys to the project's folder, which is claimed — by its
    # project, or by discovery's position before the project exists (F-S07-1) — so the catalog
    # leaves it alone until the intake has moved it under the seeded `Projects/*/models` shelf.
    # Pinned by scan_job_test.rb's IntakeOrderTest ("cataloguing runs after the project intake…"),
    # which is RED on the swap with [] — the `Projects/` half; the top-level half has no test yet.
    #
    # CALLS THE JOB, NOT Maker::ModelIntake DIRECTLY, for the reason #intake_project_folders
    # records as a finding rather than a preference: Maker::ModelIntake logs NOTHING itself, so
    # Maker::ModelIntakeJob#perform is the only place a run's created count or a MAX_MODELS
    # refusal is ever written down. Calling the service here would give a share/s3 deployment less
    # operator visibility than the chunk deployment gets from the scheduled sweep — the identical
    # regression that method's comment reproduces and closes, one file over. Concurrency controls
    # apply at ENQUEUE, so ModelIntakeJob's own limit cannot discard this perform_now.
    def intake_models(user)
      Maker::ModelIntakeJob.perform_now(user_id: user.id)
    rescue StandardError => e
      # A catalog failure must not fail the SCAN, whose job was done before this ran — the same
      # argument, and the same narrow scoping, as the rescue above.
      Rails.logger.error("Library::ScanJob: the reconcile SUCCEEDED but the model catalog " \
                         "failed for user #{user.id}: #{e.class}: #{e.message}")
    end
  end
end
