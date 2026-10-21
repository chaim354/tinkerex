module Projects
  # THE ADD-MODEL PICKER (2026-10-21; docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md):
  # Projects::AttachmentsController#new's page, for models. Search by title, or the most recently
  # changed with no query; each result posts to Models::ProjectsController#create — the one attach
  # door — with `return_to=project` so the maker lands back on the Models panel.
  #
  # CATALOGUED ONLY: a dismissed auto model is one the maker removed from the catalog, and offering
  # it here would put it back on a page through a side door.
  class ModelsController < ApplicationController
    RECENT_LIMIT = 40

    # GET /projects/:project_id/models/new?q=
    def new
      @project = current_user.maker_projects.find_by!(slug: params[:project_id].to_s)
      scope = current_user.maker_models.catalogued
      if params[:q].present?
        # LOWER on both sides: Postgres (managed) LIKE is case-sensitive where SQLite's is not.
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s.downcase)}%"
        scope = scope.where("LOWER(title) LIKE ?", pattern)
      end
      @results = scope.order(updated_at: :desc, id: :desc).limit(RECENT_LIMIT).to_a
    end
  end
end
