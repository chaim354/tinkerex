module Tools
  # THE generic addon surface. Nothing here knows about any particular addon — that is precisely why
  # shipping a new addon needs no Rails redeploy (spec §3.1).
  class AddonsController < BaseController
    include Tools::LibraryFolders

    # TODAY'S NUMBERS, KEPT AS THE DEFAULTS SO NO PUBLISHED BUNDLE CHANGES BEHAVIOUR (spec §10.3).
    # Both are per-REQUEST: at most this many files in one save, and at most this many bytes ACROSS
    # ALL OF THEM. `ADDON_SAVE_MAX_BYTES` is deliberately NOT a per-file cap — making it one would
    # LOOSEN today's rule (8 files × 4 MB = 32 MB where 4 MB is refused now), and a cap that grows
    # when it is made explicit is not the same cap.
    DEFAULT_MAX_FILES = 8
    # 4 MB, and the number is chosen against Rack rather than picked. THE TWO WIRE SHAPES HIT
    # DIFFERENT RACK LIMITS, WHICH IS THE WHOLE REASON THIS COMMENT SURVIVES THE CAP BECOMING
    # TUNABLE — verified against rack 3.2.6, not assumed:
    #
    #   url-encoded POST -> Rack::QueryParser::BYTESIZE_LIMIT, 4_194_304 (4 MiB), env
    #                       RACK_QUERY_PARSER_BYTESIZE_LIMIT. A body at or above it never reaches
    #                       this action: each_query_pair raises QueryLimitError ->
    #                       ActionController::BadRequest (400) while parsing params, before
    #                       load_addon or create runs. So for THIS shape, raising
    #                       ADDON_SAVE_MAX_BYTES past ~4 MiB buys nothing — the app-level 422 is
    #                       simply replaced by Rack's bare 400.
    #   multipart POST   -> a DIFFERENT limit entirely, Rack::Multipart::Parser's own
    #                       RACK_MULTIPART_PARSER_BYTESIZE_LIMIT, default 10 GiB. The query
    #                       parser's 4 MiB never applies, INCLUDING to the JSON `files` text field
    #                       inside a multipart body — multipart fields are parsed by the multipart
    #                       parser, not by each_query_pair.
    #
    # So an operator raising ADDON_SAVE_MAX_BYTES gets what they asked for from the SDK (which
    # always sends multipart) and not from a hand-rolled url-encoded POST. That asymmetry is Rack's,
    # not ours, and it fails LOUDLY (a 400) rather than silently.
    DEFAULT_MAX_BYTES = 4_000_000

    # READ PER REQUEST, NOT FROZEN AT BOOT, and that is for the tests as much as the operator: a
    # guard whose limit cannot be moved from a test is a guard that gets exercised with a 4 MB
    # payload or not at all. The cost is two ENV reads per save.
    #
    # A GARBAGE VALUE FALLS BACK TO THE DEFAULT RATHER THAN TO 0. `"four".to_i` is 0, and a 0 cap
    # refuses every save in the deployment — an operator typo must not be able to turn the save
    # door off, and must certainly not be able to turn the cap off either.
    def self.max_files = positive_env_int("ADDON_SAVE_MAX_FILES", DEFAULT_MAX_FILES)
    def self.max_bytes = positive_env_int("ADDON_SAVE_MAX_BYTES", DEFAULT_MAX_BYTES)

    def self.positive_env_int(name, fallback)
      value = Integer(ENV[name].to_s, exception: false)
      value&.positive? ? value : fallback
    end

    before_action :load_addon

    # PARAMS WRAPPING OFF, AND THIS IS LOAD-BEARING FOR #service RATHER THAN TIDINESS. Rails 8
    # defaults `wrap_parameters format: [:json]` in the FRAMEWORK — there is no
    # config/initializers/wrap_parameters.rb in this repo, so grepping config/ for it finds nothing
    # and the behaviour reads as absent. It is not: ParamsWrapper MERGES a duplicate of the whole
    # body under a key derived from the controller's own name into `request.request_parameters`,
    # which is verbatim what #service forwards to the sidecar. Probed, before and after: a
    # `{generator, params}` JSON body arrived at the proxy as
    # `{"generator"=>…, "params"=>…, "addon"=>{"generator"=>…, "params"=>…}}` — every sidecar call
    # carrying a second, complete copy of itself under a key no sidecar has ever heard of.
    #
    # It only bites now because `host.service.post` sends JSON; the old FormData body was multipart,
    # which ParamsWrapper does not touch, so this was inert until the transport changed and would
    # have shipped as a doubled request body on the boxes sidecar's every keystroke-debounced render.
    # boxes.py would tolerate the extra key, which is exactly why nothing would have reported it.
    #
    # Safe for the other actions by construction: wrapping only ADDS the duplicate, so nothing that
    # reads `params[:name]` / `params[:files]` (all multipart from the save door) loses anything.
    # There is no `Addon` model for it to have been wrapping FOR.
    wrap_parameters format: []

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

    # 422, NOT 404 — AND NOT FOR THE REASON THIS COMMENT USED TO GIVE. It said "NotFound here means
    # the save named a destination folder that no longer exists", which this door cannot produce:
    # Tools::LibraryFolders#chosen_parent_node_id resolves an unknown, stale or foreign
    # parent_node_id to nil BEFORE any port call, and nil means the library ROOT. That save answers
    # 302, succeeds, and quietly writes to the root — probed on all three backends, and documented
    # for addon authors in docs/addon-api-v1.md §5, which carries the consequence (a folderNodeId
    # persisted in an AddonState can name a folder that is gone, and nothing reports it).
    #
    # THE OTHER CAUSE WAS AN OUTPUT NAME THE LIBRARY SCAN COULD NEVER OBSERVE, AND IT IS NOW CLOSED
    # ONE LAYER EARLIER — read the two paragraphs together, because the second retires the first.
    # The `observable!` guard in FileLayer::Share and FileLayer::S3 (§14b's skip-list rule) refuses
    # ".DS_Store", "._x", "__MACOSX", ".Trashes", (at the library root) ".trash" and — on share only
    # — ".maker-tmp-x", because a file written to a path the scan skips is a ghost the Reconciler
    # can never pair. Those are all perfectly good LEAF names, so Maker::MoveNode.valid_leaf_name?
    # passed them, and each answered this 422 on share and s3 while CHUNK ACCEPTED THEM — the write
    # goes through Maker::Addons::LibraryOutput#write_chunk, which never calls the port at all. One
    # condition, two answers across backends, with the main deployment on the wrong side.
    #
    # #parse_files now asks Library::ReservedNames.reserved? beside valid_leaf_name?, at the door,
    # before any backend is chosen — so a reserved name is a routine `head :unprocessable_entity`
    # from #create on EVERY backend and no longer reaches this rescue on any of them. What that
    # leaves here is the TOCTOU below, alone.
    #
    # EVERY OTHER NotFound INSIDE #write IS CLOSED BEFORE IT, which is why this arm is narrow rather
    # than a catch-all: `leaf!` by valid_leaf_name? (strictly stricter), the path-escape guard by
    # `leaf!` in turn, `read_capped!` by MAX_FILE_BYTES (4 MB) sitting far under FileLayer::MAX_BYTES
    # (256 MB), and "parent is not a live directory" by chosen_parent_node_id having just resolved
    # that id against the user's own live dirs — which leaves it reachable only as a TOCTOU, a folder
    # tombstoned between those two lookups (a real window on share/s3, where Library::ScanJob
    # tombstones a folder removed on the NAS). Nothing AFTER the write can reach here either:
    # #attach_addon_files_to_current_project and #intake_project_folder both rescue StandardError,
    # and Maker::ProjectIntake#place already rescues FileLayer::NotFound into a :not_found skip.
    #
    # THE MESSAGE STILL NAMES THE RESERVED-NAME CAUSE, DELIBERATELY LEFT WIDER THAN THE ARM. Its
    # "rename the output" clause is now belt-and-braces for this door — #parse_files gets there
    # first — but the sentence costs nothing, and narrowing it to the race alone would be a
    # user-facing change made on the strength of an unreachability argument, which is the kind of
    # argument §14e says to probe rather than trust. Prefer widening the arm's own test over
    # trimming the sentence. None of #show, #asset, #service or #states touches FileLayer at all,
    # so this class-level arm covers those four vacuously.
    #
    # A 404 on a POST to the save endpoint would read as "this endpoint is gone", which sends an
    # addon author looking in entirely the wrong place; the honest answer is that the request was
    # refused.
    rescue_from FileLayer::NotFound do
      render json: { error: "not_found",
                     message: "Your library refused that write. Rename the output if it is named " \
                              "like a system file, or try again." },
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
        params: get_like ? request.query_parameters : request.request_parameters,
        # THE MANIFEST ASKS; THE HOST DECIDES. Resolution lives in ServiceProxy.read_timeout_for
        # rather than here, next to the default and the cap it clamps against, so a second call
        # site cannot ship with the cap applied differently — or not at all.
        read_timeout: Maker::Addons::ServiceProxy.read_timeout_for(
          @addon.service_timeouts[params[:service].to_s]
        )
      )
      type, disposition = proxied_delivery(res.content_type)
      send_data res.body, type:, disposition:, status: res.status
    rescue Maker::Addons::Source::Error, Maker::Addons::ServiceProxy::Error
      head :not_found
    end

    # The addon's own saved states, for the current user, as JSON. A bundle has no database access —
    # this is how it lists (and relinks the output files of) a user's prior saves. Scoped BOTH ways —
    # by addon_key AND by current_user, in that order below.
    #
    # THE addon_key SCOPE IS A DATA-SCOPING RULE, NOT A BOUNDARY BETWEEN ADDONS — it decides which
    # bucket THIS request's own resolved addon (`@addon`, via `load_addon` off `params[:key]`) reads
    # from, and nothing more. It cannot stop a script from calling a DIFFERENT addon's own
    # `/tools/<other-key>/states` directly — no `states_key` needed — because nothing binds a request
    # to "the addon whose page is open"; a bundle is browser code running same-origin in the
    # authenticated session and can just ask (audit §2.1, `docs/AUDIT-2026-08-03.md`). The
    # current_user scope is the real protection here, keeping one user's rows from a stranger's.
    # Scoped by `states_key`, not `key`: they're the same value unless the manifest says otherwise
    # (Maker::Addons::Registry#build), which is how one addon can read another's saves — see the
    # `states_key` comment there for what that widens, and `states_key_permitted?` for who may ask.
    def states
      states = current_user.maker_addon_states.for_addon(@addon.states_key)
                            .includes(:files).order(updated_at: :desc, id: :desc)
      render json: states.map { |s|
        { id: s.id, name: s.name, data: s.data, updated_at: s.updated_at,
          files: s.files.map { |f| { node_id: f.node_id, role: f.role } } }
      }
    end

    # GET /tools/:key/file/:node_id — ONE library file's bytes, to the addon that asked for it.
    #
    # THE GATE IS THE MANIFEST DECLARING `library:read`, AND IT IS DECLARATION CONSISTENCY RATHER
    # THAN CONTAINMENT — spec §8.1's own words, repeated here because a 403 in a controller reads
    # like a boundary and this one is not. A Ring 1 bundle is same-origin browser code in the
    # signed-in session: it can call `/tools/<some-other-key>/file/<id>` directly, and if that
    # addon's manifest declares the permission, it is served. What the gate buys is that an addon
    # which starts reading the library must SAY SO on the card the operator reads at publish time,
    # in a deployment where publishing a bundle IS the deploy.
    #
    # THE `current_user` SCOPE BELOW IS THE PART THAT IS REAL. Stated precisely, because the loose
    # version ("the only thing between one user's files and another's") is not quite true and a
    # test written against it passes under mutation: all three shipped adapters ALSO re-scope
    # inside their own `live_node!`, so removing this line today still answers 404 — via the port's
    # NotFound rather than this lookup. That is defence in depth, not a reason to delegate. The
    # port's contract is that the CALLER has already decided the request is legitimate
    # (FilesController#blob scopes identically before calling), so an adapter is entitled to trust
    # it, and the day one does this line is the whole guard. Pinned with a port double that does
    # trust it, since a real adapter cannot tell the two implementations apart.
    #
    # It is also why an unknown id and another user's id answer identically: `find_by` over
    # `current_user.nodes.present` cannot tell them apart and must not — a 403-vs-404 split here
    # would confirm the existence of a stranger's node.
    #
    # ALWAYS `application/octet-stream` + `attachment`, WHATEVER THE FILE IS — never Marcel's
    # answer, and never the SAFE_INLINE_TYPES allowlist FilesController weighs for a human's browser
    # tab. Nothing is lost: the only caller is `host.files.read`, a `fetch` reading `.arrayBuffer()`,
    # and neither header affects a fetch body (the same reasoning that keeps image/svg+xml off the
    # service proxy's inline allowlist, §14c). Two things are gained, and the FIRST WAS A LIVE BUG
    # FOUND BY PROBING THIS ENDPOINT RATHER THAN BY READING IT:
    #
    #   1. A `.js` FILE IN THE LIBRARY WAS UNREADABLE. Marcel answers `text/javascript`, and
    #      `verify_same_origin_request` — an `append_after_action` that fires on ANY non-XHR
    #      JavaScript response — raised `InvalidCrossOriginRequest`. `fetch` sets no
    #      `X-Requested-With`, so `request.xhr?` is false for every SDK call; probed, and the addon
    #      got a **422 HTML error page** where its bytes should have been. (The same latent shape
    #      exists on `FilesController#blob`, which serves Marcel's type too — out of scope here, but
    #      it is why the fix belongs in the CONTENT TYPE rather than in a `skip_forgery_protection`
    #      on this action.)
    #   2. …AND THAT SKIP WOULD HAVE BEEN THE WORSE FIX. It is what `#asset` does, but `#asset`
    #      serves the same static bundle to every viewer, so its residual leaks nothing. Here the
    #      body is a USER'S OWN FILE: with `text/javascript` and the same-origin guard skipped, a
    #      third-party page's `<script src>` would execute a library file in ITS origin and could
    #      read the contents out. `octet-stream` + `nosniff` makes that structurally impossible
    #      instead of relying on a guard, and needs no list of script-capable types to keep current
    #      — §14b's skip-list blind spot is what a list here would become.
    #
    # A bundle loses nothing it needs: it picked the file and knows what it asked for. It is also
    # why there is deliberately NO `host.files.blobUrl` helper — forced to attachment, this URL
    # cannot back an `<img src>`, so a helper would exist only to be a trap.
    #
    # DELIVERY IS CONSUMED EXACTLY AS FilesController#blob CONSUMES IT — all three variants, NO
    # `else`. An unhandled variant raises NoMatchingPatternError, which is what a new Delivery
    # mechanism with no consumer here should do; a silent fallthrough would answer a blank 200 and
    # an addon would measure an empty file (§14a).
    #
    # ON S3, `Redirect` HANDS THE BROWSER A PRESIGNED URL AT THE OBJECT STORE — cross-origin, so a
    # `fetch` can only READ that response if the bucket's CORS policy allows this app's origin. That
    # is a real operator prerequisite on the s3 backend, stated in docs/addon-api-v1.md rather than
    # worked around: the alternative is streaming the bytes through Rails, which is the one thing
    # §15 exists to prevent. Chunk mode hits it only for a single-chunk file on an S3ChunkStore;
    # share mode never does.
    OPAQUE_TYPE = "application/octet-stream".freeze

    def file
      unless @addon.declares_permission?("library:read")
        return render json: { error: "forbidden_capability",
                              message: "This addon's manifest does not declare library:read." },
                      status: :forbidden
      end

      node = current_user.nodes.present.find_by(node_id: params[:node_id], kind: "file")
      return render_file_not_found if node.nil?

      filename = node.name
      delivery = FileLayer.current.download(current_user, node_id: node.node_id,
                                            disposition: "attachment", content_type: OPAQUE_TYPE)

      case delivery
      in FileLayer::Delivery::Redirect(url:)
        redirect_to url, allow_other_host: true
      in FileLayer::Delivery::SendFile(path:)
        response.headers["X-Content-Type-Options"] = "nosniff"
        send_file path, disposition: "attachment", type: OPAQUE_TYPE, filename:
      in FileLayer::Delivery::Stream(enum:)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Content-Type"] = OPAQUE_TYPE
        response.headers["Content-Disposition"] =
          ActionDispatch::Http::ContentDisposition.format(disposition: "attachment", filename:)
        self.response_body = enum
      end
    rescue FileLayer::NotFound
      render_file_not_found
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

      # THE TARGET OF A REVISION, or nil for a new box — resolved BEFORE any write, so an id this
      # door cannot honour costs nothing. #resolve_revision_target owns the argument for why that
      # is a 404 rather than a create, and renders nothing itself; the `if` is what keeps its nil
      # to one meaning.
      #
      # `present?` AND NOT `!params[:state_id].nil?`, WHICH IS THE TIDY-UP TO REFUSE. A bundle
      # rendering an EMPTY hidden `state_id` field is the natural way to say "no target yet", and
      # `""` must therefore CREATE — that is the §14c compatibility promise this whole method rests
      # on. The `!nil?` spelling turns every one of those saves into a 404, and left the entire
      # suite green until "an empty state_id creates, exactly as an absent one does" was written
      # for it.
      state = nil
      if params[:state_id].present?
        state = resolve_revision_target
        return render_no_such_state if state.nil?
      end

      parent_node_id = chosen_parent_node_id
      # WHAT THIS REVISION MAY OVERWRITE — `{}` for a new box, so a save sending no `state_id` hands
      # LibraryOutput a byte-identical argument to before. Resolved ONCE and passed to both checks
      # below: they ask about DIFFERENT folders and answer with different statuses, but they must
      # share one answer to "is the file in the way this state's own?"
      owned = owned_destinations(state)
      refuse_taken_names!(files, parent_node_id, owned)
      # TWO COLLISION CHECKS, AGAINST TWO DIFFERENT FOLDERS, AND THAT IS THE POINT rather than
      # redundancy. #refuse_taken_names! asks about the folder the user PICKED and is terminal
      # ("pick another name"). This asks about the CATEGORY folder the sweep will file into, which
      # is where a re-save actually collides — and is answerable ("overwrite?"). The gap between
      # them is the bug: after the first save is filed, the picked folder is vacant again, so the
      # first check passes and the sweep is left holding a file it cannot place.
      #
      # A REVISION MEETS WHICHEVER ONE ITS OWN FILE IS SITTING IN, WHICH IS WHY BOTH TAKE `owned`.
      # A box swept into `Projects/<slug>/design/` leaves the picked folder vacant and collides
      # here; a box saved to a plain library folder is still sitting there and collides above,
      # where the refusal is terminal and no `overwrite` could ever answer it. Exempting only one
      # of them leaves "open a saved design, tweak it, re-save it" refused (spec §1.3).
      placements = resolve_placements(files, parent_node_id, owned)
      return if render_would_replace(files, placements)

      # HOISTED OUT OF BOTH BRANCHES so they cannot drift on what a save's name and data are. Kept
      # HERE, immediately before the transaction rather than at the top of the action, because
      # `require` raises ParameterMissing (-> 400) and these used to be the transaction's first
      # statement: moving them any earlier would answer 400 where a nameless save with a taken
      # filename answers 422 today.
      name = params.require(:name)
      data = parse_data

      addon_files = nil
      ApplicationRecord.transaction do
        if state
          # A REVISION RENAMES THE BOX when the name changed — `name` is a property of the design,
          # not of one snapshot, so a rename has nowhere else to land. The snapshot below records
          # `data` only.
          #
          # THE INCREMENT IS A READ-MODIFY-WRITE AND IS DELIBERATELY NOT LOCKED. `state.revision`
          # was read before this transaction opened, so two concurrent revisions of the SAME item
          # by the SAME user — a double-click — both compute N+1. What the snapshot row's unique
          # index on [addon_state_id, revision] buys is that the loser gets a RecordNotUnique 500
          # instead of the two things that would otherwise both happen: a DUPLICATE REVISION NUMBER
          # (two rows at N+1 carrying different `data`, with nothing to say which is the real one)
          # and a LOST UPDATE on the state row itself. ACCEPTED: the transaction rolls back before
          # `LibraryOutput.write` runs, so nothing reaches the library, no snapshot is lost, and a
          # retry succeeds. A `state.lock!` here would buy that at the price of a NEW LOCK-ORDERING
          # EDGE inside a transaction that goes on to take `Sync::`'s own `FOR UPDATE` on the users
          # row via `next_seq!` (chunk mode) — precisely where §14e's deadlock rule lives, and a
          # deadlock this repo has already paid for once. Small race, right failure direction, not
          # worth a new lock next to that one.
          state.update!(name:, data:, revision: state.revision + 1)
        else
          state = current_user.maker_addon_states.create!(
            addon_key: @addon.states_key, name:, data:
          )
        end
        # THE CREATE BRANCH TAKES THIS LINE TOO, so a state's history is complete from its first
        # save — revision 1 is the schema default on `maker_addon_states.revision`, and the
        # migration's backfill wrote the same row for every state that predates this door. A
        # history that starts at 2 would make "restore the original" impossible for exactly the
        # designs a user has revised most.
        state.revisions.create!(revision: state.revision, data: state.data)
        addon_files = Maker::Addons::LibraryOutput.write(
          user: current_user, state:, parent_node_id:,
          files: files.each_with_index.map do |f, i|
            # AN ALLOWLIST OF THE TWO KEYS LibraryOutput ACTUALLY READS, not a skip-list of the
            # ones it does not — §14b's blind spot is this repo's recorded failure shape, and a
            # placement that grows a third key (the own-file collision exemption is going to add
            # one) would be silently ignored downstream rather than refused, with no test able to
            # go red. `:folder` is #render_would_replace's business — it names the folder in the
            # 409 body — and means nothing here. A non-colliding file's placement is `{}`, and
            # `{}.slice` is `{}`, so `fetch(:parent_node_id, …)`'s absent-vs-nil distinction over
            # in LibraryOutput survives this untouched.
            { name: f.name, bytes: f.bytes, content_type: f.content_type, role: "output" }
              .merge(placements[i].slice(:parent_node_id, :replace))
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
                                                  unfiled_by_conflict(intake_result, files.map(&:name)))
    end

    private

    def load_addon
      @addon = Maker::Addons::Registry.find(params[:key])
      head :not_found unless @addon
    end

    # THE STATE A SAVE REVISES, for a request that asked for one. ONLY EVER CALLED WHEN A
    # `state_id` WAS SENT, so its nil has exactly one meaning — "that id does not resolve" — and it
    # renders nothing: the caller answers. (An earlier draft resolved and rendered in one method,
    # whose nil meant both "no state_id" and "already 404'd", and needed a `performed?` check plus
    # a paragraph explaining it. Two pure methods and an `if` say the same thing without either.)
    #
    # NO `state_id` MEANS CREATE, UNCHANGED — the compatibility contract rather than a convenience:
    # every already-published bundle sends none, and publishing a bundle IS the addon deploy while
    # Rails is never rebuilt (§14c), so this door may never assume bundles moved with it. The
    # caller's `present?` is what implements that, and `present?` rather than `!nil?` because a
    # form rendering an empty hidden field sends "".
    #
    # SCOPED BY `states_key`, NOT `key` — that is the DATA scope (the same one #states reads),
    # while `key` builds routes. Scoping by `key` would let a save under one addon append a
    # revision to a state filed under another's namespace whenever the two diverge. Note what this
    # is NOT: it is not an inter-addon boundary, for the reason #states already gives at length —
    # a bundle is same-origin browser code in the session and can POST to another addon's own save
    # URL directly. What it enforces is that a manifest cannot redirect ITS OWN saves into another
    # addon's namespace by declaration alone.
    #
    # A STRING OR AN INTEGER, ALLOWLISTED, AND THE REFUSAL WAS PROBED RATHER THAN REASONED ABOUT.
    # `state_id[]=1&state_id[]=2` arrives as an ARRAY and `find_by(id: [...])` is an `IN`: before
    # this check it RESOLVED, writing a revision onto whichever of the user's own boxes the
    # database returned first — a design nobody named, with no error anywhere. Both scopes still
    # held, so nothing was disclosed; it is refused because it is SILENT and it WRITES. Integer is
    # on the list because a JSON request body preserves JSON's types, so a caller posting
    # `{"state_id": 5}` would otherwise get a 404 whose message is a lie about a state that exists
    # and is theirs. An allowlist and not a `reject if Array`: a nested `state_id[a]=b` is a Hash,
    # and naming the shapes we accept covers it (and whatever the next one is) without a second
    # probe.
    def resolve_revision_target
      raw = params[:state_id]
      return nil unless raw.is_a?(String) || raw.is_a?(Integer)

      current_user.maker_addon_states.for_addon(@addon.states_key).find_by(id: raw)
    end

    # 404 AND NOT A SILENT FALLBACK TO CREATING. An id that does not resolve is a bundle bug or a
    # stale tab, and creating a new box instead would file a revision of an existing design as an
    # unrelated one — the pile-up this whole feature exists to end, reintroduced by its own error
    # path. JSON with a real status for the same reason the rescue_from arms above use it: the only
    # caller is a `fetch` that branches on `res.ok`, and fetch FOLLOWS a 302, so answering an error
    # the way success is answered would report "Saved." over a save that never happened.
    #
    # ONE ANSWER FOR FOUR CAUSES — no such id, another user's, another addon's, and not one id at
    # all — deliberately, so this door cannot be used to report which state ids exist or who owns
    # them. Sibling of #render_file_not_found below, and note the two share the `not_found` code
    # while meaning different things ("no such file" there, "no such saved item" here); anything
    # mapping these codes to exceptions has to key on the endpoint, not the string alone.
    def render_no_such_state
      render json: { error: "not_found", message: "No such saved item for this addon." },
             status: :not_found
    end

    # 404, AND RESCUED INSIDE #file RATHER THAN LEFT TO THE CLASS-LEVEL `rescue_from
    # FileLayer::NotFound` — which answers 422 with "Your library refused that write." That arm is
    # correct for the SAVE door, where NotFound means the port refused a write the caller could have
    # made differently; it is a lie on a read, whose request was well-formed and simply named
    # something that is not there. Same shape as FilesController#geometry rescuing RecordNotFound
    # locally because the class-level handler is right for a different action (§14h).
    #
    # 404 rather than 422 for the second reason too: 422 says "your request was malformed", which
    # sends an addon author looking at their own code for a file the user deleted.
    #
    # ONE ANSWER FOR THREE CAUSES, deliberately: no such node, someone else's node, and a node whose
    # BYTES have gone (the port's own NotFound). Splitting them would make this endpoint report
    # whether a stranger's node id exists.
    def render_file_not_found
      render json: { error: "not_found", message: "No such file in your library." },
             status: :not_found
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
          # ALSO A BASE, for the same reason and by the same derivation: append one node id.
          # Emitted for EVERY addon, including one whose manifest does not declare `library:read` —
          # the URL is not the gate (the endpoint's own check is), and withholding it would make a
          # missing declaration surface as a broken SDK method instead of the 403 that names it.
          file: file_base_url,
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

    # The base a bundle appends ONE node id to. Same placeholder-substitution trick as
    # service_base_url and for the same reason: the shape of the route lives in config/routes.rb
    # exactly once, so changing it cannot silently desync a hand-copied literal here.
    def file_base_url
      tools_addon_file_path(@addon.key, "__NODE__").delete_suffix("__NODE__")
    end

    # The manifest must DECLARE the service, and the host must have a URL for it. Both, not either —
    # an addon naming a service the host never configured must not fall back to a guess.
    #
    # THE DECLARATION CHECK STAYS HERE; ONLY THE ENV LOOKUP MOVED. The two halves answer different
    # questions and only one of them is per-request: "did THIS addon's manifest declare this
    # service" is about `@addon`, and it is the spec §4.1 SSRF guard — without it any addon could
    # name any service the deployment configures. "Where does that service live" is deployment-wide,
    # and `Addon#unavailable_reason` now asks it too in order to grey an unconfigured addon out, so
    # the derivation lives once in Maker::Addons::Services rather than being spelled here and there.
    def sidecar_url_for(name)
      return nil unless @addon.services.include?(name.to_s)

      Maker::Addons::Services.url_for(name)
    end

    # THE (parent, name) PAIRS THE TARGET STATE ALREADY OWNS — what a revision is entitled to
    # overwrite, and nothing else. `{}` for a new box, which is what keeps every save that sends no
    # `state_id` byte-identical to today: publishing a bundle IS the addon deploy and Rails is never
    # rebuilt (§14c), so this door may never assume bundles moved with it.
    #
    # KEYED BY (parent, name) RATHER THAN BY node_id, because that is the question both collision
    # checks below actually ask — "is something already sitting at this destination?" A set of
    # node_ids would still need the destination lookup to compare against, and resolving them here
    # means ONE query for the whole save instead of one per file.
    #
    # A STALE ROW STILL COUNTS, and that is the rule rather than an exception to it. A state keeps
    # the AddonFile row of an output a later revision stopped emitting — Maker::Addons::LibraryOutput
    # #upsert_file! leaves it alone on purpose (§14c: a save door must not delete user bytes) — so a
    # revision that re-emits that old name replaces the file this same box produced.
    #
    # `.present` MATTERS: a tombstoned output is not a destination anybody can collide with, and
    # #refuse_taken_names!'s own query scopes the same way, so the two cannot disagree about what is
    # there. The `current_user` scope is defence in depth — `state` was already resolved through
    # `current_user.maker_addon_states` — kept because a node_id list is the one thing here that
    # came out of another table.
    def owned_destinations(state)
      return {} if state.nil?

      node_ids = state.files.pluck(:node_id)
      return {} if node_ids.empty?

      current_user.nodes.present.where(node_id: node_ids)
                  .pluck(:parent_node_id, :name, :node_id)
                  .to_h { |parent, name, node_id| [ [ parent, name ], node_id ] }
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
    #
    # AN OWNED DESTINATION IS EXEMPT, AND ONLY AN OWNED ONE. Hitting the file this same state
    # produced is what revising a design IS — naming the state is the consent — while a name held
    # by a file this state did not produce stays the terminal 422 it has always been, because no
    # `overwrite` can make somebody else's file the right thing to rewrite.
    #
    # EXEMPTING IT HERE IS ONLY HALF THE ANSWER, and the halves must move together: this check
    # asks about the PICKED folder, and #resolve_placements has to mark that same file
    # `replace: true` or the write lands as a CREATE. See arm 2 of its own note for what that
    # looked like when measured.
    def refuse_taken_names!(files, parent_node_id, owned = {})
      taken = files.map(&:name).select do |name|
        next false if owned.key?([ parent_node_id, name ])

        Maker::MoveNode.collision?(current_user, parent_node_id:, name:, except_node_id: nil)
      end
      return if taken.empty?

      raise FileLayer::UnsupportedOperation,
            "#{taken.map(&:inspect).join(', ')} already #{taken.one? ? 'exists' : 'exist'} in that " \
            "folder. Rename the save or pick another folder."
    end

    # Per file: where it should go and whether it replaces what is there. An EMPTY hash is "the
    # picked folder, create" — today's behaviour, and the answer for every save that is neither a
    # re-save into a project folder's root nor a revision landing on its own output.
    #
    # PER FILE, NOT PER SAVE, because one save can collide on some outputs and not others: the
    # boxes addon emits `<base>.svg` and `<base>-plan.svg` together, and a re-save can find the
    # first name taken in its category folder and the second free. That is why
    # Maker::Addons::LibraryOutput takes a per-file destination.
    #
    # TWO WAYS TO LAND ON A REPLACE, AND THE SECOND WAS FOUND BY MEASURING RATHER THAN BY READING:
    #
    #   1. THE CATEGORY FOLDER IS OCCUPIED. The destination is then the OCCUPANT'S OWN PARENT, not
    #      a folder this method resolves separately — there IS an occupant, so its parent is the
    #      category folder and it already exists. Nothing here mkdirs: a save that needs a folder
    #      made still lands at the picked folder and the sweep files it, exactly as before.
    #   2. THE PICKED FOLDER ALREADY HOLDS THIS STATE'S OWN OUTPUT. Maker::ProjectIntake
    #      .destination_for answers nil for anything that is not a project folder's own root, so the
    #      ordinary "re-save a box that lives in a plain library folder" — the mainline revision
    #      flow, and the dead end spec §1.3 is about — never reaches arm 1 at all. Without this arm
    #      such a file clears #refuse_taken_names!'s exemption and then lands as a CREATE: probed on
    #      chunk, that is a SECOND live node with the same name in the same directory, and on
    #      share/s3 the port's own clobber refusal turns the exemption straight back into the 422 it
    #      exists to remove. `owned: true` is a tautology inside this arm, since its condition IS the
    #      ownership test, and `folder:` is absent because that key exists only for the 409 body an
    #      owned placement never reaches.
    #
    # `owned` MARKS A COLLISION THE CALLER HAS ALREADY CONSENTED TO by naming this state. It still
    # sets `replace: true` — the write is a replace either way — and is what keeps
    # #render_would_replace from asking a question the `state_id` already answered.
    def resolve_placements(files, parent_node_id, owned = {})
      files.map do |f|
        dest = Maker::ProjectIntake.destination_for(user: current_user, parent_node_id:,
                                                    name: f.name)
        occupied = dest&.occupied_by
        if occupied
          { folder: dest.folder, parent_node_id: occupied.parent_node_id, replace: true,
            owned: owned[[ occupied.parent_node_id, occupied.name ]] == occupied.node_id }
        elsif owned.key?([ parent_node_id, f.name ])
          { parent_node_id:, replace: true, owned: true }
        else
          {}
        end
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
    #
    # AN `owned` PLACEMENT IS NEVER ASKED ABOUT. Naming the state IS the consent, so asking again
    # would put a confirm dialog in front of the ordinary act of saving a design a second time.
    def render_would_replace(files, placements)
      return false if params[:overwrite].present?

      colliding = files.zip(placements).select { |_f, p| p[:replace] && !p[:owned] }
      return false if colliding.empty?

      render json: { error: "would_replace",
                     files: colliding.map { |f, p| { name: f.name, folder: p[:folder] } } },
             status: :conflict
      true
    end

    # ONE SAVE FILE, NORMALIZED OUT OF EITHER WIRE SHAPE. `bytes` is a String either way, so
    # everything downstream — the name checks, the collision checks, LibraryOutput — sees exactly
    # one shape and no branch.
    SaveFile = Data.define(:name, :content_type, :bytes)

    # Returns nil (-> 422) rather than raising, so a malformed or oversized payload is a routine
    # refusal instead of a 500.
    #
    # TWO WIRE SHAPES, ONE ORDERED LIST, AND THE JSON ARRAY IS ALWAYS THE LIST.
    #
    #   {name, content_type, body}  — today's shape. `body` is a String carried INSIDE the JSON
    #                                 field. Every published bundle sends this and it must keep
    #                                 working: publishing a bundle is the deploy and Rails is never
    #                                 rebuilt (§14c), so a host may never assume bundles moved.
    #   {name, part: "f0"}          — the bytes are a REAL multipart file part, posted alongside as
    #                                 `parts[f0]`. This is what makes binary output possible.
    #
    # WHY THE JSON ARRAY STAYS THE MANIFEST INSTEAD OF PARTS BEING THE LIST: order is load-bearing
    # (AddonFile#position, and `placements[i]` pairs a file with the destination resolved for it),
    # and a request carrying two collections has no ordering rule that is not implicit. One list,
    # one index, nothing to get wrong.
    #
    # THE NAME ALWAYS COMES FROM THE JSON ENTRY, NEVER FROM THE PART'S OWN filename. The SDK does
    # send a filename on the part (it makes the request readable in devtools) and this ignores it:
    # two sources for one value is the drift shape this file already carries scars from, and the
    # single source means valid_leaf_name? + ReservedNames below cover BOTH shapes with no second
    # copy. THE CONTENT TYPE IS THE OPPOSITE — for a part it comes FROM THE PART and is never
    # guessed from the name, which is spec §6.1's own words.
    #
    # A TEXT FILE'S CONTENT MUST NEVER TRAVEL AS A BARE MULTIPART TEXT FIELD, and that rule is the
    # reason there is no third shape here. multipart/form-data serialization NORMALIZES EVERY TEXT
    # ENTRY'S NEWLINES TO CRLF (the HTML standard's own encoding algorithm), which silently
    # corrupted a line-by-line sidecar payload once already (§14c, `service.post`). Both shapes
    # above are safe, for two different reasons worth keeping straight: a `body` inside the JSON
    # field is JSON-ESCAPED, so a "\n" is the two characters `\` and `n` on the wire and the
    # serializer has no newline to rewrite; and a `parts[…]` entry is a FILE part, which the same
    # algorithm transmits verbatim precisely because it is not a text entry. Add a shape that puts
    # raw file content in a plain field and you reintroduce the bug.
    def parse_files
      parsed = JSON.parse(params[:files].to_s)
      return nil unless parsed.is_a?(Array) && parsed.any? && parsed.size <= self.class.max_files

      # TWO PHASES, AND THE SPLIT IS THE POINT: sources are SIZED before any of them is read, so a
      # save over the cap is refused without the bytes ever entering the Rails heap. Read first and
      # the cap protects nothing it was written to protect.
      sources = parsed.map { |f| file_source(f) }
      return nil if sources.any?(&:nil?)
      # THE NAME CHECK, BACKEND-NEUTRAL AND BEFORE ANY WRITE. This used to be `f["name"].present?`,
      # which is not a filename check — it accepted "../../escape.txt", and on chunk (the main
      # deployment, and the one door with no name validation anywhere downstream) that produced a
      # live node with that name, bound for every device's mount. See Maker::MoveNode.valid_leaf_name?
      # for the full argument and why the guard belongs here rather than in the chunk adapter.
      return nil unless parsed.all? { |f| Maker::MoveNode.valid_leaf_name?(f["name"]) }
      # THE SECOND HALF OF THE SAME DOOR CHECK, and the two are always asked together: the line
      # above is SYNTAX ("is this a storable leaf at all"), this one is the library's own reserved
      # NAMESPACE. Identical asymmetry, identical reason it survived — share and s3 refuse these in
      # their own `observable!` inside #write, and chunk never calls the port at all, so a
      # `.DS_Store` / `.trash` / `.maker-tmp-x` output was a live node on the main deployment and a
      # 422 on the other two. See Library::ReservedNames for the probe table and for why the door
      # enforces the UNION of the two adapters' guards rather than their intersection.
      return nil unless parsed.none? { |f| Library::ReservedNames.reserved?(f["name"]) }
      # Within ONE save, too: #refuse_taken_names! asks the database, which cannot see two files
      # in this same batch claiming the same name — neither exists yet, so both pass and chunk
      # writes the duplicate pair itself.
      return nil unless parsed.map { |f| f["name"] }.uniq.size == parsed.size
      # SIZED, NOT READ — see the two-phase note above. `UploadedFile#size` is the tempfile's stat,
      # so a 900 MB part is refused for the price of a stat.
      return nil if sources.sum(&:size) > self.class.max_bytes

      parsed.each_with_index.map do |f, i|
        SaveFile.new(name: f["name"], content_type: sources[i].content_type, bytes: sources[i].bytes)
      end
    rescue JSON::ParserError
      nil
    end

    # ONE FILE'S BYTES AND THEIR DECLARED TYPE, RESOLVED BUT NOT YET READ. nil means refuse.
    #
    # `size` answers the cap without touching the bytes; `bytes` is called only after every check
    # has passed, exactly once per file, and only then does a part leave its tempfile.
    FileSource = Data.define(:content_type, :size, :reader) do
      def bytes = reader.call
    end

    def file_source(entry)
      return nil unless entry.is_a?(Hash)
      return inline_file_source(entry) if entry["part"].nil?

      part = uploaded_part(entry["part"])
      return nil if part.nil?

      # FROM THE PART, NEVER GUESSED (spec §6.1). A part whose type the browser left blank is
      # octet-stream — which is still the PART's answer, not an inference from the filename. The
      # JSON entry's own `content_type` is ignored for a part entry on purpose: one value, one
      # source. (The SDK stamps the author's declared contentType onto the Blob it builds, so an
      # author's choice still lands here — it just travels as the part's type rather than beside
      # it, where the two could disagree.)
      FileSource.new(content_type: part.content_type.presence || "application/octet-stream",
                     size: part.size, reader: -> { part.read })
    end

    def inline_file_source(entry)
      body = entry["body"]
      return nil unless body.is_a?(String)

      FileSource.new(content_type: entry["content_type"], size: body.bytesize, reader: -> { body })
    end

    # THE PART NAMED BY A JSON ENTRY, OR nil. TWO GUARDS, AND BOTH ARE ABOUT A CLIENT-SUPPLIED KEY
    # BEING USED TO INDEX A PARAMS HASH:
    #
    #   1. IT IS LOOKED UP INSIDE `parts[…]`, ITS OWN NAMESPACE, never at the top level of `params`.
    #      `part: "name"` at the top level would resolve to the state's own NAME — an ordinary
    #      String — and `part: "files"` to this very JSON blob. A namespace makes an addon unable to
    #      name anything but a part.
    #   2. THE VALUE MUST BE AN UploadedFile. A client can post `parts[f0]=hello` as a plain text
    #      field, and a String answers `#size` (CHARACTER count, not bytes — so it also mis-measures
    #      the cap) and has no `#read`, i.e. a 500 from inside the save. Refusing here makes it the
    #      routine 422 every other malformed payload gets.
    def uploaded_part(key)
      return nil unless key.is_a?(String) && key.present?

      parts = params[:parts]
      return nil unless parts.is_a?(ActionController::Parameters)

      part = parts[key]
      part.is_a?(ActionDispatch::Http::UploadedFile) ? part : nil
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
