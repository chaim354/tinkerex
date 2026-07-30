module Maker
  # Make the catalog agree with what is in a project's library folder: attach every file under it,
  # and file whatever is loose at its root into a category subfolder.
  #
  # WHY A SWEEP RATHER THAN A HOOK ON EVERY WRITE. A file can reach `Projects/<slug>/` seven ways —
  # FilesController#create (share/s3), #finalize_upload (chunk), Library::Reconciler (the scan),
  # Sync::Commit#finalize (a device push), Maker::Addons::LibraryOutput, Maker::MoveNode, and a
  # trash restore. There is no single funnel. Hooking each is seven sites that must agree, and a
  # SEVENTH door silently skips the rule — the failure this repo has recorded more than once
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
    # the rake task can print source -> destination without a second traversal.
    Result = Data.define(:attached, :moved, :skipped, :plan, :status)

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

    def initialize(user:, project:, dry_run: false, move: true)
      @user = user
      @project = project
      @dry_run = dry_run
      @move = move
    end

    def call
      folder = live_folder
      return Result.new(attached: 0, moved: 0, skipped: 0, plan: [], status: :no_folder) unless folder

      files = subtree_files(folder)
      # ATTACH FIRST, AND THE ORDER IS LOAD-BEARING. It inherits Maker::AttachToProject's rule that
      # the attach is the DURABLE half and the move is BEST-EFFORT: a collision or an unmounted NAS
      # must never cost the user a reference they asked for, and the reference is exactly as true
      # with the bytes still sitting at the root.
      attached = attach(files)
      return Result.new(attached:, moved: 0, skipped: 0, plan: [], status: :ok) unless @move

      # THE INBOX IS THE ROOT, AND ONLY THE ROOT. Anything already in a subfolder is the user's
      # filing — including filing we would disagree with — and position is what records that, so
      # there is no state to keep. Re-filing a subfolder would fight the user every 15 minutes, and
      # on chunk each round of that fight is a changelog entry broadcast to every device.
      inbox = files.select { |n| n.parent_node_id == folder.node_id }
      moved, skipped, plan = file_all(inbox)

      Result.new(attached:, moved:, skipped:, plan:, status: :ok)
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

    # File each loose file, counting outcomes. Returns [moved, skipped, plan].
    def file_all(inbox)
      moved = 0
      skipped = 0
      plan = []
      inbox.each do |node|
        dest = place(node)
        if dest
          moved += 1
          plan << [ node.name, dest ]
        else
          skipped += 1
        end
      end
      [ moved, skipped, plan ]
    end

    # Move one file into its category folder. Answers the folder name, or nil if it stayed put.
    #
    # IT ASKS Maker::AttachToProject#refusal_for FIRST, and that is this method's most important
    # line. Those three rules (:not_a_file, :model_bundle, :attached_elsewhere) are policy about
    # where a file may be moved to, and #refusal_for is PUBLIC precisely so a second door can ask
    # rather than reimplement. The class's own header records what happens otherwise: when
    # #relocate was added it called the move BELOW all three, and silently pulled one file out of a
    # model's bundle folder while reporting success. This is the third door.
    #
    # FetchError IS DELIBERATELY NOT RESCUED HERE — it means the library is unreachable, so every
    # remaining move would fail identically, and #file_all's caller turns it into one abort rather
    # than N identical log lines. Adding it to this list would make an unmounted NAS log once per
    # file and pretend each one was an independent skip.
    #
    # InvalidName IS DELIBERATELY ABSENT TOO. The name comes from an existing `nodes` row, which
    # #leaf! has already vetted — there is no producer on this path. Maker::AttachToProject#move
    # records what a too-wide rescue costs: it caught bare ArgumentError until a review drove the
    # consequence that arity drift, a kwarg rename, or a nil reaching File.extname all became a
    # flash message with a green suite.
    def place(node)
      return nil if attach_policy.refusal_for(node)

      dest = Maker::ProjectFolders.folder_for(node.name)
      # Before ensure_path!, so a dry run creates no folder — the reason it is a `dry run` and not
      # a `report`.
      return dest if @dry_run

      target = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", @project.slug, dest ])
      Maker::MoveNode.call(@user, node:, new_parent_node_id: target.node_id)
      dest
    rescue Maker::MoveNode::Collision, FileLayer::NotFound, FileLayer::UnsupportedOperation => e
      # INFO, not warn: each of these is an ordinary thing that happens to a user's library, and the
      # per-project summary line is where the operator-visible count lives. A warn per file would
      # make a single permanently-colliding name noise every 15 minutes forever.
      Rails.logger.info("Maker::ProjectIntake: left #{node.name.inspect} at the root of " \
                        "#{@project.slug} — #{e.class}")
      nil
    end

    # Memoized: #refusal_for runs per file and the object holds no per-file state.
    def attach_policy
      @attach_policy ||= Maker::AttachToProject.new(user: @user, project: @project)
    end
  end
end
