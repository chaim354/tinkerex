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
  # instead of merely with the failure — the shape §14a requires of ChunkRemote's own 409. There
  # are NINE, counted here because a count in prose is exactly the comment that drifts (this one
  # shipped saying "seven" over eight): no id; an id that resolves to nothing; a dot name;
  # `Projects/` itself; an unresolvable chain; this folder's own project (a redirect onto it); a
  # project ABOVE; a project BELOW; a working tree above.
  #
  # ONE RESIDUAL, RECORDED RATHER THAN FIXED (S4-6 review). Two adoptions landing at the same
  # instant on folders with the same name both pass Maker::Project.available_slug — nothing
  # serialises that read against the insert — so the loser's `create!` raises
  # ActiveRecord::RecordNotUnique on the (user_id, slug) unique index, which nothing here maps: a
  # 500 on a door whose every other failure is a flash. The fix is a bounded retry around the
  # create, not a wider transaction. Same class of residual as tinkerex#281.
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
      redirect_to project_path(project), notice: adopted_notice(node, project, @model_delisted)
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

    # ONE TREE ANSWERS ALL THREE CLAIM QUESTIONS, AND THE THIRD IS THE ONE AN UPWARD WALK CANNOT
    # SEE. Maker::LibraryTree#ancestors_of yields the node ITSELF first and then climbs, so the
    # head of this node's chain is "this folder is already a project" and the tail is "this folder
    # is inside one" — but nesting is reachable from ABOVE as well: with `designs/tray` already a
    # project, adopting `designs` builds exactly the state the inside-refusal exists to prevent,
    # one level up and by a door that never looks down. So each CLAIMED folder's own chain is
    # walked on this same tree.
    #
    # ONE PLUCK, NEVER A QUERY PER PROJECT: the downward answer costs an in-memory walk per claimed
    # folder (nine on the measured real library) over rows the tree already holds. The project ROW
    # is fetched only in the branch that links to it, so the mainline pays two queries plus the
    # tree's own pluck.
    #
    # UNSCOPED ON STATUS, exactly as Maker::ProjectDiscovery#adoptable and
    # Maker::ModelIntake.claimed_folders are: an ARCHIVED project keeps folder_node_id and still
    # claims its folder, and THE ROW IS THE MEMORY. Filtering archived rows out here is precisely
    # how a dismissed folder comes back — with a button on it.
    def claim_on(node)
      tree  = Maker::LibraryTree.new(current_user)
      chain = tree.ancestors_of(node.node_id)
      # nil is an unresolvable/cyclic chain (library_tree.rb's :broken sentinel). Refuse rather
      # than adopt into a tree we cannot describe — and name the act that repairs it, like every
      # other refusal here.
      if chain.nil?
        return refuse(node, "That folder's place in the library can't be resolved right now — " \
                            "rescan the library and try again.")
      end

      names = current_user.maker_projects.where.not(folder_node_id: nil)
                          .pluck(:folder_node_id, :name).to_h
      return nil if names.empty?

      if names.key?(node.node_id)
        own = current_user.maker_projects.find_by(folder_node_id: node.node_id)
        return redirect_to project_path(own),
                           alert: "“#{node.name}” is already the folder for #{own.name}."
      end

      if (ancestor = chain.compact.find { |id| names.key?(id) })
        return refuse(node, "“#{node.name}” is inside #{names[ancestor]}'s folder, so its files " \
                            "already belong to that project.")
      end

      if (contained = contained_project(tree, names, node))
        return refuse(node, "“#{node.name}” contains #{contained}'s folder — a project can't " \
                            "hold another project's folder.")
      end

      nil
    end

    # STRICTLY INSIDE, AND `.drop(1)` IS WHAT SAYS SO — not the early return above. A claimed folder
    # that IS this node is the "already a project" branch, and a containment test that depended on
    # that branch having run first would quietly become a different rule the day the two are
    # reordered.
    #
    # NIL IS "NOT INSIDE", NOT "EVERYTHING" — the same reading Maker::ModelIntake::Prune.inside?
    # records for this walk. A project whose folder_node_id points at a tombstoned or missing node
    # cannot be SHOWN to be under this one, and refusing every adoption in the library because one
    # stale row is unresolvable is the wrong answer to "I cannot tell".
    def contained_project(tree, names, node)
      names.each do |folder_id, project_name|
        return project_name if (tree.ancestors_of(folder_id) || []).drop(1).include?(node.node_id)
      end
      nil
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
          # there. The edit form is where a maker turns it on (S4-2), and the flash NAMES that
          # form in words — it is escaped text, so it cannot link to it (see #adopted_notice).
          autofile: false
        )
        @model_delisted = destroy_auto_model(node)
      end
      project
    end

    # THE MODEL THIS FOLDER HAD ALREADY BECOME (story 1.3). The seeded `*` shelf makes every
    # top-level folder a shelf, so `designs/tray` was catalogued as a Maker::Model before anyone
    # thought to call it a project. Maker::ModelIntake stops accreting the instant a project claims
    # the folder — its own comment says so — but the ROW SURVIVES, so the folder would be a project
    # AND a model at once, with the model's card offering Delete for a thing that is now a build.
    #
    # DESTROYED, NOT DISMISSED — AND THIS IS THE CALL Maker::ModelIntake::Prune ALREADY MAKES FOR
    # THIS EXACT ROW (`destroyed.each(&:destroy!)`, prune.rb — its `destroyed` partition IS "an auto
    # model whose folder a project claims"). The repair predates this door, so a dismissal here gave
    # ONE state TWO answers, the shape §14a forbids. It was also wrong on its own terms, driven
    # rather than reasoned: a dismissal is IRREVERSIBLE (docs/invariants/model-intake.md), so
    # deleting the project released the folder back to the sweep while the row the sweep would have
    # recreated stayed dismissed forever — the folder became uncataloguable by an act nobody took.
    # Row-is-the-memory is for a MAKER'S OWN "this is not a model"; adoption is a CLAIM, and
    # Maker::ModelIntake.for_user already respects a claim by dropping the key before `existing` is
    # looked up, which is why destroying is safe: nothing accretes while the project holds the
    # folder, and the catalogue comes back when it lets go.
    #
    # THE ATTACHMENTS GO WITH IT, through `dependent: :destroy` on Model#file_attachments — the same
    # way they go in Prune, which `delete_all`s attachment rows for the models it KEEPS and lets the
    # association take the ones it destroys. No library file is touched either way (prune.rb's own
    # "IT NEVER TOUCHES THE PORT"), so this stays port-free on all three backends.
    #
    # AUTO ONLY. Nothing recreates an IMPORT-origin model, so destroying one would be a deletion the
    # maker never asked for and could not undo; that folder is `Models/<slug>`, minted by an import,
    # and leaving its row alone is the same "look, do not take" reading the intake already applies.
    #
    # KEYED ON `auto_node_id`, AND IT IS NOT INTERCHANGEABLE WITH `folder_node_id`. auto_node_id is
    # the sweep's identity for the row and carries the partial unique index on (user_id,
    # auto_node_id) (schema.rb, `where: "auto_node_id IS NOT NULL"`) — re-read after the change, one
    # indexed lookup and not a scan. folder_node_id answers a different question, "where this
    # model's files are kept": nil for a one-file model, `Models/<slug>` for an import, equal to the
    # key only when the key is a dir. The test fixture gives the two DIFFERENT values, so keying on
    # the wrong column goes red instead of passing by coincidence.
    #
    # Returns whether a LISTED model went away, which is what the flash may speak about; an
    # already-dismissed row is destroyed just the same (Prune does not consult dismissed_at either)
    # but was never on /models to be delisted from.
    def destroy_auto_model(node)
      model = current_user.maker_models.find_by(origin: "auto", auto_node_id: node.node_id)
      return false unless model

      listed = model.dismissed_at.nil?
      model.destroy!
      listed
    end

    # WHERE THE SWITCH IS, SAID IN WORDS. A flash is ESCAPED TEXT, so a link into the edit form is
    # impossible from here — which is why the sentence names the surface instead. It shipped naming
    # none at all while the comment beside `autofile:` above claimed "the flash points at it": a
    # maker told filing is off had nowhere to go to turn it on. The form is projects/_form's
    # `autofile` checkbox, reached by Edit on the project page this redirect lands on.
    def adopted_notice(node, _project, delisted)
      sentences = [ "Made “#{node.name}” a project — its files stay where they are, and " \
                    "automatic filing is off, so nothing moves (turn it on under Edit project)." ]
      sentences << "It is no longer listed as a model." if delisted
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
