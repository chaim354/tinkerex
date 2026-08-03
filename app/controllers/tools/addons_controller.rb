module Tools
  # THE generic addon surface. Nothing here knows about any particular addon — that is precisely why
  # shipping a new addon needs no Rails redeploy (spec §3.1).
  class AddonsController < BaseController
    include Tools::LibraryFolders

    MAX_FILES = 8
    # Kept below Rack::QueryParser's own bytesize_limit (4_194_304 = 4 MiB, Rack's hard ceiling on
    # a url-encoded request body — see Rack::Utils.default_query_parser). Anything at or above that
    # never reaches this action at all: Rack raises QueryLimitError -> ActionController::BadRequest
    # (400) while parsing params, before load_addon or create ever runs. Setting this cap ABOVE the
    # Rack ceiling would make it dead code for that request shape (a real multipart FormData upload
    # from the addon's own JS isn't bound by this same Rack limit, but a plain url-encoded POST is,
    # and this app-level check exists precisely to give a routine 422 instead of a bare 400 either
    # way). Leave real headroom under 4_194_304, not just less-than.
    MAX_FILE_BYTES = 4_000_000

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
      @service_url = service_base_url
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

    # Proxy one request to a sidecar the addon's manifest declares. THREE refusals, each 404:
    # a service the manifest does not name, a service the host has no URL for, and a traversing path.
    # The URL never comes from the addon — only from ENV — which is what keeps this from being an
    # SSRF primitive (spec §4.1).
    def service
      url = sidecar_url_for(params[:service])
      return head(:not_found) if url.nil?

      path = Maker::Addons::Source.new(url).asset_path!(params[:path])
      # `request.get?` is false for a HEAD request even though the route (`via: %i[get post]`) routes
      # HEAD to this same action like any other GET route does by default — Brakeman's VerbConfusion
      # check catches exactly this shape. `head?` is checked alongside it so a HEAD request is
      # forwarded (and its params read) the same way a GET is, not silently treated as a POST.
      get_like = request.get? || request.head?
      res = Maker::Addons::ServiceProxy.current.call(
        method: get_like ? :get : :post, url: url, path: path,
        params: get_like ? request.query_parameters : request.request_parameters
      )
      send_data res.body, type: res.content_type, disposition: "inline", status: res.status
    rescue Maker::Addons::Source::Error, Maker::Addons::ServiceProxy::Error
      head :not_found
    end

    # The addon's own saved states, for the current user, as JSON. A bundle has no database access —
    # this is how it lists (and relinks the output files of) a user's prior saves. Scoped BOTH ways —
    # by addon_key AND by current_user, in that order below — because a bundle is browser code and
    # this scoping is the only thing standing between one addon's saves and another's, or one user's
    # and a stranger's.
    def states
      states = current_user.maker_addon_states.for_addon(@addon.key)
                            .includes(:files).order(updated_at: :desc, id: :desc)
      render json: states.map { |s|
        { id: s.id, name: s.name, data: s.data, updated_at: s.updated_at,
          files: s.files.map { |f| { node_id: f.node_id, role: f.role } } }
      }
    end

    # The ONE save door for every addon. Generation happens in the browser, so the bytes arrive in
    # the request — bounded here, because a client-supplied body is not a trusted size.
    def create
      files = parse_files
      return head(:unprocessable_entity) if files.nil?

      state = current_user.maker_addon_states.create!(
        addon_key: @addon.key, name: params.require(:name), data: parse_data
      )
      addon_files = Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: files.map { |f| { name: f["name"], bytes: f["body"], content_type: f["content_type"], role: "output" } }
      )
      attach_addon_files_to_current_project(addon_files)
      redirect_to tools_addon_path(@addon.key), notice: "Saved “#{state.name}”."
    end

    private

    def load_addon
      @addon = Maker::Addons::Registry.find(params[:key])
      head :not_found unless @addon
    end

    # The base URL a bundle can reach its sidecar(s) through: append `service_name/path` and fetch.
    # Computed from the ACTUAL route (via placeholder substitution) rather than hand-duplicating its
    # pattern as a literal string, so a future change to the service route's shape cannot silently
    # desync this — the same reasoning as `merged_importmap` re-drawing from config rather than
    # mutating a shared map. A bundle names its own service (from its manifest) and appends it, so it
    # never has to know Rails' route shape at all, only string concatenation.
    #
    # The placeholders are synthetic and `delete_suffix` matches literally (not a regex), so this is
    # correct even in the degenerate case where an addon's own key collides with a placeholder.
    def service_base_url
      tools_addon_service_path(@addon.key, "__SERVICE__", "__PATH__").delete_suffix("__SERVICE__/__PATH__")
    end

    # The manifest must DECLARE the service, and the host must have a URL for it. Both, not either —
    # an addon naming a service the host never configured must not fall back to a guess.
    def sidecar_url_for(name)
      return nil unless @addon.services.include?(name.to_s)

      ENV["#{name.to_s.upcase.tr('-', '_')}_SIDECAR_URL"].presence
    end

    # Returns nil (-> 422) rather than raising, so a malformed or oversized payload is a routine
    # refusal instead of a 500.
    def parse_files
      parsed = JSON.parse(params[:files].to_s)
      return nil unless parsed.is_a?(Array) && parsed.any? && parsed.size <= MAX_FILES
      return nil unless parsed.all? { |f| f.is_a?(Hash) && f["name"].present? && f["body"].is_a?(String) }
      return nil if parsed.sum { |f| f["body"].bytesize } > MAX_FILE_BYTES

      parsed
    rescue JSON::ParserError
      nil
    end

    def parse_data
      parsed = JSON.parse(params[:data].to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
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
