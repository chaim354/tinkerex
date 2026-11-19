# THE ONBOARDING WIZARD (2026-11-09; docs/superpowers/specs/2026-11-09-onboarding-wizard-design.md):
# five pages a person walks once — Choose, Tour, Project, Files, Done — on one of two tracks, `files`
# (laser, CNC, electronics, documents) or `models` (3D printing). The track lives in the URL, where
# config/routes.rb constrains it, and is never stored. The one piece of state is
# `users.onboarding_pending`: the doors that make an account for a person set it, Recent sends a
# pending account here (HomeController#index, the only redirect in), and Skip or a project made here
# clears it. Anyone can walk it again from Recent's Getting started panel or from Help.
class WelcomeController < ApplicationController
  # "Edit in <Addon>" on Done's file tiles, as Recent's tiles have it.
  include AddonOrigins

  STEPS = { choose: "Choose", tour: "Tour", project: "Project", files: "Files", done: "Done" }.freeze

  # THE FILES TRACK OFFERS EVERY KIND BUT `print`, which is the 3D track's — stated there, not asked.
  FILES_KINDS = (Maker::Project::KINDS - %w[print]).freeze

  # The extensions whose shelf the Files step names, read from the user's own filing rules so a
  # renamed shelf shows its new name (Maker::FilingRules; Settings → Shelves).
  NAMED_EXTS = %w[svg lbrn2 pdf stl].freeze

  # What Done lists. A project made a minute ago holds what was just uploaded, so this bounds an odd
  # case; it is not a page size.
  LANDED_LIMIT = 48

  helper_method :track
  before_action :set_project, only: %i[files done]

  def choose; end

  def tour; end

  def skip
    finish_onboarding!
    redirect_to root_path, status: :see_other
  end

  def new_project
    @project = current_user.maker_projects.new(kind: track == "models" ? "print" : "mixed")
  end

  def create_project
    @project = current_user.maker_projects.new(project_attributes)
    result = Maker::CreateProject.call(current_user, @project)
    return render(:new_project, status: :unprocessable_entity) unless result.created?

    # A PROJECT MADE HERE ENDS THE PENDING STATE, not Done, which is a page a closed tab never
    # reaches: a person who made a project and walked away must not be sent back to make a second.
    finish_onboarding!
    redirect_to welcome_files_path(track:, project: @project.slug), notice: result.notice, alert: result.alert
  end

  # Upload is this page's one action, aimed at the project's folder and pointed back at Done
  # (FolderDestination#use_upload_return: the share/s3 form's allowlisted `return_to` flag, the chunk
  # uploader's redirectUrl). The folder is ensured best-effort first, as ProjectsController#show
  # does: a create whose folder failed gets another try on every visit, and a port failure renders
  # the folder-pending state instead of a 500.
  def files
    @folder = project_folder
    if @folder
      use_folder_destination(@folder.node_id, path: Maker::LibraryTree.new(current_user).path_for(@folder.node_id),
                                              primary: true)
      use_upload_return("welcome_#{track}", url: welcome_done_path(track:, project: @project.slug))
    end
    rules = Maker::FilingRules.for(current_user)
    @shelves = NAMED_EXTS.index_with { |ext| rules.fetch(ext, Maker::ProjectFolders::OTHER) }
  end

  def done
    # THE CATALOG RUNS NOW ON THE 3D TRACK, NOT ON THE NEXT SCAN. On share and s3 a web upload is
    # catalogued by Library::ScanJob every 15 minutes, so an STL uploaded a moment ago would not be in
    # 3D models yet. The upload's filing sweep already moved it under models/ before the redirect
    # here, which is the order model-intake.md requires; Files::UnpacksController#finish enqueues the
    # same job for the same reason. One per user, duplicates discarded, so a reload costs nothing.
    Maker::ModelIntakeJob.perform_later(user_id: current_user.id) if track == "models"
    @groups = landed_groups
    ids = @groups.values.flatten.map(&:node_id)
    @covers = Maker::Previews::ThumbnailMap.for(current_user, ids)
    @addon_origins = addon_origins_for(ids)
  end

  private

  def track = params[:track]

  def set_project
    @project = current_user.maker_projects.find_by!(slug: params[:project].to_s)
  end

  def finish_onboarding!
    current_user.update_column(:onboarding_pending, false) if current_user.onboarding_pending?
  end

  def project_attributes
    attrs = params.require(:project).permit(:name, :description, :kind)
    attrs[:kind] = "print" if track == "models"
    attrs
  end

  def project_folder
    @project.ensure_library_folder!(current_user)
  rescue StandardError
    nil
  end

  # WHAT LANDED, grouped by the folder each file sits in. The project's ATTACHMENTS, because the
  # upload's filing sweep attaches before it moves (Maker::ProjectIntake), so an attachment is
  # exactly "a file this project holds", filed or not. A nil key is the project folder itself (a
  # README is never filed); it sorts first. Two queries, whatever the count.
  def landed_groups
    ids = @project.file_attachments.limit(LANDED_LIMIT).pluck(:node_id)
    nodes = current_user.nodes.present.where(node_id: ids, kind: "file").order(:name).to_a
    names = current_user.nodes.where(node_id: nodes.map(&:parent_node_id).uniq).pluck(:node_id, :name).to_h
    nodes.group_by { |node| node.parent_node_id == @project.folder_node_id ? nil : names[node.parent_node_id] }
         .sort_by { |folder, _| folder.to_s }.to_h
  end
end
