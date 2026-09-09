module Projects
  # WHAT THE PANELS DOOR AND THE DRAWER'S CONVERSIONS SHARE (2026-09-09, the page editor): the
  # owner's project by slug, a DIRS-ONLY listing for the vocabulary, and the one document over
  # them. Extracted rather than copied because two controllers building the same document from two
  # different listings is exactly how a folder key would exist for one door and not the other.
  #
  # NOT MEMOIZED PAST ONE REQUEST, for Maker::Project#panel_layout's own reason: the panels door
  # writes the column and could read the layout back in the same request.
  #
  # `current_layout`, NOT `layout`: `layout` is ActionController::Base's own class-level renderer
  # setting, and a private instance method of that name reads as a controller-level layout choice
  # to anyone who has met the framework's own (2026-09-09).
  module LayoutScoped
    extend ActiveSupport::Concern

    included do
      before_action :set_project
    end

    private

    def set_project
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
      @listing = Maker::ProjectFolderListing.new(current_user, @project, load_files: false)
    end

    def current_layout = @project.panel_layout(folders: @listing.panel_folders)

    def document = Maker::LayoutDocument.new(current_layout, @listing.tree.to_h { |dir| [ dir.node_id, dir.name ] })

    def kind_label = Maker::ProjectKind.label(@project.kind)
  end
end
