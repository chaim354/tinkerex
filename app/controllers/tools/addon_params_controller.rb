require "json"

module Tools
  # The params behind any addon state, as the download the `.params.json` library file used to be.
  # That file was removed 2026-07-29: nothing ever read it back, and `Maker::AddonState#data` is the
  # record. Addon-agnostic on purpose — `data` IS each addon's own shape, so there is nothing here to
  # branch on, and one endpoint serves boxes, generators and openscad alike.
  #
  # Serves the WHOLE `data` hash, which is byte-identical to the file that was removed (all three
  # addons wrote `JSON.pretty_generate` of the whole hash). `generator` is what made it
  # self-describing; the show pages' list shows only `params` because they already print the
  # generator above it.
  class AddonParamsController < BaseController
    def show
      state = current_user.maker_addon_states.find(params[:id])
      send_data JSON.pretty_generate(state.data),
                type: "application/json", disposition: "attachment", filename: filename_for(state)
    end

    private

    # `current_user.maker_addon_states.find` (above) is the tenant scope: another user's id raises
    # RecordNotFound -> 404, by construction rather than by a check someone can forget.

    # Matches what the removed file was called. `name.parameterize` can come back BLANK (a name of
    # only emoji or punctuation), which would emit "-12.params.json" — hence the addon-key fallback.
    # The per-addon fallbacks in the create actions (box/drawing/model) are not reproduced: this is a
    # download hint, not a library name.
    def filename_for(state)
      "#{state.name.parameterize.presence || state.addon_key}-#{state.id}.params.json"
    end
  end
end
