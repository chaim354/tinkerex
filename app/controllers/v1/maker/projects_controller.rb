module V1
  module Maker
    class ProjectsController < V1::BaseController
      def index
        projects = current_user.maker_projects.by_status(params[:status]).order(updated_at: :desc)
        render json: { projects: projects.map { |p| project_json(p) } }
      end

      def show
        project = current_user.maker_projects.find(params[:id])
        render json: project_json(project, full: true)
      end

      def create
        project = current_user.maker_projects.new(project_params)
        project.save!
        render json: project_json(project, full: true), status: :created
      end

      def update
        project = current_user.maker_projects.find(params[:id])
        project.update!(project_params)
        render json: project_json(project, full: true)
      end

      def destroy
        current_user.maker_projects.find(params[:id]).destroy!
        head :no_content
      end

      private

      def project_params
        params.require(:project).permit(:name, :slug, :description, :status, :archived_at)
      end

      def project_json(project, full: false)
        base = {
          id: project.id, name: project.name, slug: project.slug, status: project.status,
          archived_at: project.archived_at, created_at: project.created_at, updated_at: project.updated_at
        }
        return base unless full
        base.merge(
          description: project.description,
          build_log_entries: project.build_log_entries.map { |e| build_log_entry_json(e) },
          file_attachments: project.file_attachments.map { |a| attachment_json(a) }
        )
      end

      def build_log_entry_json(entry)
        { id: entry.id, body: entry.body, entry_type: entry.entry_type, logged_at: entry.logged_at }
      end

      def attachment_json(att)
        { id: att.id, node_id: att.node_id, version_id: att.version_id,
          role: att.role, label: att.label, position: att.position }
      end
    end
  end
end
