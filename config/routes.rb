Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

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
