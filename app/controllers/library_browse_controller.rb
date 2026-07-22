# Session-authed, user-scoped JSON data source for the reusable folder/file chooser
# (app/javascript/controllers/filechooser_controller.js). NOT the device-token v1 API — this is the
# web UI. Reads the shared `nodes` catalog (backend-neutral: chunk/share/s3 all populate it) and
# creates folders through the one cross-backend seam, Maker::LibraryFolder. No bytes flow through
# here — metadata reads and dir-node creates only (§15).
class LibraryBrowseController < ApplicationController
  before_action :authenticate_user!

  # GET /library/children?parent=<node_id>&files=0|1 -> one folder's children as JSON:
  #   { parent: <id|null>, crumbs: [{node_id,name}…], entries: [{node_id,name,kind}…] }
  # A blank/foreign/stale `parent` resolves to the library root (never another user's tree) — the
  # same guard FilesController#current_folder uses. Folders always; files only when files=1.
  def children
    parent  = resolve_dir(params[:parent])
    scope   = current_user.nodes.present.where(parent_node_id: parent&.node_id)
    scope   = scope.where(kind: "dir") unless params[:files] == "1"
    entries = scope.to_a.sort_by { |n| [ n.dir? ? 0 : 1, n.name.downcase ] }
                   .map { |n| { node_id: n.node_id, name: n.name, kind: n.kind } }
    render json: { parent: parent&.node_id, crumbs: crumbs(parent), entries: entries }
  end

  private

  def resolve_dir(id)
    id.present? ? current_user.nodes.present.find_by(node_id: id, kind: "dir") : nil
  end

  # Root -> folder as [{node_id,name}], climbing parent_node_id with a cycle guard (mirrors
  # FilesController#folder_crumbs). Small duplication over a shared concern is deliberate here —
  # the walk is 6 lines and the two callers differ in param names and return shape.
  def crumbs(folder)
    out = []
    seen = Set.new
    node = folder
    while node && seen.add?(node.node_id)
      out.unshift(node_id: node.node_id, name: node.name)
      node = node.parent_node_id &&
             current_user.nodes.present.find_by(node_id: node.parent_node_id, kind: "dir")
    end
    out
  end
end
