require "rugged"

module Maker
  module Git
    # HEAD's tree with the SELECTED PATHS replaced. The class is named for the rule.
    #
    # NEVER `index.clear` FOLLOWED BY add_all. That is what tinkerex#161's reverted code did, and
    # it turns "commit these two files" into "commit whatever is lying around the maker's working
    # tree". It passes every bytes-oriented test, because the bytes of the selected files are
    # right; what is wrong is everything else that came along.
    #
    # AND NEVER LEAVE THE INDEX UNTOUCHED EITHER, which is the symmetric mistake. After the commit
    # the index still holds the OLD blob for a committed path, so the maker's own `git status`
    # reports it as staged-and-different — reading as "the app half-did something". Read the index,
    # update the committed entries, write it back.
    #
    # THE WRITE WINDOW IS TWO OPERATIONS WIDE (§8 rule 3). Objects are content-addressed and safe
    # to write early, so blobs and trees go in first; only the ref update and the index write need
    # a lock, and share is a NETWORK filesystem where a lock is the risky part.
    class CommitPaths
      class RefMoved < StandardError; end
      class NothingToCommit < StandardError; end

      def initialize(local_repo)
        @local = local_repo
        @repo = local_repo.rugged
      end

      # `expected_head` is the compare-and-swap. A caller that read the head, rendered a page and
      # came back passes what it saw; a mismatch means another commit landed meanwhile and this
      # one must be re-shown rather than silently layered on top.
      def call(paths:, message:, expected_head: nil)
        raise NothingToCommit if paths.empty?

        parents = @local.unborn? ? [] : [ @repo.head.target ]
        if expected_head && (parents.first&.oid != expected_head)
          raise RefMoved, "another commit landed while you were reviewing"
        end

        builder = tree_builder(parents.first)
        paths.each { |rel| stage(builder, rel) }

        oid = Rugged::Commit.create(@repo,
                                    tree: builder.write, message: message.to_s,
                                    parents: parents.map(&:oid),
                                    update_ref: ref_name,
                                    author: identity, committer: identity)
        refresh_index(paths)
        oid
      end

      private

      # HEAD's tree is the STARTING POINT, which is the whole design. `Rugged::Tree::Builder.new`
      # with a source tree copies it; without one, the commit would contain only the selected
      # paths and delete the entire rest of the repository.
      def tree_builder(head_commit)
        head_commit ? Rugged::Tree::Builder.new(@repo, head_commit.tree) : Rugged::Tree::Builder.new(@repo)
      end

      # Nested paths need each intermediate tree rebuilt, so this recurses rather than assuming a
      # flat repository. A repository with everything at the root is the easy case, not the case.
      #
      # THE WORKDIR PATH AND THE POSITION IN THE TREE ARE TWO DIFFERENT THINGS, and the recursion
      # has to carry both. Recursing on the JOINED REMAINDER — the plan's spelling,
      # `stage(sub, segments.drop(1).join("/"))` — re-enters holding "a.txt" for a file that is
      # really at "src/a.txt", so `Rugged::Blob.from_workdir` raises
      # `Rugged::OSError: could not find '<workdir>/a.txt' to stat` and `filemode_for` would stat
      # the wrong path even if it did not. `rel` therefore stays the workdir-relative path the
      # whole way down and only `segments` shortens.
      def stage(builder, rel, segments = rel.split("/"))
        if segments.size == 1
          builder.insert(name: segments.first, oid: Rugged::Blob.from_workdir(@repo, rel),
                         filemode: filemode_for(rel))
          return
        end

        head = segments.first
        sub_oid = builder[head]&.fetch(:oid, nil)
        sub = sub_oid ? Rugged::Tree::Builder.new(@repo, @repo.lookup(sub_oid)) : Rugged::Tree::Builder.new(@repo)
        stage(sub, rel, segments.drop(1))
        builder.insert(name: head, oid: sub.write, filemode: 0o040000)
      end

      # Preserve the executable bit a file already has. Dropping it silently un-chmods scripts.
      def filemode_for(rel)
        File.executable?(File.join(@local.workdir, rel)) ? 0o100755 : 0o100644
      end

      def ref_name
        return "HEAD" if @local.unborn?

        @repo.head.name
      end

      # ONLY THE COMMITTED PATHS. Anything wider is index.clear with extra steps.
      def refresh_index(paths)
        index = @repo.index
        paths.each do |rel|
          index.add(path: rel, oid: Rugged::Blob.from_workdir(@repo, rel), mode: filemode_for(rel))
        end
        index.write
      end

      # Repo-local config if BOTH halves are set. `Rugged::Config.global` reads the CONTAINER's
      # config and is meaningless here, so there is no second git source to fall back to; the
      # fallback is the tinkerex account. `users` has no name column (checked against
      # db/schema.rb), so the address's local-part is the name — if that column is ever added, it
      # becomes the name and this comment is the reason to change it.
      def identity
        cfg   = local_config
        name  = cfg["user.name"]
        email = cfg["user.email"]
        if name.present? && email.present?
          { name:, email:, time: now }
        else
          account = @local.user_email
          { name: account.split("@").first, email: account, time: now }
        end
      end

      # `.to_time`, NOT a bare `Time.current`. Rugged wants a real Time and refuses an
      # ActiveSupport::TimeWithZone outright — `TypeError: expected Time object` from
      # Rugged::Commit.create, raised after the blobs and the tree are already written. Going
      # through Time.current rather than Time.now keeps the app's configured zone, which is what
      # the committer's offset is recorded from.
      def now = Time.current.to_time

      # `.git/config` DIRECTLY, NEVER `@repo.config`. Rugged::Repository#config hands back the whole
      # config STACK — system, global, then local — so on any box with a `~/.gitconfig` it answers
      # with THAT identity and the account fallback below can never run. That is the same
      # "meaningless here" objection the comment above makes about Rugged::Config.global, and it
      # applies to the stack for exactly the reason it applies to the global file: the container's
      # git identity is not the maker's. A repository whose `.git` is a FILE (a submodule or a
      # linked worktree) has no config at this path; Rugged::Config answers nil for every key
      # rather than raising, so that repository takes the account fallback, which is correct.
      def local_config
        @local_config ||= Rugged::Config.new(File.join(@local.workdir, ".git", "config"))
      end
    end
  end
end
