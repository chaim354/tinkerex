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
    # maps to -- which is what stops a stray PDF loose on a shelf from becoming a model, while a PDF
    # sitting IN a model folder still attaches to it. (`owners` is NOT the whole subtree: the three
    # filters in .classify decide which of a model folder's files actually join it.) `dir_keys`
    # remembers which keys are folders, so the sweep can set folder_node_id without asking the
    # database again per model.
    # `names` carries every file's name so the sweep derives roles without a second query.
    Plan = Data.define(:owners, :model_keys, :dir_keys, :titles, :names, :skips) do
      def files_for(key) = owners.select { |_file, owner| owner == key }.keys
    end

    MODEL_ROLE = "model".freeze

    # ROLES A MODEL DOES NOT CLAIM, even inside its own folder. A DENYLIST, NOT AN ALLOWLIST, and
    # the direction is the safe one: a role added to Maker::FileAttachment::ROLE_LABELS later joins
    # models by default, where an allowlist would drop it silently and nothing would go red.
    # Membership is pinned against ROLES (model_intake_classify_test.rb) so a typo here cannot
    # quietly filter nothing.
    #
    # THE LINE IS "IS THIS THE MODEL, OR ITS OWN ARTEFACT". `vector` (dxf/svg) and `laser` (lbrn2)
    # are 2D cut jobs that merely share a folder -- the reported bug, where `warso main/plans 1`
    # gave three .obj files a model that also held three .dxf drawings. `code` is a firmware or
    # script tree, `gcode` is sliced OUTPUT, `document` is READMEs and name lists. What stays is
    # everything a mesh needs or came from: `image` (renders AND texture maps), `instructions`,
    # `cad_source`, `source_archive`, and `other` -- which is where an .obj's .mtl lands, so
    # narrowing this to MODEL_ROLE alone ships a mesh that renders untextured.
    EXCLUDED_ROLES = %w[code document gcode laser vector].freeze

    # What one run did. `status` is :ok or :capped -- a caller has to be able to tell "your library
    # is catalogued" from "there is more of it than one run will do".
    #
    # `attached` IS THIS RUN'S DELTA, NOT THE TOTAL -- the rows insert_all actually wrote, so a
    # steady-state sweep over a fully catalogued library reports 0 rather than the library's size.
    # Measured, not assumed: the conflicting rows come back out of RETURNING, so `result.rows` is
    # the inserted set alone (see .attach_all).
    RunResult = Data.define(:created, :attached, :skipped, :status, :cap)

    # The ceiling on models created in one UNATTENDED run. ABSOLUTE, NOT A PERCENTAGE, for the
    # reason Maker::ProjectIntake::MAX_MOVES gives at length: the intended first run catalogues
    # 100% of what is there, so a percentage would be guarding against success.
    #
    # THERE IS DELIBERATELY NO SECOND, SMALLER CAP. Maker::ProjectIntake carries MAX_MOVES AND
    # EAGER_MAX_MOVES because it has an entry point that runs inside a browser request. This class
    # does not: nothing in a web request sweeps. If a nudge is ever added it needs its own cap, for
    # the reason §14f states at both of those constants.
    MAX_MODELS = 200

    # A BAD OVERRIDE FALLS BACK; IT DOES NOT CRASH THE JOB. `Integer("-5")` SUCCEEDS, so the rescue
    # below never sees a negative -- and a negative reaches `todo.first(-5)`, which raises
    # `ArgumentError: negative array size` deep inside a recurring job, long after the typo. Zero
    # is refused for the same reason it would be surprising: a cap of 0 catalogues nothing, forever,
    # silently. Both fall back to the default rather than guessing what was meant.
    def self.max_models
      value = Integer(ENV.fetch("MODEL_CATALOG_MAX_MODELS", MAX_MODELS))
      value.positive? ? value : MAX_MODELS
    rescue ArgumentError, TypeError
      MAX_MODELS
    end

    def self.for_user(user:, cap: nil)
      Maker::Shelf.seed_once!(user)
      cap ||= max_models
      plan = classify(user)

      claimed = claimed_folders(user, plan.model_keys)
      # DROPPED BEFORE `existing` IS EVEN LOOKED UP, so a claimed key has no model in the index and
      # attach_all's `next unless model` leaves its files alone too -- both halves, which is the
      # reading the imported-model rule has always had (§14k). It also means an auto model written
      # by the OLD rule stops accreting the moment a project claims its folder; clearing that row
      # out is Maker::ModelIntake::Prune's job, not a sweep that only ever inserts.
      keys = plan.model_keys.reject { |k| claimed.include?(k) }
      existing = user.maker_models.where(auto_node_id: keys).index_by(&:auto_node_id)

      # DETERMINISTIC ORDER so a capped run is reproducible and a second run continues where the
      # first stopped instead of re-rolling the dice.
      todo = keys.reject { |k| existing.key?(k) }.sort
      capped = todo.size > cap
      todo = todo.first(cap)

      created = 0
      todo.each do |key|
        model = user.maker_models.create!(
          # fetch WITHOUT A DEFAULT, deliberately. `classify` writes titles[key] on the line above
          # the one that adds the key, so a key with no title is unreachable -- and the tempting
          # `fetch(key, key)` would ship a model TITLED `d-enc` if it ever became reachable, a
          # visible bug wearing a successful sweep. §14b's `fetch` with no default, same argument.
          title: plan.titles.fetch(key),
          origin: "auto",
          auto_node_id: key,
          # A DIR KEY IS ALREADY THE MODEL'S FOLDER. Setting it here creates nothing; calling
          # ensure_library_folder! would mint Models/<slug> per model as a side effect of looking
          # (§14f, and Projects::AttachmentsController#relocate's recorded bug).
          folder_node_id: plan.dir_keys.include?(key) ? key : nil
        )
        existing[key] = model
        created += 1
      end

      attached = attach_all(user, plan, existing)
      RunResult.new(created:, attached:, skipped: plan.skips.size,
                    status: capped ? :capped : :ok, cap:)
    end

    # PUBLIC because Maker::ModelIntake::Prune is its second caller and must ask the same
    # question this sweep asks, not a second spelling of it.
    #
    # FOLDERS THAT ARE SOMEONE ELSE'S ALREADY -- look, do not take (§14f's "reads folder_node_id,
    # never calls ensure_library_folder!" has the same shape). TWO CLAIMANTS:
    #
    #   an IMPORT-origin model -- a folder the user imported into is that model's;
    #   a PROJECT -- a folder under `Projects/` is a build, not a print. `*` makes `Projects` a
    #     shelf, so without this a project folder became one model holding its whole tree: measured,
    #     `Projects/TheFlightWall_OSS` had 2305 attachments of which 2 were meshes. Asking WHO
    #     CLAIMS THE FOLDER rather than re-testing the path keeps ProjectDiscovery's policy in one
    #     place, and Library::ScanJob already runs discovery before this sweep (§14k). A user who
    #     deletes the project releases the folder, which is the same "the row is the memory" rule
    #     dismissal runs on.
    #
    # BOTH QUERIES ARE UNSCOPED ON STATUS. An ARCHIVED project keeps folder_node_id and still claims
    # its folder; filtering archived rows out here is exactly how a dismissed thing comes back, the
    # mistake Maker::ProjectDiscovery#adoptable and the `catalogued` scope both record.
    def self.claimed_folders(user, model_keys)
      user.maker_models.where(origin: "import").where(folder_node_id: model_keys)
          .pluck(:folder_node_id)
          .concat(user.maker_projects.where(folder_node_id: model_keys).pluck(:folder_node_id))
          .to_set
    end

    # ONE STATEMENT, NOT ONE QUERY PER FILE. `unique_by` names the existing uniqueness index, so a
    # re-sweep of an already-attached library inserts nothing rather than raising. insert_all
    # bypasses timestamp autofill, hence the explicit stamps.
    def self.attach_all(user, plan, models)
      now = Time.current
      rows = plan.owners.filter_map do |file_id, key|
        model = models[key]
        next unless model
        next if model.dismissed_at.present?

        { user_id: user.id, attachable_type: "Maker::Model", attachable_id: model.id,
          node_id: file_id, role: Maker::FileAttachment.role_for(plan.names[file_id]), position: 0,
          created_at: now, updated_at: now }
      end
      return 0 if rows.empty?

      result = Maker::FileAttachment.insert_all(
        rows, unique_by: %i[user_id attachable_type attachable_id node_id]
      )
      result.rows.size
    end
    private_class_method :attach_all

    # PURE. Reads `nodes` and `maker_shelves`, writes nothing, and is the whole rule.
    def self.classify(user)
      tree     = Maker::LibraryTree.new(user)
      patterns = user.maker_shelves.pluck(:path)
      shelves  = shelf_dir_ids(tree, patterns, user)

      owners  = {}
      titles  = {}
      names   = {}
      parents = {}
      skips   = []
      model_keys = Set.new
      dir_keys   = Set.new
      # DIRS THAT DIRECTLY HOLD A MODEL-ROLE FILE. Collected in this same pass rather than by a
      # second query, so the sweep stays constant in query count (§14k).
      model_dirs = Set.new

      user.nodes.present.where(kind: "file")
          .pluck(:node_id, :name, :parent_node_id).each do |node_id, name, parent_id|
        model_role = Maker::FileAttachment.role_for(name) == MODEL_ROLE
        model_dirs << parent_id if model_role

        key, title = owner_key(tree, shelves, node_id:, name:, parent_id:)
        if key.nil?
          skips << [ node_id, :no_shelf ]
          next
        end

        owners[node_id] = key
        titles[key] = title
        names[node_id] = name
        parents[node_id] = parent_id
        dir_keys << key if tree.dir?(key)
        model_keys << key if model_role
      end

      # THREE FILTERS, AND THE SECOND TWO ARE THE 2026-09-02 FIX. Until then a folder model claimed
      # its ENTIRE subtree with every role, which on a real share library gave
      # `Projects/TheFlightWall_OSS` 2305 attachments of which 2 were meshes, and gave
      # `warso main/plans 1` three .obj files plus the three .dxf drawings beside them -- the
      # reported bug. Measured across that library: 2441 attachments on 6 folder models, 32 of them
      # model-role.
      #
      # 1. A key nothing model-role claims is not a model, so neither it nor the files under it are
      #    in the plan at all -- that is how `notes.pdf` loose on a shelf becomes nothing.
      # 2. A file joins only from a folder that is PART OF THE MODEL: the model's own folder, or one
      #    that itself holds one of the model's meshes. `parent == key` IS LOAD-BEARING AND IS NOT
      #    IMPLIED BY THE OTHER ARM -- an ordinary download is `Kit/notes.pdf` beside
      #    `Kit/stl/part.stl`, whose root folder holds no mesh at all, and without it that PDF is
      #    dropped. (A one-file model's key is the FILE, so `parent == key` is never true there and
      #    the model_dirs arm is what covers it.)
      # 3. EXCLUDED_ROLES -- see the constant.
      owners.select! do |file_id, key|
        next false unless model_keys.include?(key)

        parent = parents[file_id]
        next false unless parent == key || model_dirs.include?(parent)

        !EXCLUDED_ROLES.include?(Maker::FileAttachment.role_for(names[file_id]))
      end
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
