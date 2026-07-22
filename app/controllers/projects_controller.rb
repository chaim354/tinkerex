# Server-rendered web UI for the maker Projects hub: list, create, edit, and a detail page
# tying together a build log, attached design files, and tasks.
#
# Maker data is backend-neutral: it does not live in the file library, so the file backend being
# unreachable degrades design-file THUMBNAILS (see Maker::Previews::ThumbnailMap) but never the
# page. This controller stays on the maker side of the FileLayer port — it only READS file
# metadata (never writes/moves/deletes bytes), so none of the §10 tripwire surfaces are touched.
class ProjectsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_project, only: %i[show edit update destroy]

  # Exposes the `capabilities` helper the attachments panel's upload control branches on
  # (chunk two-phase vs. share/s3 multipart). Read-only here — no action is capability-gated.
  include LibraryCapabilities

  # STATUS order for the grouped list; `archived` is intentionally excluded from the default view.
  LISTED_STATUSES = %w[planning active paused done].freeze

  def index
    projects = current_user.maker_projects.includes(:file_attachments).order(updated_at: :desc).to_a
    @by_status = projects.reject { |p| p.status == "archived" }.group_by(&:status)
    @archived_count = projects.count { |p| p.status == "archived" }
    @covers = Maker::Previews::ThumbnailMap.for(current_user, projects.filter_map(&:cover_node_id))
  end

  def show
    @attachments = @project.file_attachments.order(:position).to_a
    att_ids = @attachments.map(&:node_id)
    @att_nodes = current_user.nodes.present.where(node_id: att_ids).index_by(&:node_id)
    @thumbs = Maker::Previews::ThumbnailMap.for(current_user, att_ids)
    @entries = @project.build_log_entries.includes(:file_attachments).reorder(logged_at: :desc).to_a
    entry_photo_ids = @entries.flat_map { |e| e.file_attachments.map(&:node_id) }
    @entry_nodes = current_user.nodes.present.where(node_id: entry_photo_ids).index_by(&:node_id)
    @entry_thumbs = Maker::Previews::ThumbnailMap.for(current_user, entry_photo_ids)
    @tasks = @project.tasks.order(:position, :created_at).to_a
    # The folder project-view uploads go into. Best-effort (re-ensured here so a folder the user
    # deleted is recreated); nil → uploads fall back to the library root rather than 500 the page.
    @upload_parent_node_id = begin
      @project.ensure_library_folder!(current_user).node_id
    rescue StandardError
      nil
    end
  end

  def new
    @project = current_user.maker_projects.new(status: "planning")
  end

  def create
    @project = current_user.maker_projects.new(project_params)
    if @project.save
      ensure_project_folder(@project)
      redirect_to project_path(@project), notice: "Project created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @project.update(project_params)
      redirect_to project_path(@project), notice: "Project updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Soft archive — the model's lifecycle op (keeps the record + its history). Hard delete is a
  # deliberately deferred secondary affordance.
  def destroy
    @project.archive!
    redirect_to projects_path, notice: "Archived #{@project.name}."
  end

  private

  def set_project
    @project = current_user.maker_projects.find_by!(slug: params[:id])
  end

  # Best-effort: a project MUST save even if the library backend can't make its folder right now
  # (unmounted NAS, bucket blip). The folder is re-ensured on the next upload. Never fail creation
  # on a folder hiccup — hence the broad rescue.
  def ensure_project_folder(project)
    project.ensure_library_folder!(current_user)
  rescue StandardError => e
    Rails.logger.warn("[projects] folder ensure failed for #{project.slug}: #{e.class} #{e.message}")
  end

  def project_params
    params.require(:project).permit(:name, :description, :status)
  end
end
