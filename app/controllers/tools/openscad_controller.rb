module Tools
  # The OpenSCAD addon. Rails owns the UI, param handling, auth and save-to-library; the sidecar
  # (via OpenscadClient) only renders.
  #
  # THE CENTRAL DESIGN POINT (spec §3.1): there is ONE render path and TWO sources of .scad. Every
  # action resolves its source to TEXT first — a catalog key via the sidecar's /source, a
  # bring-your-own file via FileLayer#read — and from there nothing downstream can tell them apart.
  # Do not add a `generator_key` fast path that lets the sidecar resolve the catalog itself: two
  # paths means two caches, two error surfaces, and a catalog that can drift from BYO behaviour.
  class OpenscadController < BaseController
    include Tools::LibraryFolders

    ADDON_KEY = "openscad".freeze
    # The model rendered but no preview IMAGE could be made — a deployment condition, not a bad
    # request, but the user still needs a sentence rather than a 500. See #rasterize.
    PreviewUnavailable = Class.new(StandardError)
    before_action :require_openscad!

    def index
      @generators = client.generators
      @scad_files = library_scad_files
      @saved = current_user.maker_addon_states.for_addon(ADDON_KEY)
                           .includes(:files).order(updated_at: :desc, id: :desc)
    end

    def new
      redirect_to(tools_openscad_path, alert: "Unknown generator.") if load_editor!.nil?
    rescue OpenscadClient::Error, FileLayer::NotFound, FileLayer::FetchError => e
      redirect_to tools_openscad_path, alert: "Couldn't read that generator: #{e.message}"
    end

    # POST /tools/openscad/preview -> PNG, inline.
    # Renders 3MF then rasterizes it server-side through the SAME preview renderer the library uses,
    # rather than shipping a mesh to the browser — matching Boxes' "rasterize server-side, never
    # inline untrusted markup" posture.
    def preview
      scad = source_text!
      bytes = client.render(scad:, params: scad_params(scad))
      png = rasterize(bytes)
      send_data png[:bytes], type: png[:content_type], disposition: "inline"
    rescue OpenscadParams::Invalid, OpenscadClient::Error, PreviewUnavailable,
           FileLayer::NotFound, FileLayer::FetchError => e
      render plain: e.message, status: :unprocessable_entity
    end

    # POST /tools/openscad -> save the state + write the tied bundle (3mf output + params file).
    def create
      scad = source_text!
      p = scad_params(scad)
      bytes = client.render(scad:, params: p)

      state = current_user.maker_addon_states.create!(
        addon_key: ADDON_KEY, name: params.require(:name),
        # Record WHICH source produced this so `show` and "duplicate & tweak" can reopen it. We do
        # NOT store the .scad itself (spec §6.1): for a bring-your-own file that would copy a
        # possibly restrictively-licensed design around the user's library and into any future
        # share/export path. `data` records what was rendered; the source stays where the user
        # put it.
        data: { generator: params[:generator].presence, node_id: params[:node_id].presence,
                params: p }.compact
      )
      base = state.name.parameterize.presence || "model"
      # ONE file. The params are NOT written beside it: `state.data` above is the record, and
      # `Tools::AddonParamsController` serves it as a download.
      addon_files = Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: [
          { name: "#{base}-#{state.id}.3mf", bytes:, content_type: "model/3mf", role: "output" }
        ]
      )
      attach_addon_files_to_current_project(addon_files)
      redirect_to tools_openscad_design_path(state), notice: "Saved “#{state.name}”."
    rescue OpenscadParams::Invalid => e
      # A REJECTED VALUE IS SOMETHING TO FIX, so hand the editor straight back with the user's own
      # values still in it. Bouncing to the index would make the check cost them the whole form,
      # which is how a correctness guard turns into something people route around. `flash.now` +
      # render rather than a redirect: submitted values can be long, and a redirect would have to
      # carry every one of them in the query string.
      editor_again(e.message)
    rescue OpenscadClient::Error, FileLayer::NotFound, FileLayer::FetchError => e
      redirect_to tools_openscad_path, alert: "Generation failed: #{e.message}"
    end

    def show
      @state = current_user.maker_addon_states.for_addon(ADDON_KEY).find(params[:id])
    end

    private

    def client = OpenscadClient.current

    def require_openscad!
      return if OpenscadClient.configured? || OpenscadClient.stubbed?

      redirect_to tools_path, alert: "OpenSCAD isn't configured on this deployment."
    end

    # 3MF -> PNG, with every way the rasterizer can fail collapsed into ONE readable condition.
    # A sidecar-produced 3MF carries no slicer thumbnail, so this ALWAYS falls through to ThreeMf's
    # mesh path, which shells out to the `stl-thumbnailer` binary — absent on a dev box and on any
    # deployment that hasn't installed it. Open3 answers that with Errno::ENOENT, which is in
    # nobody's rescue list, so without this a missing binary is a 500 on the addon's main
    # interaction. (Boxes takes the same posture for a missing resvg; it can fall back to the raw
    # SVG, and there is no equivalent here — a browser cannot display a 3MF.)
    def rasterize(bytes)
      Maker::Previews::ThreeMf.render(bytes, size: 512)
    rescue Maker::Previews::ThreeMf::NoThumbnail, Maker::Previews::Stl::RenderError,
           Errno::ENOENT, Errno::EACCES => e
      raise PreviewUnavailable, "the model rendered, but no preview image could be made: #{e.message}"
    end

    # Everything the editor view needs, for `new` AND for `create`'s re-render on a rejected value.
    # -> the source, or nil when the generator key is unknown.
    def load_editor!
      @source = resolve_source
      return nil if @source.nil?

      @param_groups = @source[:param_groups]
      # Doubles as the prefill on `new` ("duplicate & tweak") and as the user's own submitted values
      # when `create` hands the form back — the same read is right for both.
      @values = params[:params]&.to_unsafe_h || {}
      # BEFORE folder_options: ensures the project folder exists so it is a selectable option.
      @default_parent_node_id = current_project_folder_node_id
      @folders = folder_options
      @prior = prior_designs_for(@source)
      @source
    end

    # Re-render the editor with an alert. Falls back to the index if the source has become
    # unreadable since the submit — a rescue clause can't be caught by its own sibling, so without
    # this the fallback would be a 500.
    def editor_again(message)
      flash.now[:alert] = message
      return redirect_to(tools_openscad_path, alert: message) if load_editor!.nil?

      render :new, status: :unprocessable_entity
    rescue OpenscadClient::Error, FileLayer::NotFound, FileLayer::FetchError => e
      redirect_to tools_openscad_path, alert: "#{message} (#{e.message})"
    end

    # --- the two sources, resolved to ONE thing: text -----------------------------------------

    # -> .scad source text for whichever source this request names. Raises rather than returning
    # nil: #preview and #create both have a rescue that turns these into a 422/alert.
    def source_text!
      if params[:node_id].present?
        FileLayer.current.read(current_user, node_id: own_scad_node_id!)
      else
        client.source(params.require(:generator))
      end
    end

    # -> { title:, subtitle:, key:, param_groups: } or nil, for the editor heading + form.
    def resolve_source
      if params[:node_id].present?
        node_id = own_scad_node_id!
        node = current_user.nodes.present.find_by(node_id:)
        scad = FileLayer.current.read(current_user, node_id:)
        { title: node.name, subtitle: "Your file", node_id:,
          param_groups: client.params_for(scad)["param_groups"] }
      else
        g = client.generators.find { |x| x.key == params[:generator] }
        return nil unless g

        { title: g.title, subtitle: "#{g.description} · #{g.license}", generator: g.key,
          license: g.license, attribution: g.attribution, source_url: g.source_url,
          param_groups: g.param_groups }
      end
    end

    # SCOPED to the user's own live files, so a forged or foreign node_id can neither read someone
    # else's bytes nor be handed to FileLayer#read at all. Raises NotFound (caught by the callers'
    # rescue) rather than returning nil, so a bad id can never fall through to a nil read.
    def own_scad_node_id!
      id = current_user.nodes.present.find_by(node_id: params[:node_id], kind: "file")&.node_id
      raise FileLayer::NotFound, "no such .scad in your library" if id.nil?

      id
    end

    # The user's .scad files, for the bring-your-own picker. `.scad` is matched case-insensitively
    # because a NAS or an S3 bucket will happily hold `Part.SCAD`.
    def library_scad_files
      current_user.nodes.present.where(kind: "file")
                  .where("LOWER(name) LIKE ?", "%.scad")
                  .order(:name).pluck(:node_id, :name)
    end

    # Saved designs made from THIS same source, newest first. Filtered in Ruby, not SQL: `data` is a
    # JSON column and `data->>'generator'` is Postgres-only, which would break the SQLite/Postgres
    # adapter-agnostic rule (CLAUDE.md §14). One user's saved designs is a small set.
    def prior_designs_for(source)
      key, value = source[:node_id] ? [ "node_id", source[:node_id] ] : [ "generator", source[:generator] ]
      current_user.maker_addon_states.for_addon(ADDON_KEY)
                  .includes(:files).order(updated_at: :desc, id: :desc)
                  .select { |s| s.data[key] == value }
    end

    # The submitted fields, COERCED against the declared schema — NOT a pass-through. A value
    # OpenSCAD cannot parse is silently IGNORED by its parameterSet, so passing text through means a
    # typo renders the default geometry with no feedback at all. See OpenscadParams for the whole
    # argument; it raises Invalid, which both callers turn into a 422 / a form-level alert.
    def scad_params(scad)
      OpenscadParams.coerce(params[:params]&.to_unsafe_h || {}, declared_param_groups(scad))
    end

    # THE SAME DECLARATION THE FORM WAS RENDERED FROM — the two branches mirror `resolve_source`'s
    # exactly, so what the user was shown and what their answers are checked against cannot drift.
    # A catalog generator's schema arrives with the catalog listing; a bring-your-own file's is
    # derived from its own source text (the sidecar memoizes that by text, so the /render call right
    # behind this one reuses it). Both are the sidecar's one derivation, so this is not a second
    # render path — only a second way of asking for a schema we were already given.
    # nil when it can't be had at all; OpenscadParams then refuses rather than forwarding unchecked.
    def declared_param_groups(scad)
      if params[:node_id].present?
        client.params_for(scad)["param_groups"]
      else
        client.generators.find { |g| g.key == params[:generator] }&.param_groups
      end
    end
  end
end
