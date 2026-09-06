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

      # What the commit box shows for one path. `state` is :modified, :added, :deleted, :unchanged,
      # :ignored or :missing; only the first three can be committed.
      Row = Data.define(:path, :state, :additions, :deletions) do
        def committable? = state == :modified || state == :added || state == :deleted
      end

      FullStatus = Data.define(:rows, :truncated_count)

      DEFAULT_STATUS_LIMIT = 500

      # CONTENT AGAINST HEAD'S BLOB, NEVER A STAT COMPARISON — §8 rule 1, and the reason is the
      # backend rather than fussiness: `share` is a NAS over SMB/NFS, where attribute caching can
      # make a stat-based "unchanged" answer wrong. git's own stat cache is an optimisation it can
      # afford because it is talking to a local disk. We are not.
      def status_for(paths)
        paths.index_with { |rel| row_for(rel) }
      end

      # Everything git sees as changed, capped. The counterpart to #status_for, which answers about
      # paths a caller names; this one ENUMERATES.
      #
      # CAPPED FOR THE SAME REASON THE HISTORY WALK IS, and the number is not decoration: every row
      # costs a content comparison against HEAD's blob, and over CIFS that is ~15 ms per object
      # (the history spec's measurement). `truncated_count` reaches the view — a truncated list that
      # does not say so is the same lie as a capped walk reporting "no history".
      #
      # `.gitignore`d PATHS ARE DROPPED HERE, NOT IN THE VIEW. git will not commit them without
      # `-f`, so offering them is offering something that cannot happen.
      #
      # `Rugged::Repository#status` TAKES A BLOCK, as #other_dirty_count already records, so the
      # paths are accumulated rather than filtered off an enumerator. Probed on rugged 1.9.6: an
      # ignored path arrives as exactly `[:ignored]` and never alongside another flag, so one
      # `include?` is the whole filter.
      def full_status(limit: DEFAULT_STATUS_LIMIT)
        return FullStatus.new(rows: [], truncated_count: 0) unless committable?

        paths = []
        rugged.status { |path, flags| paths << path unless flags.include?(:ignored) }
        paths.sort!

        rows = paths.first(limit).map { |rel| row_for(rel) }.reject { |r| r.state == :unchanged }
        FullStatus.new(rows:, truncated_count: [ paths.size - limit, 0 ].max)
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

      # The account's address, for the commit-identity fallback. Exposed rather than reaching for
      # `@user.email` from CommitPaths so that class needs no User at all.
      def user_email = @user.email

      # HEAD's facts for a repository CARD (stage 3, S3-2) — oid, summary, author, time.
      # `short_oid` is 8 hex characters, NOT git's traditional 7: Maker::Git::History::Entry
      # already made that choice (`oid[0, 8]`, pinned by repo_history_flow_test.rb's "history JSON
      # lists the commits that touched this path" — `assert_equal 8, …["short_oid"].length`) and a
      # card sitting next to a commit list that trims to a different length would be a visible,
      # pointless inconsistency.
      Head = Data.define(:oid, :short_oid, :summary, :author, :time)

      # nil when HEAD is unborn — there is no commit for a card to summarise. READS RUGGED ONLY; a
      # repository whose `refusal` is set (not local, no .git, locked, mid-operation) must not
      # reach here — the caller asks `refusal`/`committable?` FIRST, the same order
      # `Maker::Git::History.new` is required to keep (git-editing.md) and for the identical
      # reason: constructing anything here dereferences the port's `workdir` on the way to rugged.
      def head_summary
        return nil if unborn?

        c = rugged.head.target
        Head.new(oid: c.oid, short_oid: c.oid[0, 8], summary: c.message.lines.first.to_s.strip,
                author: c.author[:name], time: c.time)
      end

      # Tag names whose target is HEAD — a lightweight tag's own target, or an annotated tag's
      # PEELED target (the annotation object sits between the ref and the commit) — sorted; []
      # when none. `[] if unborn?` for the same reason `head_summary` returns nil: nothing here
      # needs the working tree, only the ref database, but an unborn HEAD has no target to compare
      # tags against at all.
      def tags_at_head
        return [] if unborn?

        head = rugged.head.target_id
        rugged.tags.select { |t| t.target_id == head || (t.annotated? && t.annotation.target_id == head) }
             .map(&:name).sort
      end

      Tag = Data.define(:name, :oid)
      TAG_CAP = 200

      # EVERY tag with the COMMIT it resolves to — an annotated tag's PEELED target, a lightweight
      # tag's own target — name-sorted, for the release picker (stage 3, S3-5). The peel is the same
      # one `tags_at_head` above makes and for the same reason: the annotation object sits between
      # the ref and the commit, so an unpeeled `target_id` records the TAG object's oid, which is
      # not a commit and matches nothing a maker can look up.
      #
      # CAPPED, LIKE EVERY WALK IN THIS CLASS, AND SORTED BEFORE THE CAP (git-editing.md): a
      # repository with more tags than this lists the alphabetical first TAG_CAP and the picker
      # says so. The sort comes first for the reason `full_status` sorts before it caps -- an
      # unsorted cap keeps an arbitrary subset, and two renders of one repository could offer
      # different tags with nothing reporting it (S3-5's review; an earlier version of this method
      # capped first and cited `full_status` as precedent for doing so, which was false). Sorting
      # names costs nothing; the peel is what the cap bounds, and it still runs TAG_CAP times.
      #
      # THIS LIST IS FOR THE PICKER ONLY. Verifying a tag the maker chose goes through `tag(name)`
      # below -- a direct lookup, uncapped -- because a real tag past the cap must never be refused
      # as "no such tag".
      def tags
        return [] if unborn?

        rugged.tags.sort_by(&:name).first(TAG_CAP).map { |t| peel(t) }
      end

      # ONE tag by exact name, or nil. Rugged's collection resolves the ref directly, so this is
      # O(1) and sees every tag, past any cap.
      def tag(name)
        return nil if unborn? || name.blank?

        found = rugged.tags[name]
        found && peel(found)
      end

      private

      # The PEEL both readers share: an annotated tag's target is the annotation object, and the
      # commit sits one hop behind it; a lightweight tag points at the commit itself.
      def peel(tag)
        Tag.new(name: tag.name, oid: tag.annotated? ? tag.annotation.target_id : tag.target_id)
      end

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

        # TWO SITUATIONS, NOT ONE, AND CONFLATING THEM IS SILENT EITHER WAY. In HEAD and gone from
        # the worktree is a real DELETION the maker may want to commit; in neither is a stale
        # maker_repo_edits row the commit box already drops. One `:missing` for both means either
        # every stale row becomes a committable deletion, or every real deletion vanishes.
        unless File.file?(abs)
          in_head = !unborn? && !head_blob_for(rel).nil?
          return Row.new(path: rel, state: in_head ? :deleted : :missing, additions: 0, deletions: 0)
        end

        return Row.new(path: rel, state: :ignored, additions: 0, deletions: 0) if rugged.path_ignored?(rel)

        head_blob = unborn? ? nil : head_blob_for(rel)
        current   = File.binread(abs)
        return Row.new(path: rel, state: :added, additions: current.lines.size, deletions: 0) if head_blob.nil?
        return Row.new(path: rel, state: :unchanged, additions: 0, deletions: 0) if head_blob == current

        added, removed = line_delta(head_blob, current)
        Row.new(path: rel, state: :modified, additions: added, deletions: removed)
      end

      # A COUNT, NOT A DIFF -- but it must be the count GIT would report, and for eight months of
      # this file's life it was not.
      #
      # THIS WAS `(b & a).size` AND THAT IS WRONG ON ALMOST EVERY REAL FILE. `Array#&` returns
      # UNIQUE elements, so every repeated line -- blank lines above all, but also `}`, `end`,
      # `---` -- collapses to one, `common` is undercounted, and BOTH numbers are inflated.
      # Measured on the live share deployment against a real repository: appending two lines to a
      # 23-line README with 8 blank lines reported `+9 -7`, where git 2.50.1 said
      # `1 file changed, 2 insertions(+)` (tinkerex#185).
      #
      # ITS OWN COMMENT IS WHY IT SURVIVED. "A count, not a diff" argued that a real diff would
      # rebuild the server-side text diff this design deletes -- true, and irrelevant to whether the
      # count is right. libgit2 is already in the process and will do it exactly, so the cheap
      # approximation bought nothing.
      #
      # NO NEW DEPENDENCY: Rugged::Patch.from_strings is the same libgit2 diff the rest of this
      # class uses, and `stat` returns [additions, deletions] directly.
      def line_delta(before, after)
        Rugged::Patch.from_strings(before, after).stat
      end
    end
  end
end
