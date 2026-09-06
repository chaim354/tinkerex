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
  # in ITS OWN card, never a 500 for the page. `git_facts` and `Maker::Readme` are the two places
  # that hold, and both fail closed.
  #
  # ASKS `capabilities.local_worktree?`, NEVER `is_a?(FileLayer::Share)` — git-editing.md's rule,
  # restated here rather than reinvented (LocalRepo itself asks the same way).
  #
  # SUBCLASSED RATHER THAN `Data.define(…) do … end` FOR ONE REASON: WHERE THE CONSTANTS LAND. A
  # constant assigned inside a `do … end` block is scoped LEXICALLY, so the three README constants
  # below used to be `Maker::README_CAP` and friends while every reader — this file's own comments
  # included — called them `RepoCard::README_CAP`, a spelling that raised NameError (probed,
  # 2026-09-05). Nothing outside this file named them, so making the class body real costs nothing
  # and stops the next reader from citing a constant that does not exist.
  class RepoCard < Data.define(:dir, :head, :tags, :readme_html, :readme_note, :refusal)
    # THE README RULES MOVED TO `Maker::Readme` (stage 3, S3-4) — the public project page needs the
    # same reader for the FOLDER's own README, with different rows and a different link target.
    # These three names stay as aliases because this card's rules are cited by them from outside
    # (project_repo_card_test.rb's comments, review notes); they are the SAME objects, not a second
    # definition that could drift.
    README_NAMES = Maker::Readme::NAMES
    README_CAP = Maker::Readme::CAP
    README_READ_LIMIT = Maker::Readme::READ_LIMIT

    # `root_node` is the repo dir's own Node row, fetched ONCE for every repo on the page by the
    # controller — never here. `LocalRepo.open` needs `root_node.storage_path` (through the port's
    # `absolute_path`), which `dir` (Maker::ProjectFolderListing::Dir) does not carry, so SOME query
    # is unavoidable; batching it into one `WHERE node_id IN (...)` per page rather than one `for`
    # call each is what keeps the number of repos from showing up in page_query_budget_test.rb —
    # the query-count guard counts SQL, so an O(repos) DB call for every card would fail it the
    # moment a project holds more than one, and the fixture there already does (a `.git` marker is
    # seeded once per grown row, for an unrelated reason — S3-1's own nesting coverage).
    # `link:` IS WHERE A RESOLVED RELATIVE HREF IN THE README POINTS, and it is a parameter rather
    # than the constant it used to be because THE PUBLIC PROJECT PAGE RENDERS THIS SAME CARD
    # (stage 3, S3-4) for a visitor who has no session and cannot open `/files/:id`. The default is
    # the private page's answer, so every existing caller is unchanged; `Maker::PublicProject`
    # passes a lambda onto its own `/u/<handle>/<slug>/files/:id`. A DEFAULT rather than a required
    # kwarg because the private page is the overwhelmingly common caller and a card whose links
    # silently pointed nowhere would look exactly like a card with no links.
    DEFAULT_LINK = ->(id) { Rails.application.routes.url_helpers.file_path(id) }

    def self.for(user:, dir:, root_node:, listing:, capabilities:, link: DEFAULT_LINK)
      head, tags, refusal = git_facts(user:, dir:, root_node:, capabilities:)
      # `dir.path` is the repo dir's FULL library path — the shape `listing.path_index` keys on, and
      # what a relative href in this README resolves against (Maker::Readme's own rule).
      readme = Maker::Readme.for(user:, rows: dir.files, base_path: dir.path, listing:, link:)
      new(dir:, head:, tags:, readme_html: readme&.html, readme_note: readme&.note, refusal:)
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
    end
  end
end
