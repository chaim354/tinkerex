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

    # THE PORT'S REFUSALS, MAPPED ONCE — the gap FilesController's own rescue_from block warns
    # about, one controller over. This controller inherited none of that mapping, so every
    # condition the port answers routinely for an upload answered a 500 for an addon save: a
    # duplicate output filename on share/s3 is FileLayer::UnsupportedOperation (§14a: "a clobber is
    # UnsupportedOperation"), and an unmounted share is FetchError. Same condition, two answers,
    # one layer up — which is the shape §14a's clobber bullet and the TrashController incident both
    # describe, and which no adapter suite can see because the gap is in the CONTROLLER.
    #
    # JSON, NOT A REDIRECT-WITH-FLASH, and this is a correctness point rather than a style one: the
    # only caller is the bundle's `fetch(ctx.saveUrl, { method: "POST" })`, which branches on
    # `res.ok`. fetch FOLLOWS a 302, so answering an error the way #create answers success would
    # make a failed save arrive as `res.ok === true` and render "Saved." over a save that did not
    # happen. The status code has to carry the refusal. The body is there for the error contract
    # the addon API plan wants; today's bundles read only the status, which is why they currently
    # report a bare "Save failed."
    #
    # NotImplementedError is deliberately absent, per LibraryCapabilities: it is a wiring bug and
    # must stay a loud 500 (and it is a ScriptError, so rescue_from would not reach it anyway).
    rescue_from FileLayer::UnsupportedOperation do |e|
      render json: { error: "unsupported_operation", message: e.message },
             status: :unprocessable_entity
    end

    rescue_from FileLayer::FetchError do
      render json: { error: "fetch_error", message: "Couldn't reach your library. Try again." },
             status: :service_unavailable
    end

    # 422, NOT 404. NotFound here means the save named a destination folder that no longer exists
    # (the leaf-name arm that used to raise it is closed in #parse_files, before any write is
    # attempted). A 404 on a POST to the save endpoint reads as "this endpoint is gone", which
    # would send an addon author looking in entirely the wrong place; the honest answer is that the
    # request was refused.
    rescue_from FileLayer::NotFound do
      render json: { error: "not_found", message: "That destination folder no longer exists." },
             status: :unprocessable_entity
    end

    def show
      @importmap = merged_importmap
      @default_parent_node_id = current_project_folder_node_id
      # BOTH shapes of "where does this save go?", because a bundle may be built against either.
      # `folders` is the flat [label, node_id] list the shipped bundles build a <select> from;
      # `default_folder_label` is the one path a chooser trigger shows. This repo cannot know which
      # a given bundle reads — publishing the bundle image is the addon deploy and Rails is never
      # rebuilt (§14c) — so it answers both until the addons repo says otherwise.
      @folders = folder_options
      @default_folder_label = folder_path_label(@default_parent_node_id)
      @service_url = service_base_url
      @ctx = addon_ctx
    end

    # Same-origin proxy for the addon's bundle and its pinned modules. Same-origin is not a
    # convenience: the addon source and the sidecars are internal-only (no `port:` in deploy.yml), so
    # a browser cannot reach them, and CSP is script_src :self (spec §4.2). Proxying is what lets the
    # addon's JS run with the host's session and no token (spec §3.3).
    #
    # CACHED NOW, BOUNDED BY THE REGISTRY'S OWN TTL — see ASSET_TTL.
    def asset
      source = Maker::Addons::Source.current
      body = cached_asset(source, @addon.key, params[:path])
      # A repeat navigation inside the window then costs NOTHING — no request at all, which is the
      # larger half of the win: a page load fetches 4–6 modules at once and that burst landed on the
      # web pool every single time. `public: false` because this endpoint sits behind
      # authenticate_user! and a shared cache must not hold a response fetched with a session.
      expires_in ASSET_TTL, public: false if source.cacheable?
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
      type, disposition = proxied_delivery(res.content_type)
      send_data res.body, type:, disposition:, status: res.status
    rescue Maker::Addons::Source::Error, Maker::Addons::ServiceProxy::Error
      head :not_found
    end

    # The addon's own saved states, for the current user, as JSON. A bundle has no database access —
    # this is how it lists (and relinks the output files of) a user's prior saves. Scoped BOTH ways —
    # by addon_key AND by current_user, in that order below — because a bundle is browser code and
    # this scoping is the only thing standing between one addon's saves and another's, or one user's
    # and a stranger's. Scoped by `states_key`, not `key`: they're the same value unless the manifest
    # says otherwise (Maker::Addons::Registry#build), which is how one addon can read another's saves
    # (see the `states_key` comment there for what that widens and why it's fine here).
    def states
      states = current_user.maker_addon_states.for_addon(@addon.states_key)
                            .includes(:files).order(updated_at: :desc, id: :desc)
      render json: states.map { |s|
        { id: s.id, name: s.name, data: s.data, updated_at: s.updated_at,
          files: s.files.map { |f| { node_id: f.node_id, role: f.role } } }
      }
    end

    # The ONE save door for every addon. Generation happens in the browser, so the bytes arrive in
    # the request — bounded here, because a client-supplied body is not a trusted size.
    #
    # THE STATE AND ITS FILES ARE ONE UNIT OF WORK. Before this transaction, a save whose second
    # file collided left the AddonState row committed with the AddonFile rows of however many
    # writes happened to land first — probed on share: four files with a collision at #2 and #3
    # produced two written files, an orphan state, and a 500. The state row is the addon's own
    # record of "this save happened"; committing it for a save that did not is worse than failing.
    #
    # WHAT THE TRANSACTION DOES NOT COVER, STATED PLAINLY SO NOBODY READS MORE INTO IT: on
    # share/s3 the bytes already written are FILES/OBJECTS in the user's library and a DB rollback
    # does not remove them. They become ordinary library files (the scan indexes them on its next
    # pass), which is the honest outcome — and deliberately not "fixed" by a compensating delete
    # here, because §14a's copy->delete->tombstone landmine is exactly what inventing one produces.
    # What the rollback buys is that no AddonState/AddonFile row claims a save that did not
    # complete, and that the caller gets a routine 422 naming the collision instead of a 500.
    def create
      files = parse_files
      return head(:unprocessable_entity) if files.nil?

      parent_node_id = chosen_parent_node_id
      refuse_taken_names!(files, parent_node_id)
      # TWO COLLISION CHECKS, AGAINST TWO DIFFERENT FOLDERS, AND THAT IS THE POINT rather than
      # redundancy. #refuse_taken_names! asks about the folder the user PICKED and is terminal
      # ("pick another name"). This asks about the CATEGORY folder the sweep will file into, which
      # is where a re-save actually collides — and is answerable ("overwrite?"). The gap between
      # them is the bug: after the first save is filed, the picked folder is vacant again, so the
      # first check passes and the sweep is left holding a file it cannot place.
      placements = resolve_placements(files, parent_node_id)
      return if render_would_replace(files, placements)

      state = nil
      addon_files = nil
      ApplicationRecord.transaction do
        state = current_user.maker_addon_states.create!(
          addon_key: @addon.states_key, name: params.require(:name), data: parse_data
        )
        addon_files = Maker::Addons::LibraryOutput.write(
          user: current_user, state:, parent_node_id:,
          files: files.each_with_index.map do |f, i|
            { name: f["name"], bytes: f["body"], content_type: f["content_type"], role: "output" }
              .merge(placements[i].except(:folder))
          end
        )
      end
      attach_addon_files_to_current_project(addon_files)

      # THE EAGER NUDGE, and this door was the last browser-facing one without it. §14f names seven
      # ways a file reaches `Projects/<slug>/`; the three web upload doors call this inline and a
      # device push got one in 2b9ca85, but an addon save — where the save dialog DEFAULTS to the
      # current project's folder and the user is watching the redirect land — left its output at the
      # project root until the next sweep. That is up to 15 minutes on chunk, and on share/s3 there
      # is no `project_folder_intake` schedule at all (ProjectIntakeJob.sweep_all! declines on a
      # scannable backend), so the wait is on Library::ScanJob's own poll.
      #
      # ONE SWEEP FOR THE WHOLE SAVE. Every file in a save shares `parent_node_id`, and .for_node
      # sweeps the OWNING PROJECT rather than the one node, so the first written file covers all of
      # them — calling it per file would re-sweep the same project N times for one request.
      #
      # AFTER attach_addon_files_to_current_project, per ProjectFolderIntake's own call-site ordering
      # rule: a door that makes its own file_attachments create! for these files must do it first.
      intake_result = intake_project_folder(addon_files.first&.node_id)

      # @addon.key here, NOT states_key — this builds a ROUTE (back to this addon's own page), not a
      # data scope. The state was just filed under states_key above; conflating the two here would
      # send the user to the wrong addon's page after a states_key-diverging save.
      redirect_to tools_addon_path(@addon.key),
                  notice: project_intake_sentence("Saved “#{state.name}”", intake_result,
                                                  unfiled_by_conflict(intake_result, files.map { |f| f["name"] }))
    end

    private

    def load_addon
      @addon = Maker::Addons::Registry.find(params[:key])
      head :not_found unless @addon
    end

    # THE SDK's VIEW OF THE HOST, AS ONE SERIALIZED VALUE. Everything here is data the SERVER knows;
    # the two browser-side members of ctx (`chooseFolder`, which is a function, and the CSRF token,
    # which lives in a meta tag) are added by addon_controller.js. Splitting it that way keeps this
    # hash JSON-serializable and keeps the token out of a second place in the DOM.
    #
    # The nine legacy data attributes are NOT removed and this does not replace them — see the
    # compatibility rule in docs/addon-api-v1.md §6. This is an addition.
    def addon_ctx
      {
        apiVersion: Maker::Addons::Registry::API_VERSION,
        hostLevel: Maker::Addons::Host::LEVEL,
        capabilities: Maker::Addons::Host.capabilities,
        addon: { key: @addon.key },
        urls: {
          save: tools_addon_path(@addon.key),
          states: tools_addon_states_path(@addon.key),
          # A BASE, ending in "/" — a bundle builds `${service}/${path}` onto it. Derived from the
          # real route by service_base_url, never a literal.
          service: @service_url,
          children: library_children_path,
          create: library_folders_path
        },
        defaultFolder: { nodeId: @default_parent_node_id, label: @default_folder_label }
      }
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

    # ALL THE NAMES, CHECKED BEFORE ANY BYTE IS WRITTEN — which closes two different defects.
    #
    # 1. CHUNK MODE HAD NO CLOBBER CHECK AT ALL. Share and S3 refuse a taken destination inside
    #    FileLayer#write, so saving the same output name twice there is a refusal; on chunk the
    #    same save SUCCEEDS TWICE and leaves two sibling nodes with the same name in one directory
    #    — POSIX-illegal the moment a device materializes that directory on a real mount. One
    #    condition must not have two answers across backends; that is the port's whole job.
    # 2. IT MAKES THE PARTIAL WRITE MUCH SMALLER. LibraryOutput writes files one at a time, so a
    #    collision discovered on file #3 has already put #1 and #2 into the library — and on
    #    share/s3 those bytes are real files a DB rollback cannot take back. Asking first means the
    #    common case fails before anything is written at all.
    #
    # A CHECK, NOT A LOCK — the same caveat §14a states for S3#write's head-then-put. Two
    # simultaneous saves of the same name can both pass here; share/s3 still refuse the loser at
    # write time (-> the same 422 via rescue_from), and chunk still permits it. Closing that
    # remaining window means server-side adjudication of sibling names, which §5 of the audit
    # explicitly rules out: the CLIENT adjudicates collisions by design, and a unique index on
    # (user, parent, name) would break its displacement model.
    #
    # Raises UnsupportedOperation rather than returning a flag so it lands on the one mapping at
    # the top of this class — §14a: "the destination is taken" IS UnsupportedOperation, and a
    # second spelling of that answer is the exact drift that bullet was written about.
    # Per file: where it should go and whether it replaces what is there. An EMPTY hash is "the
    # picked folder, create" — today's behaviour, and the answer for every save that is not a
    # re-save into a project folder's root.
    #
    # PER FILE, NOT PER SAVE, because one save can collide on some outputs and not others: the
    # boxes addon emits `<base>.svg` and `<base>-plan.svg` together, and a re-save can find the
    # first name taken in its category folder and the second free. That is why
    # Maker::Addons::LibraryOutput takes a per-file destination.
    #
    # THE DESTINATION IS THE OCCUPANT'S OWN PARENT, not a folder this method resolves separately —
    # there is an occupant, so its parent IS the category folder, already created. Nothing here
    # mkdirs: a save that needs a folder made still lands at the picked folder and the sweep files
    # it, exactly as before.
    def resolve_placements(files, parent_node_id)
      files.map do |f|
        dest = Maker::ProjectIntake.destination_for(user: current_user, parent_node_id:,
                                                    name: f["name"])
        occupied = dest&.occupied_by
        next {} unless occupied

        { folder: dest.folder, parent_node_id: occupied.parent_node_id, replace: true }
      end
    end

    # 409 when a save would replace something and the user has not said so. Answers true if it
    # rendered, so #create can return.
    #
    # 409, NOT THE 422 #refuse_taken_names! RAISES, and a bundle needs the two kept apart: 422
    # (`unsupported_operation`) means "that name is taken where you asked" and never succeeds on
    # retry, while 409 means "this WOULD replace something — resend with overwrite and it will".
    # One is an error to report, the other is a question to ask.
    #
    # THE BODY NAMES EVERY COLLIDING FILE AND ITS FOLDER, so the dialog can say which output it is
    # about — a multi-file save that reported only a count would make the user guess.
    #
    # OLD BUNDLES DEGRADE HONESTLY. They branch on `res.ok` alone, so a 409 reads as "Save failed."
    # — no dialog, but also no silent second copy stranded at the project root, which is what they
    # got before. The dialog itself ships in the bundle repo.
    def render_would_replace(files, placements)
      return false if params[:overwrite].present?

      colliding = files.zip(placements).select { |_f, p| p[:replace] }
      return false if colliding.empty?

      render json: { error: "would_replace",
                     files: colliding.map { |f, p| { name: f["name"], folder: p[:folder] } } },
             status: :conflict
      true
    end

    def refuse_taken_names!(files, parent_node_id)
      taken = files.map { |f| f["name"] }.select do |name|
        Maker::MoveNode.collision?(current_user, parent_node_id:, name:, except_node_id: nil)
      end
      return if taken.empty?

      raise FileLayer::UnsupportedOperation,
            "#{taken.map(&:inspect).join(', ')} already #{taken.one? ? 'exists' : 'exist'} in that " \
            "folder. Rename the save or pick another folder."
    end

    # Returns nil (-> 422) rather than raising, so a malformed or oversized payload is a routine
    # refusal instead of a 500.
    def parse_files
      parsed = JSON.parse(params[:files].to_s)
      return nil unless parsed.is_a?(Array) && parsed.any? && parsed.size <= MAX_FILES
      return nil unless parsed.all? { |f| f.is_a?(Hash) && f["body"].is_a?(String) }
      # THE NAME CHECK, BACKEND-NEUTRAL AND BEFORE ANY WRITE. This used to be `f["name"].present?`,
      # which is not a filename check — it accepted "../../escape.txt", and on chunk (the main
      # deployment, and the one door with no name validation anywhere downstream) that produced a
      # live node with that name, bound for every device's mount. See Maker::MoveNode.valid_leaf_name?
      # for the full argument and why the guard belongs here rather than in the chunk adapter.
      return nil unless parsed.all? { |f| Maker::MoveNode.valid_leaf_name?(f["name"]) }
      # Within ONE save, too: #refuse_taken_names! asks the database, which cannot see two files
      # in this same batch claiming the same name — neither exists yet, so both pass and chunk
      # writes the duplicate pair itself.
      return nil unless parsed.map { |f| f["name"] }.uniq.size == parsed.size
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

    # WHAT A SIDECAR MAY BE SERVED AS, UNDER THIS APP'S OWN ORIGIN. `#service` used to echo
    # `res.content_type` verbatim with `disposition: "inline"`, which is a same-origin script-
    # execution channel wearing a proxy's clothes — and NOT a hypothetical one: the route is
    # `via: %i[get post]` while the boxes sidecar's `/generate` is POST-only, so a plain GET to it
    # reaches Werkzeug's 405 page, `Content-Type: text/html`, rendered inline as OUR document. The
    # bodies a sidecar emits are static today so there is no working XSS, but the channel is open
    # and the first sidecar endpoint that reflects any input closes the gap for an attacker, not us.
    # Its sibling `#asset` has always mapped through `content_type_for`; this is that same rule,
    # arriving late on the more dangerous of the two doors (a sidecar's output is DERIVED FROM USER
    # INPUT; an addon's own asset is a static file the operator published).
    #
    # THE LIST IS THE UNION OF WHAT THE SIDECARS ACTUALLY EMIT, minus what is unsafe inline —
    # verified against sidecar/boxes/app.py and sidecar/openscad/app.py, not guessed:
    #   application/json  boxes' generator lists + its JSON error bodies. LOAD-BEARING: the boxes
    #                     bundle's preview.js branches on `content-type` including "json" to read
    #                     an error message, so demoting this would silently degrade every sidecar
    #                     error to the generic fallback text.
    #   image/jpeg        the `/sample/<name>` generator photos. ALSO LOAD-BEARING: gallery.js sets
    #                     `img.src` straight at this proxy, so these must stay INLINE or the tiles
    #                     stop rendering.
    #   text/plain        openscad's catalog reads.
    #   model/*           openscad's rendered 3MF (`model/3mf`).
    #
    # image/svg+xml IS DELIBERATELY ABSENT, and that is the one entry worth explaining because it
    # is the box generator's main output. SVG is script-capable and `nosniff` does not help, so it
    # must not be a same-origin inline document. It costs nothing here: preview.js consumes the
    # render with `fetch()` + `res.text()` and re-encodes it into a `data:image/svg+xml` URL
    # itself, and neither Content-Type nor Content-Disposition affects a fetch() body. So the
    # generator keeps working byte-for-byte while the top-level-navigation path stops being a
    # script vector. If a future bundle wants an SVG straight in an `<img src>`, add it back
    # WITH a `Content-Security-Policy: sandbox` response header, not by relaxing this line.
    #
    # Anything unlisted is served as an opaque download rather than refused: a proxy that 415s on
    # an unexpected type turns a sidecar upgrade into an outage, while octet-stream + attachment
    # is inert in every browser and still delivers the bytes to a `fetch()` caller.
    PROXIED_INLINE_TYPES = %w[application/json image/jpeg image/png text/plain].freeze
    PROXIED_INLINE_TYPE_PREFIXES = %w[model/].freeze

    # -> [type, disposition]. Parameters (`; charset=utf-8`, which Flask appends to text/*) are
    # stripped before matching and not echoed back — the allowlist decides the whole header.
    def proxied_delivery(content_type)
      base = content_type.to_s.split(";").first.to_s.strip.downcase
      inline = PROXIED_INLINE_TYPES.include?(base) ||
               PROXIED_INLINE_TYPE_PREFIXES.any? { |prefix| base.start_with?(prefix) }
      inline ? [ base, "inline" ] : [ "application/octet-stream", "attachment" ]
    end

    # HOW STALE AN ASSET MAY BE, AND WHY THAT NUMBER. The old comment on #asset said caching was
    # deferred because "a stale bundle reads as 'my fix didn't deploy', which is worse than a slow
    # one", and it was right about the risk and wrong about the baseline: the addon INDEX is already
    # cached for Registry::TTL, so a republished bundle already takes up to five minutes to be
    # noticed at all. Matching that number means caching adds NO staleness the system did not
    # already have — the index and the assets it names now expire together, instead of assets being
    # fresh against an index that is not.
    #
    # NOT THE CONTENT-HASH SCHEME the audit ultimately wants (immutable URLs, cached for a year).
    # That needs a per-publish version to key on, and the manifest contract has none — Registry
    # REQUIREs key/title/icon/description/api_version/entry and nothing that changes when only an
    # asset's bytes do. Adding one is a change to the manifest format, which lives in a separate
    # repo and would have to be rolled out to every bundle; it belongs with the addon API plan, not
    # here. This is the version of the fix that is entirely inside this repo's control.
    ASSET_TTL = Maker::Addons::Registry::TTL

    # Bodies above this are served but NOT cached. A bundle asset is JS/CSS/JSON — the largest in
    # production is makerjs at ~180 KB — so anything at this scale is anomalous, and Solid Cache
    # writes to the same Postgres/SQLite the sync engine uses. Refusing to cache the outlier is
    # cheaper than discovering it as a cache table full of one file.
    MAX_CACHED_ASSET_BYTES = 8_000_000

    # THE RESCUE SITS OUTSIDE THE CACHE WRITE, and that placement is the same one Registry#all
    # documents: a Source::Error must propagate to #asset's rescue (-> 404) rather than being
    # cached. Caching a failure would turn a two-second accessory blip into five minutes of a
    # broken addon page — the exact bug Registry's comment was written about, one layer down.
    def cached_asset(source, key, path)
      return source.asset(key, path) unless source.cacheable?

      cached = Rails.cache.read(asset_cache_key(key, path))
      return cached if cached

      body = source.asset(key, path)
      if body.bytesize <= MAX_CACHED_ASSET_BYTES
        Rails.cache.write(asset_cache_key(key, path), body, expires_in: ASSET_TTL)
      end
      body
    end

    # `path` is already validated by Source.validate_asset_path! before it reaches the source, but
    # it is interpolated into a cache key here BEFORE that validation runs — so it is scoped under a
    # fixed namespace and never used to address anything but the cache.
    def asset_cache_key(key, path) = [ "maker/addons/asset", key, path.to_s ]

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
