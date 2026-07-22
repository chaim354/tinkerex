require "json"

module Tools
  # The Box Generator addon. Rails owns the UI, param handling, and save-to-library; the sidecar
  # (via BoxesClient) only generates. Preview rasterizes the generated SVG to PNG (resvg) rather
  # than inlining untrusted SVG, matching the web layer's no-inline-SVG posture.
  class BoxesController < BaseController
    before_action :require_boxes!

    def index
      @generators = client.generators
      @saved = current_user.maker_addon_states.for_addon("boxes").order(updated_at: :desc)
    end

    def new
      @generator = client.generators.find { |g| g.key == params[:generator] }
      redirect_to(tools_boxes_path, alert: "Unknown generator.") and return unless @generator

      @values = params[:params]&.to_unsafe_h || {} # optional prefill (e.g. "duplicate & tweak")
      @folders = folder_options # where to save the output (existing folders + root)

      # Saved boxes made with THIS generator, newest first. Filtered in Ruby (not SQL): `data` is a
      # JSON column and a `data->>'generator'` query is Postgres-only, which would break the
      # SQLite/Postgres adapter-agnostic rule. The set is one user's saved boxes — small. `id: :desc`
      # is a deterministic tie-break on `updated_at`. `includes(:files)` preloads the rail's output
      # nodes (no N+1).
      @prior = current_user.maker_addon_states.for_addon("boxes")
                           .includes(:files).order(updated_at: :desc, id: :desc)
                           .select { |s| s.data["generator"] == @generator.key }
    end

    # POST /tools/boxes/preview -> PNG (rasterized SVG), inline.
    def preview
      svg = client.generate(generator: params.require(:generator), params: box_params)
      begin
        png = Maker::Previews::SvgRasterizer.to_png(svg, size: 512)
        send_data png, type: "image/png", disposition: "inline"
      rescue Maker::Previews::SvgRasterizer::RasterizeError
        # resvg absent (dev box): hand back the raw SVG so preview still works locally.
        send_data svg, type: "image/svg+xml", disposition: "inline"
      end
    rescue BoxesClient::Error => e
      render plain: e.message, status: :unprocessable_entity
    end

    # GET /tools/boxes/thumb/:key -> proxy a generator's sample photo from the internal-only sidecar
    # (which bundles boxes.py's GPL thumbnails), so the browser never hits an external host. Missing
    # photo -> 404, and the tile's thumbfallback controller hides the broken <img>.
    def thumb
      bytes = client.sample(params[:key].to_s)
      return head(:not_found) if bytes.blank?

      expires_in 30.days, public: true # samples are immutable (pinned ref) -> let the browser cache hard
      send_data bytes, type: "image/jpeg", disposition: "inline"
    end

    # POST /tools/boxes -> save the state + write the tied bundle (svg output + params file).
    def create
      generator = params.require(:generator)
      p = box_params
      svg = client.generate(generator:, params: p)

      state = current_user.maker_addon_states.create!(
        addon_key: "boxes", name: params.require(:name), data: { generator:, params: p }
      )
      base = state.name.parameterize.presence || "box"
      Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: [
          { name: "#{base}-#{state.id}.svg", bytes: svg,
            content_type: "image/svg+xml", role: "output" },
          { name: "#{base}-#{state.id}.params.json",
            bytes: JSON.pretty_generate({ generator:, params: p }),
            content_type: "application/json", role: "parameters" }
        ]
      )
      redirect_to tools_box_path(state), notice: "Saved “#{state.name}”."
    rescue BoxesClient::Error => e
      redirect_to tools_boxes_path, alert: "Generation failed: #{e.message}"
    end

    def show
      @state = current_user.maker_addon_states.for_addon("boxes").find(params[:id])
    end

    private

    def client = BoxesClient.current

    # Available when a sidecar is configured, or when a test has injected a stub.
    def require_boxes!
      return if BoxesClient.configured? || BoxesClient.stubbed?

      redirect_to tools_path, alert: "Box generator isn't configured on this deployment."
    end

    # params[:params] is a flat hash of the generator's fields. The sidecar validates against the
    # real schema; this is a plain pass-through of the submitted values.
    def box_params
      params[:params]&.to_unsafe_h || {}
    end

    # The folder the user picked to save into, or nil (= library root). SCOPED to the user's own
    # live dirs, so a forged/foreign node_id can't write into someone else's tree and a stale or
    # blank one simply falls back to root.
    def chosen_parent_node_id
      id = params[:parent_node_id].presence
      return nil unless id

      current_user.nodes.present.find_by(node_id: id, kind: "dir")&.node_id
    end

    # Existing folders to offer in the "save to" picker, as [label, node_id] pairs with the library
    # root first. Restricted to folders that ALREADY exist: creating folders on save needs a
    # cross-backend mkdir story we haven't built (the addon-framework plan's deferral), so the
    # picker only chooses among indexed dirs. Paths are built in Ruby (one pluck of the user's own
    # dirs — a bounded set) rather than a recursive SQL CTE, to stay SQLite/Postgres-agnostic.
    def folder_options
      rows = current_user.nodes.present.where(kind: "dir").pluck(:node_id, :parent_node_id, :name)
      by_id = rows.index_by(&:first)
      labels = {}
      label = lambda do |nid|
        return labels[nid] if labels.key?(nid)

        _id, parent, name = by_id[nid]
        prefix = parent && by_id[parent] ? label.call(parent) : ""
        labels[nid] = "#{prefix}/#{name}"
      end
      folders = rows.map { |nid, _p, _n| [ label.call(nid), nid ] }.sort_by(&:first)
      [ [ "/ (library root)", "" ] ] + folders
    end
  end
end
