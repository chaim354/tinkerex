module Projects
  # Inline photos on a build-log entry: attach an EXISTING image node to the entry, or remove the
  # reference. Same rules as project attachments — a reference, DB-scoped ownership, no byte writes.
  # #create answers JSON too, for the chunk inline-upload flow (uploader_controller.js).
  class EntryPhotosController < ApplicationController
    before_action :authenticate_user!

    def create
      entry = current_user.maker_build_log_entries.find(params[:build_log_entry_id])
      node = current_user.nodes.present.find_by(node_id: params.require(:node_id))
      if node
        att = entry.file_attachments.create!(user: current_user, node_id: node.node_id, role: "image")
        respond_to do |format|
          format.html { redirect_to project_path(entry.project), notice: "Photo added." }
          format.json { render json: { node_id: att.node_id, role: att.role }, status: :created }
        end
      else
        respond_to do |format|
          format.html { redirect_to project_path(entry.project), alert: "That image isn't in your library." }
          format.json { render json: { error: "not_found" }, status: :not_found }
        end
      end
    end

    def destroy
      att = current_user.maker_file_attachments.find(params[:id])
      entry = att.attachable
      att.destroy!
      redirect_to project_path(entry.project), notice: "Photo removed."
    end
  end
end
