module Models
  # Attach an already-uploaded library node to a model (import's final step, JSON) or detach it
  # (HTML, from the detail page). Attaching is a reference (node_id + role); it never moves or
  # uploads bytes, so no capability gating and no §10 surface. Role is derived SERVER-SIDE from the
  # node name (authoritative), mirroring Projects::AttachmentsController.
  class AttachmentsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_model, only: %i[create destroy]

    # POST /models/:model_id/attachments (JSON) { node_id, cover? }
    def create
      node = current_user.nodes.present.find_by(node_id: params.require(:node_id))
      return render(json: { error: "not_found" }, status: :not_found) unless node
      att = @model.file_attachments.create!(user: current_user, node_id: node.node_id,
                                            role: Maker::FileAttachment.role_for(node.name))
      @model.update!(cover_node_id: node.node_id) if ActiveModel::Type::Boolean.new.cast(params[:cover])
      render json: { id: att.id, node_id: att.node_id, role: att.role }, status: :created
    end

    # DELETE /models/:model_id/attachments/:id (non-shallow — see routes.rb) — remove the reference
    # only; the library file is untouched. Scoped through the model so one model's URL can't detach
    # another's attachment.
    def destroy
      att = @model.file_attachments.find(params[:id])
      att.destroy!
      redirect_back_or_to model_path(@model), notice: "Removed from model."
    end

    private

    def set_model
      @model = current_user.maker_models.find_by!(slug: params[:model_id])
    end
  end
end
