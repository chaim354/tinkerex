module Maker
  # Make the model catalog agree with what is in the library: every model-role file belongs to a
  # model, and which model is decided by the nearest SHELF above it.
  #
  # WHY A SWEEP RATHER THAN A HOOK ON EVERY WRITE -- the same argument Maker::ProjectIntake makes,
  # one level up. A file can reach the library seven ways (FilesController#create,
  # #finalize_upload, Library::Reconciler, a device push landing on the sync server,
  # Maker::Addons::LibraryOutput, Maker::MoveNode, a trash restore) and there is no funnel. Hooking
  # each is seven sites that must agree and an eighth that silently skips the rule. This reads
  # `nodes`, the catalog ALL THREE BACKENDS populate, so it covers every door and any future one.
  #
  # IT NEVER TOUCHES THE PORT. Cataloguing writes database rows only -- no mkdir, no move, no
  # bytes -- which is what makes it identical on all three backends and testable without a library
  # on disk.
  class ModelIntake
    # The classification, before anything is written. `owners` maps a file node_id to the KEY of
    # the model that claims it; a key is either a DIR node_id (a folder model) or a FILE node_id (a
    # loose one-file model). `model_keys` is the subset of keys that at least one MODEL-ROLE file
    # maps to -- which is what stops a stray PDF loose on a shelf from becoming a model while still
    # letting the PDF inside a model folder attach to it. `dir_keys` remembers which keys are
    # folders, so the sweep can set folder_node_id without asking the database again per model.
    # `names` carries every file's name so the sweep derives roles without a second query.
    Plan = Data.define(:owners, :model_keys, :dir_keys, :titles, :names, :skips) do
      def files_for(key) = owners.select { |_file, owner| owner == key }.keys
    end

    MODEL_ROLE = "model".freeze

    # PURE. Reads `nodes` and `maker_shelves`, writes nothing, and is the whole rule.
    def self.classify(user)
      tree     = Maker::LibraryTree.new(user)
      patterns = user.maker_shelves.pluck(:path)
      shelves  = shelf_dir_ids(tree, patterns, user)

      owners = {}
      titles = {}
      names  = {}
      skips  = []
      model_keys = Set.new
      dir_keys   = Set.new

      user.nodes.present.where(kind: "file")
          .pluck(:node_id, :name, :parent_node_id).each do |node_id, name, parent_id|
        key, title = owner_key(tree, shelves, node_id:, name:, parent_id:)
        if key.nil?
          skips << [ node_id, :no_shelf ]
          next
        end

        owners[node_id] = key
        titles[key] = title
        names[node_id] = name
        dir_keys << key if tree.dir?(key)
        model_keys << key if Maker::FileAttachment.role_for(name) == MODEL_ROLE
      end

      # A key nothing model-role claims is not a model, so neither it nor the files under it are in
      # the plan at all -- that is how `notes.pdf` loose on a shelf becomes nothing.
      owners.select! { |_file, key| model_keys.include?(key) }
      Plan.new(owners:, model_keys: model_keys.to_a, dir_keys:, titles:, names:, skips:)
    end

    # Which DIR node_ids (plus nil, the library root) the shelf patterns name.
    def self.shelf_dir_ids(tree, patterns, user)
      ids = Set.new
      ids << nil if patterns.any? { |p| Maker::Shelf.matches?(p, "") }
      user.nodes.present.where(kind: "dir").pluck(:node_id).each do |dir_id|
        path = tree.path_for(dir_id)
        next if path.nil?

        ids << dir_id if patterns.any? { |p| Maker::Shelf.matches?(p, path) }
      end
      ids
    end
    private_class_method :shelf_dir_ids

    # THE RULE ITSELF. Walk up to the nearest shelf: a direct child of one is its own model, and
    # anything deeper belongs to the shelf's direct child folder on the way down. Returns
    # [key, title], or [nil, nil] when no ancestor is a shelf.
    def self.owner_key(tree, shelves, node_id:, name:, parent_id:)
      chain = tree.ancestors_of(parent_id)
      return [ nil, nil ] if chain.nil?

      index = chain.index { |dir_id| shelves.include?(dir_id) }
      return [ nil, nil ] if index.nil?

      # index 0 means the shelf IS the file's own parent -> the file is its own model. Otherwise
      # the model is the entry one step BELOW the shelf, which is the dir directly under it.
      return [ node_id, File.basename(name.to_s, ".*") ] if index.zero?

      dir_id = chain[index - 1]
      [ dir_id, tree.path_for(dir_id).to_s.split("/").last ]
    end
    private_class_method :owner_key
  end
end
