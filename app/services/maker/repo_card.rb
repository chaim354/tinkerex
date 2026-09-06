module Maker
  # One repository's card on the project page (stage 3, S3-2): the README rendered, the latest
  # commit, the current tag, and links to the commit/history pages. A PORO, built fresh per render
  # from Maker::Git::LocalRepo and the port — the same two sources the dedicated repo pages
  # (RepoCommitsController, RepoHistoriesController) already read, so this is a THIRD reader of
  # facts those two already established, never a new way to derive them.
  #
  # A CARD MUST NEVER TAKE THE WHOLE PROJECT PAGE DOWN. The project page renders every repo the
  # folder holds alongside the BOM, the build log and every other panel, so one repo's corrupt
  # `.git`, unmounted share, missing README, or — the case that actually bit this in review — a
  # `repo?`-flagged dir with no real `storage_path` (a synthetic `.git` marker built straight from
  # `Node.create!` in a fixture, never real production data: a live repo's dir is always either
  # scanned in or made by the port's own mkdir, and both set storage_path) must degrade to a line
  # in ITS OWN card, never a 500 for the page. `git_facts` and `readme_facts` are the two places
  # that hold, and both fail closed.
  #
  # ASKS `capabilities.local_worktree?`, NEVER `is_a?(FileLayer::Share)` — git-editing.md's rule,
  # restated here rather than reinvented (LocalRepo itself asks the same way).
  RepoCard = Data.define(:dir, :head, :tags, :readme_html, :readme_note, :refusal) do
    README_NAMES = %w[README.md README readme.md].freeze
    README_CAP = 64 * 1024 # A CALLER-SIDE cap; the port's own MAX_BYTES (256 MB) isn't built for a card.

    # `root_node` is the repo dir's own Node row, fetched ONCE for every repo on the page by the
    # controller — never here. `LocalRepo.open` needs `root_node.storage_path` (through the port's
    # `absolute_path`), which `dir` (Maker::ProjectFolderListing::Dir) does not carry, so SOME query
    # is unavoidable; batching it into one `WHERE node_id IN (...)` per page rather than one `for`
    # call each is what keeps the number of repos from showing up in page_query_budget_test.rb —
    # the query-count guard counts SQL, so an O(repos) DB call for every card would fail it the
    # moment a project holds more than one, and the fixture there already does (a `.git` marker is
    # seeded once per grown row, for an unrelated reason — S3-1's own nesting coverage).
    def self.for(user:, dir:, root_node:, listing:, capabilities:)
      head, tags, refusal = git_facts(user:, dir:, root_node:, capabilities:)
      readme_html, readme_note = readme_facts(user:, dir:, listing:)
      new(dir:, head:, tags:, readme_html:, readme_note:, refusal:)
    end

    class << self
      private

      # HEAD's oid/summary/author/time and the tags sitting on it — LOCAL_WORKTREE ONLY. Everything
      # past the capability guard reaches rugged through LocalRepo, which resolves `workdir`
      # through the port (`FileLayer::Share#absolute_path` is the only adapter that defines one) —
      # and `LocalRepo#refusal` itself is what touches it, one line into `compute_refusal`, BEFORE
      # any rugged call. A `root_node` with a blank `storage_path` therefore raises
      # `FileLayer::NotFound` out of `refusal`, not out of anything git-shaped — probed against
      # exactly the fixture shape template_hygiene_test.rb and page_query_budget_test.rb already
      # seed (a `.git`-marked dir built by hand, no real folder behind it). `Rugged::OSError` is
      # rescued alongside `Rugged::Error` because it does NOT descend from it (probed:
      # `Rugged::OSError.ancestors` is `IOError`, not `Rugged::Error` — `LocalRepo#compute_refusal`
      # already lists both for the identical reason); both are kept here too in case a REAL
      # repository goes flaky (a corrupt object, a permissions change) between the refusal check
      # and the read a line later, which a network filesystem makes a live possibility rather than
      # a footnote (§14a).
      def git_facts(user:, dir:, root_node:, capabilities:)
        return [ nil, [], "History is available where the library is a local folder." ] unless capabilities.local_worktree?
        return [ nil, [], "This repository's folder could not be found." ] if root_node.nil?

        local = Maker::Git::LocalRepo.open(user, root_node)
        return [ nil, [], local.refusal ] unless local.refusal.nil?

        [ local.head_summary, local.tags_at_head, nil ]
      rescue Rugged::Error, Rugged::OSError, FileLayer::NotFound, FileLayer::FetchError => e
        [ nil, [], "History unavailable (#{e.class.name.demodulize})." ]
      end

      # The first of README.md / README / readme.md among the repo's OWN root files — never one
      # nested in a subfolder, and never a query: `dir.files` is already in memory, the same rows
      # the tree section is about to render as tiles. Reads through the PORT
      # (git-editing.md: bytes the catalog tracks go through the port; a README is a catalog file
      # like any other, not git's own working-tree read) — one call per repo, on EVERY backend,
      # not gated on local_worktree?: a share/s3/chunk_remote README is still a file the port can
      # read regardless of whether this repo's git facts are available.
      def readme_facts(user:, dir:, listing:)
        row = README_NAMES.filter_map { |name| dir.files.find { |r| r.node.name == name } }.first
        return [ nil, nil ] if row.nil?

        bytes = FileLayer.current.read(user, node_id: row.node_id)
        truncated = bytes.bytesize > README_CAP
        text = truncated ? bytes.byteslice(0, README_CAP) : bytes
        # `.scrub` after forcing UTF-8: a byte cap can split a multi-byte character at the tail,
        # and a NAS file is not guaranteed to be valid UTF-8 to begin with (§14b makes the same
        # point about filenames) — either way this must degrade to a replacement character, never
        # raise Encoding::InvalidByteSequenceError out of a card into a 500 for the whole page.
        text = text.dup.force_encoding(Encoding::UTF_8).scrub

        base = Pathname.new(dir.path)
        index = library_path_index(listing)
        html = Maker::Markdown.render(text) do |href|
          target_id = index[base.join(href).cleanpath.to_s]
          target_id && Rails.application.routes.url_helpers.file_path(target_id)
        end
        note = "Showing the first #{README_CAP / 1024} KB of this README." if truncated
        [ html, note ]
      rescue FileLayer::NotFound, FileLayer::FetchError
        [ nil, "README unavailable." ]
      end

      # Full library path => node_id, for every row `listing` holds anywhere (loose, any repo, any
      # depth of subfolder) — NOT scoped to this one repo, so a README may link `../hardware/x.pdf`
      # into a SIBLING section of the same project, not only within its own subtree. Built from
      # `listing.all_rows` (already in memory — the same union the tree, Backups and Linked groups
      # render from) and `listing.path_for`, which the class documents as costing no extra query
      # (an already-built, memoised map off the one dirs pluck `Maker::LibraryTree.new` did for the
      # whole page) — so this is safe to build once per repo without showing up as SQL in
      # page_query_budget_test.rb, however many rows the project folder holds.
      #
      # `Pathname#join`/`#cleanpath` resolve "." and ".." the way a filesystem would, WITHOUT
      # touching the filesystem — pure string arithmetic on the CATALOG's own path strings, never
      # `File.expand_path` against the real (and, on share, NETWORK) disk. `href` reaching this
      # block is already guaranteed relative (no scheme, no leading "/") by
      # `Maker::Markdown.rewrite_relative_links`, so `Pathname#join` never resets to an unrelated
      # absolute path partway through.
      def library_path_index(listing)
        listing.all_rows.index_by { |row| "#{listing.path_for(row.node)}/#{row.node.name}" }
               .transform_values(&:node_id)
      end
    end
  end
end
