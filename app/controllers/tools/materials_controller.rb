module Tools
  # THE MATERIAL ESTIMATE (2026-11-22; spec docs/superpowers/specs/2026-11-22-material-estimate-design.md),
  # a BUILT-IN tool with a page of its own: add flat files, give each a quantity, pick a sheet, and
  # read how many sheets they need, the total area, and a drawing of each sheet.
  #
  # STATELESS. The parts list rides in the form as hidden fields (tools/materials/_parts), so every
  # request rebuilds the estimate from what it sent (Maker::Material::Estimate) and nothing is saved.
  # Under Turbo a request answers with streams for the two regions it changed: the results always,
  # the parts list only when the list itself changed (an add, an upload, a remove) — replacing it on
  # a quantity edit would take the box being typed in away from under the cursor. Without
  # JavaScript the same request renders the whole page.
  #
  # UPLOADS HAVE THEIR OWN ACTION so they carry their own rate limit; re-figuring is arithmetic under
  # Estimate's caps and needs none.
  class MaterialsController < ApplicationController
    PART_FIELDS = %i[name node_id page width height qty reason].freeze
    STOCK_FIELDS = %i[sheet_width sheet_height gap unit rotate].freeze
    UPLOADS_PER_MINUTE = 20

    rate_limit to: UPLOADS_PER_MINUTE, within: 1.minute, by: -> { current_user.id }, only: :measure,
               name: "material-uploads", with: -> { too_many_uploads }

    def show
      @estimate = Maker::Material::Estimate.new(parts: [], stock: Maker::Material::Estimate::DEFAULT_STOCK)
      @projects = projects
    end

    def create
      estimate = submitted_estimate
      changed = false
      if params[:remove].present?
        estimate = estimate.without(Integer(params[:remove].to_s, 10, exception: false))
        changed = true
      end
      library_additions.each do |added|
        estimate = estimate.adding(added.parts, notes: added.notes)
        changed = true
      end
      render_estimate(estimate, parts_changed: changed)
    end

    def measure
      added = Maker::Material::Sources.uploads(params[:uploads])
      render_estimate(submitted_estimate.adding(added.parts, notes: added.notes), parts_changed: true)
    end

    private

    def submitted_estimate
      Maker::Material::Estimate.from_params(parts: params.permit(parts: PART_FIELDS).to_h["parts"],
                                            stock: params.permit(*STOCK_FIELDS).to_h)
    end

    def library_additions
      sources = Maker::Material::Sources
      [
        project_addition(sources),
        (sources.folder(current_user, params[:add_folder_id]) if params[:add_folder_id].present?),
        (sources.file(current_user, params[:add_file_id]) if params[:add_file_id].present?)
      ].compact
    end

    # A FOLDER INSIDE THE PROJECT, WHEN ONE WAS CHOSEN, INSTEAD OF THE WHOLE PROJECT (2026-11-23, the
    # owner's call). Picking a project opens the folder chooser inside its library folder
    # (material_estimate_controller.js#addProject): Choose at the top adds the whole project as it
    # always has, and a subfolder chosen there arrives here as `add_project_folder_id` beside the
    # project's own id, which it REPLACES — adding both would count the folder's files twice. The
    # folder is looked up from the user like any other (Sources.folder), so it needs no check that it
    # sits inside the project: a folder anywhere in the user's own library is already addable through
    # "Add a folder…". Without JavaScript the field stays empty and the project adds whole.
    def project_addition(sources)
      if params[:add_project_folder_id].present?
        sources.folder(current_user, params[:add_project_folder_id])
      elsif params[:add_project_id].present?
        sources.project(current_user, params[:add_project_id])
      end
    end

    def render_estimate(estimate, parts_changed:, status: :ok)
      @estimate = estimate
      @parts_changed = parts_changed
      @projects = projects
      respond_to do |format|
        format.turbo_stream { render :update, status: }
        format.html { render :show, status: }
      end
    end

    def too_many_uploads
      note = "Paused uploads: more than #{UPLOADS_PER_MINUTE} batches in a minute. Wait a minute, then add them again."
      render_estimate(submitted_estimate.with_note(note), parts_changed: false, status: :too_many_requests)
    end

    # The "Add a project" menu's options, each `[name, id, attributes]`. A project whose library folder
    # is live carries it as `data-folder-id`, which is what the chooser opens inside. A project with no
    # folder, or one whose folder is in the Trash, carries none and adds whole at once, as before:
    # a chooser opened on a dead folder would list nothing.
    def projects
      rows = current_user.maker_projects.where.not(status: "archived").order(:name).pluck(:name, :id, :folder_node_id)
      live = current_user.nodes.present.where(kind: "dir", node_id: rows.filter_map(&:last)).pluck(:node_id).to_set
      rows.map do |name, id, folder_id|
        [ name, id, (live.include?(folder_id) ? { "data-folder-id" => folder_id } : {}) ]
      end
    end
  end
end
