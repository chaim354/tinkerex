# Server-rendered web Trash view: list deleted files and restore (undelete) them.
#
# Deletes are tombstones and versions are kept (CLAUDE.md §5/§6), so this is purely a
# recovery surface — no new chunks are created on restore (Sync::Trash re-points the
# node at its existing current version). Kept separate from FilesController so the auth
# workstream and the file browser stay easy to merge.
class TrashController < ApplicationController
  before_action :authenticate_user!

  rescue_from ActiveRecord::RecordNotFound do
    redirect_to trash_index_path, alert: "Item not found."
  end

  # GET /trash — tombstoned nodes (name, deleted-when, size), newest first.
  def index
    @nodes = Sync::Trash.list(user: current_user).to_a
    @versions_by_node = current_user.versions
      .where(version_id: @nodes.map(&:current_version_id).compact)
      .index_by(&:version_id)
  end

  # POST /trash/:id/restore — un-tombstone; returns the file to the normal listing.
  # If the parent folder is itself deleted, restore to root (so it's reachable).
  def restore
    node, = Sync::Trash.restore(user: current_user, node_id: params[:id], to_root: true)
    LibraryChannel.broadcast_change(current_user, current_user.reload.head_seq)
    redirect_to files_path, notice: "Restored #{node.name}."
  end
end
