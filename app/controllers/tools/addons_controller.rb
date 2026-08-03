module Tools
  # THE generic addon surface. Nothing here knows about any particular addon — that is precisely why
  # shipping a new addon needs no Rails redeploy (spec §3.1).
  class AddonsController < BaseController
    include Tools::LibraryFolders

    before_action :load_addon

    # `asset` is a plain GET that streams static bundle bytes for the browser's own
    # `<script type="module" src="...">`/ESM `import` to load — inherently non-XHR. Rails'
    # forgery protection marks every protected GET action for a same-origin check on its
    # response (`verify_same_origin_request`, actionpack's request_forgery_protection.rb) and
    # unconditionally raises `InvalidCrossOriginRequest` (-> 422) for a non-XHR JS response,
    # regardless of Origin — that guard exists to stop a third-party page's `<script src>` from
    # exfiltrating a *user-specific secret* embedded in protected JS. This response has no such
    # secret: it is the same static addon bundle for every viewer, same-origin-proxied only to
    # satisfy CSP `script_src :self` (see the `asset` action comment below), so there is nothing
    # for the guard to protect and it would otherwise make the endpoint permanently unusable for
    # its one real caller, the browser's own module loader.
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
