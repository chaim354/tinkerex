module Maker
  # Make the catalog agree with what is in a project's library folder: attach every file under it,
  # and file whatever is loose at its root into a category subfolder.
  #
  # WHY A SWEEP RATHER THAN A HOOK ON EVERY WRITE. A file can reach `Projects/<slug>/` seven ways —
  # FilesController#create (share/s3), #finalize_upload (chunk), Library::Reconciler (the scan),
  # Sync::Commit#finalize (a device push), Maker::Addons::LibraryOutput, Maker::MoveNode, and a
  # trash restore. There is no single funnel. Hooking each is seven sites that must agree, and an
  # EIGHTH door silently skips the rule — the failure this repo has recorded more than once
  # (Maker::AttachToProject's header; the five port_writable? copies; the four instances of the
  # Scanner's skip-list blind spot, each found only after the previous explanation said it could not
  # happen). This reads `nodes`, the catalog ALL THREE BACKENDS populate, so it covers every door
  # and any future one without touching any of them.
  #
  # IT ADDS NO NEW COPY OF THE port_writable? BRANCH. Maker::MoveNode owns the move and
  # Maker::LibraryFolder owns the mkdir; both already branch correctly for this deployment.
  #
  # §10 BOUNDARY: maker-layer policy. It reaches bytes only through those two services, and nothing
  # here touches Sync::*, the changelog, conflicts, locks or the mounts.
  class ProjectIntake
    # What one project's intake did. `plan` is filled only in a dry run — [name, folder] pairs, so
    # the rake task can print source -> destination without a second traversal. `skips` is the
    # SAME shape for the other outcome — [name, reason] pairs, one per file #file_all did not
    # move — so Task 12's rake task can say which files and why, not just how many.
    Result = Data.define(:attached, :moved, :skipped, :skips, :plan, :status)

    # What one USER's whole intake run did. The cap is a property of the RUN, so its refusal lives
    # here rather than on Result: a single project cannot know whether the run as a whole is
    # implausible.
    RunResult = Data.define(:results, :status, :inbox_total, :cap)

    # The default ceiling on files filed in one PERIODIC, UNATTENDED run — .for_user (the 15-minute
    # sweep / a chunk deployment's Maker::ProjectIntakeJob, or Library::ScanJob's post-reconcile
    # call on share/s3). See .for_user for why it is an absolute count rather than a percentage.
    #
    # NOT THE CAP A WEB REQUEST USES — see EAGER_MAX_MOVES just below. Two constants that both
    # answer "how many files get filed" is exactly the shape a future reader collapses into one, so
    # the distinction is recorded at both definitions: this one bounds CHURN across a run nobody is
    # waiting on (SQLite has no statement timeout; a NAS or a bucket does not care how long a
    # background job takes), EAGER_MAX_MOVES bounds LATENCY inside a request a browser IS waiting
    # on. Measured, not assumed, ON CHUNK MODE / LOCAL SQLITE: 200 loose files already at a project
    # root costs 2,425 queries and ~340 ms to file with zero network latency (see the query-count
    # test below) — fine once every 15 minutes in a background job, not fine stacked onto the
    # response time of every single upload into a project with any kind of backlog. See
    # EAGER_MAX_MOVES's comment for the SCOPE of that number: it is real, but it is one backend's
    # metadata cost, not a bound on what this class costs everywhere.
    MAX_MOVES = 500

    # The ceiling .for_node uses INSTEAD OF MAX_MOVES — deliberately a different constant, a
    # different env var, and a much smaller default, because .for_node is the only entry point this
    # class has that can run INSIDE a web request (FilesController's eager nudge, Task 11) rather
    # than an unattended background job. Reusing MAX_MOVES here would let a single upload's response
    # wait on the cost described in that constant's comment, and a 200-file backlog is not exotic —
    # the Printables zip importer drops a whole bundle into a project in one request.
    #
    # THE DEFAULT IS EVIDENCE-BASED BUT NOT EVENLY EVIDENCED ACROSS BACKENDS, and that is worth
    # stating plainly rather than leaving implicit in a number. MAX_MOVES' comment's 2,425-queries/
    # ~340ms figure is CHUNK-MODE METADATA COST ON LOCAL SQLITE WITH ZERO NETWORK LATENCY — real,
    # and the evidence this default is an improvement over reusing MAX_MOVES, but it is the
    # CHEAPEST of the three backends this cap governs, not a bound on what filing costs on the other
    # two:
    #
    #   - S3: FileLayer::S3#move is THREE SEQUENTIAL, UNBATCHED NETWORK CALLS per file —
    #     object_exists? (a HEAD), copy! (a COPY), then delete_object (a DELETE); verified by
    #     reading the method, not assumed. At this cap's default that is 25 * 3 = 75 sequential S3
    #     API calls inside one browser-facing request. docs/r2-migration.md / docs/STATUS.md
    #     measured ~85–205 ms per comparable call against a real R2 bucket, so at the low end alone
    #     that is several seconds an upload's response would sit waiting on.
    #   - Chunk: filing N files fires N synchronous LibraryChannel.broadcast_change calls (one per
    #     Sync::Mutation.apply inside MoveNode#chunk_move) PLUS one more per category subfolder
    #     Maker::LibraryFolder.ensure_path! has to create along the way — verified directly: 25
    #     same-category files (all .stl, one new folder) broadcast 26 times, 25 files split across
    #     two categories (two new folders) broadcast 27, both measured at ~43–50 ms on local SQLite
    #     with no contention. LibraryChannel's own header states the intent this pattern strains
    #     under load: "Coarse (one event per commit) — never per-operation." Each broadcast's
    #     Sync::Mutation.apply also takes the user-row lock in User#next_seq! (a Postgres FOR
    #     UPDATE) inside its own transaction — a serialization point this local-SQLite-with-no-
    #     contention number cannot speak to; it was never positioned to measure write contention on
    #     managed Postgres, and does not claim to.
    #
    # THE DEFAULT STAYS 25 ANYWAY. It is a large, evidenced improvement over reusing MAX_MOVES (500)
    # regardless of backend; it fails toward SLOW rather than WRONG on every one of the three (a
    # project over the cap still attaches — always — and simply waits for the periodic sweep to
    # file; see .for_node); and it is operator-tunable per deployment via
    # PROJECT_ORGANIZE_EAGER_MAX_MOVES. An S3 deployment expecting large backlog uploads is the one
    # where an operator should consider tuning it DOWN from 25, not up — the arithmetic above is
    # the reason, left as arithmetic on purpose rather than a second, S3-specific constant this
    # class does not have the evidence to pick a number for.
    #
    # A LOW-TENS DEFAULT keeps the synchronous path cheap on the backend it was measured against:
    # the attach half is always O(new files) regardless of this cap (see .call's ordering), and
    # filing a couple dozen files is a couple dozen Maker::MoveNode calls, not a couple hundred —
    # while staying large enough that the ordinary case, a handful of files dropped into a folder,
    # files itself immediately without ever touching this ceiling.
    #
    # OVER THIS CAP: attach still runs (always — see .for_node), filing does not, and the PERIODIC
    # sweep (MAX_MOVES' run) picks up the backlog on its own schedule. That is the SAME
    # durable-now/best-effort-later split .for_user already applies to MAX_MOVES; this constant does
    # not introduce a new policy, it gives the existing policy a cheaper threshold for the one caller
    # that cannot afford the expensive one.
    EAGER_MAX_MOVES = 25

    # How deep the tree walks go before giving up. A project folder is shallow; this is a backstop
    # against a CYCLE in `nodes`, which makes an unbounded walk spin — fatal on SQLite, which has
    # no statement timeout (the same hazard V1::NodesController#move spends would_create_cycle? on).
    #
    # THE TRADE-OFF: this bound cannot tell a cycle from a genuinely deep, cycle-free tree. A
    # project folder is not expected to nest 32 levels — but if one somehow does, files past the
    # cutoff go unattached, and `status` alone would still read `:ok`, indistinguishable from a
    # complete sweep that simply found nothing more. Silence there is a promise made and not kept,
    # the same shape this repo already refuses elsewhere (Library::Reconciler's `unreadable_dirs`,
    # so it never tombstones what it could not see; S3Observer's once-per-scan warn, because a zero
    # must not read as "moves are fine"). So when the bound runs out with directories still
    # unexplored, #warn_if_truncated logs instead of letting the sweep look complete.
    MAX_DEPTH = 32

    def self.for_project(user:, project:, dry_run: false, move: true)
      new(user:, project:, dry_run:, move:).call
    end

    # Sweep every one of this user's projects that HAS a folder, under one shared cap.
    #
    # THE CAP IS ABSOLUTE, NOT A PERCENTAGE, and Library::Reconciler's mass-deletion guard is the
    # wrong model here — which is worth saying because copying it looks like the safe choice. A
    # percentage needs a denominator, and the only honest one is "files currently at project roots",
    # of which the intended first run files 100%. A percentage would be guarding against SUCCESS.
    # The diagnostic number is the raw count: 40 files at project roots is a few projects, 40,000 is
    # a misconfiguration.
    #
    # IT IS PER RUN, NOT PER PROJECT. A per-project cap of 500 lets fifty projects move 25,000 files
    # without ever tripping — it would bound the wrong thing, since the blast radius that matters is
    # the churn ONE run produces on the NAS or on the changelog.
    #
    # OVER THE CAP, THE ATTACH STEP STILL RUNS. The two halves have different costs: an attach
    # writes a row and moves no bytes, so there is nothing to be careful about, and withholding it
    # would deny the harmless half of the feature out of concern for the other. That is the
    # durable/best-effort split applied to the guard itself.
    #
    # IT ANSWERS A STATUS AND DOES NOT RAISE FOR THE CAP TRIP, unlike Library::Scanner::UnsafeScan,
    # for two reasons — and the second is the load-bearing one. A cap trip on a big first run is an
    # EXPECTED outcome, not a malfunction (Maker::AttachToProject's argument for every move outcome
    # being a symbol: "each one is a normal thing that happens to a user's library"). And on share/s3
    # this is called at the END of Library::ScanJob#perform, where there is no transaction — so a
    # raise would fail a job whose scan had ALREADY SUCCEEDED AND COMMITTED, telling an operator the
    # library did not index when it did. A guard must not lie about which operation it stopped.
    #
    # THAT CLAIM IS SCOPED TO THE CAP TRIP, NOT TO A MALFORMED CAP — the two are different failure
    # modes and only one of them is an expected outcome of a healthy run. A non-numeric
    # PROJECT_ORGANIZE_MAX_MOVES DOES raise, uncaught, out of .max_moves below, deliberately: see its
    # comment for why that stays a raise rather than a silent fallback.
    #
    # WHAT IT DOES NOT PROTECT AGAINST, so it is not mistaken for covered: it bounds VOLUME, not
    # correctness. There is no data loss to guard — node_id never changes (the port's stated
    # promise), so every attachment, BOM link and tag survives a move, and the move is reversible by
    # dragging the file back. That asymmetry is exactly why a count suffices here where a percentage
    # of the library was necessary there.
    def self.for_user(user:, dry_run: false, cap: nil)
      cap ||= max_moves
      projects = user.maker_projects.where.not(folder_node_id: nil).to_a

      # ONE query for the whole run's inbox, and it is what makes "checked before the first move"
      # true. An observer cannot decide this per project: the cap is a property of the run.
      #
      # THIS IS ALSO THE ONLY RunResult.new CALL IN THE METHOD, DELIBERATELY — an earlier version
      # short-circuited `projects.empty?` with a second, separately-worded construction that
      # hardcoded `status: :ok`. There was nothing to save: `parent_node_id: []` already makes
      # ActiveRecord short-circuit to a NullRelation (zero SQL), so the empty case flows through the
      # very same arithmetic below for free. Splitting it cost correctness for no speed — under a
      # negative cap, "zero projects" and "one project with an empty inbox" are the SAME real
      # situation (nothing to file) but disagreed on `status`, because 0 > cap is true in both yet
      # only one of them ever reached that comparison. One construction site cannot disagree with
      # itself. Pinned by the "zero-projects and zero-loose-files agree" test below.
      inbox_total = user.nodes.present
                        .where(kind: "file", parent_node_id: projects.map(&:folder_node_id)).count

      # A dry run never refuses — seeing this number is the entire reason to run one.
      refused = !dry_run && inbox_total > cap
      results = projects.map do |project|
        [ project, for_project(user:, project:, dry_run:, move: !refused) ]
      end

      RunResult.new(results:, status: refused ? :refused_too_many_moves : :ok, inbox_total:, cap:)
    end

    # Intake for the project that owns ONE node — the eager nudge's entry point, so a web upload
    # into a project folder attaches and files itself NOW rather than at the next sweep, which would
    # read as broken. Answers nil when the node is not under any project folder.
    #
    # A THIRD RETURN SHAPE, EASY TO MISS: if the node resolves to a project whose folder has since
    # been tombstoned, this answers a Result with status: :no_folder — NOT nil. Inherited from
    # for_project/live_folder rather than new here, but undocumented at this entry point until now.
    # A caller that only checks `result.nil?` would read a dead folder as "nothing to do" instead of
    # a Result it still needs to inspect.
    #
    # It sweeps the whole owning project rather than just this node. That is deliberate: the policy
    # is identical, the work is bounded by one project's inbox, and a single-file path would be a
    # second copy of the two steps — the thing this class exists to avoid having.
    #
    # IT APPLIES ITS OWN CAP — EAGER_MAX_MOVES / .eager_max_moves, NOT MAX_MOVES / .max_moves —
    # SCOPED TO THIS PROJECT'S OWN INBOX, the only count this entry point can honestly take, since
    # one node names one project and nothing here sees the rest of the user's library. See
    # EAGER_MAX_MOVES's comment for why this entry point needs a cap of its own rather than reusing
    # for_user's: this is the one caller that runs INSIDE a web request. What the scoping guarantees
    # is unchanged by that split: a SINGLE project's inbox cannot be drained past the cap one upload
    # at a time — each call re-checks that project's own count before moving anything, so a project
    # already sitting over the cap stays refused across repeated uploads into it.
    #
    # WHAT IT DOES NOT GUARANTEE: for_user's run-level total — and splitting the two caps apart
    # (Task 11 Part A) makes that MORE true, not less. for_node checks ITS PROJECT'S inbox against
    # EAGER_MAX_MOVES (a request-latency budget); for_user checks the WHOLE RUN's inbox against
    # MAX_MOVES (a per-run churn budget). Different counts, against different numbers, for different
    # reasons — neither tells you anything about the other. A project sitting at, say, 30 loose
    # files is over for_node's own cap (an eager upload into it only attaches) while nowhere near
    # for_user's 500 (the periodic sweep files it without complaint next time it runs). That is not
    # a bug to fix here: reproducing the whole-run total would mean scanning every other project on
    # every single upload, a cost this eager path is not meant to pay — and even if it did, MAX_MOVES
    # would be the wrong number to compare against, since the two methods are not protecting the
    # same resource.
    def self.for_node(user:, node:)
      project = owning_project(user, node)
      return nil unless project

      inbox = user.nodes.present.where(kind: "file", parent_node_id: project.folder_node_id).count
      cap = eager_max_moves
      if inbox > cap
        Rails.logger.warn("Maker::ProjectIntake: attaching but NOT filing #{project.slug} — " \
                          "#{inbox} loose files is over the #{cap}-file eager cap. The periodic " \
                          "sweep will file the rest on its own schedule; raise " \
                          "PROJECT_ORGANIZE_EAGER_MAX_MOVES to file more inline.")
      end
      for_project(user:, project:, move: inbox <= cap)
    end

    # The project whose library folder is an ancestor of `node`, or nil.
    #
    # Walks UP, one query per level. MAX_DEPTH IS WHAT MAKES TERMINATION CORRECT: it bounds the
    # iteration count, so a cycle in `nodes` cannot spin forever — fatal on SQLite, which has no
    # statement timeout.
    #
    # THE VISITED SET HERE IS A COST GUARD, NOT A CORRECTNESS ONE — and that is a narrower claim
    # than #subtree_files can make for its own visited set, worth stating precisely rather than
    # copying that comment over. `by_folder[current]` is checked BEFORE `seen.add?(current)` on
    # every iteration, so up to the first repeat both versions run identically — and a cycle only
    # ever re-presents a node already checked, so revisiting it can never surface a match that was
    # not already there. Given MAX_DEPTH already bounds the loop, the set cannot change the return
    # value for ANY input; what it changes is how many iterations a cycle costs before MAX_DEPTH
    # would have caught it anyway — measured at 3 queries with it against 33 without, on a 2-node
    # cycle. Worth keeping for that; not what stops the spin.
    #
    # CONTRAST #subtree_files, where its visited set DOES change the answer — though what it
    # protects against changed shape under Task 9a. Without it, a file reachable by two paths
    # would be collected into `files` twice, so #attach's `rows` would carry two identical hashes
    # into the SAME insert_all call. Before Task 9a's unique index that meant two stored rows for
    # one file; today insert_all's `unique_by:` skips the intra-batch duplicate the same way it
    # skips a genuinely concurrent one (verified directly: `insert_all([row, row], unique_by:
    # idx_maker_file_attachments_unique)` inserts one and silently skips the other) — so the
    # failure mode moved from a duplicated row to a merely-wasted collection pass. Still worth
    # preventing at the source rather than leaning on that. There is no equivalent double-count to
    # prevent here in #owning_project, either way: this walk stops at the first match, so the two
    # methods' visited sets are not doing the same job even though they look like the same idiom.
    #
    # One pluck up front means the loop compares against a hash rather than querying maker_projects
    # per level.
    def self.owning_project(user, node)
      by_folder = user.maker_projects.where.not(folder_node_id: nil)
                      .pluck(:folder_node_id, :id).to_h
      return nil if by_folder.empty?

      current = node.parent_node_id
      seen = Set.new
      MAX_DEPTH.times do
        return nil if current.blank?
        id = by_folder[current]
        return user.maker_projects.find_by(id:) if id
        return nil unless seen.add?(current)
        current = user.nodes.where(node_id: current).pick(:parent_node_id)
      end
      nil
    end

    # READ PER CALL, never frozen into a constant at boot. The refusal's log line names this
    # variable as the operator's way out, and a value fixed at boot makes that advice false inside a
    # running process and unreachable from a test — which is how an escape hatch rots shut. That is
    # Library::Reconciler#max_delete_pct's recorded lesson, and it applies verbatim. One ENV fetch
    # per run costs nothing.
    #
    # Integer() RAISES, UNCAUGHT, ON A NON-NUMERIC VALUE — inherited verbatim from
    # Reconciler#max_delete_pct, and deliberately not rescued: a malformed cap is an operator
    # configuration error that should be loud, not one this method should paper over with a default
    # the operator never chose. That is a different failure mode from .for_user's cap-trip status —
    # see its comment just above. Also inherited, also worth knowing before it surprises someone: a
    # zero-padded value parses as OCTAL (`Integer("0500") => 320`, not 500).
    def self.max_moves
      Integer(ENV.fetch("PROJECT_ORGANIZE_MAX_MOVES", MAX_MOVES.to_s))
    end

    # THE SAME MECHANICS AS .max_moves, FOR THE SAME REASONS — read per call (not frozen at boot),
    # Integer() raises uncaught on a malformed value (including the zero-padded-octal gotcha) —
    # not repeated verbatim here; see .max_moves' comment just above for the full argument, which
    # applies to this method unchanged.
    #
    # WHAT IS DIFFERENT IS WHICH CALLER READS WHICH VARIABLE, AND THAT IS THE WHOLE POINT: .for_user
    # (and .for_project) never read PROJECT_ORGANIZE_EAGER_MAX_MOVES, and .for_node never reads
    # PROJECT_ORGANIZE_MAX_MOVES. See EAGER_MAX_MOVES's comment for why collapsing the two would be
    # wrong, and project_intake_test.rb's independence tests for proof rather than assertion —
    # setting one variable and checking the OTHER method's behaviour is untouched.
    #
    # NAMED "eager", NOT "sync" — deliberately avoiding this codebase's other, precisely-defined
    # sense of that word (Capabilities#syncable? — "this backend IS the chunk/sync engine"). This
    # cap is orthogonal to that axis: it applies identically on all three backends and is gated only
    # on which CONTROLLER ACTION runs it (the eager nudge vs. the periodic sweep), never on which
    # backend is current. A reader primed by capabilities.rb could otherwise misread "sync" here as
    # backend-specific, which it is not.
    def self.eager_max_moves
      Integer(ENV.fetch("PROJECT_ORGANIZE_EAGER_MAX_MOVES", EAGER_MAX_MOVES.to_s))
    end

    def initialize(user:, project:, dry_run: false, move: true)
      @user = user
      @project = project
      @dry_run = dry_run
      @move = move
    end

    def call
      folder = live_folder
      return Result.new(attached: 0, moved: 0, skipped: 0, skips: [], plan: [], status: :no_folder) unless folder

      files = subtree_files(folder)
      # ATTACH FIRST, AND THE ORDER IS LOAD-BEARING. It inherits Maker::AttachToProject's rule that
      # the attach is the DURABLE half and the move is BEST-EFFORT: a collision or an unmounted NAS
      # must never cost the user a reference they asked for, and the reference is exactly as true
      # with the bytes still sitting at the root.
      attached = attach(files)
      return Result.new(attached:, moved: 0, skipped: 0, skips: [], plan: [], status: :ok) unless @move

      # THE INBOX IS THE ROOT, AND ONLY THE ROOT. Anything already in a subfolder is the user's
      # filing — including filing we would disagree with — and position is what records that, so
      # there is no state to keep. Re-filing a subfolder would fight the user every 15 minutes, and
      # on chunk each round of that fight is a changelog entry broadcast to every device.
      inbox = files.select { |n| n.parent_node_id == folder.node_id }
      moved, skipped, skips, plan = file_all(inbox)

      Result.new(attached:, moved:, skipped:, skips:, plan:, status: :ok)
    end

    private

    # READ, never Project#ensure_library_folder!.
    #
    # NOT AN OPTIMIZATION. Calling the ensure would make a SWEEP create `Projects/<slug>` for every
    # project that never had one, as a side effect of looking — which is the bug
    # Projects::AttachmentsController#relocate shipped ("the endpoint created Projects/<slug> as a
    # side effect of being POSTed to"), at library scale. The MoveConflicts concern reads rather
    # than calls for the same reason.
    def live_folder
      return nil if @project.folder_node_id.blank?
      @user.nodes.present.find_by(node_id: @project.folder_node_id, kind: "dir")
    end

    # Every live FILE in the folder's subtree, breadth-first — ONE QUERY PER LEVEL, not per node.
    #
    # A `dir` is descended into and a `file` is collected; a SYMLINK is neither, so it is ignored
    # rather than enqueued as a parent it cannot be. The visited set makes a cycle terminate instead
    # of spinning (see MAX_DEPTH), and it is checked before the kind so a cycle through a directory
    # cannot re-enqueue it.
    def subtree_files(folder)
      files = []
      frontier = [ folder.node_id ]
      seen = Set.new(frontier)
      MAX_DEPTH.times do
        break if frontier.empty?
        children = @user.nodes.present.where(parent_node_id: frontier).to_a
        frontier = []
        children.each do |node|
          next unless seen.add?(node.node_id)
          if node.file?
            files << node
          elsif node.dir?
            frontier << node.node_id
          end
        end
      end
      warn_if_truncated(frontier)
      files
    end

    # Fires ONLY when MAX_DEPTH ran out with directories still unexplored — a walk that simply
    # finished leaves `frontier` empty (the loop `break`s) and has nothing to report. See
    # MAX_DEPTH's comment for why a partial sweep must say so rather than reading as a complete one.
    def warn_if_truncated(frontier)
      return if frontier.empty?

      Rails.logger.warn(
        "project intake hit MAX_DEPTH=#{MAX_DEPTH} for project=#{@project.slug}: " \
        "#{frontier.size} #{'directory'.pluralize(frontier.size)} left unvisited, sweep incomplete"
      )
    end

    # Create the missing attachment rows in ONE statement.
    #
    # Bulk, not one SELECT + one INSERT per file, for the reason Maker::AttachToProject#attach_bundle
    # records: that loop cost 2 queries per file and ran inside a write transaction, so on the
    # SQLite self-host deployment the write lock was taken at the first INSERT and held to COMMIT —
    # one attach stalled every other writer in the app. A sweep is strictly larger than a bundle.
    #
    # insert_all SKIPS VALIDATIONS, so what they protected holds by construction, exactly as it does
    # there: role_for answers a member of ROLES for ANY input, node_id comes from a nodes row so it
    # is present, user and attachable are set right here, `position` has a DB default, and
    # created_at/updated_at are stamped by record_timestamps.
    #
    # TWO LAYERS HERE, DOING TWO DIFFERENT JOBS — NEITHER MAKES THE OTHER REDUNDANT (Task 9a):
    #
    #   1. THE PLUCK-AND-REJECT READ, still first, still a plain dedupe. It is what keeps the
    #      ORDINARY case cheap: a sweep that finds nothing new to attach sends no INSERT at all,
    #      and one that finds a few new files sends a small one — not a statement re-proposing
    #      every file the project already has and relying on the database to quietly discard most
    #      of it, every 15 minutes, forever. What it is NOT is a concurrency guard: a read followed
    #      later by a write, with nothing atomic tying the two together, cannot be one — any writer
    #      that attaches the same tuple in the gap between them still gets through.
    #
    #   2. `unique_by:`, naming the unique index the DedupeAndIndexMakerFileAttachments migration
    #      added on (user_id, attachable_type, attachable_id, node_id). THIS is what makes the
    #      write correct when a second writer lands that exact tuple in the gap #1 cannot close —
    #      the gap a PERIODIC, unserialized sweep (Task 9 wires this class into one) opens up in a
    #      way every earlier, user-triggered writer of this table never had to survive; see that
    #      migration's own header for why the index has to exist before this can work at all, and
    #      CLAUDE.md's count of this table's other five writers for who else can land in the gap.
    #      The conflicting row is skipped BY THE DATABASE rather than raising or duplicating.
    #      Naming the index explicitly — rather than leaving `unique_by:` unset — is not cosmetic:
    #      omitted, insert_all still defaults to `on_duplicate: :skip`, but resolves to a bare,
    #      UNTARGETED `ON CONFLICT DO NOTHING` that would silently swallow a violation of ANY
    #      unique constraint this table ever gains, not only this one. Naming it scopes the skip to
    #      exactly the tuple this method already knows it might be racing on. See
    #      project_intake_test.rb's race test for the SQL both forms actually emit.
    def attach(files)
      return 0 if files.empty?

      existing = @project.file_attachments.where(node_id: files.map(&:node_id))
                         .pluck(:node_id).to_set
      rows = files.reject { |n| existing.include?(n.node_id) }.map do |node|
        { user_id: @user.id, attachable_type: "Maker::Project", attachable_id: @project.id,
          node_id: node.node_id, role: Maker::FileAttachment.role_for(node.name) }
      end
      return rows.size if rows.empty? || @dry_run

      Maker::FileAttachment.insert_all(rows, unique_by: :idx_maker_file_attachments_unique)
      rows.size
    end

    # File each loose file, counting outcomes. Returns [moved, skipped, skips, plan].
    #
    # #place ANSWERS A STRING (the destination folder) ON SUCCESS OR A SYMBOL (the skip reason) ON
    # FAILURE — the two never collide, since Maker::ProjectFolders::ROLE_FOLDERS' values are all
    # folder-name strings and every reason below is a Symbol — so the dispatch here is a plain
    # `is_a?(Symbol)` rather than a second lookup that could disagree with #place about what
    # happened.
    #
    # FileLayer::FetchError IS RESCUED HERE, AROUND THE WHOLE LOOP — DELIBERATELY NOT INSIDE
    # #place, which says so in its own comment. A FetchError USUALLY means the LIBRARY is
    # unreachable (an unmounted share, an unreachable bucket) rather than anything about the one
    # file #place was looking at, so treating it as "stop, the rest would fail the same way" is
    # the right read most of the time. Catching it per file instead would produce N identical log
    # lines and report each as its own independent skip — reading to an operator like a library
    # full of individually-broken files rather than one unmounted NAS. Catching it once here turns
    # that into one abort and one line.
    #
    # THE DELIBERATE TRADE-OFF, NAMED RATHER THAN ASSUMED: "usually" is not "always", and two real
    # counterexamples exist today where a FetchError is about ONE file, not the library.
    # FileLayer::S3#move sends copy_source_if_match, and a source object that changed since the
    # scan indexed it raises Aws::S3::Errors::PreconditionFailed — an Aws::S3::Errors::ServiceError,
    # caught by the same rescue that maps every other S3 failure to FetchError — which is a fact
    # about that object, not the bucket (already pinned on the sibling #delete by
    # test/services/file_layer/s3_test.rb's "a concurrent overwrite makes the trash copy refuse
    # rather than trash the wrong bytes"). FileLayer::Share#move rescues EVERY SystemCallError into
    # FetchError with no library_present? disambiguation — unlike #read, #download and #undelete,
    # which all ask that question first — so an ENOENT on a file that vanished mid-sweep, or an
    # EACCES on one destination subfolder's permissions, also surfaces as FetchError.
    #
    # So this abort can occasionally fire on a genuinely per-file condition and mark a file that
    # would have succeeded :unavailable instead of moving it. THAT DOES NOT CHANGE THE DESIGN: the
    # sweep is idempotent and :unavailable persists nothing, so the cost of an over-eager abort is
    # a delayed retry on the NEXT sweep — not data loss, not a stuck file, nothing a user has to
    # undo. That is far cheaper than the mistake this design exists to avoid (N identical log
    # lines misreporting one unmounted NAS as N broken files), so accepting the rare false abort is
    # the safe direction — the same shape as Share#read's own trade-off (FetchError over NotFound
    # whenever a library looks unmounted).
    #
    # `processed` counts files #place has already returned an outcome for (moved OR skipped), so
    # `inbox[processed..]` is exactly "every file #place has not yet had a chance to answer for" —
    # and that INCLUDES the file that raised, since its outcome was never recorded.
    def file_all(inbox)
      moved = 0
      skips = []
      plan = []
      processed = 0
      inbox.each do |node|
        outcome = place(node)
        if outcome.is_a?(Symbol)
          skips << [ node.name, outcome ]
        else
          moved += 1
          plan << [ node.name, outcome ]
        end
        processed += 1
      end
      [ moved, skips.size, skips, plan ]
    rescue FileLayer::FetchError => e
      unreached = inbox[processed..]
      unreached.each { |node| skips << [ node.name, :unavailable ] }
      Rails.logger.warn(
        "Maker::ProjectIntake: aborting sweep for #{@project.slug} — library unreachable " \
        "(#{e.class}: #{e.message}) — #{moved} #{'file'.pluralize(moved)} filed before it " \
        "stopped, #{unreached.size} left unavailable#{unreached_note(unreached)}"
      )
      [ moved, skips.size, skips, plan ]
    end

    # A refusal should diagnose itself — Library::Reconciler#unreadable_note is the precedent this
    # copies, same first-3-then-ellipsis shape. The count alone says THAT files did not move, not
    # WHICH ones, and nothing reads Result.skips yet (Tasks 9-12 are the pending consumers), so
    # until one exists this log line is an operator's only way to find them.
    def unreached_note(unreached)
      return "" if unreached.empty?
      " (#{unreached.first(3).map { |n| n.name.inspect }.join(', ')}#{'...' if unreached.size > 3})"
    end

    # Move one file into its category folder. Answers the folder name, or the skip reason (a
    # Symbol) if it stayed put — see #file_all for why those two shapes never collide.
    #
    # IT ASKS Maker::AttachToProject#refusal_for FIRST, and that is this method's most important
    # line. Those three rules (:not_a_file, :model_bundle, :attached_elsewhere) are policy about
    # where a file may be moved to, and #refusal_for is PUBLIC precisely so a second door can ask
    # rather than reimplement. The class's own header records what happens otherwise: when
    # #relocate was added it called the move BELOW all three, and silently pulled one file out of a
    # model's bundle folder while reporting success. This is the third door.
    #
    # FetchError IS DELIBERATELY NOT RESCUED HERE — every file that hits it goes through
    # #file_all's whole-loop abort instead of a per-file skip. #file_all's own comment has the
    # full reasoning, including the two known cases where a FetchError is actually about one file
    # rather than the library, and why the design accepts that cost. Adding it to this list would
    # make an unmounted NAS log once per file and pretend each one was an independent skip.
    #
    # :not_found AND :unsupported STAY SPLIT, RATHER THAN COLLAPSING INTO ONE :unavailable THE WAY
    # AttachToProject#move DOES — and that is not an inconsistency between the two. #move collapses
    # FetchError/NotFound/UnsupportedOperation together because all three there mean "try again
    # later": it words a single sentence ("couldn't move it") for a flash message, and FetchError
    # sits in that same bucket. `skips` is not a flash message, and the extra detail is worth
    # keeping there: :unsupported never succeeds on retry (a directory, or a name the backend
    # refuses outright) while :not_found is a race or an out-of-band change that might. An operator
    # reading `skips` benefits from that distinction; a flash message does not.
    #
    # InvalidName IS RESCUED, AND THE EARLIER VERSION OF THIS COMMENT SAYING IT HAD "no producer on
    # this path" WAS WRONG — reproduced (see project_intake_test.rb): `Node` validates only
    # presence (app/models/node.rb), so a name #leaf! would reject can already be sitting in
    # `nodes` from a door that never ran #leaf! at all — Library::Reconciler#create_or_revive!
    # writes File.basename(rel_path) verbatim, V1::CommitsController feeds params[:name] into
    # Sync::Commit.begin unchecked, and FileLayer::Share#leaf! is looser (no length or backslash
    # check) than MoveNode#leaf!. It is not adversarial input either: MoveNode::MAX_NAME_BYTES is
    # 255 BYTES because NTFS counts UTF-16 units, so an ordinary CJK filename, legal on the Windows
    # client that made it, is enough — and it arrives via a normal sync push. One unmovable name
    # must not abort the sweep over the rest of the project's library, which is exactly what an
    # uncaught InvalidName did. Rescuing it here is the intended use of the named subclass, not a
    # widening of it: MoveNode's own header says InvalidName exists so "a caller that wants to
    # answer 'that name is not allowed' can now do so WITHOUT also swallowing arity drift" — and
    # AttachToProject#move, one file away, already treats it as an ordinary :bad_name outcome
    # rather than letting it raise.
    #
    # BARE ArgumentError STAYS OUT, and that is a different rule, not a loosened version of this
    # one. AttachToProject#move records what a too-wide rescue costs: it caught bare ArgumentError
    # until a review drove the consequence that arity drift, a kwarg rename, or a nil reaching
    # File.extname all became a flash message with a green suite. InvalidName is a NAMED subclass
    # created for exactly this purpose; ArgumentError itself is not.
    def place(node)
      refusal = attach_policy.refusal_for(node)
      return refusal if refusal

      dest = Maker::ProjectFolders.folder_for(node.name)
      # Before ensure_path!, so a dry run creates no folder — the reason it is a `dry run` and not
      # a `report`.
      return dest if @dry_run

      target = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", @project.slug, dest ])
      Maker::MoveNode.call(@user, node:, new_parent_node_id: target.node_id)
      dest
    rescue Maker::MoveNode::Collision => e
      # :conflict, matching Maker::AttachToProject#move — one file away, rescuing the same
      # exception for the same reason. Two names for one condition in sibling classes is
      # exactly the drift this codebase works to avoid.
      skip(node, :conflict, e)
    rescue FileLayer::NotFound => e
      skip(node, :not_found, e)
    rescue FileLayer::UnsupportedOperation => e
      skip(node, :unsupported, e)
    rescue Maker::MoveNode::InvalidName => e
      skip(node, :bad_name, e)
    end

    # Log one skipped file and answer the reason, so #place can end every rescue clause with a
    # single expression. WARN, not info: every other per-item skip in the library-scan family warns
    # for exactly this shape — an ordinary, individually-unsurprising thing that recurs forever —
    # Library::Scanner for an unreadable dir/file or an invalid-encoding name, S3Observer for a
    # permanently un-indexable key, Reconciler when it cannot hash. There is no precedent in this
    # codebase for logging nothing here, and this is not the genuinely-routine-OS-clutter case that
    # would justify one. e.message is included, not just e.class: FileLayer::NotFound alone is
    # raised with several different messages for different causes (AttachToProject#log_failure
    # includes it for the same reason), and the class name alone cannot tell them apart later.
    def skip(node, reason, error)
      Rails.logger.warn("Maker::ProjectIntake: left #{node.name.inspect} at the root of " \
                        "#{@project.slug} — #{error.class}: #{error.message}")
      reason
    end

    # Memoized: #refusal_for runs per file and the object holds no per-file state.
    def attach_policy
      @attach_policy ||= Maker::AttachToProject.new(user: @user, project: @project)
    end
  end
end
