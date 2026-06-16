module V1
  module Maker
    class FileAttachmentsController < V1::BaseController
      def create
        item = current_user.maker_items.find(params[:item_id])
        att = item.file_attachments.new(attachment_params.merge(user: current_user))
        att.save!
        render json: attachment_json(att), status: :created
      end

      def destroy
        att = current_user.maker_file_attachments.find(params[:id])
        att.destroy!
        head :no_content
      end

      private

      def attachment_params
        params.require(:file_attachment).permit(:node_id, :version_id, :role, :label, :position)
      end

      def attachment_json(att)
        { id: att.id, node_id: att.node_id, version_id: att.version_id,
          role: att.role, label: att.label, position: att.position }
      end
    end
  end
end
