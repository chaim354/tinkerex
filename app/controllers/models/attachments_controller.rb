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

      # create_or_find_by!, NOT create! (Task 9a's follow-up). A bare create! raised
      # ActiveRecord::RecordNotUnique, UNCAUGHT, the moment maker_file_attachments gained its
      # unique index: a double-click on "Attach" (or an importer retry after a dropped response)
      # that used to silently write a duplicate row now 500d instead — verified directly before
      # this fix existed. "Already attached" is this request's intent already satisfied by
      # whichever request won the race, not an error to surface — so this re-reads the row that
      # won instead of raising (Maker::AttachToProject#call's comment has the full argument,
      # including the residual find_by!-finds-nothing race this does not special-case either).
      att = @model.file_attachments.create_or_find_by!(user: current_user, node_id: node.node_id) do |a|
        a.role = Maker::FileAttachment.role_for(node.name)
      end
      @model.update!(cover_node_id: node.node_id) if ActiveModel::Type::Boolean.new.cast(params[:cover])
      # GATED ON previously_new_record?, not just att.role == "instructions": if this attachment
      # already existed — an ordinary re-attach, or the race above — extraction already ran for it
      # when IT was created. Re-enqueuing here would be a harmless but pointless duplicate job, and
      # the gate is what keeps "already attached" meaning nothing NEW happened, not just nothing
      # new stored.
      if att.previously_new_record? && att.role == "instructions"
        Maker::ExtractPdfMetadataJob.perform_later(model_id: @model.id, node_id: node.node_id)
      end
      # 200, not 201, when the row already existed — matching Projects::AttachmentsController's
      # own rule ("claiming Created would be a lie") rather than inventing a second one.
      render json: { id: att.id, node_id: att.node_id, role: att.role },
             status: att.previously_new_record? ? :created : :ok
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
