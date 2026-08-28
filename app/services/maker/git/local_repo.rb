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
    end
  end
end
