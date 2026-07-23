module Tools
  # The Generators addon — a client-only Maker.js harness. Generator-AGNOSTIC: it persists a
  # Maker::AddonState and writes a [svg, params.json] bundle via LibraryOutput. All generator schema
  # + geometry live in JS (app/javascript/generators/*). No sidecar, no per-generator branching.
  class GeneratorsController < BaseController
    include Tools::LibraryFolders

    ADDON_KEY = "generators".freeze

    def index
      @saved = current_user.maker_addon_states.for_addon(ADDON_KEY)
                           .includes(:files).order(updated_at: :desc, id: :desc)
      @folders = folder_options
    end

    private

    def addon_params = params[:params]&.to_unsafe_h || {}
  end
end
