module Maker
  # THE ONE ANSWER TO "WHICH 3D MODEL DOES THIS FOLDER SHOW?" AND "WHERE DOES /models/:id SEND YOU?"
  # (structural redesign §5.4, slice 5). The Library's model strip and ModelsController#show's redirect
  # read this, so the two can never disagree about whether a model has a strip to land on.
  #
  # KEYED ON `folder_node_id`, NOT `auto_node_id`: an imported model's Models/<slug> sets only the
  # first, an auto folder model sets both to the folder, and a one-file auto model's `auto_node_id`
  # is a FILE on a shelf (docs/invariants/model-intake.md). `folder_node_id` has no index; the scan is
  # over this user's own models, the argument FilesController's @folder_project already makes.
  #
  # NEVER CALLS `ensure_library_folder!`: rendering a folder must not mint one (model-intake.md, "the
  # sweep never calls ensure_library_folder!" — and neither does a page).
  module ModelFolder
    module_function

    # The catalogued model whose strip the Library shows in this folder, or nil. An emptied auto model
    # is hidden exactly as the 3D models view hides it (model-intake.md: hidden, not dismissed), read
    # off the eager-loaded association rather than a `where.missing`. Several rows can name one folder
    # (a stale auto row beside an import, until `rake models:prune`), so the oldest VISIBLE one wins.
    # Does NOT check a project's claim: the Library already holds that answer (@folder_project).
    def model_in(user, folder_node_id)
      user.maker_models.catalogued.includes(:file_attachments)
          .where(folder_node_id:).order(:id)
          .detect { |model| !model.hollow? }
    end

    # The folder /models/:id redirects to, or nil to keep the model page: the model's folder, when it
    # is live, no project claims it (a project's claim wins — model-intake.md), and it shows THIS
    # model's strip. Everything else — a one-file model, a trashed folder, an import whose folder was
    # never made — keeps the page.
    def landing_folder_id(user, model)
      id = model.folder_node_id
      return nil if id.blank?
      return nil unless user.nodes.present.exists?(node_id: id, kind: "dir")
      return nil if user.maker_projects.exists?(folder_node_id: id)

      model_in(user, id)&.id == model.id ? id : nil
    end
  end
end
