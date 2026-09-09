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
      # WITH FILES SINCE CONTENT BLOCKS (2026-09-09): the document names an image by its PATH under
      # the project folder, so the file rows are what `folder_images` needs — `load_files: false`
      # answers `total` and the dirs alone, and an image block would then have no name to export
      # and no picture to resolve. One capped files query; the page itself pays it on every render.
      @listing = Maker::ProjectFolderListing.new(current_user, @project)
    end

    # ONE READ, TWO USES (2026-09-09, content blocks): the layout's `blocks:` pairs and the
    # document's block ROWS come from the same array. Read twice, a block created between them
    # would reach the layout with no kind — and `render "projects/#{key}"` with a `block:` key.
    def blocks = @blocks ||= @project.blocks.to_a

    def current_layout
      @project.panel_layout(folders: @listing.panel_folders, blocks: blocks.map { |b| [ b.key, b.kind ] })
    end

    # THE FOLDER'S IMAGE FILES, BY PATH RELATIVE TO THE FOLDER — what an image block or the cover
    # may name in the YAML (spec §2). `Row#role` is the filing role the listing already answers.
    # THE PATH COMES OFF `path_index`, NEVER REBUILT HERE: that map is the listing's ONE definition
    # of "this row's full library path", the same one a README's relative links resolve through, and
    # a second spelling is how the exported `file:` and the resolved one drift. The folder's own
    # path comes off the front; what is left is what a reader of the text can find in the folder.
    def folder_images
      prefix = "#{@listing.path}/"
      images = @listing.all_rows.select { |row| row.role == "image" }.map(&:node_id).to_set
      @listing.path_index.filter_map { |path, id| [ id, path.delete_prefix(prefix) ] if images.include?(id) }.to_h
    end

    def document
      Maker::LayoutDocument.new(current_layout, @listing.tree.to_h { |dir| [ dir.node_id, dir.name ] },
                                blocks: blocks, images: folder_images,
                                page: { "description" => @project.description, "cover" => @project.cover_node_id })
    end

    def kind_label = Maker::ProjectKind.label(@project.kind)
  end
end
