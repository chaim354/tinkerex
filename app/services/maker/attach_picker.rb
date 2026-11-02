module Maker
  # WHAT THE "ATTACH A FILE" PICKER SAYS ABOUT EACH RESULT (2026-11-02, the UX audit's C9): where the
  # file is, and whether attaching it will also MOVE it into the project's folder. The picker listed
  # forty bare names with one "Attach" each, and Attach moved the file without saying so until the
  # flash afterwards ("Attached X and moved it into Y").
  #
  # THE MOVE IS PREDICTED FROM Maker::AttachToProject's OWN RULES, asked for the whole page at once:
  # a file moves on attach unless it belongs to a model's bundle (`:model_bundle`, which attaches
  # the bundle and moves nothing), another project already claims it (`:attached_elsewhere`), it is
  # inside a git working tree (`:in_working_tree`), or it is already in the project's folder. Each
  # rule is one query for every row rather than #refusal_for per row — the model owners through
  # AttachToProject.owners_by_node, the other projects' claims in one pluck, and the working trees
  # as the parents of every live `.git` marker, walked up the LibraryTree in memory — so the page
  # costs a handful of queries whatever it lists. A PREDICTION: AttachToProject decides at the click,
  # and a name collision there still answers "attached, left where it was" with its own prompt.
  #
  # Reads only; never attaches, moves or creates anything, and never calls the port.
  class AttachPicker
    Row = Data.define(:node, :folder, :moves)

    def self.rows(user:, project:, nodes:)
      return [] if nodes.empty?

      ids = nodes.map(&:node_id)
      tree = Maker::LibraryTree.new(user)
      bundled = Maker::AttachToProject.owners_by_node(user, ids)
      elsewhere = user.maker_file_attachments.where(attachable_type: "Maker::Project", node_id: ids)
                      .where.not(attachable_id: project.id).distinct.pluck(:node_id).to_set
      repo_roots = user.nodes.present.where(kind: "dir", name: Library::RepoMetadata::DIR_NAME)
                       .pluck(:parent_node_id).to_set
      folder_id = project.folder_node_id.presence
      # A folder named but no longer a live dir is in the trash: the attach then moves nothing
      # (AttachToProject#move's `:unavailable`). A project with no folder yet gets one minted on the
      # first attach, so its files do move.
      folder_gone = folder_id && !tree.dir?(folder_id)

      nodes.map do |node|
        chain = tree.ancestors_of(node.parent_node_id).to_a.compact
        in_repo = ([ node.parent_node_id ] + chain).any? { |id| repo_roots.include?(id) }
        moves = !folder_gone && !bundled.key?(node.node_id) && !elsewhere.include?(node.node_id) && !in_repo &&
                (folder_id.nil? || node.parent_node_id != folder_id)
        Row.new(node:, folder: node.parent_node_id ? tree.path_for(node.parent_node_id) : nil, moves:)
      end
    end
  end
end
