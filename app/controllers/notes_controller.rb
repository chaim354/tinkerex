# Per-file notes. Keyed by node_id (a bare string), session-authed, all current_user-scoped.
# Ownership is a DB fact (current_user.nodes) — no file-layer call, so an unmounted backend never
# blocks noting a file the user owns. Answers HTML (the detail-page form) and JSON (the right-click
# popover).
class NotesController < ApplicationController
  # POST /files/:node_id/notes  { note: { body } }
  def create
    node_id = params.require(:node_id)
    unless current_user.nodes.present.exists?(node_id:)
      return respond_to do |f|
        f.html { redirect_back_or_to(files_path, alert: "File not found.") }
        f.json { render json: { error: "not_found" }, status: :not_found }
      end
    end

    note = current_user.maker_notes.new(node_id:, body: params.dig(:note, :body))
    if note.save
      respond_to do |f|
        f.html { redirect_to file_path(node_id), notice: "Note added." }
        f.json { render json: { id: note.id, count: current_user.maker_notes.where(node_id:).count }, status: :created }
      end
    else
      respond_to do |f|
        f.html { redirect_to file_path(node_id), alert: note.errors.full_messages.to_sentence }
        f.json { render json: { error: note.errors.full_messages.to_sentence }, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /notes/:id
  def destroy
    note = current_user.maker_notes.find(params[:id])
    node_id = note.node_id
    note.destroy!
    redirect_to file_path(node_id), notice: "Note deleted."
  end
end
