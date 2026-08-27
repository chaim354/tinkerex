module Maker
  module Git
    # ONE PROJECT'S COMMIT PASS: gather what has SETTLED, decide content vs pointer, commit,
    # consolidate, persist.
    #
    # THE ORDER IS LOAD-BEARING -- commit, then consolidate, then persist. Persisting before
    # consolidating pushes LOOSE OBJECTS into the library, which is the 11,287-request hydrate
    # Repo#consolidate! exists to prevent, and they would then have to be deleted again. On share
    # `persist!` is a no-op, so nothing there can ever show the ordering is wrong; the guard for it
    # is the hydrated (FakeS3) test in this class's suite.
    #
    # ALL THREE BACKENDS, BY TWO ROUTES TO ONE REL -- see #paths_for. Every committed path was
    # derived from `storage_path` until 2026-08-27, which left the whole feature INERT on
    # `chunk_remote`, whose nodes carry no storage_path at all: #paths_for yielded nothing and
    # #call! returned nil before touching the repository. Nothing errored, and that is what made it
    # the worst available shape of gap -- `chunk_remote` is the BASE deployment (§7), so "history
    # everywhere except the product's primary destination" would have been found late, by someone
    # wondering why a project had no versions.
    class ProjectCommit
      # A cap on the DESCENT, for the same reason Maker::AttachToProject::MAX_ANCESTOR_WALK caps
      # the walk in the other direction and with the same argument: `parent_node_id` is a plain
      # string column with no foreign key, so a cycle is representable, and an uncapped descent is
      # an infinite loop inside an unattended 15-minute sweep. Same number, deliberately -- 64 is
      # far past any real library depth, and two different caps on the same tree would be two
      # different claims about how deep a library can get.
      MAX_DEPTH = Maker::AttachToProject::MAX_ANCESTOR_WALK

      # `cache_root:` IS A SEAM WITH A PRODUCTION-SHAPED REASON, not a test convenience -- it is
      # Repo's own, forwarded, because this class constructs the Repo and a caller otherwise cannot
      # reach it. Repo keys its cache by user and project ID, and IDS ARE NOT UNIQUE OVER TIME
      # inside a transactional suite: every test rolls back, so the next one mints user 1 /
      # project 1 again and hydrates the PREVIOUS run's repository. Measured while writing this --
      # a pass that had just committed an identical tree returned nil, because `commit!` correctly
      # refused to re-commit a tree a leftover `tmp/git-cache/1/1` already had. Production never
      # reuses an ID, so nil (Repo's default) is right there.
      def initialize(project:, scan_started_at:, cache_root: nil)
        @project = project
        @user = project.user
        @scan_started_at = scan_started_at
        @cache_root = cache_root
      end

      # SETTLE DETECTION. A node is eligible only if it has NOT been touched since this scan
      # started -- meaning it survived a full quiet interval.
      #
      # WHY `updated_at` RATHER THAN A NEW COLUMN: Library::Reconciler already writes the node on
      # every in-place content change (`node.update!(size:, mtime:, content_hash:)`). A file still
      # being written therefore gets a fresh `updated_at` on each scan that observes a different
      # size, and never settles until the writer stops. The schema already carries the property.
      #
      # THE COST IS ONE TICK OF LATENCY, DELIBERATELY. A file saved at T is committed after the
      # scan FOLLOWING the one that first observed it -- up to 30 minutes rather than 15. That is
      # the price of never committing a truncated 3MF mid-write as a legitimate version, and it is
      # worth paying: a late commit is invisible, a corrupt one is permanent and looks entirely
      # normal afterwards.
      def eligible_nodes
        folder = @user.nodes.present.find_by(node_id: @project.folder_node_id)
        return Node.none unless folder

        @user.nodes.present
             .where(parent_node_id: directory_ids_at_or_under(folder))
             .where(kind: "file")
             .where(updated_at: ...@scan_started_at)
      end

      # Returns the new commit oid, or nil when there was nothing to record.
      #
      # NOTHING IS OPENED UNTIL THERE IS SOMETHING TO COMMIT, and that ordering is not tidiness.
      # `Repo#hydrate!` initialises the repository, which in place CREATES `.git` in the project
      # folder -- and an empty `.git` is not inert, it is the MARKER Maker::AttachToProject reads
      # to decide whether §14f's intake filing applies. Minting one for a project that has nothing
      # settled would switch that off silently, at the next scan, nowhere near this call. So the
      # paths are gathered FIRST (which needs no repository) and an empty set returns early.
      def call!
        nodes = eligible_nodes.to_a
        return nil if nodes.empty?

        paths = paths_for(nodes)
        return nil if paths.empty?

        repo = Repo.for(@project, cache_root: @cache_root)
        repo.hydrate!
        oid = repo.commit!(paths:, message: commit_message(paths))
        # nil means the tree is identical to HEAD's -- the ordinary answer for a quiet project, and
        # there is then nothing loose to pack and nothing new to push.
        return nil unless oid

        repo.consolidate!
        repo.persist!
        oid
      end

      private

      # `{ "cad/body.step.ptr" => "version tinkerex/v1\n..." }` -- repository-relative path to the
      # blob body that goes in at it.
      #
      # TWO ROUTES TO ONE REL, AND `storage_path` IS AUTHORITATIVE WHEREVER IT AND THE FOLDER'S
      # BOTH EXIST. It is what the SCAN OBSERVED and what a share/s3 read resolves against -- the
      # bytes are literally at that path -- so deriving the rel from anything else there would file
      # real content into the repository under a name the store does not agree with. The parent
      # chain is what the MIRROR says, and on `chunk_remote` it is all there is (§14a).
      #
      # THE SECOND ROUTE IS A FALLBACK, NOT A CROSS-CHECK, and the difference is worth saying: a
      # storage_path that does not sit under the folder's own prefix is still DROPPED rather than
      # re-derived from the tree, which is what the guard below has always done and is exactly what
      # a fallback there would undo. Where a node carries an observed path, that path is the answer
      # or the node does not go in.
      def paths_for(nodes)
        folder = @user.nodes.find_by(node_id: @project.folder_node_id)
        return {} if folder.nil?

        prefix = folder.storage_path.presence && "#{folder.storage_path}/"

        nodes.each_with_object({}) do |node, out|
          rel = relative_path(node, folder, prefix)
          # A ROW THAT CANNOT BE PLACED UNDER THE PROJECT FOLDER IS DROPPED, WHICHEVER ROUTE ASKED.
          # The descent found it beneath the project folder, but the path it claims is elsewhere;
          # committing it anyway would put it in the repository at an absolute-looking path
          # ("Elsewhere/stray.md"), or -- if the prefix were merely stripped where it happened to
          # match -- at a path belonging to some other project's folder. Neither is recoverable by
          # a later pass, because git keeps whatever it was told.
          next if rel.nil?

          case Tracking.mode_for(node.name)
          when :content
            content = content_of(node)
            out[rel] = content unless content.nil?
          when :pointer
            out["#{rel}.ptr"] = Tracking.pointer_for(node)
          end
        end
      end

      # THE OBSERVED PATH WINS WHERE THERE IS ONE, AND THE CHOICE IS PER NODE RATHER THAN PER
      # BACKEND. This class must not ask which backend it is on -- `is_a?(FileLayer::Share)` is the
      # spelling §14b has the scar about -- and it does not have to: a node either carries a path
      # the store observed or it does not, and that is the whole question.
      def relative_path(node, folder, prefix)
        return rel_from_storage_path(node, prefix) if prefix && node.storage_path.present?

        rel_from_tree(node, folder)
      end

      def rel_from_storage_path(node, prefix)
        path = node.storage_path.to_s
        return nil unless path.start_with?(prefix)

        rel = path.delete_prefix(prefix)
        rel.presence
      end

      # THE PROJECT-RELATIVE REL, DERIVED FROM Maker::LibraryTree'S OUTPUT RATHER THAN BY A SECOND
      # ANCESTOR WALK. LibraryTree is §14k's ONE definition of where a node sits in the library --
      # cycle guard, memo and the memo's whole-walk write included -- but it answers
      # LIBRARY-ROOT-relative and a repository wants project-folder-relative, so the folder's own
      # path is SUBTRACTED from the parent's here. Re-walking parents to get the shorter answer
      # directly would be a second spelling of the same climb, which is the drift §14d keeps
      # warning about; one subtraction is not.
      #
      # NIL IS LibraryTree'S ANSWER FOR A BROKEN CHAIN, AND BOTH nil CHECKS BELOW ARE THE SENTINEL
      # CHECK ITS HEADER DEMANDS OF EVERY CALLER. Unchecked it fails QUIETLY -- `:broken` answers
      # `.name` too, so half a chain becomes an ordinary-looking path segment -- and quiet here
      # means a file committed at a wrong path, which git then keeps forever. A file missed this
      # tick is picked up by the next one once the mirror catches up: §14a's own trade, a
      # recoverable refusal over a silent permanent wrong answer.
      #
      # A BROKEN CHAIN ABOVE THE PROJECT FOLDER DROPS THE WHOLE PROJECT FOR THAT TICK, not just one
      # file, because `base` is nil for every node in it. That is stated rather than worked around:
      # descending from the folder to rebuild the rels would sidestep it and cost exactly the
      # second walk this method exists to avoid.
      def rel_from_tree(node, folder)
        base = tree.path_for(folder.node_id)
        parent_path = tree.path_for(node.parent_node_id)
        return nil if base.nil? || parent_path.nil?
        return nil unless parent_path == base || parent_path.start_with?("#{base}/")

        dir_rel = parent_path.delete_prefix(base).delete_prefix("/")
        name = node.name.to_s
        return nil if name.empty?

        dir_rel.empty? ? name : "#{dir_rel}/#{name}"
      end

      # ONE INDEX PER PASS, BUILT ONLY IF SOMETHING ASKS FOR IT. It costs one pluck of this user's
      # live DIRECTORY rows, so a share or s3 pass -- where every node carries an observed path --
      # never builds it at all, and a chunk_remote pass builds it once for the project instead of
      # querying parents per file. A sweep over many projects pays it once per project; sharing one
      # index across a whole sweep is a real optimisation, and it would be an injected argument
      # rather than anything global.
      def tree = @tree ||= Maker::LibraryTree.new(@user)

      # A FILE THAT VANISHED OR IS UNREACHABLE MID-SWEEP IS SKIPPED, NOT FATAL. The next tick picks
      # it up; failing the whole pass would stall every other project's history behind one bad
      # file. The rescue names the PORT'S OWN vocabulary and nothing wider -- a broken adapter or a
      # bug in here must still be loud, and `rescue => e` would swallow both.
      def content_of(node)
        FileLayer.current.read(@user, node_id: node.node_id)
      rescue FileLayer::NotFound, FileLayer::FetchError
        nil
      end

      def commit_message(paths)
        "Observed #{paths.size} file#{'s' unless paths.size == 1} at #{Time.current.utc.iso8601}"
      end

      # Every DIRECTORY id at or beneath the project folder, so one final query can ask for their
      # file children. DIRECTORIES ONLY: a file is never a parent, so carrying file ids here would
      # put every file in the project into an IN list that asks about nothing.
      #
      # `- seen` IS THE CYCLE GUARD AND THE CAP IS THE BACKSTOP; neither replaces the other. The
      # subtraction stops a cycle spinning between levels it has already visited, and the cap stops
      # anything a subtraction cannot see (an adversarially deep chain) from running unbounded.
      #
      # THE `.git` MARKER IS NOT DESCENDED INTO. On share and s3 nothing beneath it is observed, so
      # there are no rows to find; on chunk_remote the desktop client syncs `.git` and there are.
      # Walking in would offer the repository its own internals as content to commit. Excluded via
      # Node.outside_repo_metadata so `.git` keeps being spelled in exactly one place
      # (Library::RepoMetadata::DIR_NAME).
      def directory_ids_at_or_under(folder)
        ids = [ folder.node_id ]
        seen = []
        MAX_DEPTH.times do
          break if ids.empty?

          seen.concat(ids)
          ids = @user.nodes.present.outside_repo_metadata
                     .where(parent_node_id: ids, kind: "dir").pluck(:node_id) - seen
        end
        seen
      end
    end
  end
end
