module Tools
  # THE generic addon surface. Nothing here knows about any particular addon — that is precisely why
  # shipping a new addon needs no Rails redeploy (spec §3.1).
  class AddonsController < BaseController
    include Tools::LibraryFolders

    before_action :load_addon

    # `skip_forgery_protection` only does `skip_before_action :verify_authenticity_token`
    # (actionpack's request_forgery_protection.rb, `protect_from_forgery`) — it does NOT skip the
    # `verify_same_origin_request` after_action, which stays installed via
    # `append_after_action :verify_same_origin_request` and runs on every request regardless. This
    # is not a no-op: `verify_authenticity_token` is the ONLY place that calls
    # `mark_for_same_origin_verification!`, and the after_action's first condition is
    # `marked_for_same_origin_verification?`. Skip the before_action and the request is never
    # marked, so the after_action's guard short-circuits to nothing. If a future reader sees the
    # after_action still `append`ed and "restores" the before_action believing the skip was inert,
    # they undo this fix.
    #
    # Scoped to exactly one effect, because `asset` is GET-only: `verified_request?` is already
    # true for every GET (`verify_authenticity_token` treats GET/HEAD as "should be safe and
    # idempotent" and never checks a token for them), so the CSRF-token check this skip removes
    # was doing nothing here regardless. The ONLY thing this skip actually disables is the
    # cross-origin-JS guard (`verify_same_origin_request`) that piggybacks on the same
    # before_action having run. That guard exists to stop a third-party page's
    # `<script src="our-host/...">` from having ITS origin execute OUR JS with the visiting
    # user's cookies attached, letting the attacker's page read a *per-user secret* the response
    # body would otherwise leak (the classic script-inclusion/JSONP-era attack the check was built
    # for). It does not apply here: every addon asset is the same static bundle for every viewer —
    # there is no per-user data in the body to exfiltrate. And it must be disabled, not narrowed:
    # `verify_same_origin_request` fires unconditionally for any non-XHR JS response regardless of
    # Origin, which is exactly what the browser's own `<script type="module" src="...">`/ESM
    # `import` load looks like (same-origin, plain GET, non-XHR) — the guard has no way to tell
    # that load apart from a hostile one, so it must go for the endpoint's one real caller to work
    # at all.
    #
    # Residual, stated plainly: `asset` still sits behind `authenticate_user!` (Tools::BaseController),
    # so this is not made anonymous. But a signed-in user's browser will run ANY page's embedded
    # `<script src>` with that user's session cookie attached, same-origin check or not — that is
    # what this skip removes. A third-party page can still `<script src>` a chosen addon key/path
    # and observe success (200 vs 404) via `onload`/`onerror`, without reading the response body.
    # That makes this endpoint a login-state oracle ("is this visitor signed in to our app?") and,
    # per addon key, an addon-inventory oracle ("does this signed-in user's server have addon X
    # configured?"). Small — no response bytes leak, no state changes — but real, and a reader
    # should not have to rediscover it. Whether that residual is acceptable, or the endpoint
    # should move to a per-manifest content hash / different auth shape to close it, is a product
    # decision, not one made by this comment.
    skip_forgery_protection only: :asset

    def show
      @importmap = merged_importmap
      @default_parent_node_id = current_project_folder_node_id
      @folders = folder_options
    end

    # Same-origin proxy for the addon's bundle and its pinned modules. Same-origin is not a
    # convenience: the addon source and the sidecars are internal-only (no `port:` in deploy.yml), so
    # a browser cannot reach them, and CSP is script_src :self (spec §4.2). Proxying is what lets the
    # addon's JS run with the host's session and no token (spec §3.3).
    #
    # NOT cached in this phase, deliberately: a stale bundle reads as "my fix didn't deploy", which is
    # worse than a slow one (spec §8 risk 3). Caching gets designed against a working pipeline with a
    # real content hash to key on.
    def asset
      body = Maker::Addons::Source.current.asset(@addon.key, params[:path])
      send_data body, type: content_type_for(params[:path]), disposition: "inline"
    rescue Maker::Addons::Source::Error
      head :not_found
    end

    private

    def load_addon
      @addon = Maker::Addons::Registry.find(params[:key])
      head :not_found unless @addon
    end

    def content_type_for(path)
      case File.extname(path.to_s)
      when ".js"   then "text/javascript"
      when ".css"  then "text/css"
      when ".json" then "application/json"
      when ".svg"  then "image/svg+xml"
      else "application/octet-stream"
      end
    end

    # The host's own pins plus the addon's, as ONE map — a document may only have one importmap, and
    # the browser honours only the first. Built per-request because the addon's pins vary; the host's
    # own pins are re-drawn from config.importmap.paths rather than mutating the shared
    # Rails.application.importmap, which is process-global and must not acquire addon entries.
    def merged_importmap
      map = Importmap::Map.new
      Rails.application.config.importmap.paths.each { |path| map.draw(path) }
      @addon.pins.each { |name, asset| map.pin name, to: tools_addon_asset_path(@addon.key, asset) }
      map
    end
  end
end
