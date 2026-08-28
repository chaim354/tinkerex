require "rugged"

module Maker
  module Git
    # A git repository the maker brought, opened IN PLACE.
    #
    # NOT tinkerex#161's Maker::Git::Repo. That class hydrated an ephemeral cache, wrote packs and
    # persisted them back, because it had to make git work where there is no filesystem. This one
    # answers `local_worktree` instead: there is a filesystem, or there is no commit button. The
    # filename differs from `repo.rb` deliberately — spec part 10.
    #
    # NOTHING HERE WRITES. Opening, inspecting and refusing live here; the write is
    # Maker::Git::CommitPaths, so every refusal in this class is decided before any object exists.
    #
    # THE PATH COMES FROM THE PORT, NEVER FROM A REBUILT STRING. FileLayer::Share#absolute_path
    # resolves inside the library root and raises on a NULL storage_path — §14b records that
    # resolving one to the library ROOT once handed a whole directory to send_file.
    class LocalRepo
      # Operations that leave a marker in .git and mean "a human is halfway through something".
      # Half-finished operations belong to real git, not a web form.
      IN_PROGRESS_MARKERS = {
        "MERGE_HEAD"        => "a merge",
        "REBASE_HEAD"       => "a rebase",
        "CHERRY_PICK_HEAD"  => "a cherry-pick",
        "REVERT_HEAD"       => "a revert",
        "BISECT_LOG"        => "a bisect"
      }.freeze

      # §8 rule 2. `index.lock` is the common one; a ref lock is the one that bites during a
      # concurrent commit.
      LOCK_FILES = %w[index.lock HEAD.lock].freeze

      def self.open(user, root_node, adapter: FileLayer.current)
        new(user, root_node, adapter:)
      end

      attr_reader :root_node

      def initialize(user, root_node, adapter: FileLayer.current)
        @user = user
        @root_node = root_node
        @adapter = adapter
      end

      def workdir = @workdir ||= @adapter.absolute_path(@root_node).to_s

      def rugged = @rugged ||= Rugged::Repository.new(workdir)

      # nil when this repository can be committed to; otherwise a sentence the UI shows verbatim.
      # ONE METHOD, so `committable?` and the message can never disagree about why.
      def refusal
        return @refusal if defined?(@refusal)

        @refusal = compute_refusal
      end

      def committable? = refusal.nil?

      # True when HEAD points at a branch that has no commits yet. Allowed: the commit simply has
      # no parents.
      def unborn? = rugged.head_unborn?

      # What the commit box shows for one path. `state` is :modified, :added, :unchanged, :ignored
      # or :missing; only :modified and :added can be committed.
      Row = Data.define(:path, :state, :additions, :deletions) do
        def committable? = state == :modified || state == :added
      end

      # CONTENT AGAINST HEAD'S BLOB, NEVER A STAT COMPARISON — §8 rule 1, and the reason is the
      # backend rather than fussiness: `share` is a NAS over SMB/NFS, where attribute caching can
      # make a stat-based "unchanged" answer wrong. git's own stat cache is an optimisation it can
      # afford because it is talking to a local disk. We are not.
      def status_for(paths)
        paths.index_with { |rel| row_for(rel) }
      end

      # How many OTHER paths git sees as dirty. Counted, never listed: listing them is the staging
      # panel, and hiding them entirely would let the box misrepresent the repository.
      #
      # `Rugged::Repository#status` TAKES A BLOCK AND RETURNS NO ENUMERATOR. Called without one it
      # raises "A block was expected for iterating through the repository contents." (rugged
      # 1.9.6), so `rugged.status.count { … }` — the obvious spelling, and the plan's — cannot
      # work. Accumulate inside the block instead.
      def other_dirty_count(known_paths)
        known = known_paths.to_set
        return 0 if unborn?

        count = 0
        rugged.status do |rel, flags|
          next if known.include?(rel)

          count += 1 if flags.any? { |f| f != :ignored }
        end
        count
      end

      # HEAD's bytes for one path, or nil when HEAD does not carry it (an untracked file). PUBLIC
      # because the browser diffs against it: RepoCommitsController ships this blob and the working
      # tree's, and diffs neither.
      def head_blob_for(rel)
        entry = rugged.head.target.tree.path(rel)
        rugged.lookup(entry[:oid]).content
      rescue Rugged::TreeError
        nil # not in HEAD: an untracked file, which is :added
      end

      # The same, as text and never nil, for the endpoint that serves it. An unborn HEAD has no
      # blob for anything, so every path diffs against the empty document.
      def head_text_for(rel)
        return "" if unborn?

        head_blob_for(rel).to_s
      end

      private

      def compute_refusal
        unless @adapter.capabilities.local_worktree?
          return "Committing needs a library on a local filesystem."
        end

        if (lock = LOCK_FILES.find { |f| File.exist?(File.join(workdir, ".git", f)) })
          return "Another git process may be using this repository (.git/#{lock} exists). " \
                 "Close it, or remove that file yourself if you are sure nothing is running."
        end

        if (marker = IN_PROGRESS_MARKERS.keys.find { |f| File.exist?(File.join(workdir, ".git", f)) })
          return "This repository has #{IN_PROGRESS_MARKERS[marker]} in progress. Finish it in git first."
        end

        return "HEAD is detached, so a commit here would not be on any branch." if !unborn? && rugged.head_detached?

        nil
      rescue Rugged::RepositoryError, Rugged::OSError => e
        "This folder could not be opened as a git repository (#{e.class})."
      rescue FileLayer::FetchError
        raise # an unmounted share is 503, not a refusal sentence (§14a)
      end

      def row_for(rel)
        abs = File.join(workdir, rel)
        return Row.new(path: rel, state: :missing, additions: 0, deletions: 0) unless File.file?(abs)
        return Row.new(path: rel, state: :ignored, additions: 0, deletions: 0) if rugged.path_ignored?(rel)

        head_blob = unborn? ? nil : head_blob_for(rel)
        current   = File.binread(abs)
        return Row.new(path: rel, state: :added, additions: current.lines.size, deletions: 0) if head_blob.nil?
        return Row.new(path: rel, state: :unchanged, additions: 0, deletions: 0) if head_blob == current

        added, removed = line_delta(head_blob, current)
        Row.new(path: rel, state: :modified, additions: added, deletions: removed)
      end

      # A COUNT, NOT A DIFF. The real diff is rendered by @codemirror/merge in the browser from the
      # two blobs; this is only the "+3 −1" on the row. Computing a proper diff here would rebuild
      # the server-side text diff this design deletes (spec part 13).
      def line_delta(before, after)
        b = before.lines
        a = after.lines
        common = (b & a).size
        [ a.size - common, b.size - common ]
      end
    end
  end
end
