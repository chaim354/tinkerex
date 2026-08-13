Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Where the browser POSTs CSP violations. NAMED, because the policy's `report_uri` is built from
  # this route rather than repeating the path as a literal — the same reasoning as the Active
  # Storage shadow below: a path written twice is a path that can desync, and a report-uri pointing
  # at a 404 fails SILENTLY. The browser simply stops reporting, and a report-only policy with
  # nothing arriving looks exactly like a policy with no violations.
  post "csp-violation-report" => "csp_reports#create", as: :csp_violation_report

  # Active Storage's direct-upload endpoint, REMOVED. ActiveStorage::DirectUploadsController
  # descends from ActiveStorage::BaseController — not this app's ApplicationController — so it
  # shipped live and UNAUTHENTICATED: an anonymous POST minted a real Blob and returned a signed
  # upload URL. That is an anonymous write surface into storage through Rails (CLAUDE.md §15).
  #
  # REMOVED rather than authenticated: `direct_upload` appears nowhere in app/, config/ or lib/, and
  # both Lexxy editors run attachments-off, so nothing in this app calls it. Re-enabling it should
  # be a deliberate act.
  #
  # DRAWN HERE, NOT VIA draw_routes = false: Maker::Preview uses has_one_attached :asset served with
  # url_for, so the blob routes must survive. An app-drawn route DOES win over the engine's — this
  # was verified by driving a real request, because `recognize_path` reports the engine's route for
  # a proc endpoint (it carries no controller/action) and is the wrong instrument for the check.
  #
  # THE PATH MUST BE DERIVED, NEVER A LITERAL. The engine wraps its own direct_uploads route (and
  # every other Active Storage route) in `scope ActiveStorage.routes_prefix` (activestorage's own
  # config/routes.rb), not a hard-coded "/rails/active_storage" — that's only the DEFAULT. Reconfigure
  # config.active_storage.routes_prefix and a literal shadow here silently guards nothing: the old
  # path 404s (nothing left to hit), the engine's route reappears live at the NEW prefix, and an
  # anonymous POST there mints a real Blob again — the original hole, reopened by a one-line config
  # change nobody would think to connect to this file. `ActiveStorage.routes_prefix` is assigned by
  # the engine's own `active_storage.configs` initializer, which runs during app boot strictly before
  # routes are ever drawn or reloaded — so reading it here, at draw time, is safe.
  #
  # `bin/rails routes` still lists the engine's own direct_uploads entry further down the table
  # (routes are tried in declaration order, and ours is declared first) — that is expected and
  # correct. It is SHADOWED, not removed from the table; an auditor grepping the route list will
  # still see it and should not read its presence there as the hole being open.
  post "#{ActiveStorage.routes_prefix}/direct_uploads", to: proc { |_env|
    [ 404, { "content-type" => "text/plain" }, [ "Not Found" ] ]
  }

  # --- Web UI (server-rendered file browser) ---
  root to: redirect("/files")

  # --- Human-identity web auth (Devise) ---
  # Governs the server-rendered web UI only. The v1 device-token machinery (namespace :v1
  # below) is unchanged. Custom controllers keep our redirect copy + OmniAuth seam.
  devise_for :users,
             controllers: {
               sessions:           "users/sessions",
               registrations:      "users/registrations",
               confirmations:      "users/confirmations",
               passwords:          "users/passwords",
               omniauth_callbacks: "users/omniauth_callbacks"
             }

  # Trash / undelete: list tombstoned nodes + restore (re-points at the kept version).
  resources :trash, only: %i[index] do
    member { post "restore" }
  end

  # File library: list / view / upload / download / delete. TWO upload routes, because there are
  # two flows and each deployment has exactly one: `create` takes the bytes for a share/s3
  # library (nothing to presign), begin+finalize is the chunk store's two-phase presigned flow.
  # FilesController gates each on a capability, so the wrong one for this deployment answers 501.
  resources :files, only: %i[index create show destroy] do
    collection do
      post "begin_upload"
      post "finalize_upload"
      # On-demand reconcile for a scannable (share/s3) library — index changes made directly on
      # the NAS/bucket now, instead of waiting for the 15-minute recurring Library::ScanJob.
      # Gated on the `scannable` capability in FilesController (chunk mode refuses).
      post "rescan"
      # Current-version thumbnail state for a batch of node ids (JSON), for the grid's
      # poll-until-ready. Session-authed web endpoint, not the device-token v1 previews API.
      get "thumbnails"
    end
    member do
      get "blob"
      # The .lbrn2 Measure view's coordinate payload. A SECOND preview kind for the same node
      # (kind: "geometry"), so this neither replaces nor disturbs the thumbnail. The payload
      # itself leaves via the blob URL, off Rails — this action only reports where it is.
      get "geometry"
    end
  end

  # --- Library browse (session-authed JSON; data source for the reusable folder/file chooser) ---
  get  "library/children", to: "library_browse#children",      as: :library_children
  post "library/folders",  to: "library_browse#create_folder", as: :library_folders

  # --- Per-file notes (keyed by node_id, session auth) ---
  post "files/:node_id/notes", to: "notes#create", as: :file_notes
  resources :notes, only: %i[destroy]

  # --- Maker: Projects (server-rendered web UI, session auth) ---
  # The maker product hub. Uses Maker::* models directly (NOT the device-token /v1/maker API).
  resources :projects do
    # Return an archived project to the live list. A member PATCH rather than an update to a
    # `status` field: the web form no longer exposes status at all (spec decision #1).
    patch :unarchive, on: :member
    resources :attachments, only: %i[new create destroy], module: :projects, shallow: true do
      # Finish an attach whose auto-move hit a name collision: move the file in under a new name.
      # DELIBERATELY SCOPED TO THE PROJECT rather than a general POST /files/:id/move — the
      # conflict flow needs a move endpoint either way, and this one can only ever move a file
      # into the named project's own folder. A general move is a larger web surface than any
      # feature here wants. `on: :collection` keeps it nested despite `shallow: true`.
      post :relocate, on: :collection
    end
    resources :build_log_entries, only: %i[create destroy], module: :projects, shallow: true
    resources :tasks, only: %i[create update destroy], module: :projects, shallow: true
    # Free-form spreadsheets. Shallow like tasks and build-log entries: create is nested under the
    # project, the grid page and its autosave/CSV live at /sheets/:id.
    resources :sheets, only: %i[create show update destroy], module: :projects, shallow: true
    # Inline upload-and-attach (share/s3 multipart write). Chunk mode uploads via
    # /files/{begin,finalize}_upload then POSTs the node_id to the attachments endpoint.
    resources :uploads, only: :create, module: :projects
  end

  # NON-NESTED ATTACH. The file page attaches via a <select> of projects, and a <select> cannot
  # set its form's action — the nested route needs the project in the PATH. Rather than add JS to
  # rewrite `action` on change, the project rides as a body param here.
  # Projects::AttachmentsController#set_project reads params[:project_id], which resolves a body
  # param and a path segment identically, so this reaches the SAME action with no controller
  # change and no second create path. (`attachments_path` is free: the shallow `resources
  # :attachments` under :projects claims only project_attachments_path and the singular
  # attachment_path.)
  post "attachments", to: "projects/attachments#create", as: :attachments

  # Session-scoped "current project" (the top-bar default destination). Singular resource: no id in
  # the URL — the id rides in params[:project_id] so a blank one can clear it. `controller:` is
  # required here: Rails' singular `resource` DSL still infers a PLURALIZED controller name by
  # default (-> CurrentProjectsController), which would not match CurrentProjectController below.
  resource :current_project, only: %i[update destroy], controller: "current_project"

  # Inline photo upload on a build-log entry (share/s3 multipart), same Projects::UploadsController.
  resources :build_log_entries, only: [], module: :projects do
    resources :uploads, only: :create
  end

  # A build-log entry's inline photos (attach an existing image node to the entry). Explicit
  # routes so the helpers read entry_photos_path / entry_photo_path (a nested `resources :photos`
  # would generate build_log_entry_photos_path, which the controller/views/tests do NOT use).
  post   "build_log_entries/:build_log_entry_id/photos",
         to: "projects/entry_photos#create", as: :entry_photos
  delete "entry_photos/:id", to: "projects/entry_photos#destroy", as: :entry_photo

  # --- Maker: Models (3D-print model library; server-rendered web UI, session auth) ---
  # A curated view over library files at Models/<slug>/. `create` is the JSON import endpoint the
  # importer Stimulus controller calls; there is no plain-HTML create (import IS the new flow).
  resources :models do
    # NOT shallow: a shallow member route here would collapse to DELETE /attachments/:id and
    # collide with the pre-existing shallow `resources :attachments` under :projects (first
    # definition wins, leaving this one unreachable). Non-shallow keeps it at
    # /models/:model_id/attachments/:id (helper model_attachment_path) — distinct and correct.
    # The collection route model_attachments_path (POST /models/:model_id/attachments) is
    # identical either way, so the importer's attach step is unaffected.
    resources :attachments, only: %i[create destroy], module: :models
    resources :print_runs, only: %i[create destroy], module: :models, shallow: true
  end

  # --- Addons (Tools) — the /tools gallery + every addon's UI ---
  # EVERY addon is now manifest-driven and served by the generic surface (Tools::AddonsController,
  # `tools/:key` below). `generators`, `boxes` and — last — `openscad` have all migrated, so no
  # addon has a controller or routes of its own any more, and adding one needs no edit to this file.
  get "tools", to: "tools/home#index", as: :tools

  # The params behind ANY addon state, as a download. ONE route for every addon: `Maker::AddonState`
  # is addon-agnostic (`data` IS each addon's own shape), so there is nothing per-addon to branch on.
  # Declared at top level so the helper reads like its `tools_addon_*` siblings below.
  #
  # ITS LAST HOST-SIDE CALLER WENT WITH THE OPENSCAD SHOW PAGE (which rendered
  # `tools/shared/_params`, the only view that ever linked here). The endpoint is deliberately KEPT:
  # it is addon-agnostic, it still serves any addon's saved state to a bundle that asks, and
  # deleting a working download endpoint is a user-visible removal the migration does not require.
  # So "no caller in this repo" is the intended state, not rot — do not read it as dead code.
  get "tools/addon_states/:id/params", to: "tools/addon_params#show", as: :tools_addon_params

  # DECLARED LAST, AND THAT IS STILL LOAD-BEARING — THOUGH ITS JUSTIFICATION HAS CHANGED. `tools/:key`
  # matches any TWO-segment /tools/* path, so it collides with ANY two-segment `/tools/*` route
  # declared after it — route recognition is first-match-wins by declaration order, regardless of
  # which named helper built the URL.
  #
  # WHAT CHANGED: this ordering used to protect live siblings. It no longer protects anything that
  # exists. `boxes` and `generators` migrated first, and `openscad` — the last hand-written
  # two-segment `/tools/*` route, and the one this comment previously named as "the one sibling left
  # for this ordering to protect" — is now gone too. `tools/:key` matching `key="openscad"` is the
  # CORRECT resolution, not a collision.
  #
  # SO WHY KEEP THE ORDER? Because it is the invariant a FUTURE two-segment `/tools/*` route needs,
  # and the failure it prevents is a 404 on a route that is right there in this file — read as "my
  # route isn't registered", which sends you to look at the wrong thing. Anything two-segment added
  # under /tools must go ABOVE this block or it is unreachable. The three multi-segment routes below
  # (`states`, `file/:node_id`, `asset/*path`) sit above for tidiness, not safety — see the
  # segment-count note.
  #
  # THE MUTATION CHECK, KEPT BECAUSE IT IS THE EVIDENCE AND IT IS NO LONGER REPRODUCIBLE HERE. Done
  # for real against `boxes` while it still had its own `resources :boxes` block: moving `tools/:key`
  # above it turned `bin/rails test test/controllers/tools/boxes_controller_test.rb` from green to
  # 12 failures + 2 errors, all 404s/UrlGenerationErrors where `/tools/boxes` and `/tools/boxes/:id`
  # used to resolve, because `tools/:key` (key="boxes") beat that block's own index route to the
  # match. Restoring this order fixed it. With no hand-written sibling left there is nothing to
  # re-run that against — which is exactly why the anecdote stays written down.
  #
  # IT DOES NOT COLLIDE WITH `tools/addon_states/:id/params`: that path has four segments and Rails
  # requires a segment-count match, so no ordering hazard exists between them — moving `tools/:key`
  # above that one specific route left `addon_params_controller_test.rb` green. (An earlier draft of
  # this comment claimed the opposite; verified false with
  # `Rails.application.routes.recognize_path`.) That is still true and is the reason the
  # four-segment routes below are safe wherever they sit.
  #
  # An addon reaching its sidecar. The manifest names WHICH service; the host's own env says WHERE —
  # a manifest-supplied URL would be an SSRF primitive aimed at the internal network (spec §4.1).
  match "tools/:key/service/:service/*path", to: "tools/addons#service",
        via: %i[get post], as: :tools_addon_service, format: false

  # An addon's own saved states (Maker::AddonState rows), as JSON — a bundle has no database access
  # of its own, so this is how it lists a user's prior saves. Scoped BOTH by addon_key and by
  # current_user in the controller — a DATA-SCOPING rule, not a boundary between one addon and
  # another's saved work (a bundle can call another addon's own /tools/<other-key>/states directly,
  # no states_key required — audit §2.1, docs/AUDIT-2026-08-03.md); current_user is what actually
  # keeps one user's rows from a stranger's. Lives above the tools/:key wildcard for the same reason
  # the service route does.
  get "tools/:key/states", to: "tools/addons#states", as: :tools_addon_states

  # ONE saved state's revision history, newest first. FIVE segments, so — unlike the two-segment
  # routes this block's long comment is about — it has no ordering hazard with the `tools/:key`
  # wildcard at all: Rails requires a segment-count match, the same reason
  # `tools/addon_states/:id/params` is safe wherever it sits. Nor does either glob route above reach
  # it: both pin their third segment to a literal ("service", "asset"), and this path's third
  # segment is "states". It sits here to keep the addon surface in one block, not because the order
  # protects it.
  #
  # LAZY BY DESIGN, WHICH IS WHY IT IS A SECOND ENDPOINT RATHER THAN A KEY ON #states. A 20-revision
  # history of 40-param snapshots, for every saved box, would bloat a gallery's first paint with
  # data nobody has expanded — and #states' one-entry-per-box shape is itself the compatibility
  # promise to every published bundle (§14c).
  get "tools/:key/states/:id/revisions", to: "tools/addons#revisions",
      as: :tools_addon_state_revisions

  # ONE library file's bytes, for an addon whose manifest declares `library:read`. Four segments, so
  # unlike the two-segment sibling routes above there is no ordering hazard with `tools/:key` at all
  # (Rails requires a segment-count match, the same reason tools/addon_states/:id/params is safe) —
  # it sits here to keep the addon surface in one block, not because the order protects it.
  #
  # `format: false` because a node_id is opaque. Today it is a dot-free UUID, but if one ever
  # carried a dot Rails would slice it off as a format segment and the lookup would 404 for a file
  # that is right there — a silent failure, for a format this endpoint never negotiates.
  get "tools/:key/file/:node_id", to: "tools/addons#file", as: :tools_addon_file, format: false

  # `format: false` on the asset route stops Rails stripping ".js" from the path as a format segment.
  get  "tools/:key/asset/*path", to: "tools/addons#asset", as: :tools_addon_asset, format: false
  post "tools/:key",             to: "tools/addons#create"
  get  "tools/:key",             to: "tools/addons#show",  as: :tools_addon

  # DEV/TEST ONLY chunk-bytes endpoint backing the MemoryChunkStore's presigned URLs.
  # NOT mounted in production (there STORAGE_BACKEND=s3 presigns straight to storage).
  unless Rails.env.production?
    get "dev/blobs/*key", to: "dev_blobs#show",   format: false, as: :dev_blob
    put "dev/blobs/*key", to: "dev_blobs#update", format: false
  end

  # TEST/DEV-ONLY confirmed-account signup seam for the Rust integration tests. Mounted when
  # the explicit ENABLE_TEST_SIGNUP flag is set (off by default) OR in any non-production env —
  # so a self-hosted NON-production test/dev deploy (e.g. the Unraid box, which runs as
  # RAILS_ENV=production for deploy reasons) can opt in via the flag. The controller re-checks
  # the flag at request time. NEVER set ENABLE_TEST_SIGNUP on the real managed SaaS production.
  if ENV["ENABLE_TEST_SIGNUP"].present? || !Rails.env.production?
    post "v1/test/users", to: "v1/test_users#create"
  end

  # --- Sync engine API (v1) ---
  namespace :v1 do
    # Device enrollment by login (the Dropbox model): email+password -> a device token.
    # Replaces the pairing-code flow. No Bearer auth — the credentials ARE the auth.
    post "devices/login", to: "devices#login"
    # Direct add-a-device for an already-authenticated device (keeps its Bearer-authed path).
    resources :devices, only: [ :create ]

    # content commits (two-phase)
    post "commit", to: "commits#create"
    post "commit/:commit_id/finalize", to: "commits#finalize"

    # pull
    get "changes", to: "changes#index"
    get "tree", to: "tree#index"

    # search (name/path; scoped to the device's user — for the web UI / a fresh device)
    get "search", to: "search#index"

    # metadata ops + history
    post "nodes", to: "nodes#mkdir"
    post "nodes/symlink", to: "nodes#symlink"
    delete "nodes/:node_id", to: "nodes#destroy"
    post "nodes/:node_id/move", to: "nodes#move"
    get "nodes/:node_id/versions", to: "nodes#versions"
    post "nodes/:node_id/restore", to: "nodes#restore"
    post "nodes/:node_id/resolve_conflict", to: "nodes#resolve_conflict"

    # conflicts (offline-edit divergence)
    get "conflicts", to: "conflicts#index"

    # trash / undelete (deleted-file recovery; deletes are tombstones + versions kept)
    get "trash", to: "trash#index"
    post "trash/:node_id/restore", to: "trash#restore"

    # best-effort advisory edit locks
    post "nodes/:node_id/lock", to: "nodes#lock"
    post "nodes/:node_id/unlock", to: "nodes#unlock"
    get "locks", to: "locks#index"

    namespace :maker do
      resources :items, only: %i[index show create update destroy] do
        resources :file_attachments, only: %i[create destroy], shallow: true
        resources :taggings, only: %i[create destroy], shallow: true
      end
      resources :tags, only: %i[index create destroy]
      resources :collections, only: %i[index create update destroy] do
        member do
          get  "items"
          post "items", action: :add_item
          delete "items/:item_id", action: :remove_item
        end
      end
      resources :tasks, only: %i[index show create update destroy]
      resources :projects, only: %i[index show create update destroy] do
        resources :build_log_entries, only: %i[index create destroy], shallow: true
        resources :file_attachments, only: %i[create destroy], shallow: true
      end
      resources :locations, only: %i[index show create update destroy]
      resources :suppliers, only: %i[index show create update destroy]
      resources :inventory_items, only: %i[index show create update destroy] do
        member do
          post "adjust"
          get  "transactions"
        end
        collection { get "low_stock" }
      end
      resources :previews, only: %i[index create]
      resources :projects, only: [] do
        resources :boms, only: %i[index create], shallow: true
      end
      resources :boms, only: %i[show update destroy] do
        member { get "rollup" }
        resources :bom_lines, only: %i[index create update destroy], shallow: true
      end
    end

    # hydration
    post "chunks/download", to: "chunks#download"

    # Read-only share links. Owner side (authenticated): mint/revoke a link to one immutable
    # version. Redeem side (anonymous — the link token is the auth, no device bearer): view
    # the version's metadata + presign GETs for its chunks.
    resources :share_links, only: %i[create destroy]
    get  "share/:token",          to: "share#show"
    post "share/:token/download", to: "share#download"

    # The `local` (filesystem) chunk backend's storage tier — presigned, HMAC-authorized blob
    # PUT/GET (no bearer token; the URL's signature is the auth). Only active under
    # STORAGE_BACKEND=local; a 404/403 otherwise. The hash is hex (`[0-9a-f]+`), constrained so the
    # route can't capture a path with slashes.
    put "chunks/blob/:user_id/:hash", to: "chunks/blob#upload", constraints: { hash: /[0-9a-f]+/ }
    get "chunks/blob/:user_id/:hash", to: "chunks/blob#download", constraints: { hash: /[0-9a-f]+/ }
  end

  # ActionCable mount (change notifications)
  mount ActionCable.server => "/cable"
end
