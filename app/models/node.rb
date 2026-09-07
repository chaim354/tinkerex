class Node < ApplicationRecord
  belongs_to :user

  KINDS = %w[file dir symlink].freeze

  validates :node_id, presence: true, uniqueness: { scope: :user_id }
  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :present, -> { where(deleted: false) }

  # THE `.git` MARKER IS INDEXED ON PURPOSE AND DISPLAYED NEVER. Library::RepoMetadata explains
  # why it is kept: it is the evidence that a directory IS a working tree, which is what
  # Maker::AttachToProject's :in_working_tree reads to stop the intake sweep filing a repo's root
  # files away by category. None of that is a reason to render a tile for it.
  #
  # EXCLUDED BY NAME, which is exact and costs no extra query — and on share and s3 the name is
  # the whole of it, because the contents beneath the marker are never observed and so have no
  # rows at all.
  #
  # KNOWN LIMITATION ON chunk_remote, RECORDED RATHER THAN HALF-FIXED: there the `nodes` table
  # MIRRORS the sync server's tree and the desktop client syncs `.git` whether this app likes it
  # or not, so the files INSIDE `.git` do exist as rows. This hides the MARKER on every backend
  # and does NOT hide those descendants from the flat by-extension view. Closing that needs a
  # recursive CTE on a page already in the hot path — a real per-request cost, on the product's
  # main deployment, to tidy a view — and §14j says that tree is the sync server's to decide
  # about. If it becomes a real complaint the fix belongs there, or in a materialized ancestor
  # column, not in a CTE bolted onto FilesController#index.
  scope :outside_repo_metadata, -> { where.not(name: Library::RepoMetadata::DIR_NAME) }

  # DOT-PREFIXED ENTRIES ARE HIDDEN BY DEFAULT AND REACHABLE ON REQUEST — the Finder/`ls`
  # convention, and the answer to a library where `.gitignore` x17, `.github` x11, `.piopm` x11 and
  # `.clang-format` x6 sat between the user's models on the deployed share box (78 nodes).
  #
  # A DISPLAY FILTER, NOT A SKIP, AND THE DISTINCTION IS THE ONE §14b IS BUILT AROUND. Skipping
  # these at the OBSERVER would stop them being indexed at all — and the instant a name becomes
  # unobservable, any live node still pointing there is a ghost the Reconciler can never pair,
  # whose tombstone trips the mass-deletion guard and refuses that scan AND EVERY SCAN AFTER IT,
  # permanently. That blind spot has cost four separate wedges. Hiding a row that still exists,
  # still syncs and still attaches to projects costs nothing and is trivially reversible, which is
  # exactly why `.git` was already handled this way rather than at the scanner.
  #
  # `.git` IS EXCLUDED SEPARATELY AND STAYS HIDDEN EVEN WITH HIDDEN FILES SHOWN. It is not more
  # dot-prefixed clutter: Library::RepoMetadata keeps the marker indexed as the EVIDENCE that a
  # directory is a working tree (Maker::AttachToProject reads it), and on share and s3 nothing
  # beneath it is observed at all — so revealing it offers an empty folder that cannot be opened
  # usefully. Folding it into this scope would also make "show hidden" quietly change what the
  # intake sweep's marker looks like to a reader debugging it. Two rules, two reasons.
  #
  # LIKE, NOT A RUBY FILTER, because #index counts with `.count` on this same scope before it
  # loads rows — filtering in Ruby would make the truncation banner and the pager count files the
  # page never renders, which is the §14b bug this scope's placement already exists to avoid.
  # `LIKE '.%'` is adapter-agnostic (SQLite and Postgres both), and a leading dot carries no
  # wildcard meaning, so no escaping is needed.
  #
  # STRAY `*.ptr` POINTER STUBS (stage 3, S3-1) ARE EXCLUDED UNCONDITIONALLY, NOT GATED ON
  # `show_hidden` THE WAY A DOT-FILE IS. A dot-file is ordinary clutter a user may reasonably want
  # to see (`.gitignore`, `.clang-format`); a `.ptr` stub is a leftover from the git-tracking arc
  # that NOTHING writes any more and no user has a reason to ever look at — `rake
  # projects:sweep_pointers` is the write side that actually removes one (through the port, into
  # the trash, never the two kinds this app already knows to keep distinct — see §14a's "two
  # tombstone kinds"); this is the read side, a display rule exactly like `.git`'s marker two
  # scopes up, and for the same reason: hiding a row that still exists and still syncs costs
  # nothing and is trivially reversible, where skipping it at the OBSERVER would be the §14b
  # blind spot a fifth time. `LIKE '%.ptr'` (a suffix, not the whole name) because the stub sits
  # beside its real file under that file's own name plus the suffix, not under a fixed basename.
  #
  # BUILD-OUTPUT DIRECTORIES JOIN THE DOT-DIRS (stage 4, S4-2; story 4.8), gated on `show_hidden`
  # exactly as they are — not unconditional like `.git` or `*.ptr`, because there IS a reason to
  # open one (a linker map, a generated header) and "Show hidden" is already the way in.
  # `Library::BuildOutput` holds the names and the whole argument, including why this is a DISPLAY
  # rule that must never reach an observer or a write guard, and why `build` is not on the list.
  scope :visible_entries, ->(show_hidden = false) {
    scope = outside_repo_metadata.where.not("name LIKE ?", "%.ptr")
    return scope if show_hidden

    # WRITTEN AS A POSITIVE `where("NOT (...)")` rather than `where.not(name: …, kind: "dir")`:
    # multi-attribute `where.not` builds a NAND, which is correct here and is exactly the kind of
    # correctness a later reader has to look up. `kind` is NOT NULL (db/schema.rb), so the
    # predicate has no third answer to leak rows through.
    scope.where.not("name LIKE ?", ".%")
         .where("NOT (kind = 'dir' AND name IN (?))", Library::BuildOutput::NAMES)
  }

  def dir? = kind == "dir"
  def file? = kind == "file"
  def symlink? = kind == "symlink"

  def children
    user.nodes.present.where(parent_node_id: node_id)
  end
end
