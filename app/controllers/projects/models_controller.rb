module Projects
  # THE ADD-MODEL PICKER (2026-10-21; docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md):
  # Projects::AttachmentsController#new's page, for models. Search by title, or the most recently
  # changed with no query; each result posts to Models::ProjectsController#create — the one attach
  # door — with `return_to=project` so the maker lands back on the Models panel.
  #
  # CATALOGUED ONLY: a dismissed auto model is one the maker removed from the catalog, and offering
  # it here would put it back on a page through a side door. NOT HOLLOW EITHER (#new says how).
  #
  # AN ARCHIVED PROJECT GETS THE REFUSAL, NOT THE BUTTONS: #create refuses an attach to one, so a
  # list of Attach buttons that all bounce would be a page of dead ends. The view says why instead.
  class ModelsController < ApplicationController
    RECENT_LIMIT = 40

    # GET /projects/:project_id/models/new?q=
    def new
      @project = current_user.maker_projects.find_by!(slug: params[:project_id].to_s)
      @archived = @project.status == "archived"
      @results = []
      return if @archived

      # THE FILES SEARCH IDIOM (SearchController's header): `LOWER(title) LIKE ? ESCAPE '\'`, the
      # pattern built with sanitize_sql_like and capped at SearchController::QUERY_MAX. THE ESCAPE
      # CLAUSE IS LOAD-BEARING: SQLite has no default LIKE escape character, so without it the
      # backslash sanitize_sql_like puts before `%` and `_` is matched literally and a search for
      # "50%" finds nothing on self-host. LOWER on both sides: Postgres LIKE is case-sensitive.
      @q = params[:q].to_s.strip.first(SearchController::QUERY_MAX).presence
      scope = current_user.maker_models.catalogued
      # THE FOURTH SITE OF Maker::Model#hollow? (an auto model with no file rows), and the one that
      # must spell it in SQL: #create refuses a hollow model (:empty_model), so listing one offers a
      # dead Attach — and filtered in Ruby after the LIMIT, hollow rows would still spend
      # RECENT_LIMIT and push real models off the page. Keep it equal to the predicate.
      filed = current_user.maker_file_attachments.where(attachable_type: "Maker::Model").select(:attachable_id)
      scope = scope.where.not(origin: "auto").or(scope.where(id: filed))
      scope = scope.where("LOWER(title) LIKE ? ESCAPE '\\'", "%#{Maker::Model.sanitize_sql_like(@q.downcase)}%") if @q
      @results = scope.order(updated_at: :desc, id: :desc).limit(RECENT_LIMIT).to_a
    end
  end
end
