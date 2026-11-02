# Server-rendered web UI for the 3D-print model library. Session auth (NOT the device-token v1
# API). Reads file metadata + capabilities through FileLayer.current; `create` writes FOLDERS only
# (via LibraryFolder), never bytes — the importer uploads files through the existing /files
# endpoints, so §15/§10 are untouched here.
#
# SINCE SLICE 5 THE LIST IS A LIBRARY VIEW (Files::ModelsController, /files/models) and `#index` only
# 301s there. SINCE 2026-10-21 `#show` RENDERS EVERY MODEL'S OWN PAGE — its files on the left, a pane
# on the right — and no longer sends a folder model to its folder; the Library's strip stays above
# that folder's files and its title links here. What else stays here is the import, edit and destroy.
class ModelsController < ApplicationController
  before_action :set_model, only: %i[show edit update destroy]

  # The page's assembly (the live-node index, the pane, the file list), shared with the print log's
  # refusal so that door can re-render this page (Models::Page).
  include Models::Page

  # /models IS THE LIBRARY'S 3D MODELS VIEW NOW (slice 5): Files::ModelsController#index, which this
  # action's body moved to verbatim with SORTS. Permanent, keeping the filters a bookmark or a "See
  # all" link carries; anything else in the query is dropped.
  def index
    filters = request.query_parameters.slice(*Files::ModelsController::FILTERS).select { |_, value| value.is_a?(String) }
    redirect_to files_models_path(filters),
                status: :moved_permanently
  end

  # EVERY MODEL HAS ITS OWN PAGE (2026-10-21): its files on the left, a pane on the right
  # (models/_stage), Printables-style. Until then a model whose folder showed the Library's strip was
  # sent there with a 302 (Maker::ModelFolder's second answer, deleted with it); the owner asked for a
  # model with several files to open a page of its own instead.
  def show
    load_model_stage(params[:file])
    # The print log's composer opens when asked to (`?log=1`, Recent's "Log a print").
    @print_log_open = params[:log].present?
    # A FRAME REQUEST IS THE PANE ALONE: the list sits outside the frame (its scroll survives a click),
    # so a switch needs one pane's setup and nothing else, not the tree walk. models/pane renders in
    # this app's turbo_rails/frame layout, whose real <head> is what lets Turbo record the promoted
    # visit (layouts/_head says why; a bare partial here broke Back).
    return render(:pane) if turbo_frame_request_id == "model_stage"

    load_model_files
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
      redirect_to model_path(@model), notice: "Saved #{@model.title}."
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
      redirect_to files_models_path,
                  notice: "Removed #{@model.title} from the catalog. It won't be re-added by the next scan."
    else
      @model.destroy!
      redirect_to files_models_path, notice: "Deleted #{@model.title}."
    end
  end

  # An unmounted NAS / bucket blip while ensuring folders: 503, not a 500 or a fake "gone".
  rescue_from FileLayer::FetchError do
    respond_to do |format|
      format.html { redirect_to files_models_path, alert: "Couldn't reach your library. Try again." }
      format.any  { render json: { error: "fetch_error" }, status: :service_unavailable }
    end
  end

  # Defense in depth: ensure_folders filters traversal/reserved segments before they reach the
  # port, but other port ops can raise NotFound too — never let it reach the default 500.
  rescue_from FileLayer::NotFound do
    respond_to do |format|
      format.html { redirect_to files_models_path, alert: "That location isn't valid." }
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
end
