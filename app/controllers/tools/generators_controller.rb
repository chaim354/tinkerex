require "json"

module Tools
  # The Generators addon — a client-only Maker.js harness. Generator-AGNOSTIC: it persists a
  # Maker::AddonState and writes a [svg, params.json] bundle via LibraryOutput. All generator schema
  # + geometry live in JS (app/javascript/generators/*). No sidecar, no per-generator branching.
  class GeneratorsController < BaseController
    include Tools::LibraryFolders

    ADDON_KEY = "generators".freeze
    MAX_SVG_BYTES = 2_000_000 # generation is client-side + bounded; this is a backstop.

    def index
      @saved = current_user.maker_addon_states.for_addon(ADDON_KEY)
                           .includes(:files).order(updated_at: :desc, id: :desc)
      @folders = folder_options
    end

    def create
      bytes = svg_bytes
      return head(:unprocessable_entity) if bytes.blank? || bytes.bytesize > MAX_SVG_BYTES

      generator = params.require(:generator)
      state = current_user.maker_addon_states.create!(
        addon_key: ADDON_KEY, name: params.require(:name),
        data: { generator:, params: addon_params }
      )
      base = state.name.parameterize.presence || "grid"
      Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: [
          { name: "#{base}-#{state.id}.svg", bytes:, content_type: "image/svg+xml", role: "output" },
          { name: "#{base}-#{state.id}.params.json",
            bytes: JSON.pretty_generate(state.data), content_type: "application/json", role: "parameters" }
        ]
      )
      redirect_to tools_generator_path(state), notice: "Saved “#{state.name}”."
    end

    private

    def addon_params = params[:params]&.to_unsafe_h || {}

    # SVG arrives as a plain form field (SVG is text). Accept a string or an uploaded part.
    def svg_bytes
      raw = params[:svg]
      (raw.respond_to?(:read) ? raw.read : raw).to_s
    end
  end
end
