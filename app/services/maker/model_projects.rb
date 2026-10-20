module Maker
  # WHICH PROJECT EACH MODEL ON THE 3D MODELS VIEW SITS IN, so the view can show them grouped by
  # project (Files::ModelsController#index) — the owner's ask on 2026-10-20, when 9 of the live
  # library's 42 models lived under a project's folder (through the `Projects/*/models` shelf) and
  # the page showed them mixed in with the other 33.
  #
  # A MODEL'S PROJECT IS THE NEAREST FOLDER AT-OR-ABOVE IT THAT A PROJECT CLAIMS (`folder_node_id`),
  # the reading Tools::AddonsController#owning_project_folder already gives a save destination.
  # Where a model sits is its own key: `auto_node_id` for a sweep-made model — a FOLDER for a folder
  # model, but the FILE for a loose one-file model (Maker::ModelIntake), which is why a key that is
  # not a dir walks from its parent — then an import's `folder_node_id`, then its first attachment.
  # Archived projects still claim their folder (docs/invariants/model-intake.md), so their models
  # stay grouped under them rather than reading as loose.
  #
  # CONSTANT IN QUERY COUNT, whatever the number of models or the depth of the tree: one query for the
  # projects, one pluck of every live dir (Maker::LibraryTree, walked in memory), and one pluck of
  # the parents of the keys that are files. The caller has already loaded :file_attachments.
  # page_query_budget_test.rb pins that with models nested inside project folders.
  class ModelProjects
    Group = Data.define(:project, :models)

    # Groups in display order: projects by name, then the models in no project (project nil) last.
    # Each group keeps the models in the order they were handed in, so the page's own sort holds
    # inside every group. An empty list answers no groups at all.
    def self.group(user, models)
      return [] if models.empty?

      projects = user.maker_projects.where.not(folder_node_id: nil).index_by(&:folder_node_id)
      return [ Group.new(project: nil, models:) ] if projects.empty?

      tree = Maker::LibraryTree.new(user)
      starts = models.map { |m| m.auto_node_id || m.folder_node_id || m.file_attachments.first&.node_id }
      file_ids = starts.compact.reject { |id| tree.dir?(id) }.uniq
      parents = file_ids.empty? ? {} : user.nodes.where(node_id: file_ids).pluck(:node_id, :parent_node_id).to_h

      by_project = models.each_with_index.group_by do |_model, i|
        start = starts[i]
        dir = tree.dir?(start) ? start : parents[start]
        # An unresolvable chain (a tombstoned or missing ancestor) answers nil, and so does the
        # library root: the model is simply in no project.
        dir && tree.ancestors_of(dir)&.compact&.lazy&.filter_map { |id| projects[id] }&.first
      end

      grouped = by_project.keys.compact.sort_by { |p| [ p.name.downcase, p.id ] }
      grouped << nil if by_project.key?(nil)
      grouped.map { |project| Group.new(project:, models: by_project[project].map(&:first)) }
    end
  end
end
