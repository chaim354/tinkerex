module Maker
  module Git
    # A project's git repository: hydrate from the library, commit, consolidate into a pack,
    # persist back.
    #
    # THE CACHE IS EPHEMERAL AND THAT IS LOAD-BEARING, NOT AN OPTIMISATION. Durable state on an app
    # volume was rejected outright; the library is the only durable store, so git data lives beside
    # the files it describes in the user's own storage. Anything this class leaves in the cache and
    # does not persist IS LOST, and must be treated as lost.
    #
    # ON SHARE THE CACHE STEP IS SKIPPED, and the port says so rather than this class guessing:
    # `FileLayer#repo_data_dir` answers a real directory when the backend's repo data can be
    # operated on IN PLACE, and nil otherwise. It is deliberately NOT `is_a?(FileLayer::Share)` --
    # that class check is the one §14b records as having made Library::ScanJob answer false for S3
    # and silently never index the library.
    #
    # THE IN-PLACE PATH IS WHY THE MAKER GETS `git log` IN FINDER, which is the strongest single
    # argument for git over a bespoke version store -- and it is a real promise this class has to
    # keep, not a side effect. Three things are needed for it and each was measured, not assumed:
    # HEAD must be repointed at the branch we actually commit to (libgit2's `init_at` writes
    # `refs/heads/master` while we use `main`, so without this `git log` answers "your current
    # branch 'master' does not have any commits yet" while the history sits there perfectly
    # intact); `core.bare` must be false so the project folder is the repository's work tree; and
    # the index must be written, or `git status` reports every tracked file as DELETED -- which to
    # a maker looking at their own folder reads as "the app deleted my files".
    class Repo
      # The marker that says this repo is OURS. A git config key rather than a database column,
      # because it has to travel WITH the repository: a restore, a re-hydrate, or a maker copying
      # their library to a new NAS all keep it, and a maker who drops their OWN repo into Projects/
      # never acquires it. `maker_git_repos` is an index over this, never the source of truth.
      MANAGED_CONFIG_KEY = "tinkerex.managed".freeze
      BRANCH = "refs/heads/main".freeze

      # WHERE THE EPHEMERAL CACHE LIVES. Under tmp/ because it is losable by design -- that is the
      # whole difference between a cache and the app volume this architecture rejects.
      CACHE_ROOT = "tmp/git-cache".freeze

      def self.for(project, adapter: FileLayer.current, cache_root: nil)
        new(project, adapter:, cache_root:)
      end

      # `cache_root:` IS INJECTABLE AND THAT IS NOT ONLY FOR TESTS' CONVENIENCE. The cache path is
      # keyed by user and project ID, and IDs ARE NOT UNIQUE OVER TIME inside a transactional test
      # suite: every test rolls back, so the next one mints user 2 / project 1 again and would
      # hydrate the PREVIOUS test's repository -- observed as `Rugged::ReferenceError: old
      # reference value does not match` and a repository appearing where a fresh one was expected.
      # Production never reuses an ID, so the default path is correct there; a caller that needs
      # isolation says so rather than hoping.
      def initialize(project, adapter: FileLayer.current, cache_root: nil)
        @project = project
        @user = project.user
        @adapter = adapter
        @cache_root = cache_root || Rails.root.join(CACHE_ROOT)
      end

      # Bring the working directory up to date with the library, then make sure it is a repository.
      # A no-op copy on a backend that can be operated on in place.
      def hydrate!
        unless in_place?
          FileUtils.mkdir_p(cache_dir)
          @adapter.list_repo_data(@user, project: @project).each do |rel|
            dest = File.join(cache_dir, rel)
            FileUtils.mkdir_p(File.dirname(dest))
            File.binwrite(dest, @adapter.read_repo_data(@user, project: @project, rel:))
          end
        end
        ensure_initialized!
        self
      end

      # paths: { "docs/notes.md" => "content" }. Returns the new commit oid, or NIL if the resulting
      # tree is identical to HEAD's.
      #
      # NIL RATHER THAN AN EMPTY COMMIT IS REQUIRED, NOT TIDY. The caller is a sweep that runs every
      # 15 minutes forever; minting a commit per tick would fill the history with nothing and make
      # the version list useless within a week.
      def commit!(paths:, message:)
        index = rugged.index
        index.clear
        parent = head_oid
        carry_forward(index, parent) if parent

        paths.each do |path, content|
          index.add(path:, oid: rugged.write(content.to_s, :blob), mode: 0o100644)
        end

        tree = index.write_tree(rugged)
        return nil if parent && rugged.lookup(parent).tree.oid == tree

        oid = ::Rugged::Commit.create(rugged, tree:, message:, parents: [ parent ].compact,
                                              author: signature, committer: signature,
                                              update_ref: BRANCH)
        # ONLY IN PLACE. The index is derived state and is meaningless without a work tree, so on a
        # cache-backed backend it would be a file to persist for nothing. In place it is what keeps
        # `git status` honest -- see the class header.
        index.write if in_place?
        Maker::GitRepo.find_or_initialize_by(project: @project)
                      .update!(head_oid: oid, last_commit_at: Time.current)
        oid
      end

      # Collapse every loose object into one pack, and return its name (or nil if there was nothing
      # loose). PART OF THE COMMIT LOOP, NOT A BACKGROUND TIDY-UP: an unconsolidated 1,500-commit
      # repo needs 11,287 GETs to hydrate on s3 against ~3 packed, so a window that commits without
      # packing leaves the project unusable on two of three backends. See PackWriter for why this
      # is not rugged's job.
      def consolidate!
        rels = loose_object_rels
        return nil if rels.empty?

        objects = rels.map do |rel|
          type, payload = PackWriter.read_loose(File.join(git_dir, rel))
          # `objects/ab/cdef...` -> `abcdef...`. The directory IS the first byte of the oid.
          [ rel.split("/")[-2] + File.basename(rel), type, payload ]
        end
        name = PackWriter.write(File.join(git_dir, "objects/pack"), objects)[:name]
        rels.each { |rel| File.unlink(File.join(git_dir, rel)) }
        name
      end

      # Push everything the library does not already have. A no-op in place.
      #
      # PACKS AND REFS, NEVER LOOSE OBJECTS. #consolidate! runs first; persisting loose objects
      # would reintroduce the 11,287-request hydrate that consolidation exists to prevent.
      def persist!
        return if in_place?

        have = @adapter.list_repo_data(@user, project: @project).to_set
        local_rels.each do |rel|
          # A pack is IMMUTABLE and named for its own content hash, so one the library already has
          # can never differ from ours. Refs, HEAD and config are rewritten and always re-sent.
          next if rel.start_with?("objects/") && have.include?(rel)

          File.open(File.join(git_dir, rel), "rb") do |io|
            @adapter.write_repo_data(@user, project: @project, rel:, io:)
          end
        end
      end

      def head_oid = rugged.references[BRANCH]&.target_id
      def managed? = rugged.config[MANAGED_CONFIG_KEY].to_s == "true"
      def loose_object_rels = Dir.glob("objects/??/*", base: git_dir)

      # Throw the cache away. A no-op in place, where the "cache" is the user's own library and
      # deleting it would delete their repository.
      def discard_cache!
        return if in_place?
        return unless Dir.exist?(cache_dir)

        FileUtils.remove_entry(cache_dir)
        @rugged = nil
      end

      def log(limit:)
        return [] unless head_oid

        walker = ::Rugged::Walker.new(rugged)
        walker.sorting(::Rugged::SORT_TOPO)
        walker.push(head_oid)
        walker.first(limit).map do |c|
          CommitInfo.new(oid: c.oid, message: c.message, author: c.author[:name],
                         time: c.time, parent_oids: c.parent_oids)
        end
      end

      def blob_at(oid:, path:)
        entry = rugged.lookup(oid).tree.path(path)
        rugged.lookup(entry[:oid]).content
      rescue ::Rugged::TreeError
        raise FileLayer::NotFound, "#{path.inspect} is not in #{oid}"
      end

      # Where this repository is being operated on. Public because the tests -- and, later, a
      # caller wanting to hand the path to a subprocess -- need it, and reaching it through `send`
      # would make a private method part of the contract anyway without saying so.
      def git_dir = (local_dir || cache_dir).to_s

      private

      # THE PORT ANSWERS THIS, NOT A CLASS CHECK. See the class header.
      def local_dir
        return @local_dir if defined?(@local_dir)

        @local_dir = @adapter.repo_data_dir(@user, project: @project)
      end

      def in_place? = !local_dir.nil?

      def local_rels
        Dir.glob("**/*", base: git_dir, flags: File::FNM_DOTMATCH)
           .reject { |r| File.directory?(File.join(git_dir, r)) }
      end

      # PER USER AND PER PROJECT. The rels inside two repositories are identical, so a shared
      # directory would silently merge them.
      def cache_dir
        @cache_dir ||= Pathname.new(@cache_root).join(@user.id.to_s, @project.id.to_s).to_s
      end

      # Every blob HEAD already has, so a commit that names three paths does not delete the rest of
      # the tree. `:preorder` yields directories too; only blobs are index entries.
      def carry_forward(index, parent)
        rugged.lookup(parent).tree.walk(:preorder) do |root, entry|
          index.add(path: root + entry[:name], oid: entry[:oid], mode: entry[:filemode]) if entry[:type] == :blob
        end
      end

      def ensure_initialized!
        FileUtils.mkdir_p(git_dir)
        ::Rugged::Repository.init_at(git_dir, true) unless File.exist?(File.join(git_dir, "HEAD"))
        @rugged = nil
        # HEAD FOLLOWS THE BRANCH WE COMMIT TO. libgit2 writes `refs/heads/master` at init; without
        # this the history is intact and `git log` cannot see it. See the class header.
        rugged.head = BRANCH if rugged.references[BRANCH].nil? || rugged.head_unborn?
        rugged.config[MANAGED_CONFIG_KEY] = "true"
        # In place, the project folder IS the work tree, which is the whole Finder promise. In the
        # cache there is nothing but `.git`, so it stays bare.
        rugged.config["core.bare"] = in_place? ? "false" : "true"
      end

      def rugged = @rugged ||= ::Rugged::Repository.new(git_dir)

      # A BOT IDENTITY, NOT THE MAKER'S. These commits record that the app OBSERVED a change; on
      # share the maker may have made that edit from a machine this app knows nothing about, so
      # attributing it to them is a small lie `git blame` would then repeat forever.
      # `.to_time` IS REQUIRED, NOT DECORATION. `Time.current` is an ActiveSupport::TimeWithZone
      # and rugged rejects it outright with `TypeError: expected Time object` -- so this fails at
      # the FIRST commit, loudly, rather than subtly. Kept as Time.current.to_time rather than
      # Time.now so the app's configured zone still decides the offset git records.
      def signature = { name: "Tinkerex", email: "bot@tinkerex.invalid", time: Time.current.to_time }
    end
  end
end
