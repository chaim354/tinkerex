module Tools
  # The Generators addon — a client-only Maker.js harness. This controller is generator-AGNOSTIC:
  # it persists a Maker::AddonState and writes a [svg, params.json] bundle via LibraryOutput. All
  # generator schema + geometry live in JS (app/javascript/generators/*). No sidecar, no per-
  # generator branching here. Mirrors Tools::BoxesController minus the sidecar.
  class GeneratorsController < BaseController
    def index
    end
  end
end
