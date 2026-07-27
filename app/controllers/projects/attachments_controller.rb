module Projects
  # Attach an EXISTING library file to a project (or detach it). "Attach" creates a reference
  # (node_id + role) AND, on a file's first project, relocates it into that project's library
  # folder — see #create for the rule and #relocate_into_project for the mechanics.
  # Ownership is a DB fact (current_user.nodes) — deliberately NOT a FileLayer.stat check, so an
  # unmounted backend cannot block attaching a file the user demonstrably owns.
  #
  # NO CAPABILITY GATE, even though it now moves bytes: Maker::MoveNode picks the door this
  # deployment has (port move on share/s3, Sync::Mutation on chunk) and every backend has one, so
  # there is nothing to 501. The §10 boundary holds the same way Maker::LibraryFolder's does —
  # this controller calls that service and never reaches into Sync:: or the port itself.
  #
  # #create answers JSON as well as HTML: the chunk inline-upload flow (uploader_controller.js)
  # uploads via /files/{begin,finalize}_upload, then POSTs the node_id here to finish the attach.
  class AttachmentsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project, only: %i[new create]

    RECENT_LIMIT = 40

    # GET /projects/:project_id/attachments/new?q= — the picker: search by name + recent files.
    def new
      scope = current_user.nodes.present.where(kind: "file")
      scope = scope.where("name LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%") if params[:q].present?
      @results = scope.order(updated_at: :desc).limit(RECENT_LIMIT).to_a
    end

    # POST /projects/:project_id/attachments  { node_id }
    # POST /attachments                       { project_id, node_id, return_to? }
    #
    # ATTACHING ALSO RELOCATES — the rule is the user's: a file joining its first project should
    # live in that project's folder, and a file already claimed by another project should not be
    # yanked out of it. Put here, at the ONE action every attach path reaches (the file page's
    # dropdown, the project page's picker, the importer's JSON attach), so the verb means the same
    # thing everywhere. Tool and importer UPLOADS already write straight into the project folder,
    # so they arrive in place and the "already there" check short-circuits.
    #
    # THE ATTACH IS THE DURABLE HALF AND THE MOVE IS BEST-EFFORT. A collision or an unmounted NAS
    # must never lose the attachment: it is a reference the user asked for, and it is exactly as
    # true with the bytes in the old folder. Same trade as #enqueue_preview and
    # CurrentProject#attach_addon_files_to_current_project.
    def create
      node = current_user.nodes.present.find_by(node_id: params.require(:node_id))
      unless node
        return respond_to do |format|
          format.html { redirect_to new_project_attachment_path(@project), alert: "That file isn't in your library." }
          format.json { render json: { error: "not_found" }, status: :not_found }
        end
      end

      # Read BEFORE the create below, or this attach is itself the "other" project.
      attached_elsewhere = current_user.maker_file_attachments
                                       .where(node_id: node.node_id, attachable_type: "Maker::Project")
                                       .where.not(attachable_id: @project.id).exists?

      # find_or_create_by, not create!: maker_file_attachments has no uniqueness index (a unique
      # one would need a backfill dedupe, and this controller is the only writer), so a
      # double-submit or a second attach from the dropdown would otherwise make a duplicate row —
      # and the file page would then render the same project chip twice.
      att = @project.file_attachments.find_or_create_by!(user: current_user, node_id: node.node_id) do |a|
        a.role = Maker::FileAttachment.role_for(node.name)
      end

      notice = "Attached #{node.name}."
      conflict = nil
      # Files only: a directory has no place in a project folder, and FileLayer::S3#move refuses
      # one outright (movable_file!) — so this would be a policy that silently works on one
      # backend and 422s on another.
      if node.file? && !attached_elsewhere
        case relocate_into_project(node)
        when :moved       then notice = "Attached #{node.name} and moved it into #{@project.name}."
        when :conflict    then conflict = att.id
        when :unavailable then notice = "Attached #{node.name} — couldn't move it into the project folder right now."
        end
      end

      respond_to do |format|
        format.html { redirect_to attach_redirect_path(node, conflict), notice: }
        # 200, not 201, when find_or_create_by found: the whole point of the dedupe is that the
        # second attach creates nothing, so claiming Created would be a lie to the only caller
        # that reads the status (the inline-upload JS).
        format.json do
          render json: { node_id: att.node_id, role: att.role },
                 status: att.previously_new_record? ? :created : :ok
        end
      end
    end

    # DELETE /attachments/:id (shallow) — remove the reference only; the library file is untouched.
    def destroy
      att = current_user.maker_file_attachments.find(params[:id])
      project = att.attachable
      att.destroy!
      redirect_back_or_to project_path(project), notice: "Detached."
    end

    private

    def set_project
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
    end

    # Move `node` into this project's library folder. Returns a SYMBOL rather than raising,
    # because every outcome here is a normal thing that happens to a user's library and the caller
    # renders a different sentence for each — an exception would make the happy path the only one
    # written down.
    #
    # `new_name:` is unused by #create, which always moves under the node's own name; it is the
    # seam the collision prompt's retry needs ("move it in as bracket (2).stl"). It is a KEYWORD
    # rather than a second positional so the `new_name.nil?` short-circuit reads as what it is:
    # renaming in place is a real move, so only a same-folder move under the SAME name is a no-op.
    def relocate_into_project(node, new_name: nil)
      folder = @project.ensure_library_folder!(current_user)
      return :already_there if new_name.nil? && node.parent_node_id == folder.node_id

      Maker::MoveNode.call(current_user, node:, new_parent_node_id: folder.node_id, new_name:)
      :moved
    rescue Maker::MoveNode::Collision
      :conflict
    rescue FileLayer::FetchError, FileLayer::NotFound, FileLayer::UnsupportedOperation,
           ArgumentError, ActiveRecord::RecordInvalid => e
      # ArgumentError = the name is not a single path segment (MoveNode#leaf!) — a crafted
      # new_name, or a node row whose own name is blank or carries a separator. FetchError = the
      # share is unmounted or the bucket is unreachable. Neither is the user's fault and neither
      # is worth a 500 over a move we already called best-effort.
      #
      # NotFound IS IN THIS LIST DELIBERATELY, though the sibling #relocate endpoint (which the
      # user asks for explicitly) should branch on it separately and answer 404. Here it cannot be
      # a caller error: #create has already resolved the node from `current_user.nodes.present`,
      # so it is live and ours, and ensure_library_folder! has just proved the destination exists.
      # What is left is a race (tombstoned between those two statements) or an out-of-band change
      # under a share/s3 store — and either way the attachment row is ALREADY COMMITTED, so
      # letting it escape would 500 a request whose durable half succeeded.
      Rails.logger.warn("attach relocate failed: #{e.class}: #{e.message}")
      :unavailable
    end

    # Where to land after an attach. `return_to` is an ALLOWLISTED FLAG, not a URL — a
    # caller-supplied redirect target is an open redirect, and there are exactly two places this
    # action is reached from. A collision rides back as ?move_conflict=<attachment id>, which is
    # what the later conflict prompt renders from.
    def attach_redirect_path(node, conflict_id)
      if params[:return_to] == "file"
        file_path(node.node_id, move_conflict: conflict_id)
      else
        project_path(@project, move_conflict: conflict_id)
      end
    end
  end
end
