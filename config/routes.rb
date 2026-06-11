Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # --- Sync engine API (v1) ---
  namespace :v1 do
    post "auth/register", to: "auth#register"
    resources :devices, only: [:create]

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

    # hydration
    post "chunks/download", to: "chunks#download"
  end

  # ActionCable mount (change notifications)
  mount ActionCable.server => "/cable"
end
