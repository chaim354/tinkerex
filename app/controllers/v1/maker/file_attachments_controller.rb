module V1
  module Maker
    class FileAttachmentsController < V1::BaseController
      # Nested under items, projects, or build_log_entries; the route supplies exactly one
      # of :item_id / :project_id / :build_log_entry_id.
      PARENTS = {
        item_id: :maker_items,
        project_id: :maker_projects,
        build_log_entry_id: :maker_build_log_entries
      }.freeze

      def create
        parent = resolve_parent
        att = parent.file_attachments.new(attachment_params.merge(user: current_user))
        att.save!
        render json: attachment_json(att), status: :created
      end

      def destroy
        current_user.maker_file_attachments.find(params[:id]).destroy!
        head :no_content
      end

      private

      def resolve_parent
        key = PARENTS.keys.find { |k| params[k].present? }
        raise ActiveRecord::RecordNotFound, "no parent" unless key
        current_user.public_send(PARENTS[key]).find(params[key])
      end

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
