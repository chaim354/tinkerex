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
  # `owned_node_ids` is the attached files whose owner is shown here — ProjectsController#show drops
  # them from "Linked from elsewhere" so each file appears once, inside its model.
  #
  # CONSTANT IN QUERY COUNT: the owner pluck, the catalogued models with their attachments, and
  # ModelProjects' own three. It loads every catalogued model, as the 3D models view does.
  class ProjectModels
    Result = Data.define(:models, :linked_ids, :owned_node_ids)

    def self.for(user, project, attached_node_ids:)
      owners = Maker::AttachToProject.owners_by_node(user, attached_node_ids)
      catalogued = user.maker_models.catalogued.includes(:file_attachments).to_a
      return Result.new(models: [], linked_ids: Set.new, owned_node_ids: Set.new) if catalogued.empty?

      located = Maker::ModelProjects.group(user, catalogued).find { |g| g.project&.id == project.id }&.models || []
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
