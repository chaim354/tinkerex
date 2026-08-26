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
  scope :visible_entries, ->(show_hidden = false) {
    show_hidden ? outside_repo_metadata : outside_repo_metadata.where.not("name LIKE ?", ".%")
  }

  def dir? = kind == "dir"
  def file? = kind == "file"
  def symlink? = kind == "symlink"

  def children
    user.nodes.present.where(parent_node_id: node_id)
  end
end
