# Server-rendered web UI for the 3D-print model library. Session auth (NOT the device-token v1
# API). Reads file metadata + capabilities through FileLayer.current; `create` writes FOLDERS only
# (via LibraryFolder), never bytes — the importer uploads files through the existing /files
# endpoints, so §15/§10 are untouched here.
class ModelsController < ApplicationController
  before_action :set_model, only: %i[show edit update destroy]

  include LibraryCapabilities

  # The page's ONE live-node index — `#show` renders attachments by role, a cover hero and a 3D
  # switcher off the same rows, and every one of them must skip a tombstone.
  include PageNodes

  SORTS = { "recent" => { updated_at: :desc }, "title" => { title: :asc },
            "status" => { print_status: :asc, title: :asc } }.freeze

  # Formats modelviewer_controller.js can parse client-side (STL/3MF/OBJ). STEP/IGES are role
  # "model" too but can't be rendered in-browser, so they're excluded from the 3D switcher.
  VIEWABLE_3D_EXTS = %w[stl 3mf obj].freeze
  private_constant :VIEWABLE_3D_EXTS

  def index
    models = current_user.maker_models.catalogued.includes(:file_attachments)
    models = models.by_status(params[:status])
    if params[:q].present?
      models = models.where("title LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%")
    end
    if params[:tag].present?
      models = models.joins(:tags).where(maker_tags: { name: params[:tag].to_s.strip.downcase })
    end
    @models = models.order(SORTS.fetch(params[:sort], SORTS["recent"])).to_a
    # AN AUTO MODEL WITH NO ATTACHMENTS IS AN EMPTIED FOLDER, and it is hidden rather than dismissed
    # or destroyed: the row keeps the user's title and tags and returns the moment a file does. The
    # rows themselves are cleared on the ordinary schedule by Maker::AttachmentReaper once the
    # tombstones age out, so this is a display rule and not a second reaper. Filtering in Ruby off
    # the ALREADY-LOADED :file_attachments include -- a `where.missing` would be a second query and
    # would disagree with what the cards render.
    @models.reject! { |m| m.auto? && m.file_attachments.empty? }
    @covers = Maker::Previews::ThumbnailMap.for(current_user, @models.map(&:cover_node_id))
    @all_tags = current_user.maker_tags.order(:name).pluck(:name)
    @status = params[:status]
  end

  def show
    # A FILE DELETED FROM THE LIBRARY LEAVES THIS MODEL TOO, on exactly the terms ProjectsController
    # #show has always used — `Library::Reconciler` tombstones rather than destroys, so the
    # attachment row outlives the file and every surface below has to skip it. It did not: this
    # action built the index and then handed `@by_role` and `@cover_att` the UNFILTERED list, so a
    # tombstoned attachment painted a broken gallery <img>, an <iframe> whose src 302s to the user's
    # whole Files listing under a heading reading "Instructions", and a hero cell polling a node
    # /files/thumbnails omits — a spinner that resolves never. The cover id joins the union because
    # it need not be an attachment at all.
    all_attachments = @model.file_attachments.order(:position).to_a
    @page_nodes = live_nodes_for(all_attachments.map(&:node_id) + [ @model.cover_node_id ])
    @attachments, missing = all_attachments.partition { |a| @page_nodes.key?(a.node_id) }
    # NOT SILENT, same sentence and same reason as the project panel's: a user who deleted a file by
    # accident and watched this page change otherwise has no thread to pull.
    @missing_attachment_count = missing.size
    @by_role = @attachments.group_by(&:role)
    @cover_att = @attachments.find { |a| a.node_id == @model.cover_node_id }
    # COVER ONLY, DELIBERATELY NOT THE UNION. This page paints exactly ONE thumbnail — the hero;
    # `_file_tree` is plain link_to's — so merging the way projects#show does would save no query
    # (there is no second call here) while spending ThumbnailMap::BACKFILL_LIMIT on up to 100 rows
    # and 100 jobs per view for images nothing renders. Pinned as a budget in page_nodes_test.rb.
    @covers = Maker::Previews::ThumbnailMap.for(current_user, [ @model.cover_node_id ].compact)
    # The model's browser-viewable 3D files, in position order, for the hero's "View in 3D"
    # switcher. Filter by extension (role "model" also covers STEP/IGES, which the viewer can't
    # render). Default selection = the cover file if it's viewable, else the first one.
    @viewable_3d = @attachments.filter_map do |a|
      name = @page_nodes[a.node_id].name
      ext = File.extname(name).downcase.delete(".")
      next unless VIEWABLE_3D_EXTS.include?(ext)
      { node_id: a.node_id, name:, format: ext }
    end
    @viewable_3d_default = @viewable_3d.find { |f| f[:node_id] == @model.cover_node_id } || @viewable_3d.first
    # The model's files as a folder TREE (preserves the imported zip's structure) for the detail
    # page, instead of a flat role-grouped list. Empty until a folder exists.
    @file_tree  = @model.folder_node_id ? build_file_tree(@model.folder_node_id) : []
    @file_count = count_files(@file_tree)
    @print_runs = @model.print_runs.reorder(printed_on: :desc, id: :desc).to_a
    @printers = current_user.maker_print_runs.where.not(printer: [ nil, "" ]).distinct.pluck(:printer)
    @materials = current_user.maker_print_runs.where.not(material: [ nil, "" ]).distinct.pluck(:material)
  end

  # GET /models/new — the import form (the importer Stimulus controller drives it).
  def new
    @model = current_user.maker_models.new
  end

  # POST /models (JSON only) — import step 1: create the record + ensure Models/<slug> and every
  # requested subfolder, returning a folder map the browser uploads each file into.
  #
  # DEVIATION FROM THE PLAN: reads params[:title] rather than params.require(:title). require
  # raises ActionController::ParameterMissing on a BLANK string (not just a missing key — Rails'
  # own #require treats "".present? as false), which Rails' default exception wrapper maps to 400,
  # not 422 — and ParameterMissing is a KeyError, not an ActiveRecord::RecordInvalid, so the
  # rescue below never sees it. The models_import_test.rb "a blank title is a 422, not a 500" test
  # caught this. Falling through to save! lets Maker::Model's own `validates :title, presence:
  # true` raise RecordInvalid instead, which IS rescued here — one path, 422 either way (blank or
  # missing key).
  def create
    @model = current_user.maker_models.new(title: params[:title], source_url: params[:source_url])
    @model.save!
    render json: {
      slug: @model.slug,
      model_url: model_path(@model),
      attach_url: model_attachments_path(@model),
      port_writable: capabilities.port_writable?,
      folder_map: ensure_folders(@model, Array(params[:dirs]))
    }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    render json: { error: "That name was just taken — try again." }, status: :unprocessable_entity
  end

  def edit; end

  def update
    if @model.update(model_params)
      redirect_to model_path(@model), notice: "Model updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # AN AUTO MODEL IS DISMISSED, NOT DESTROYED, AND THE ASYMMETRY IS THE POINT. Maker::ModelIntake
  # recreates any auto row whose node still holds a model file, so destroying one means the user
  # deletes it again on the next tick -- §14f's fight-the-user failure, which on chunk_remote costs
  # a changelog entry per round. The row IS the memory. Nothing recreates an imported model, so
  # that one keeps today's behaviour: delete the CATALOG ENTRY (record + attachments + print
  # runs), leaving the library files at Models/<slug>/ deliberately intact — same stance as
  # archiving a Project.
  def destroy
    if @model.auto?
      @model.update!(dismissed_at: Time.current)
      redirect_to models_path,
                  notice: "Removed #{@model.title} from the catalog. It won't be re-added by the next scan."
    else
      @model.destroy!
      redirect_to models_path, notice: "Deleted #{@model.title}."
    end
  end

  # An unmounted NAS / bucket blip while ensuring folders: 503, not a 500 or a fake "gone".
  rescue_from FileLayer::FetchError do
    respond_to do |format|
      format.html { redirect_to models_path, alert: "Couldn't reach your library. Try again." }
      format.any  { render json: { error: "fetch_error" }, status: :service_unavailable }
    end
  end

  # Defense in depth: ensure_folders filters traversal/reserved segments before they reach the
  # port, but other port ops can raise NotFound too — never let it reach the default 500.
  rescue_from FileLayer::NotFound do
    respond_to do |format|
      format.html { redirect_to models_path, alert: "That location isn't valid." }
      format.any  { render json: { error: "invalid_path" }, status: :unprocessable_entity }
    end
  end

  private

  def set_model
    @model = current_user.maker_models.find_by!(slug: params[:id])
  end

  def model_params
    params.require(:model).permit(:title, :source_url, :designer, :license, :notes, :print_status, :tag_list)
  end

  # { "" => <Models/slug node>, "sub/dir" => <node>, ... }. Always includes the model root.
  def ensure_folders(model, dirs)
    root = model.ensure_library_folder!(current_user)
    map = { "" => root.node_id }
    dirs.select { |d| d.is_a?(String) }.reject(&:blank?).uniq.each do |rel|
      segs = rel.split("/").reject(&:blank?)
      # Skip traversal ("..", ".") and any dot-prefixed segment: besides being unusual for a
      # model's own files, ".trash"/".maker-tmp-*" are reserved skip-list paths whose creation
      # would wedge the share/s3 library scan. Files under a skipped dir fall back to the model
      # root in the importer (folder_map[""]), so nothing is lost.
      next if segs.empty? || segs.any? { |s| s.start_with?(".") }
      map[rel] = Maker::LibraryFolder.ensure_path!(current_user, [ "Models", model.slug, *segs ]).node_id
    end
    map
  end

  # Fetch the whole present subtree under a folder node (BFS — one query per depth level, not per
  # node), then nest into [{dir:, children:[...]}, {file:}] with dirs first, alphabetical. Scoped
  # to current_user's nodes, so it can never reach another user's tree.
  def build_file_tree(root_node_id)
    collected = []
    frontier  = [ root_node_id ]
    until frontier.empty?
      kids = current_user.nodes.present.where(parent_node_id: frontier).to_a
      collected.concat(kids)
      frontier = kids.reject(&:file?).map(&:node_id)
    end
    nest_tree(root_node_id, collected.group_by(&:parent_node_id))
  end

  def nest_tree(parent_node_id, by_parent)
    (by_parent[parent_node_id] || [])
      .sort_by { |n| [ n.file? ? 1 : 0, n.name.to_s.downcase ] }
      .map { |n| n.file? ? { file: n } : { dir: n, children: nest_tree(n.node_id, by_parent) } }
  end

  def count_files(tree)
    tree.sum { |item| item[:file] ? 1 : count_files(item[:children]) }
  end
end
