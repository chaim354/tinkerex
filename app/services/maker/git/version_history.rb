module Maker
  module Git
    # "What versions does this file have, and can I actually see each one?"
    #
    # TWO KINDS OF VERSION, AND THE DIFFERENCE IS VISIBLE TO THE USER:
    #
    #   content  the bytes are IN the repo. Always available, on every backend, forever.
    #   pointer  the repo holds a content hash. The bytes resolve only where the store kept them:
    #            the sync server on chunk_remote, bucket versioning on s3, and NOWHERE on share,
    #            where the maker's Finder overwrite destroyed them before this app ever saw them.
    #
    # THE UNAVAILABLE CASE IS RENDERED, NOT HIDDEN. A greyed "not kept" tile is the truth; omitting
    # the version tells the user their file has less history than it does, and quietly. This is the
    # same choice §14a makes for an unmounted share: never let a recoverable-looking state and a
    # permanent one render identically.
    #
    # `available` IS A MEMBER, NOT AN IVAR SET AFTER CONSTRUCTION. A Data instance is FROZEN, so
    # the obvious `def available!(v) = (@available = v; self)` raises FrozenError at runtime -- and
    # only on the path that actually renders a version list, which is late to find out.
    Version = Data.define(:oid, :message, :time, :author, :mode, :content_token, :path, :available) do
      def pointer? = mode == :pointer
      def content_available? = available
    end

    class VersionHistory
      # HOW FAR BACK ONE PAGE OF HISTORY LOOKS. A cap rather than the whole walk because every
      # commit costs a tree lookup below; a project the sweep has been committing for a year has
      # thousands, and a version list nobody scrolls does not justify walking all of them.
      LOG_LIMIT = 500

      # `cache_root:` IS Repo'S OWN SEAM, FORWARDED, for the reason Repo states: the cache is keyed
      # by user and project ID and IDs REPEAT inside a transactional suite, so a shared default
      # lets one test hydrate an earlier one's repository. Production never reuses an ID, so nil
      # (Repo's default) is right there.
      def initialize(project:, cache_root: nil)
        @project = project
        @user = project.user
        @repo = Repo.for(project, cache_root:)
      end

      # `path` is the file's path within the project folder, WITHOUT the `.ptr` suffix -- callers
      # hold a real filename, not a storage detail.
      #
      # THE EARLY RETURN IS NOT AN OPTIMISATION. `hydrate!` MINTS `.git`, and that directory is the
      # marker `Maker::AttachToProject` reads to decide whether §14f's intake filing applies to a
      # folder. Opening History on a project the sweep has never committed would therefore switch
      # that filing off, permanently, from a READ -- the same hazard `ProjectCommit#call!` returns
      # early to avoid. `Maker::GitRepo` is an index rather than a source of truth (see that model),
      # which is exactly the right strength here: this is a "is there anything to show" question,
      # never a destructive decision.
      def for_path(path)
        return [] if never_committed?

        @repo.hydrate!
        mode = Tracking.mode_for(File.basename(path))
        # THE `.ptr` SUFFIX IS A STORAGE DETAIL AND IS APPLIED HERE, ONCE. `Maker::Git::ProjectCommit`
        # commits a pointer at `"#{rel}.ptr"`; a caller holding a filename must not have to know.
        repo_path = mode == :pointer ? "#{path}.ptr" : path

        rows = commits_touching(repo_path).map do |commit, blob|
          [ commit, mode == :pointer ? blob[/^oid (\S+)$/, 1] : commit.oid ]
        end
        kept = mode == :pointer ? retained_tokens(rows.map(&:last)) : nil

        rows.map do |commit, token|
          Version.new(oid: commit.oid, message: commit.message, time: commit.time,
                      author: commit.author, mode:, content_token: token, path:,
                      available: mode == :content || kept.include?(token))
        end
      end

      private

      def never_committed? = Maker::GitRepo.find_by(project: @project)&.head_oid.blank?

      # WHICH OF THESE TOKENS CAN THE STORE STILL RESOLVE? Never asks git -- a pointer's whole point
      # is that the bytes are not in the repo -- and NEVER ASKS THE NETWORK, which is the load-
      # bearing half. This runs while a page renders a version list, and a remote check would put
      # one WAN round trip per version into a metadata path (§2, §14a): the same cost the local
      # mirror exists to remove, paid per row instead of once every two minutes.
      #
      # SO IT ANSWERS FROM THE TWO LOCAL TABLES THAT RECORD WHAT THE STORE HOLDS, and asks NO
      # backend question -- no capability, and above all no `is_a?(FileLayer::Share)`, the spelling
      # §14b records as having made `Library::ScanJob` answer false for S3 and silently never index
      # the library. Each arm is simply empty on the backends it does not describe:
      #
      #   nodes.content_hash          written by Library::Reconciler (share) and FileLayer::S3, and
      #                               carried into the pointer body VERBATIM by Tracking#pointer_for
      #                               -- so equality here is exact, not a heuristic.
      #   remote_manifest_chunks      written ONLY by ChunkRemote::ChangelogSync, keyed by the
      #                               version_id that IS a chunk_remote content_token (§5's "one
      #                               column, two meanings"). `ChunkRemote#read(content_token:)`
      #                               resolves bytes through this table and nothing else, and the
      #                               manifest cannot be re-asked for -- POST /v1/chunks/download
      #                               presigns hashes it is GIVEN, it does not answer "what chunks
      #                               does version X have". So a version with no mirrored manifest
      #                               is unreadable here whatever the server still holds.
      #
      # WHAT THIS CANNOT TRUTHFULLY ANSWER, STATED RATHER THAN IMPLIED:
      #
      #   share         EXACT. Share keeps no history at all (§14a, current-state only), so a token
      #                 that is no live node's content is gone and there is nothing else to ask.
      #   chunk_remote  NECESSARY, NOT SUFFICIENT. A mirrored manifest means the read has chunks to
      #                 name; the sync server may since have GC'd them. Confirming costs a POST per
      #                 version, so the residual failure is a version that renders available and
      #                 404s on click -- recoverable, and far better than the reverse.
      #   s3            CONSERVATIVE, AND IT UNDERSTATES A VERSIONED BUCKET. Where the user turned
      #                 bucket versioning on, superseded objects DO survive -- but this app records
      #                 no object versionId anywhere and cannot map a content hash to one, so the
      #                 only truthful check is ListObjectVersions: a billed WAN request per version
      #                 per render. A superseded s3 version therefore renders "not kept", which is
      #                 the safe direction of wrong. Closing it means recording versionIds at write
      #                 time, not adding a call here.
      #
      # TWO QUERIES, CONSTANT IN N, for the same reason `stat_all` is a port verb: this is asked
      # once per version list, and a per-version `exists?` is the N+1 §14e's page query budgets
      # exist to catch. Both are index-covered -- `index_nodes_on_user_id_and_content_hash`, and
      # `index_remote_manifest_chunks_on_version_and_seq`'s (user_id, version_id) prefix.
      def retained_tokens(tokens)
        wanted = tokens.compact_blank.uniq
        return Set.new if wanted.empty?

        Set.new(@user.nodes.present.where(content_hash: wanted).pluck(:content_hash)) |
          Set.new(::RemoteManifestChunk.where(user_id: @user.id, version_id: wanted)
                                       .distinct.pluck(:version_id))
      end

      # ONE WALK, KEEPING ONLY THE COMMITS WHERE THIS PATH'S BLOB CHANGED FROM ITS PARENT'S.
      # A commit that touched other files is not a version of this one, and listing it would make
      # every file look like it changed on every scan -- which `Repo#commit!` guarantees would
      # happen, because it carries HEAD's whole tree forward, so every other blob is byte-identical
      # in every commit.
      #
      # THE COMPARISON IS AGAINST THE OLDER NEIGHBOUR, AND GETTING THAT BACKWARDS IS SILENT. A
      # single rolling `seen` set while walking newest-first compares each commit against the
      # NEWER one, which still yields the right COUNT and picks the wrong COMMIT out of every run
      # of identical blobs -- the newest that happens to carry the content rather than the one that
      # introduced it. The version list then shows the right number of versions dated and messaged
      # wrongly, which no count assertion can see. Measured: with "notes v1" followed by an
      # unrelated commit, that shape reported one version titled "unrelated".
      #
      # LINEAR BY CONSTRUCTION, so the next entry in the walk IS the parent: one ref, one writer,
      # one pass per project at a time (docs/invariants/git-tracked-projects.md), and this app
      # never merges. A file that went A -> B -> A keeps all three commits, which is correct --
      # each of them did change the file.
      #
      # THE OLDEST ENTRY IN THE WINDOW IS ALWAYS KEPT, because its parent is past LOG_LIMIT and
      # unobserved. That is the honest direction of the truncation: a real version is shown even
      # where we cannot prove it introduced the file, rather than a file's first version vanishing
      # off the end of the page.
      def commits_touching(repo_path)
        observed = @repo.log(limit: LOG_LIMIT).map { |commit| [ commit, blob_or_nil(commit, repo_path) ] }

        observed.each_with_index.filter_map do |(commit, blob), i|
          next if blob.nil? || blob == observed[i + 1]&.last

          [ commit, blob ]
        end
      end

      # Not in this commit's tree at all -- the file did not exist yet, or was removed.
      def blob_or_nil(commit, repo_path)
        @repo.blob_at(oid: commit.oid, path: repo_path)
      rescue FileLayer::NotFound
        nil
      end
    end
  end
end
