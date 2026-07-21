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
        user: current_user, state:, parent_node_id: nil,
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
  end
end
