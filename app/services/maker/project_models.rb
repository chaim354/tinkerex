module Maker
  # A PROJECT'S 3D MODELS, FOR ITS MODELS PANEL (2026-10-21; docs/superpowers/specs/
  # 2026-10-20-attach-model-to-project-design.md). Derived on every render from rows that already
  # exist — there is no project↔model table, by decision:
  #
  #   IN THE FOLDER — a catalogued model Maker::ModelProjects places in this project (the nearest
  #     project folder at-or-above it: a folder or a lone file under `Projects/<x>/models/`). Asked
  #     of ModelProjects rather than re-derived, so this panel and the 3D models view's grouping
  #     cannot disagree about where a model is.
  #   LINKED — a catalogued model that owns one of the project's attached files, by
  #     Maker::AttachToProject's rule (the oldest model row per file). A bundle attach writes those
  #     rows; so did every bundle attached before this panel existed, which is why they show as cards
  #     with no migration.
  #
  # A model that is both shows once, as in the folder: it is the project's by where it is, and a
  # Detach there would delete rows and change nothing a maker can see.
  #
  # A HOLLOW MODEL (Maker::Model#hollow?: a sweep-made model whose files are all gone) never shows,
  # exactly as the 3D models view and a folder's strip hide it.
  #
  # THE CALLER PASSES THE PROJECT'S LIVE ATTACHED NODE IDS as `attached_node_ids` — the attachments
  # whose files still exist (ProjectsController#show's @attachments, which already set the dead
  # ones aside), so a model linked only through a deleted file gets no card.
  #
  # `owned_node_ids` is the attached files whose owner is shown here — ProjectsController#show drops
  # them from "Linked from elsewhere" so each file appears once, inside its model.
  #
  # CONSTANT IN QUERY COUNT: the owner pluck, the catalogued models with their attachments, and
  # ModelProjects' own three (none for a project with no folder, which can hold no model). It loads
  # every catalogued model, as the 3D models view does.
  class ProjectModels
    Result = Data.define(:models, :linked_ids, :owned_node_ids)

    def self.for(user, project, attached_node_ids:)
      owners = Maker::AttachToProject.owners_by_node(user, attached_node_ids)
      catalogued = user.maker_models.catalogued.includes(:file_attachments).to_a.reject(&:hollow?)
      return Result.new(models: [], linked_ids: Set.new, owned_node_ids: Set.new) if catalogued.empty?

      located = if project.folder_node_id
        Maker::ModelProjects.group(user, catalogued).find { |g| g.project&.id == project.id }&.models || []
      else
        []
      end
      located_ids = located.to_set(&:id)
      by_id = catalogued.index_by(&:id)
      linked = owners.values.uniq.filter_map { |id| by_id[id] }.reject { |m| located_ids.include?(m.id) }

      models = (located + linked).sort_by { |m| [ m.title.downcase, m.id ] }
      shown = models.to_set(&:id)
      Result.new(models:, linked_ids: linked.to_set(&:id),
                 owned_node_ids: owners.select { |_, model_id| shown.include?(model_id) }.keys.to_set)
    end
  end
end
