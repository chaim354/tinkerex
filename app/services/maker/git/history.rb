require "rugged"

module Maker
  module Git
    # What happened in this repository, and to this path — as much of it as we can afford to look at.
    #
    # THE CAP IS NOT AN OPTIMISATION AND MUST NOT BE MADE OPTIONAL. Measured on the live share
    # deployment against a 333-commit repository over its real CIFS mount: a full walk is 4,917 ms,
    # a walk capped at 25 is 104 ms cold and 1 ms warm (spec part 3). ~15 ms per commit is a network
    # round trip per object. There is no "all history" call here and there must never be one.
    #
    # `stopped` IS LOAD-BEARING, NOT BOOKKEEPING. Path filtering is sparse — 1 of the last 50 commits
    # touched README.md in the measured repository, against 28 of all 333 — so an empty result
    # usually means "we stopped looking", not "nothing happened". Only `:exhausted` licenses a caller
    # to say there is no history. Delete this member and the UI starts lying quietly.
    #
    # BOTH QUESTIONS COME OFF ONE WALK on purpose. Building the file surface now and the repository
    # one later gives two walkers that drift on ordering, caps and what stopping early means.
    class History
      Entry = Data.define(:oid, :message, :author_name, :author_email, :time) do
        def short_oid = oid[0, 8]
        def subject = message.to_s.lines.first.to_s.strip
      end

      Result = Data.define(:entries, :walked, :stopped) do
        # The ONE question the view may ask before saying "nothing here".
        def exhausted? = stopped == :exhausted
      end

      DEFAULT_LIMIT      = 25
      DEFAULT_WALK_LIMIT = 250
      MAX_WALK_LIMIT     = 2_000

      def initialize(local_repo)
        @local = local_repo
        @repo = local_repo.rugged
      end

      def for_repo(limit: DEFAULT_LIMIT, walk_limit: DEFAULT_WALK_LIMIT)
        walk(limit:, walk_limit:) { true }
      end

      # Compares the blob oid at each commit against its FIRST PARENT's. Absent in both is not a
      # change; a merge is therefore attributed once, to the merge, which is what `git log` does by
      # default. Comparing against every parent looks more thorough and lists the same change twice.
      def for_path(rel, limit: DEFAULT_LIMIT, walk_limit: DEFAULT_WALK_LIMIT)
        walk(limit:, walk_limit:) do |commit|
          parent = commit.parents.first
          blob_oid(commit, rel) != (parent && blob_oid(parent, rel))
        end
      end

      # The content of `rel` at `oid`, or nil — absent path, absent commit, or an oid belonging to
      # some other repository. NIL RATHER THAN RAISING: every caller here is answering a URL
      # parameter, and a 404 is the honest answer to all three.
      #
      # THE `is_a?(Rugged::Commit)` GUARD IS NOT REDUNDANT WITH THE RESCUE. A blob or tree oid this
      # repository really does contain looks up fine, and `Rugged::Blob` has no `#tree` — probed on
      # rugged 1.9.6, the NoMethodError is not a Rugged error and would reach the caller as a 500.
      def blob_at(oid, rel)
        commit = @repo.lookup(oid)
        return nil unless commit.is_a?(Rugged::Commit)

        entry = commit.tree.path(rel)
        blob = @repo.lookup(entry[:oid])
        blob.is_a?(Rugged::Blob) ? blob.content : nil
      rescue Rugged::OdbError, Rugged::TreeError, Rugged::InvalidError, TypeError
        nil
      end

      private

      def walk(limit:, walk_limit:)
        return Result.new(entries: [], walked: 0, stopped: :exhausted) if @local.unborn?

        cap = [ walk_limit.to_i, MAX_WALK_LIMIT ].min
        entries = []
        walked = 0
        stopped = :exhausted

        walker = Rugged::Walker.new(@repo)
        # EXPLICIT ORDERING. libgit2 does not specify the walker's default, and a history list whose
        # order depends on an implementation detail will reorder itself one day for no visible reason.
        walker.sorting(Rugged::SORT_DATE)
        walker.push(@repo.head.target)

        walker.each do |commit|
          if walked >= cap
            stopped = :walk_limit
            break
          end
          walked += 1
          next unless yield(commit)

          entries << entry_for(commit)
          if entries.size >= limit
            stopped = :limit
            break
          end
        end

        Result.new(entries:, walked:, stopped:)
      end

      def entry_for(commit)
        Entry.new(oid: commit.oid, message: commit.message,
                  author_name: commit.author[:name], author_email: commit.author[:email],
                  time: commit.author[:time])
      end

      def blob_oid(commit, rel)
        commit.tree.path(rel)[:oid]
      rescue Rugged::TreeError
        nil
      end
    end
  end
end
