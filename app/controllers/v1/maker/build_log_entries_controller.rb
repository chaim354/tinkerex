module V1
  module Maker
    class BuildLogEntriesController < V1::BaseController
      def index
        project = current_user.maker_projects.find(params[:project_id])
        render json: { build_log_entries: project.build_log_entries.map { |e| entry_json(e) } }
      end

      def create
        project = current_user.maker_projects.find(params[:project_id])
        entry = project.build_log_entries.new(entry_params.merge(user: current_user))
        entry.save!
        render json: entry_json(entry), status: :created
      end

      def destroy
        current_user.maker_build_log_entries.find(params[:id]).destroy!
        head :no_content
      end

      private

      def entry_params
        params.require(:build_log_entry).permit(:body, :entry_type, :logged_at)
      end

      def entry_json(entry)
        { id: entry.id, project_id: entry.project_id, body: entry.body,
          entry_type: entry.entry_type, logged_at: entry.logged_at,
          created_at: entry.created_at, updated_at: entry.updated_at }
      end
    end
  end
end
