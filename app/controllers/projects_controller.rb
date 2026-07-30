# Server-rendered web UI for the maker Projects hub: list, create, edit, and a detail page
# tying together a build log, attached design files, and tasks.
#
# Maker data is backend-neutral: it does not live in the file library, so the file backend being
# unreachable degrades design-file THUMBNAILS (see Maker::Previews::ThumbnailMap) but never the
# page. This controller stays on the maker side of the FileLayer port — it only READS file
# metadata (never writes/moves/deletes bytes), so none of the §10 tripwire surfaces are touched.
class ProjectsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_project, only: %i[show edit update destroy unarchive]

  # Exposes the `capabilities` helper the attachments panel's upload control branches on
  # (chunk two-phase vs. share/s3 multipart). Read-only here — no action is capability-gated.
  include LibraryCapabilities

  # ?move_conflict=<id> — the prompt an attach leaves behind when the auto-move into this
  # project's folder hit a name collision. The same prompt renders on the file page; an attach can
  # come from either.
  include MoveConflicts

  # One flat list of live projects, newest activity first. `?archived=1` swaps in the archived
  # ones. The web reads `status` as archived-or-not and never shows or sets the other four values
  # (spec decision #1) — the column, its validation and the v1 API are deliberately untouched.
  def index
    # `== "1"`, not `.present?`: a checkbox submits "0" for off, and `.present?` would read that as
    # "show me the archive" — the opposite page.
    @archived_view = params[:archived] == "1"
    all = current_user.maker_projects.includes(:file_attachments).order(updated_at: :desc).to_a
    archived, live = all.partition { |p| p.status == "archived" }
    @projects = @archived_view ? archived : live
    @archived_count = archived.size
    @covers = Maker::Previews::ThumbnailMap.for(current_user, @projects.filter_map(&:cover_node_id))
  end

  def show
    @attachments = @project.file_attachments.order(:position).to_a
    att_ids = @attachments.map(&:node_id)
    @att_nodes = current_user.nodes.present.where(node_id: att_ids).index_by(&:node_id)
    @thumbs = Maker::Previews::ThumbnailMap.for(current_user, att_ids)
    # :rich_text_body is Action Text's association for `has_rich_text :body`. Without it, each
    # entry's body is its own query — 15 entries cost 15 extra round-trips. Pinned by
    # test/integration/web/page_query_budget_test.rb.
    @entries = @project.build_log_entries
                       .includes(:file_attachments, :rich_text_body)
                       .reorder(logged_at: :desc).to_a
    entry_photo_ids = @entries.flat_map { |e| e.file_attachments.map(&:node_id) }
    @entry_nodes = current_user.nodes.present.where(node_id: entry_photo_ids).index_by(&:node_id)
    @entry_thumbs = Maker::Previews::ThumbnailMap.for(current_user, entry_photo_ids)
    @tasks = @project.tasks.order(:position, :created_at).to_a
    @sheets = @project.sheets.to_a
    # The entry form binds to a real object: `rich_text_area` reads its value from the form's
    # object, and Action Text's form helper is not built for the object-less `fields_for` the plain
    # textarea used.
    @new_entry = @project.build_log_entries.new
    # The folder project-view uploads go into. Best-effort (re-ensured here so a folder the user
    # deleted is recreated); nil → uploads fall back to the library root rather than 500 the page.
    @upload_parent_node_id = begin
      @project.ensure_library_folder!(current_user).node_id
    rescue StandardError
      nil
    end
    @move_conflict = move_conflict_prompt
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

  # The inverse of #destroy (which archives). Redirects to the live list, where the project has
  # just reappeared — landing back on the archived view it left would read as a no-op.
  def unarchive
    @project.unarchive!
    redirect_to projects_path, notice: "Restored #{@project.name}."
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
