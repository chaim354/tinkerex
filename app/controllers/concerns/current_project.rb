# Session-scoped "current project": the maker's active project, shown in the top bar and used as the
# default destination for tool output and Files-page uploads (spec 2026-07-23). Session-only by
# design — it resets on sign-out and is not shared across devices. Included in ApplicationController
# so the layout's top bar can read `current_project` on every page.
#
# It reads file metadata and creates FileAttachment REFERENCES (+ the project's library folder) only
# — it never moves bytes, so none of the file-layer split's §10 surface
# (sync/changelog/conflicts/locks/mounts) is touched.
module CurrentProject
  extend ActiveSupport::Concern

  included do
    helper_method :current_project, :current_project_choices
  end

  private

  # The selected project, or nil. User-scoped (a forged/foreign id can't resolve); archived or
  # deleted projects resolve to nil — so archiving the current project silently clears it and every
  # consumer falls back to today's behavior. Memoized per request.
  def current_project
    return @current_project if defined?(@current_project)
    id = session[:current_project_id]
    @current_project =
      if id && current_user
        current_user.maker_projects.where.not(status: "archived").find_by(id: id)
      end
  end

  # The project's Projects/<slug> folder node_id, or nil. ensure_library_folder! is idempotent and
  # (re)creates the folder; a rescue → nil falls back to the library root rather than 500-ing a page.
  def current_project_folder_node_id
    current_project&.ensure_library_folder!(current_user)&.node_id
  rescue StandardError
    nil
  end

  # [name, id] pairs for the top-bar select — this user's non-archived projects, A→Z. One indexed
  # query; only when signed in.
  def current_project_choices
    return [] unless user_signed_in?
    current_user.maker_projects.where.not(status: "archived").order(:name).pluck(:name, :id)
  end

  # Attach every addon output file to the current project (if one is set), so a tool save appears on
  # the project page. No-op when no project is current. Best-effort: the file is already saved, so a
  # failed attach must never turn a successful save into an error (mirrors enqueue_preview). Atomic,
  # so a mid-loop failure leaves no partial set. `addon_files` is what LibraryOutput.write returns;
  # roles map from the node name via FileAttachment.role_for.
  def attach_addon_files_to_current_project(addon_files)
    project = current_project
    return unless project && addon_files.present?
    names = current_user.nodes.present.where(node_id: addon_files.map(&:node_id)).pluck(:node_id, :name).to_h
    ActiveRecord::Base.transaction do
      addon_files.each do |af|
        name = names[af.node_id]
        next unless name
        project.file_attachments.create!(user: current_user, node_id: af.node_id,
                                         role: Maker::FileAttachment.role_for(name))
      end
    end
  rescue StandardError => e
    Rails.logger.warn("attach_addon_files_to_current_project failed: #{e.class}: #{e.message}")
    nil
  end
end
