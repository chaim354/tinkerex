Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # --- Web UI (server-rendered file browser) ---
  root to: redirect("/files")

  # PLACEHOLDER dev login (no password) — replace when real auth lands (see
  # WebAuthentication). Selects/creates a User and stores it in the session.
  get  "login",  to: "web_sessions#new"
  post "login",  to: "web_sessions#create"
  delete "logout", to: "web_sessions#destroy"

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

    # metadata ops + history
    post "nodes", to: "nodes#mkdir"
    delete "nodes/:node_id", to: "nodes#destroy"
    post "nodes/:node_id/move", to: "nodes#move"
    get "nodes/:node_id/versions", to: "nodes#versions"
    post "nodes/:node_id/restore", to: "nodes#restore"
    post "nodes/:node_id/resolve_conflict", to: "nodes#resolve_conflict"

    # conflicts (offline-edit divergence)
    get "conflicts", to: "conflicts#index"

    # best-effort advisory edit locks
    post "nodes/:node_id/lock", to: "nodes#lock"
    post "nodes/:node_id/unlock", to: "nodes#unlock"
    get "locks", to: "locks#index"

    # hydration
    post "chunks/download", to: "chunks#download"
  end

  # ActionCable mount (change notifications)
  mount ActionCable.server => "/cable"
end
