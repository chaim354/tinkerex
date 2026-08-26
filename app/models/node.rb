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

  def dir? = kind == "dir"
  def file? = kind == "file"
  def symlink? = kind == "symlink"

  def children
    user.nodes.present.where(parent_node_id: node_id)
  end
end
