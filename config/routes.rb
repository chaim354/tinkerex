Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

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
    end
  end

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

  # --- Addons (Tools) — the /tools gallery + each addon's server-rendered UI ---
  get "tools", to: "tools/home#index", as: :tools
  namespace :tools do
    resources :boxes, only: %i[index new show create] do
      post :preview, on: :collection
      # Self-hosted proxy for a generator's sample photo: Rails fetches it from the internal-only
      # sidecar (which bundles boxes.py's GPL thumbnails) so the browser never hits an external host.
      get "thumb/:key", to: "boxes#thumb", on: :collection, as: :thumb, constraints: { key: /[A-Za-z0-9]+/ }
    end
    resources :generators, only: %i[index create show]
  end

  # OpenSCAD addon. TWO naming traps here, both about the inflector, and the routes are written out
  # by hand to dodge both.
  #
  # 1. NOT `resources :openscad`. Rails derives the collection helper from name.pluralize
  #    ("openscads") and the member helper from name.singularize ("openscad"), so `resources` would
  #    leave tools_openscad_path meaning SHOW — which requires an id. The gallery renders each
  #    addon's OWN declared `path:` proc (Maker::Addons::Registry), and this addon's names
  #    tools_openscad_path, so `resources` here would make /tools raise UrlGenerationError for
  #    every user. Guarded generically by test/services/maker/addons/registry_test.rb — "every
  #    registered addon's path resolves with no arguments".
  # 2. NOT inside `namespace :tools`. A namespace prefixes `as:`, so `as: :new_openscad` in there
  #    yields tools_new_openscad_path — while `resources` inside the same namespace yields
  #    new_tools_box_path for the sibling addon. Declared at top level, `as:` is the whole helper
  #    name, so these read the same way the other addons' do.
  #
  # `new` and `preview` precede `:id` so neither is swallowed as an id.
  get  "tools/openscad",         to: "tools/openscad#index",   as: :tools_openscad
  get  "tools/openscad/new",     to: "tools/openscad#new",     as: :new_tools_openscad
  post "tools/openscad/preview", to: "tools/openscad#preview", as: :preview_tools_openscad
  post "tools/openscad",         to: "tools/openscad#create"
  get  "tools/openscad/:id",     to: "tools/openscad#show",    as: :tools_openscad_design

  # The params behind ANY addon state, as a download. ONE route for every addon: `Maker::AddonState`
  # is addon-agnostic (`data` IS each addon's own shape), so there is nothing per-addon to branch on.
  # Declared at top level so the helper reads like its sibling `tools_openscad_design_path`. The
  # two inflector traps documented above do NOT apply here — `addon_state` inflects cleanly both
  # ways; this is about the helper name matching, nothing more.
  get "tools/addon_states/:id/params", to: "tools/addon_params#show", as: :tools_addon_params

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
