module Maker
  # WHICH PROJECT EACH MODEL ON THE 3D MODELS VIEW SITS IN, so the view can show them grouped by
  # project (Files::ModelsController#index) — the owner's ask on 2026-10-20, when 9 of the live
  # library's 42 models lived under a project's folder (through the `Projects/*/models` shelf) and
  # the page showed them mixed in with the other 33.
  #
  # A MODEL'S PROJECT IS THE NEAREST FOLDER AT-OR-ABOVE IT THAT A PROJECT CLAIMS (`folder_node_id`),
  # the reading Tools::AddonsController#owning_project_folder already gives a save destination.
  # WHERE a model sits is Maker::Model.placements' answer, the one the model's card and its search
  # row read too: its own folder, or the folder that holds its file when its key is a file (a loose
  # one-file model's is, which is why the walk never starts from the key itself).
  # Archived projects still claim their folder (docs/invariants/model-intake.md), so their models
  # stay grouped under them rather than reading as loose.
  #
  # CONSTANT IN QUERY COUNT, whatever the number of models or the depth of the tree: one query for the
  # projects, one pluck of every live dir (Maker::LibraryTree, walked in memory), and the placements'
  # own. A caller that needs the tree or the places for something else hands them in and they are
  # read once (Files::ModelsController#index). page_query_budget_test.rb pins that with models nested
  # inside project folders.
  class ModelProjects
    Group = Data.define(:project, :models)

    # Groups in display order: projects by name, then the models in no project (project nil) last.
    # Each group keeps the models in the order they were handed in, so the page's own sort holds
    # inside every group. An empty list answers no groups at all.
    def self.group(user, models, tree: nil, places: nil)
      return [] if models.empty?

      projects = user.maker_projects.where.not(folder_node_id: nil).index_by(&:folder_node_id)
      return [ Group.new(project: nil, models:) ] if projects.empty?

      tree ||= Maker::LibraryTree.new(user)
      places ||= Maker::Model.placements(user, models, tree:)
      by_project = models.group_by do |model|
        dir = places[model.id]
        # No place, the library root, and an unresolvable chain (a tombstoned or missing ancestor)
        # all answer nil: the model is simply in no project.
        dir && tree.ancestors_of(dir)&.compact&.lazy&.filter_map { |id| projects[id] }&.first
      end

      grouped = by_project.keys.compact.sort_by { |p| [ p.name.downcase, p.id ] }
      grouped << nil if by_project.key?(nil)
      grouped.map { |project| Group.new(project:, models: by_project[project]) }
    end
  end
end
