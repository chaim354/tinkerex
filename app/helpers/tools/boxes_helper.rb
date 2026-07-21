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

    # boxes.py's own gallery illustrates each generator with a photo at
    # static/samples/<GeneratorName>-thumb.jpg. We hotlink those from GitHub raw, pinned to the SAME
    # commit the sidecar installs (keep in sync with sidecar/boxes/requirements.txt) so the photo
    # matches the deployed generator version and the URL is immutable. Many generators have no photo
    # (404) — the tile then falls back to text (see the thumbfallback Stimulus controller). The key IS
    # the generator's class name, which is exactly the sample filename.
    BOXES_SAMPLES_REF = "836f5f72bedb33ac4262ed925545eacb31e926a8".freeze
    def box_thumb_url(key)
      "https://raw.githubusercontent.com/florianfesti/boxes/#{BOXES_SAMPLES_REF}/static/samples/#{key}-thumb.jpg"
    end
  end
end
