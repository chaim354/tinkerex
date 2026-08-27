require "tmpdir"

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
      # A REPOSITORY IS ALREADY HERE AND IT IS NOT OURS. Raised by #ensure_initialized! before it
      # writes anything at all, so every door into #hydrate! gets the refusal whether or not its
      # author remembered to ask. Maker::Git::ProjectCommit turns it into a skip; see there.
      class UnmanagedRepository < StandardError; end

      # The marker that says this repo is OURS. A git config key rather than a database column,
      # because it has to travel WITH the repository: a restore, a re-hydrate, or a maker copying
      # their library to a new NAS all keep it, and a maker who drops their OWN repo into Projects/
      # never acquires it. `maker_git_repos` is an index over this, never the source of truth.
      #
      # THE MARKER IS ONLY A MARKER IF IT IS READ BEFORE IT IS WRITTEN. #ensure_initialized! wrote
      # it unconditionally until 2026-08-27, which meant the one question it exists to answer --
      # "did we create this repository?" -- was destroyed at the exact moment it was asked. On the
      # share box `Projects/TheFlightWall_OSS` was a project folder holding the maker's OWN clone,
      # and the next pass would have stamped our marker into THEIR `.git/config`, cleared THEIR
      # index, and put a bot commit of 2,305 files on THEIR `refs/heads/main`.
      MANAGED_CONFIG_KEY = "tinkerex.managed".freeze
      BRANCH = "refs/heads/main".freeze

      # WHERE THE EPHEMERAL CACHE LIVES. Under tmp/ because it is losable by design -- that is the
      # whole difference between a cache and the app volume this architecture rejects.
      CACHE_ROOT = "tmp/git-cache".freeze

      # HOW MANY PACKS IS TOO MANY. Borrowed from git's own `gc.autoPackLimit` default rather than
      # invented: git has spent twenty years deciding when a repository has too many packs, and a
      # number with a source is one a later reader can go and check. The COMPARISON is borrowed
      # too -- builtin/gc.c's `too_many_packs()` is `gc_auto_pack_limit < cnt`, so fifty packs is
      # fine and fifty-one is not.
      MAX_PACKS = 50

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

      # Collapse every PACK into one, and return its name -- or nil when there are not enough packs
      # to be worth it. #consolidate! writes one pack per commit WINDOW and never collapses them,
      # which is right for the window and wrong for a year of them: 365 daily windows is 365 packs,
      # and a hydrate fetches all of them. The file-count term consolidation exists to keep small
      # grows back one window at a time, and nothing else was ever going to notice.
      #
      # THE OLD PACKS ARE DELETED ONLY AFTER THE NEW ONE IS WRITTEN AND VERIFIED, IN THE CACHE AND
      # IN THE LIBRARY. The reverse order is §14a's copy-delete-tombstone landmine with the stakes
      # raised as far as they go: a failure between the two leaves the repository with NO OBJECTS AT
      # ALL and nothing anywhere saying so. Every state this method can be interrupted in is a
      # COMPLETE repository -- new pack written beside the old ones (duplicated objects), library
      # collapsed and cache not (the next hydrate settles it), and so on down.
      #
      # OBJECTS ARE ENUMERATED FROM THE .idx FILES, NEVER FROM A REVWALK, and the difference is
      # whether a repack silently drops objects. A revwalk reaches what is reachable FROM HEAD, and
      # a pack holds more than that: a blob written by a `commit!` whose `Rugged::Commit.create`
      # then raised is packed by the next #consolidate! and is reachable from nothing, and in place
      # the repository is the MAKER'S OWN -- their branches, their tags, their stashes, none of
      # which this app created and all of which a HEAD-only walk would drop. An idx is every object
      # in its pack BY CONSTRUCTION, so this cannot: what the packs held, the new pack holds.
      # Reading the objects is then rugged's job -- an idx gives oids, `Rugged::Repository#read`
      # resolves each one through libgit2, which unlike this app's writer can also read a DELTIFIED
      # pack that a maker's own `git gc` left in an in-place repository.
      #
      # LOOSE OBJECTS ARE LEFT WHERE THEY ARE. Collapsing those is #consolidate!'s job; folding
      # them in here would be a second spelling of a method that already exists, and leaving them
      # costs nothing -- the repository is complete either way.
      def repack_all!
        idx_rels = pack_idx_rels
        return nil if idx_rels.size <= MAX_PACKS
        # A MULTI-PACK INDEX NAMES THE PACKS IT COVERS, so deleting them behind it leaves git
        # reading a repository it believes is corrupt -- and in place that is the maker's own
        # folder. This app never writes one; a maker who ran `git multi-pack-index write` in their
        # project does. Declining is recoverable (delete the index, the next run repacks); the
        # alternative is not.
        return nil if File.exist?(File.join(git_dir, "objects/pack", "multi-pack-index"))

        objects = packed_objects(idx_rels)
        name = write_verified_pack!(objects)
        # SNAPSHOTTED FROM THE LISTING TAKEN BEFORE THE WRITE, and filtered by the new pack's name.
        # A pack file is named for its own content hash, so the new one can only collide with an old
        # one by being byte-identical to it -- but the cost of being wrong is deleting the pack we
        # just wrote, which is the whole failure this method is ordered to avoid.
        superseded = idx_rels.flat_map { |rel| pack_sidecars(rel) }.reject { |rel| rel.include?(name) }
        persist_repack!(name, superseded)
        # The ODB this instance opened has had its packs replaced underneath it; the next caller
        # gets a repository that has read the directory as it now is. (#discard_cache! does the
        # same, for the same reason.)
        @rugged = nil
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
      def managed? = managed_marker?(rugged)
      def loose_object_rels = Dir.glob("objects/??/*", base: git_dir)
      # ONE PER PACK, and it is the .idx that is counted rather than the .pack: a pack this code can
      # do nothing with is a pack whose index it cannot read, and #repack_all! enumerates through
      # the index. Public for the same reason #loose_object_rels is -- it is what a caller (and the
      # suite) asks to find out whether a repack is due.
      def pack_idx_rels = Dir.glob("objects/pack/*.idx", base: git_dir)

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

      # [[oid_hex, type, payload], ...] for every object in the named packs, DEDUPLICATED BY OID.
      # The same object can legitimately sit in more than one pack -- `rugged.write` re-writes an
      # object a pack already holds as a fresh loose one, which the next #consolidate! then packs
      # again -- and two entries carrying one oid would put that oid in the new index twice.
      def packed_objects(idx_rels)
        by_oid = {}
        idx_rels.each do |rel|
          idx_oids(File.join(git_dir, rel)).each do |oid|
            next if by_oid.key?(oid)

            object = rugged.read(oid)
            by_oid[oid] = [ oid, object.type.to_s, object.data ]
          end
        end
        by_oid.values
      end

      # THE OIDS IN ONE PACK, READ OFF ITS idx v2 -- the format PackWriter#build_idx writes and the
      # one git has written by default since 2007. An 8-byte header, a 256-entry CUMULATIVE fanout
      # whose last entry IS the object count, then that many 20-byte oids.
      #
      # AN INDEX THIS CANNOT PARSE RAISES RATHER THAN RETURNING WHAT IT MANAGED TO READ. A short
      # list here is a new pack missing objects followed by the deletion of the packs that had them
      # -- silent permanent loss wearing a tidy-up's clothes. Refusing leaves every pack in place,
      # which is the recoverable direction §14a takes everywhere else.
      def idx_oids(path)
        data = File.binread(path)
        raise "#{path}: not a v2 pack index; refusing to repack" \
          unless data[0, 4] == "\xFFtOc".b && data[4, 4].unpack1("N") == 2

        count = data[8 + (255 * 4), 4].unpack1("N")
        base = 8 + (256 * 4)
        raise "#{path}: index is truncated (#{count} objects, #{data.bytesize} bytes)" \
          if data.bytesize < base + (count * 20)

        Array.new(count) { |i| data[base + (i * 20), 20].unpack1("H*") }
      end

      # Write the new pack somewhere it can be read back BY SOMETHING THAT IS NOT THIS CODE, then
      # move it into place. Returns its name.
      #
      # "VERIFIED" IS A MECHANISM HERE, NOT A WORD. The scratch directory is a real repository
      # holding NOTHING BUT THE NEW PACK, so every object read back is answered by that pack alone
      # -- verifying in `git_dir` would let the OLD packs answer, which is precisely the
      # reassurance a repack must not accept. libgit2 then parses the index this app wrote and
      # returns each object's type and bytes, both compared against what came out of the old packs.
      # That is the independent reader §14e demands: a checker that shares the writer's
      # misunderstanding confirms it, which is how FakeS3 kept 79 of 80 tests green over silent
      # data loss. `git fsck` would be a second such reader and is deliberately NOT used here -- it
      # needs a binary the container need not have, and a verification step that silently skips
      # itself is worse than no verification at all. (The suite runs it anyway, where a skip is
      # visible.)
      def write_verified_pack!(objects)
        Dir.mktmpdir("git-repack") do |scratch|
          ::Rugged::Repository.init_at(scratch, true)
          result = PackWriter.write(File.join(scratch, "objects/pack"), objects)
          verify_pack!(scratch, objects)
          Dir.glob(File.join(scratch, "objects/pack", "pack-#{result[:name]}.*")).each do |src|
            FileUtils.mv(src, File.join(git_dir, "objects/pack", File.basename(src)))
          end
          result[:name]
        end
      end

      def verify_pack!(scratch, objects)
        reader = ::Rugged::Repository.new(scratch)
        objects.each do |oid, type, payload|
          object = begin
            reader.read(oid)
          rescue ::Rugged::OdbError
            raise "repack refused: #{oid} is not readable from the pack just written"
          end
          next if object.type.to_s == type && object.data == payload

          raise "repack refused: #{oid} reads back as #{object.type}/#{object.len} bytes"
        end
      end

      # Every file belonging to one pack -- `.pack` and `.idx`, plus any sidecar git left beside
      # them (`.rev`, `.mtimes`, `.keep`, `.promisor`) in an in-place repository the maker has run
      # git in themselves. Globbing the STEM rather than naming two extensions is what keeps a
      # sidecar from outliving the pack it describes.
      def pack_sidecars(idx_rel)
        Dir.glob("#{idx_rel.delete_suffix('.idx')}.*", base: git_dir)
      end

      # PUSH THE NEW PACK, THEN DROP THE OLD ONES -- in that order, in the library first and the
      # working directory second. A library that lost its packs before gaining their replacement is
      # a repository nothing can hydrate, and no error would say so: the next hydrate would simply
      # build an empty repo out of an empty listing.
      #
      # THE LIBRARY DELETE IS THE POINT OF THE WHOLE METHOD. Without it the library keeps every pack
      # forever and the repack accomplishes nothing where it matters -- a hydrate reads the LIBRARY,
      # so 365 packs would still be 365 fetches while the cache looked tidy.
      def persist_repack!(name, superseded)
        push_pack!(name)
        superseded.each do |rel|
          @adapter.delete_repo_data(@user, project: @project, rel:)
          # IN PLACE THE LIBRARY IS THE WORKING DIRECTORY, so the delete above already removed this
          # file; on a hydrated backend the cache still holds its own copy.
          path = File.join(git_dir, rel)
          File.unlink(path) if File.exist?(path)
        end
      end

      # Exactly the pack just written, rather than #persist!'s sweep of everything the library is
      # missing. A repack changes one thing, and a sweep here would also push any LOOSE object the
      # working directory happened to be holding -- the 11,287-request hydrate #consolidate! exists
      # to prevent, reintroduced by the method that was cleaning up after it.
      def push_pack!(name)
        return if in_place?

        Dir.glob("objects/pack/pack-#{name}.*", base: git_dir).each do |rel|
          File.open(File.join(git_dir, rel), "rb") do |io|
            @adapter.write_repo_data(@user, project: @project, rel:, io:)
          end
        end
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

      # THE READ COMES FIRST, AND THE ORDER IS THE WHOLE FIX. Everything below this line writes --
      # `mkdir_p` mints the marker directory Maker::AttachToProject reads, `init_at` writes a
      # repository, and the two `config[...] =` lines write into whatever config is already there.
      # Ask whether this repository is ours BEFORE any of that, or the answer is one we just wrote.
      def ensure_initialized!
        existing = refuse_unless_ours!

        FileUtils.mkdir_p(git_dir)
        ::Rugged::Repository.init_at(git_dir, true) if existing.nil?
        @rugged = nil
        # HEAD FOLLOWS THE BRANCH WE COMMIT TO. libgit2 writes `refs/heads/master` at init; without
        # this the history is intact and `git log` cannot see it. See the class header.
        rugged.head = BRANCH if rugged.references[BRANCH].nil? || rugged.head_unborn?
        rugged.config[MANAGED_CONFIG_KEY] = "true"
        # In place, the project folder IS the work tree, which is the whole Finder promise. In the
        # cache there is nothing but `.git`, so it stays bare.
        rugged.config["core.bare"] = in_place? ? "false" : "true"
      end

      # Raise unless whatever is at `git_dir` is ours to write into. Returns the OPEN repository
      # when one is already there (so the caller does not ask twice), and nil when there is nothing
      # here yet -- which is the ordinary answer and the one that means "initialize".
      #
      # "ALREADY EXISTS" IS "libgit2 CAN OPEN IT", NEVER "THE DIRECTORY IS THERE". The hydrated
      # backends' own #hydrate! runs `mkdir_p(cache_dir)` before this, so a directory that exists is
      # the NORMAL first-pass state, and refusing on a directory would refuse every s3 and
      # chunk_remote project that ever ran. An empty `.git` a maker made by hand is not a repository
      # either -- you cannot create one by creating the folder (Library::RepoMetadata says the same
      # thing at the write guards) -- so it is ours to initialize, and #config is never asked about
      # a repository that is not there.
      #
      # A FAILURE TO OPEN IS "NOT A REPOSITORY", NOT AN ERROR. Measured against rugged 1.9.6: an
      # absent path raises Rugged::OSError, an empty directory and a directory holding fragments
      # (`objects/` but no HEAD) raise Rugged::RepositoryError. Both mean the same thing here.
      #
      # A `.git` THAT IS NOT A DIRECTORY IS ALWAYS FOREIGN, and it is checked FIRST because it is
      # the case the open cannot answer safely. That file is a `gitdir:` pointer -- what `git
      # worktree add` and a submodule write -- so the folder is somebody else's linked working tree.
      # If its target resolves, libgit2 opens the MAIN repository and the marker check below refuses
      # it; if the target is missing, the open raises OSError, which without this guard reads as
      # "nothing here" and sends `mkdir_p` at an existing FILE (Errno::EEXIST). We only ever create
      # a DIRECTORY at `git_dir`, so a file there can never be ours whatever the open says.
      def refuse_unless_ours!
        if File.exist?(git_dir) && !File.directory?(git_dir)
          refuse!("#{git_dir} is a `gitdir:` pointer file, so this folder is a linked working " \
                  "tree belonging to a repository elsewhere")
        end

        existing = existing_repository
        return nil if existing.nil?
        return existing if managed_marker?(existing)

        refuse!("#{git_dir} is a git repository this app did not create -- it carries no " \
                "#{MANAGED_CONFIG_KEY}, so its history, branches and index are the maker's own")
      end

      def refuse!(reason)
        raise UnmanagedRepository,
              "refusing to write into #{@project.slug} (project #{@project.id}): #{reason}."
      end

      # THE READ THAT CREATES NOTHING. `Rugged::Repository.new` opens; it never initializes, and it
      # does NOT search upward (libgit2's plain open, not open_ext) -- so a library that happens to
      # sit inside somebody's checkout cannot make every project look like a repository.
      def existing_repository
        ::Rugged::Repository.new(git_dir)
      rescue ::Rugged::RepositoryError, ::Rugged::OSError
        nil
      end

      def managed_marker?(repository) = repository.config[MANAGED_CONFIG_KEY].to_s == "true"

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
