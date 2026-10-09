# Server-rendered web UI for the 3D-print model library. Session auth (NOT the device-token v1
# API). Reads file metadata + capabilities through FileLayer.current; `create` writes FOLDERS only
# (via LibraryFolder), never bytes — the importer uploads files through the existing /files
# endpoints, so §15/§10 are untouched here.
class ModelsController < ApplicationController
  before_action :set_model, only: %i[show edit update destroy]

  # The page's ONE live-node index — `#show` renders attachments by role, a cover hero and a 3D
  # switcher off the same rows, and every one of them must skip a tombstone.
  include PageNodes

  SORTS = { "recent" => { updated_at: :desc }, "title" => { title: :asc },
            "status" => { print_status: :asc, title: :asc } }.freeze

  def index
    models = current_user.maker_models.catalogued.includes(:file_attachments)
    models = models.by_status(params[:status])
    # THE FILES IDIOM: LOWER on both sides, ESCAPE so sanitize_sql_like means something on SQLite,
    # capped like every other search box. This clause predates the idiom; /search previews a query
    # escaped and its "See all" landed here unescaped, so `100%` matched on one page and not the
    # other (found in review, S2-5).
    q = params[:q].to_s.strip.first(80)
    if q.present?
      models = models.where("LOWER(title) LIKE ? ESCAPE '\\'", "%#{ActiveRecord::Base.sanitize_sql_like(q.downcase)}%")
    end
    if params[:tag].present?
      # Maker::Taggable#tagged_with (stage 2, S2-5) -- same SQL this join always ran, now shared
      # with Project and InventoryItem rather than reimplemented per controller.
      models = models.tagged_with(params[:tag])
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
    # PLUS THE GALLERY'S NON-INLINE IMAGES (tinkerex#285): a .heic photo renders as a thumbnail cell
    # there, not as bytes, and the cell reads this map. Bounded by the model's own photos.
    gallery = Array(@by_role["image"]).filter_map do |a|
      a.node_id unless Maker::FileAttachment.inline_image?(@page_nodes[a.node_id]&.name.to_s)
    end
    @covers = Maker::Previews::ThumbnailMap.for(current_user, ([ @model.cover_node_id ] + gallery).compact.uniq)
    # The model's browser-viewable 3D files, in position order, for the hero's "View in 3D"
    # switcher. Default selection = the cover file if it's viewable, else the first one.
    #
    # FILTERED BY EXTENSION, NOT BY ROLE, and the two are genuinely different questions: `.fcstd`
    # is `cad_source` and IS viewable, `.f3d`/`.sldprt` are `cad_source` and are not, and `.svg` is
    # `vector` and is deliberately left out (§14d — Maker::FileAttachment::VIEWABLE_3D_EXTS says
    # why for each). This read the SAME literal `%w[stl 3mf obj]` that FilesController carried
    # until 2026-09-06; one constant now, so the file page and this page cannot drift about which
    # of a model's files open in the viewer.
    # THE MANIFEST IS PER FILE, WHICH IS WHY IT IS BUILT HERE AND NOT ON THE ELEMENT: the switcher
    # swaps one model for another, so the slicer colours and the unit factor have to travel on each
    # `<option>` (§14d — modelviewer_controller.js reads them beside `url`/`format`). `for` refuses
    # by name first, so the non-3MF entries cost nothing; a 3MF costs ONE bounded port read (one
    # query on share; on chunk_remote a chunk download through the sync server) the first time this
    # model is viewed and nothing after, cached by content token. THAT COST IS PER 3MF ATTACHMENT,
    # AND page_query_budget_test.rb DOES NOT SEE IT: its growing fixture is all `.stl`, which `for`
    # refuses by name, so the constancy it asserts is over files that never reach a read. A model
    # holding N 3MFs pays N reads on a cold cache — the same per-file shape the page's thumbnails
    # already have, stated here rather than hidden behind a guard that cannot fail for it.
    @viewable_3d = @attachments.filter_map do |a|
      node = @page_nodes[a.node_id]
      ext = File.extname(node.name).downcase.delete(".")
      next unless Maker::FileAttachment::VIEWABLE_3D_EXTS.include?(ext)
      { node_id: a.node_id, name: node.name, format: ext,
        manifest: Maker::ThreeMfManifest.for(user: current_user, node:) }
    end
    @viewable_3d_default = @viewable_3d.find { |f| f[:node_id] == @model.cover_node_id } || @viewable_3d.first
    # The model's files as a folder TREE (preserves the imported zip's structure) for the detail
    # page, instead of a flat role-grouped list.
    #
    # A MODEL WITH NO FOLDER FALLS BACK TO ITS ATTACHMENTS, AND THE PANEL IS A LIE WITHOUT IT. This
    # walked `folder_node_id`'s subtree and answered `[]` otherwise -- so a model holding live
    # attachments and no folder rendered "Files (0) / No files yet." Maker::ModelIntake makes that
    # the ordinary case rather than an edge: a ONE-FILE auto model is keyed on a FILE node, so it
    # has no folder by construction, and roughly half of what the sweep creates is one of those.
    # It was reachable before the sweep too -- `ensure_library_folder!` is best-effort at import
    # time and the controller rescues it -- just rarely.
    #
    # Found by opening the page, not by a test: every assertion here reads the tree the fixture's
    # folder produced, so none of them could see a model that has no folder at all.
    @file_tree  = file_tree_for_model
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
  # The model's folder subtree, or -- when it has no folder -- its own live attachments, flat.
  # See the comment at the assignment for why the fallback is the ordinary case, not an edge.
  def file_tree_for_model
    return build_file_tree(@model.folder_node_id) if @model.folder_node_id.present?

    @attachments.map { |a| { file: @page_nodes[a.node_id] } }
  end

  # THE FOLDER'S SHAPE, THE MODEL'S FILES. Walking the subtree gives the nesting an imported zip
  # had; `@attachments` says which of those files the model actually claims, and since 2026-09-02
  # those are NOT the same set — Maker::ModelIntake stopped giving a folder model every file
  # beneath it (§14k), so the unfiltered walk went on listing the .dxf drawings the catalog had
  # just let go, under a heading counting them.
  #
  # IT READS `@attachments`, ALREADY PARTITIONED AGAINST THE LIVE-NODE INDEX, so this adds no query
  # (the page's budget is asserted constant in N — §14e) and inherits PageNodes' tombstone rule for
  # free rather than re-deriving it. Its own walk is `.present`, so a tombstone is absent from both
  # sides and cannot come back through this door.
  def build_file_tree(root_node_id)
    collected = []
    frontier  = [ root_node_id ]
    until frontier.empty?
      kids = current_user.nodes.present.where(parent_node_id: frontier).to_a
      collected.concat(kids)
      frontier = kids.reject(&:file?).map(&:node_id)
    end
    nest_tree(root_node_id, collected.group_by(&:parent_node_id), @attachments.map(&:node_id).to_set)
  end

  # A DIRECTORY WITH NOTHING SURVIVING UNDER IT GOES TOO. Keeping it renders a folder that opens
  # onto nothing — and `docs/` holding one unclaimed `names.txt` is the ordinary case, not an edge.
  # The recursion is what makes that hold at depth: an empty branch collapses from the leaves up.
  def nest_tree(parent_node_id, by_parent, claimed)
    (by_parent[parent_node_id] || [])
      .sort_by { |n| [ n.file? ? 1 : 0, n.name.to_s.downcase ] }
      .filter_map do |n|
        if n.file?
          { file: n } if claimed.include?(n.node_id)
        else
          children = nest_tree(n.node_id, by_parent, claimed)
          { dir: n, children: } if children.any?
        end
      end
  end

  def count_files(tree)
    tree.sum { |item| item[:file] ? 1 : count_files(item[:children]) }
  end
end
