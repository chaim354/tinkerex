# frozen_string_literal: true

module FileLayer
  # THE RECURRING PER-USER PULL THAT CLOSES ARC B GAP (a). Scheduled from config/recurring.yml.
  #
  # THE DEFECT THIS CLOSES: `ChunkRemote::ChangelogSync` had exactly one caller,
  # `ChunkRemote#refresh!`, itself reached only from THIS app's own writes -- mkdir, move, delete,
  # undelete, finalize_upload (chunk_remote.rb). A node another device (or the sync server itself)
  # created was invisible to the maker UI until this app happened to write something of its own;
  # `GET /files` never refreshed the mirror as a side effect of a plain read. This job is the
  # scheduled, per-user backstop: on a schedule, pull whatever changed on the server since our
  # cursor, whether or not this app was the one that changed it.
  #
  # THIS IS A POLL, NOT THE FIX FOR LATENCY. The honest longer-term answer is a sync -> maker
  # webhook, or an ActionCable subscription to the remote host's own broadcast (matching what
  # LibraryChannel already gives the embedded `chunk` backend today) -- out of scope here. What this
  # buys is BOUNDED staleness instead of UNBOUNDED staleness, the same trade Library::ScanJob already
  # makes for share/s3 (§14b's own scanned-backend argument).
  #
  # THE INTERVAL IS IN config/recurring.yml, STATED AND ARGUED THERE, not duplicated here --
  # matching library_scan/project_folder_intake, whose own reasoning lives beside their schedule
  # lines rather than in their job files.
  class RemoteChangelogPullJob < ApplicationJob
    # Matches Library::ScanJob / Maker::ProjectIntakeJob: a periodic per-user sweep is background
    # work, not something a request is waiting on.
    queue_as :background

    # The user can be deleted between .pull_all!'s fan-out and this running. Nothing to pull and
    # nothing wrong -- discard rather than record a failure (GeneratePreviewJob sets the precedent;
    # Library::ScanJob and Maker::ProjectIntakeJob both follow it).
    discard_on ActiveRecord::RecordNotFound

    # ONE PULL PER USER AT A TIME, same shape and same reasoning as ScanJob's / ProjectIntakeJob's:
    # an unreachable or slow sync server (Transport's own OPEN_TIMEOUT/READ_TIMEOUT) must not let a
    # second scheduled pull for the SAME user queue up behind a first one that is still waiting on
    # the network. :discard, not the default :block, because the next scheduled tick re-reads the
    # server's current changelog from wherever our cursor actually sits -- a better retry than a
    # queued replay of a now-stale request (ScanJob's own argument for :discard).
    #
    # duration: matches config/recurring.yml's interval -- one schedule tick of cover for a worker
    # that dies mid-pull, not an expected runtime (a no-op pull is one or two cheap GETs).
    limits_concurrency to: 1, key: ->(args) { args[:user_id] },
                       duration: 2.minutes, on_conflict: :discard

    # #perform IS DELIBERATELY UNGATED, matching Library::ScanJob's own rule (scan_job.rb): this is
    # a COMMAND, not a schedule -- a caller who names a user deserves the pull, on any backend,
    # rather than a silent no-op that looks exactly like "nothing changed."
    #
    # `transport:` IS INJECTABLE, for the same reason FileLayer::ChunkRemote's own `transport:` and
    # `chunk_fetch:` seams are (chunk_remote.rb): a test that cannot substitute the wire can only
    # exercise this job by standing up a real sync server. Left nil in production, where it is built
    # from the same two ENV vars ChunkRemote itself reads.
    #
    # NO RESCUE HERE, DELIBERATELY -- matching ScanJob's "no retry_on, no discard_on" for
    # Library::Scanner::UnsafeScan. A raising pull (an unreachable server, a rejected token) is an
    # operator-visible condition, not a thing to swallow: it propagates, Solid Queue records ONE
    # failed execution, and the next scheduled tick is the retry. `limits_concurrency` above is what
    # keeps that failure from stacking up rather than a caught-and-logged exception here.
    def perform(user_id:, transport: nil)
      user = User.find(user_id)
      ChunkRemote::ChangelogSync.new(user, transport: transport || default_transport).call
    end

    # THE FAN-OUT, FOLLOWING Library::ScanJob.scan_all!'s SHAPE EXACTLY: `User.find_each` +
    # `perform_later` per user, so this method only ENQUEUES -- it never runs a pull itself. That is
    # what makes "one unreachable library must not stop the sweep" true structurally rather than by
    # a rescue someone has to remember: each user's pull is its OWN Solid Queue job, so one user's
    # eventual FileLayer::FetchError (raised later, inside that user's own #perform) cannot prevent
    # another user's job from ever being enqueued or run -- there is no shared loop for it to break.
    #
    # THE GATE IS HERE, NOT IN #perform -- Library::ScanJob's and Maker::ProjectIntakeJob's own
    # argument: .pull_all! is a SCHEDULE (recurring.yml fires it in every deployment, chunk_remote
    # or not), so declining to enqueue is a real answer to "should this run at all"; #perform is a
    # COMMAND, where a `return unless` would make an explicit call silently do nothing.
    #
    # A CLASS CHECK, NOT A NEW CAPABILITY. `chunk_remote` is the only backend whose `nodes` table is
    # a MIRROR of a tree that lives on ANOTHER server: `chunk` shares this app's own database with
    # the sync engine in-process, so there is no mirror to go stale, and share/s3 have no changelog
    # at all (Library::ScanJob's poll is their freshness mechanism, gated on `scannable`). No
    # existing FileLayer::Capabilities member asks "is this app's tree a mirror of a REMOTE
    # changelog" -- `syncable` is true for chunk AND chunk_remote alike, so it cannot discriminate
    # here. Adding a new Capabilities member would also require a matching change to
    # FileLayer::Chunk, which ships in the tinkerex-sync gem this repo does not own (§14j) -- not
    # reachable from here. `is_a?` is the same shape Library::ScanJob already uses to build
    # backend-specific fan-out args (`adapter.is_a?(FileLayer::Share)`), not the Phase 3 trap that
    # shape names in its OWN gate: that trap was a SECOND backend silently answering false to a
    # capability the gate assumed only one backend had. There is no second backend that mirrors a
    # remote changelog for this gate to silently exclude.
    def self.pull_all!
      return unless FileLayer.current.is_a?(FileLayer::ChunkRemote)

      User.find_each { |user| perform_later(user_id: user.id) }
    end

    private

    # Built lazily, and only when the caller did not inject one, so merely loading this class never
    # demands CHUNK_REMOTE_URL/CHUNK_REMOTE_TOKEN -- matching ChunkRemote#transport's own reasoning.
    def default_transport
      ChunkRemote::Transport.new(base_url: ENV.fetch("CHUNK_REMOTE_URL"),
                                 token: ENV.fetch("CHUNK_REMOTE_TOKEN"))
    end
  end
end
