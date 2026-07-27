module Projects
  # Attach an EXISTING library file to a project (or detach it). "Attach" creates a reference
  # (node_id + role); it never moves or uploads bytes, so no capability gating and no §10 surface.
  # Ownership is a DB fact (current_user.nodes) — deliberately NOT a FileLayer.stat check, so an
  # unmounted backend cannot block attaching a file the user demonstrably owns.
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

    # POST /projects/:project_id/attachments { node_id }
    def create
      node = current_user.nodes.present.find_by(node_id: params.require(:node_id))
      unless node
        return respond_to do |format|
          format.html { redirect_to new_project_attachment_path(@project), alert: "That file isn't in your library." }
          format.json { render json: { error: "not_found" }, status: :not_found }
        end
      end
      # find_or_create_by, not create!: maker_file_attachments has no uniqueness index (a unique
      # one would need a backfill dedupe, and this controller is the only writer), so a
      # double-submit or a second attach from the dropdown would otherwise make a duplicate row —
      # and the file page would then render the same project chip twice.
      att = @project.file_attachments.find_or_create_by!(user: current_user, node_id: node.node_id) do |a|
        a.role = Maker::FileAttachment.role_for(node.name)
      end
      respond_to do |format|
        format.html { redirect_to project_path(@project), notice: "Attached #{node.name}." }
        format.json { render json: { node_id: att.node_id, role: att.role }, status: :created }
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
  end
end
