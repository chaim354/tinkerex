module Projects
  # ADOPT IN PLACE (stage 4, S4-6; spec decision D1, stories 1.3 and 4.7). A live directory node
  # anywhere in the library becomes a project: one `maker_projects` row whose folder_node_id points
  # at that node, and nothing else. No mkdir, no move, no rename, no second kind of thing.
  #
  # A DOOR, NOT A SWEEP — the distinction the spec settles and the reason this class can be small.
  # Maker::ProjectDiscovery keeps every rule it has (direct children of `Projects/`, the unscoped
  # claim lookup, never minting `Projects/`, the caps); this is a second entrance onto the SAME
  # concept, so it shares discovery's name rule (.adoptable_name?) rather than spelling one, and it
  # takes the same can't-fail slug (Maker::Project.available_slug) for the same reason a sweep does:
  # a folder named `模型` or one colliding with a hand-made project must not raise at the user.
  #
  # NOTHING DOWNSTREAM NEEDED A CHANGE, and that is the design working rather than an omission.
  # Maker::ProjectFolderListing resolves the folder through the LibraryTree from folder_node_id
  # alone; Maker::ProjectIntake#live_folder reads the same column and #place resolves its category
  # folders UNDER THAT NODE, never a path rebuilt from the slug (§14f); and
  # Project#ensure_library_folder! returns early whenever the column names a live dir, so none of
  # its five callers mints `Projects/<slug>` beside the folder the maker chose.
  #
  # THE REFUSALS ARE ORDERED CHEAPEST FIRST, and each answers with the ACTION that would work
  # instead of merely with the failure — the shape §14a requires of ChunkRemote's own 409.
  class AdoptionsController < ApplicationController
    def create
      node_id = params[:node_id].to_s.presence
      return refuse(nil, "Pick a folder first.") if node_id.nil?

      # A FILE, A TOMBSTONE, ANOTHER USER'S NODE AND A TYPO ARE ONE ANSWER, deliberately. Telling
      # them apart would disclose that an id exists, and none of the four is a different act for
      # the maker to take.
      node = current_user.nodes.present.find_by(node_id:, kind: "dir")
      return refuse(nil, "That folder isn't in your library.") unless node

      refusal = refusal_for(node)
      return refusal if refusal

      project = adopt!(node)
      redirect_to project_path(project), notice: adopted_notice(node, project, @dismissed_model)
    end

    private

    # Returns a redirect (already performed) or nil. Split out so #create reads as the four steps
    # it is; every branch here creates NOTHING, which is what makes a refusal recoverable.
    def refusal_for(node)
      unless Maker::ProjectDiscovery.adoptable_name?(node.name)
        return refuse(node, "A folder whose name starts with a dot can't be a project.")
      end

      # `Projects/` ITSELF. Adopting it would make one project holding every other project's folder
      # — and would then claim the root against discovery, which reads the same column, silently
      # switching the whole feature off.
      if node.parent_node_id.nil? && node.name == Maker::ProjectFolders::ROOT
        return refuse(node, "#{Maker::ProjectFolders::ROOT} is where project folders live — " \
                            "pick one of the folders inside it.")
      end

      claim = claim_on(node)
      return claim if claim

      # STRICTLY INSIDE A WORKING TREE. Library::WorkingTree#root_for starts its walk at the node's
      # PARENT, so a folder that IS a repository root answers nil here and is adoptable — which is
      # what story 1.4 wants. What this refuses is `firmware/src`: a project whose README, commits
      # and history all sit OUTSIDE its own folder, so S4-1's repository card answers about a tree
      # the project does not contain.
      root = Library::WorkingTree.new(current_user).root_for(node)
      if root
        return refuse(node, "“#{node.name}” is inside the git repository “#{root.name}”. " \
                            "Make the repository's own folder the project instead.")
      end

      nil
    end

    # ONE ANCESTOR WALK ANSWERS BOTH CLAIM QUESTIONS. Maker::LibraryTree#ancestors_of yields the
    # node ITSELF first and then climbs, so the head of the chain is "this folder is already a
    # project" and the tail is "this folder is inside one".
    #
    # UNSCOPED ON STATUS, exactly as Maker::ProjectDiscovery#adoptable and
    # Maker::ModelIntake.claimed_folders are: an ARCHIVED project keeps folder_node_id and still
    # claims its folder, and THE ROW IS THE MEMORY. Filtering archived rows out here is precisely
    # how a dismissed folder comes back — with a button on it.
    def claim_on(node)
      chain = Maker::LibraryTree.new(current_user).ancestors_of(node.node_id)
      # nil is an unresolvable/cyclic chain (library_tree.rb's :broken sentinel). Refuse rather
      # than adopt into a tree we cannot describe.
      return refuse(node, "That folder's place in the library can't be resolved right now.") if chain.nil?

      by_folder = current_user.maker_projects.where(folder_node_id: chain.compact)
                              .index_by(&:folder_node_id)
      return nil if by_folder.empty?

      if (own = by_folder[node.node_id])
        return redirect_to project_path(own),
                           alert: "“#{node.name}” is already the folder for #{own.name}."
      end

      ancestor = chain.compact.find { |id| by_folder.key?(id) }
      owner = by_folder[ancestor]
      refuse(node, "“#{node.name}” is inside #{owner.name}'s folder, so its files already " \
                   "belong to that project.")
    end

    def adopt!(node)
      project = nil
      ActiveRecord::Base.transaction do
        project = current_user.maker_projects.create!(
          # THE FOLDER IS THE TRUTH (stage 4, §7): the project is named for the folder, verbatim,
          # exactly as discovery names one. The slug may diverge from the name forever and that is
          # the mainline case, not an edge case (§14f).
          name: node.name,
          slug: Maker::Project.available_slug(current_user, from: node.name),
          status: "planning",
          folder_node_id: node.node_id,
          # NOT DISCOVERED. The maker made this, so it is never "new to you" and never wears the
          # badge — `discovered_at.present?` is the whole definition of auto-created (S4-6).
          discovered_at: nil,
          # AUTOMATIC FILING OFF (stage 4, S4-6; story 1.3). Adopting a folder in `designs/` says
          # what it IS; it does not ask for it to be rearranged. Left on, the sweep moves
          # `tray.svg` into `design/` and `notes.md` into `docs/` within fifteen minutes, unasked
          # — the fight-the-user failure §14f exists to prevent, through a new door. Discovery
          # keeps the `true` default: a folder placed under `Projects/` asked for filing by being
          # there. The edit form is where a maker turns it on (S4-2), and the flash points at it.
          autofile: false
        )
        @dismissed_model = dismiss_auto_model(node)
      end
      project
    end

    # THE MODEL THIS FOLDER HAD ALREADY BECOME (story 1.3). The seeded `*` shelf makes every
    # top-level folder a shelf, so `designs/tray` was catalogued as a Maker::Model before anyone
    # thought to call it a project. Maker::ModelIntake stops accreting the instant a project claims
    # the folder — its own comment says so — but the ROW SURVIVES, so the folder would be a project
    # AND a model at once, with the model's card offering Delete for a thing that is now a build.
    #
    # DISMISSED, NOT DESTROYED, and NOT a Prune run. `dismissed_at` is the documented "I do not want
    # this" (docs/invariants/model-intake.md), and it is the SAME write ModelsController#destroy
    # makes for an auto model. Destroying instead would let the sweep recreate the row the moment
    # the project is deleted and releases the folder — the row is the memory, in both directions.
    #
    # AUTO ONLY. Nothing recreates an IMPORT-origin model, so there is nothing for a dismissal to
    # say to the sweep; that folder is `Models/<slug>`, minted by an import, and leaving its row
    # alone is the same "look, do not take" reading the intake already applies to it.
    #
    # Keyed on `auto_node_id`, which for a FOLDER model equals the dir's own node_id and carries the
    # partial unique index on (user_id, auto_node_id) — one indexed lookup, not a scan.
    def dismiss_auto_model(node)
      model = current_user.maker_models.find_by(origin: "auto", auto_node_id: node.node_id)
      return nil unless model && model.dismissed_at.nil?

      model.update!(dismissed_at: Time.current)
      model
    end

    def adopted_notice(node, _project, model)
      sentences = [ "Made “#{node.name}” a project — its files stay where they are, and " \
                    "automatic filing is off, so nothing moves." ]
      sentences << "It is no longer listed as a model." if model
      sentences.join(" ")
    end

    # BACK TO THE FOLDER THE MAKER WAS LOOKING AT, so a refusal leaves them where they can act on
    # it. `node` nil (no id, or an id that resolved to nothing) falls back to the library root
    # rather than echoing an unresolved param into a URL.
    def refuse(node, message)
      redirect_to files_path(folder: node&.node_id), alert: message
    end
  end
end
