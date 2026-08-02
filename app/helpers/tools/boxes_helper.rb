module Tools
  module BoxesHelper
    # Build the editor URL that PREFILLS the form from a saved box's params.
    #
    # `:params` is a RESERVED url_for option: it appends its hash straight onto the query string. So
    # `new_tools_box_path(generator:, params: p)` emits `?...&x=1` (flattened, top-level) and the
    # `new` action's `params[:params]` read sees nil -> the form silently doesn't prefill. Nesting one
    # level -> url_for emits `?...&params[x]=1`, which is exactly what the form fields (`params[<name>]`)
    # and `new` expect. Do NOT "simplify" this back to `params: box_params`.
    def box_prefill_path(generator, box_params)
      new_tools_box_path(generator: generator, params: { params: box_params || {} })
    end

    # boxes.py appends a Markdown manual link — `[<glyph>](https://.../usermanual.html#anchor)` — to
    # many option help strings. Rendered verbatim it dumps the glyph + raw URL inline and wraps the
    # whole form. Split the help into [visible_text, manual_url] so the view can show clean help plus
    # one compact link. Anchored to the END so ordinary parentheses like "(in mm)" are left alone.
    MANUAL_LINK = %r{\s*\[[^\]]*\]\((https?://[^)\s]+)\)\s*\z}
    def box_help(help)
      help = help.to_s
      if (m = help.match(MANUAL_LINK))
        [ help.sub(MANUAL_LINK, "").strip, m[1] ]
      else
        [ help.strip, nil ]
      end
    end

    # The picker tile's sample photo. boxes.py illustrates each generator with a photo bundled in our
    # OWN GPL sidecar (static/samples/<Class>-thumb.jpg); this returns the Rails proxy path that fetches
    # it from the internal-only sidecar (Tools::BoxesController#thumb) — the browser never hits an
    # external host. The key IS the generator's class name = the sample filename stem. Generators with
    # no photo 404 and the tile falls back to text (thumbfallback Stimulus controller).
    def box_thumb_url(key)
      thumb_tools_boxes_path(key)
    end

    # Stable DOM id for a section, so the table of contents can link to it and the collapse controller
    # can remember whether it was left open. `parameterize` returns "" for a heading that is all
    # punctuation, and a bare "box-section-" would then collide across every such heading — hence the
    # fallback.
    def box_section_id(section, prefix: "box-section")
      "#{prefix}-#{section.to_s.parameterize.presence || 'other'}"
    end
  end
end
