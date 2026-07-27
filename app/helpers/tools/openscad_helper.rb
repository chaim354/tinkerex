module Tools
  module OpenscadHelper
    # Build the editor URL that PREFILLS the form from a saved design's params.
    #
    # `:params` is a RESERVED url_for option: it appends its hash straight onto the query string, so
    # the flat form emits `?...&cols=4` and `new`'s `params[:params]` read sees nil — the form
    # silently doesn't prefill. Nesting one level emits `?...&params[cols]=4`, which is exactly what
    # the fields (`params[<name>]`) and `new` expect. Do NOT "simplify" this. (Same trap already
    # documented and tested in Tools::BoxesHelper — it shipped broken there once.)
    def openscad_prefill_path(source_key, scad_params)
      new_tools_openscad_path(**source_key, params: { params: scad_params || {} })
    end

    # A saved design's source, as the {generator:} or {node_id:} pair `new` expects.
    def openscad_source_key(state)
      state.data["node_id"].present? ? { node_id: state.data["node_id"] } : { generator: state.data["generator"] }
    end
  end
end
