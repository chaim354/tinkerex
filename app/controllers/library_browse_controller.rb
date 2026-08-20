# Session-authed, user-scoped JSON data source for the reusable folder/file chooser
# (app/javascript/controllers/filechooser_controller.js). NOT the device-token v1 API — this is the
# web UI. Reads the shared `nodes` catalog (backend-neutral: chunk/share/s3 all populate it) and
# creates folders through the one cross-backend seam, Maker::LibraryFolder. No bytes flow through
# here — metadata reads and dir-node creates only (§15).
class LibraryBrowseController < ApplicationController
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

  # POST /library/folders {parent_node_id, name} -> create ONE child dir, return its node JSON.
  # Powers the chooser's "New Folder". Goes through Maker::LibraryFolder so the cross-backend mkdir
  # branch stays in its one sanctioned place (§10). Duplicate/blank/reserved names -> 422 the modal
  # shows inline. `create_child!` is find-or-create, so the duplicate guard runs BEFORE it.
  def create_folder
    name   = params[:name].to_s.strip
    parent = resolve_dir(params[:parent_node_id])
    return folder_error("Folder name can't be blank.") if name.blank?
    # ONE name check, AT THE DOOR, backend-neutral — Maker::MoveNode.valid_leaf_name?, the same
    # validator Tools::AddonsController#parse_files uses (§14c). An `include?("/")` of its own is
    # the exact defect that method was extracted to close: share and s3 each refuse a non-leaf in
    # their own `leaf!`, but CHUNK — the main deployment — has no name check anywhere downstream
    # (Sync::Mutation validates the manifest and not the name; Node validates `name` for presence
    # only), so a private, weaker spelling here means `..`, a backslash, a NUL byte and an
    # unbounded length all become live dir nodes bound for the changelog and every device mount.
    return folder_error("That folder name isn't allowed.") unless Maker::MoveNode.valid_leaf_name?(name)
    # THE SECOND HALF OF THE SAME CHECK — syntax above, the library's own reserved NAMESPACE here,
    # always asked together. Same asymmetry, same reason it survived: share and s3 refuse these in
    # `observable!` (reached via Maker::LibraryFolder's port mkdir, and surfacing as the
    # FileLayer::NotFound already rescued at the bottom of this action), while chunk's `chunk_mkdir`
    # writes the dir row itself with nothing ahead of it. A `.trash` DIRECTORY at the library root
    # is the worst of these — FileLayer::Share#observable! documents it as wedging every delete in
    # the library, permanently, and needing someone to remove it on the NAS by hand.
    return folder_error("That folder name isn't allowed.") if Library::ReservedNames.reserved?(name)
    if current_user.nodes.present.exists?(parent_node_id: parent&.node_id, name:, kind: "dir")
      return folder_error("A folder named “#{name}” already exists here.")
    end
    # THAT CHECK IS SCOPED `kind: "dir"`, SO IT IS BLIND TO A FILE AT THE SAME NAME -- which the
    # port now refuses on ALL THREE backends. Share and s3 always did (share.rb's
    # `dest.exist? && !dest.directory?`; s3's destination_vacant!); chunk was the one that used to
    # mint a dir node alongside the file node instead, two live nodes on one (parent_node_id, name),
    # unrepresentable on every mount. Stage 2 closed that -- which is exactly why this rescue has to
    # exist now: with the refusal uniform, a user who has a file named `exports` and types `exports`
    # into New Folder reaches an UnsupportedOperation that nothing here caught, and the modal that
    # promises an inline 422 got a 500 instead.
    #
    # TrashController carries this same class in its rescue_from for the same reason, and its
    # comment says so; this door never got the equivalent update.
    node = Maker::LibraryFolder.create_child!(current_user, parent_node_id: parent&.node_id, name:)
    render json: { node_id: node.node_id, name: node.name, kind: node.kind }, status: :created
  rescue FileLayer::NotFound
    # KEPT, BUT NO LONGER FOR THE REASON IT WAS WRITTEN. This used to be the reserved-name answer on
    # share/s3 — and it was the ONLY one, which is what let chunk have no answer at all. The door
    # check above now refuses those before any backend is asked, so what still reaches here is the
    # port failing to resolve the DESTINATION (a parent whose path went away between the lookup and
    # the mkdir). Same wording either way: from the modal's side both are "that folder can't be made
    # there". It stays rather than being narrowed to a 404, because a mkdir that cannot place its
    # parent is a refusal, not a missing endpoint.
    folder_error("That folder name isn't allowed.")
  rescue FileLayer::UnsupportedOperation
    # A NON-DIRECTORY ALREADY OCCUPIES THAT NAME. Deliberately its own arm rather than folded into
    # the NotFound above: "something else is already called that" is a different fact from "that
    # name isn't allowed", and the modal shows this string to someone who can fix it by picking
    # another name. §14a's recorded lesson is the same one -- a clobber answered as NotFound told a
    # user "File not found." about a file sitting in the list behind the alert.
    folder_error("Something else here is already named “#{params[:name].to_s.strip}”.")
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

  def folder_error(message)
    render json: { error: message }, status: :unprocessable_entity
  end
end
