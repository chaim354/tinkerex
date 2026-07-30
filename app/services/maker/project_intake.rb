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

    # The default ceiling on files filed in one run. See .for_user for why it is an absolute count
    # rather than a percentage.
    MAX_MOVES = 500

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
    # The dedupe is a pluck-and-reject rather than find_or_create_by per file for the same reason,
    # and it is load-bearing: maker_file_attachments has NO uniqueness index, so a second row for
    # one node is storable and would render the same file twice on the project page.
    def attach(files)
      return 0 if files.empty?

      existing = @project.file_attachments.where(node_id: files.map(&:node_id))
                         .pluck(:node_id).to_set
      rows = files.reject { |n| existing.include?(n.node_id) }.map do |node|
        { user_id: @user.id, attachable_type: "Maker::Project", attachable_id: @project.id,
          node_id: node.node_id, role: Maker::FileAttachment.role_for(node.name) }
      end
      return rows.size if rows.empty? || @dry_run

      Maker::FileAttachment.insert_all(rows)
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
