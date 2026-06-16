Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # --- Web UI (server-rendered file browser) ---
  root to: redirect("/files")

  # --- Web auth (real Rails 8 password auth + email confirmation) ---
  # Human-identity layer (docs/parity-roadmap.md §A). Sits in front of the unchanged
  # device-token + DevicePairing bootstrap (v1 namespace below).
  get    "login",  to: "sessions#new"
  post   "login",  to: "sessions#create"
  delete "logout", to: "sessions#destroy"

  get  "signup", to: "registrations#new"
  post "signup", to: "registrations#create"

  # Email confirmation (proves email ownership — §12 step 5).
  get  "confirm",          to: "confirmations#show", as: :confirm_email
  get  "confirmations/new", to: "confirmations#new", as: :new_confirmation
  post "confirmations",     to: "confirmations#create", as: :confirmations

  # Password reset.
  get   "password/new",  to: "passwords#new",    as: :new_password
  post  "password",      to: "passwords#create", as: :passwords
  get   "password/edit", to: "passwords#edit",   as: :edit_password
  patch "password",      to: "passwords#update", as: :password

  # OmniAuth seam (no provider wired yet — see OmniauthCallbacksController). Drawn so the
  # callback path is stable; enable a strategy + middleware later. Guarded by env so it's
  # inert until configured.
  if ENV["OMNIAUTH_ENABLED"].present?
    match "auth/:provider/callback", to: "omniauth_callbacks#create", via: [ :get, :post ]
    get   "auth/failure", to: "omniauth_callbacks#failure"
  end

  # Trash / undelete: list tombstoned nodes + restore (re-points at the kept version).
  resources :trash, only: %i[index] do
    member { post "restore" }
  end

  # File library: list / view / upload (begin+finalize) / download / delete.
  resources :files, only: %i[index show destroy] do
    collection do
      post "begin_upload"
      post "finalize_upload"
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

  # --- Sync engine API (v1) ---
  namespace :v1 do
    post "auth/register", to: "auth#register"
    post "auth/pair", to: "auth#pair"
    resources :devices, only: [ :create ]
    post "devices/pairing", to: "devices#pairing"

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
      resources :projects, only: %i[index show create update destroy]
    end

    # hydration
    post "chunks/download", to: "chunks#download"

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
