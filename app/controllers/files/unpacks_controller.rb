module Files
  # THE FOLDERS A MODEL ZIP UNPACKS INTO, AND THE CATALOG NUDGE AFTER (2026-10-21; spec
  # docs/superpowers/specs/2026-10-20-zip-upload-unpacks-models-design.md).
  #
  # THE SERVER MAKES FOLDERS AND THE BROWSER MOVES BYTES — Maker::GerberArchive's "the server lists,
  # the browser extracts", applied to writing. The top bar's Upload reads a selected zip with JSZip
  # (lib/zip_bundle.js); when it holds a model-role file the page asks #create for a folder map,
  # uploads each entry through the ordinary per-file doors (FilesController#create on share/s3,
  # #begin_upload/#finalize_upload on chunk_remote), then posts #finish once. No zip byte reaches
  # Rails (§15).
  #
  # ModelsController#ensure_folders is the Import page's twin, and the two differ on purpose: that
  # one builds `Models/<slug>/` for a catalogue row it has just made; this one builds wherever the
  # Upload button said it saves to and makes no row — Maker::ModelIntake's shelves catalogue the
  # folder like any other model folder.
  class UnpacksController < ApplicationController
    # POST /files/unpack_folder (JSON) { parent_node_id, name, dirs: [...], first_model_name }
    #   -> 201 { folder_node_id, folder_url, folder_map: { "" => id, "sub/dir" => id } }
    def create
      parent = parent_dir
      return render(json: { error: "not_found" }, status: :not_found) if parent == :missing

      # THE FIFTH WEB DOOR THAT MINTS A LEAF NAME, and it asks the same two questions in the same
      # breath as the other four (CLAUDE.md §14c): syntax, then the library's own namespace.
      name = params.require(:name).to_s
      unless leaf_ok?(name)
        return render(json: { error: "#{name.inspect} is not a valid folder name" },
                      status: :unprocessable_entity)
      end

      dest = destination(parent, params[:first_model_name].to_s)
      folder = Maker::LibraryFolder.create_child!(current_user, parent_node_id: dest&.node_id,
                                                  name: free_name(dest, name))
      render json: { folder_node_id: folder.node_id, folder_url: files_path(folder: folder.node_id),
                     folder_map: folder_map(folder) }, status: :created
    rescue FileLayer::FetchError
      render json: { error: "fetch_error" }, status: :service_unavailable
    rescue FileLayer::NotFound, FileLayer::UnsupportedOperation => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # POST /files/unpacked (JSON) { folder_node_id } -> 202
    #
    # ENQUEUES, NEVER SWEEPS: nothing sweeps inside a web request (Maker::ModelIntake::MAX_MODELS
    # says why there is no in-request cap), and the job's own limits_concurrency discards a second
    # nudge while one is queued. Without it the model card waits for the next 15-minute sweep.
    def finish
      folder = current_user.nodes.present.find_by(node_id: params.require(:folder_node_id).to_s, kind: "dir")
      return render(json: { error: "not_found" }, status: :not_found) unless folder

      Maker::ModelIntakeJob.perform_later(user_id: current_user.id)
      head :accepted
    end

    private

    # nil is the library root; :missing is an id that is not one of this user's live folders —
    # another user's included, which is a 404 and never a hint that the id exists.
    def parent_dir
      id = params[:parent_node_id].presence
      return nil if id.nil?

      current_user.nodes.present.find_by(node_id: id.to_s, kind: "dir") || :missing
    end

    def leaf_ok?(name)
      Maker::MoveNode.valid_leaf_name?(name) && !Library::ReservedNames.reserved?(name)
    end

    # AT A PROJECT'S OWN FOLDER THE ZIP GOES WHERE FILING WOULD PUT ITS FIRST MODEL — `models/` for
    # every user today (Maker::ProjectFolders.folder_for reads the per-user filing rules). The
    # project root is the sweep's inbox (§14f), and intake moves FILES only, so a folder left there
    # would never be filed. A project's SUBFOLDER is where the maker chose, and is used as it is.
    def destination(parent, first_model_name)
      return parent if parent.nil? || !current_user.maker_projects.exists?(folder_node_id: parent.node_id)

      sub = Maker::ProjectFolders.folder_for(current_user, first_model_name.presence || "model.stl")
      Maker::LibraryFolder.create_child!(current_user, parent_node_id: parent.node_id, name: sub)
    end

    # A TAKEN NAME GETS A NUMBER, and "taken" is any live child — a FILE called `dragon` blocks a
    # folder called `dragon` on every backend (LibraryBrowseController#create_folder says why).
    # CASE-FOLDED, because a share on macOS or over SMB is case-insensitive: `Dragon` and `dragon`
    # are one name there, and the mkdir would land on the existing folder.
    def free_name(dest, name)
      taken = current_user.nodes.present.where(parent_node_id: dest&.node_id).pluck(:name).map(&:downcase).to_set
      return name unless taken.include?(name.downcase)

      (2..).each do |i|
        candidate = "#{name} #{i}"
        return candidate unless taken.include?(candidate.downcase)
      end
    end

    # { "" => folder, "sub/dir" => its node } for every requested dir. A dir with any segment that
    # could not be a folder name, or that starts with a dot, is LEFT OUT, so its files fall back to
    # the root — the importer's rule (ModelsController#ensure_folders) — rather than failing the
    # unpack. The dot is that rule's and lib/zip_bundle.js's clutter skip; leaf_ok? alone passes
    # `.hidden`, an ordinary name anywhere else.
    def folder_map(folder)
      map = { "" => folder.node_id }
      Array(params[:dirs]).grep(String).reject(&:blank?).uniq.each do |rel|
        segs = rel.split("/").reject(&:blank?)
        next if segs.empty? || !segs.all? { |s| leaf_ok?(s) && !s.start_with?(".") }

        leaf = segs.reduce(folder) do |dir, seg|
          Maker::LibraryFolder.create_child!(current_user, parent_node_id: dir.node_id, name: seg)
        end
        map[rel] = leaf.node_id
      end
      map
    end
  end
end
