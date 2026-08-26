module Maker
  # A folder directly under the library's `Projects/` that no project claims becomes a project.
  #
  # WHY A SWEEP RATHER THAN A HOOK PER DOOR — the same argument Maker::ProjectIntake and
  # Maker::ModelIntake make. A folder can reach `Projects/` several ways
  # (LibraryBrowseController#create_folder, Library::Reconciler observing one someone made in
  # Finder, a device push landing on the sync server, Maker::MoveNode) and there is no funnel.
  # Hooking each is N sites that must agree, and an N+1th silently skips the rule. This reads
  # `nodes`, the catalog ALL THREE BACKENDS populate, so it covers every door and any future one.
  #
  # IT NEVER TOUCHES THE PORT. It writes maker_projects rows and nothing else — no mkdir, no move,
  # no bytes — which is what makes it identical on all three backends and testable without a
  # library on disk.
  #
  # Rules and reasoning: docs/invariants/project-intake.md.
  class ProjectDiscovery
    # What one run did.
    #
    # `created` IS THIS RUN'S DELTA, not the total, so a steady-state sweep reports 0 rather than
    # the number of projects the user has. `candidates` is how many adoptable folders survived the
    # filters, which is what makes :capped legible ("created 50 of 63") and is the only reason it
    # exists — there is deliberately NO per-reason skips breakdown, because the dominant "skip" is
    # ALREADY CLAIMED, which is the steady state and would print a number every tick meaning
    # nothing happened.
    #
    # `status` IS :ok, :capped OR :no_projects_folder — three values, where Maker::ModelIntake's
    # has two, because this sweep can decline for a reason that one cannot: a library with no
    # `Projects/` folder at all. SWITCH ON IT FIRST. `candidates` and `cap` are real values in
    # every branch, never sentinels, so a caller that reads `candidates: 0` without checking
    # `status` cannot tell "there is nothing to adopt" from "there is nowhere to look" — and only
    # the second is worth an operator's attention.
    RunResult = Data.define(:created, :candidates, :status, :cap)

    # The ceiling on projects created in one run. ABSOLUTE, NOT A PERCENTAGE, for the reason
    # Maker::ProjectIntake::MAX_MOVES gives at length: the intended first run adopts 100% of what is
    # there, so a percentage would be guarding against success.
    #
    # ONE CAP, NOT TWO. Maker::ProjectIntake carries EAGER_MAX_MOVES beside MAX_MOVES because it has
    # an entry point inside a browser request. Nothing here does — the web doors' eager nudge calls
    # Maker::ProjectIntake.for_node directly and never routes through a job. WHOEVER ADDS A NUDGE
    # OWES THE SECOND CAP.
    MAX_PROJECTS = 50

    # A BAD OVERRIDE FALLS BACK; IT DOES NOT CRASH THE JOB. `Integer("-5")` SUCCEEDS, so the rescue
    # below never sees a negative — and a negative reaches `first(-5)`, which raises
    # `ArgumentError: negative array size` deep inside a recurring job, long after the typo. Zero is
    # refused for the same reason: it discovers nothing, forever, silently.
    def self.max_projects
      value = Integer(ENV.fetch("PROJECT_DISCOVERY_MAX", MAX_PROJECTS))
      value.positive? ? value : MAX_PROJECTS
    rescue ArgumentError, TypeError
      MAX_PROJECTS
    end

    def self.for_user(user:, cap: nil)
      cap ||= max_projects
      root = projects_root(user)
      return RunResult.new(created: 0, candidates: 0, status: :no_projects_folder, cap:) unless root

      candidates = adoptable(user, root)
      capped = candidates.size > cap

      created = 0
      candidates.first(cap).each do |node_id, name|
        user.maker_projects.create!(
          name:,
          # NOT #ensure_slug's derivation. A collision or a blank raises RecordInvalid inside a
          # recurring job, where nobody is there to read it — see Maker::Project.available_slug.
          slug: Maker::Project.available_slug(user, from: name),
          # THE FOLDER ALREADY EXISTS; this claims it. Calling #ensure_library_folder! would mint
          # `Projects/<slug>` as a side effect of merely looking — Projects::AttachmentsController
          # #relocate's recorded bug, at library-sweep scale.
          folder_node_id: node_id
        )
        created += 1
      end

      RunResult.new(created:, candidates: candidates.size, status: capped ? :capped : :ok, cap:)
    end

    # NEVER MINTS `Projects/`. Calling Maker::LibraryFolder.ensure_path! here would create it on
    # every library that has never had one, as a side effect of merely LOOKING. A user with no
    # Projects/ folder is simply not swept.
    #
    # `parent_node_id: nil` IS the library root — the representation Library::Reconciler and
    # Maker::LibraryTree both use.
    def self.projects_root(user)
      user.nodes.present.find_by(parent_node_id: nil, name: Maker::ProjectFolders::ROOT,
                                 kind: "dir")
    end
    private_class_method :projects_root

    # [[node_id, name], ...] in DETERMINISTIC order, so a capped run is reproducible and the next
    # run continues where this one stopped instead of re-rolling the dice.
    def self.adoptable(user, root)
      # UNSCOPED, AND THAT IS THE ENTIRE DISMISSAL MECHANISM. Archiving a project leaves
      # folder_node_id intact, so an archived project still claims its folder and this passes over
      # it. Filtering archived rows out HERE is exactly how a dismissed thing comes back —
      # docs/invariants/model-intake.md records the identical mistake for the `catalogued` scope.
      # THE ROW IS THE MEMORY.
      claimed = user.maker_projects.where.not(folder_node_id: nil).pluck(:folder_node_id).to_set

      # DIRECT CHILDREN ONLY. `Projects/desk-lamp/models/` is a category subfolder
      # Maker::ProjectFolders created, and adopting it would mint a project named "models" inside a
      # project. A project folder is `Projects/<name>` and nothing deeper.
      #
      # DOT-FOLDERS ARE SKIPPED. Library::OsClutter already stops `.DS_Store` and friends from ever
      # becoming nodes, but `.git` is THE ONE SKIP THAT KEEPS ITS ENTRY (§14b — the marker is the
      # evidence a directory is a working tree, which Maker::AttachToProject's :in_working_tree asks
      # the database for). Without this rule a repo checked out at the Projects/ root becomes a
      # project literally titled ".git".
      user.nodes.present
          .where(parent_node_id: root.node_id, kind: "dir")
          .order(:node_id)
          .pluck(:node_id, :name)
          .reject { |node_id, name| claimed.include?(node_id) || name.to_s.start_with?(".") }
    end
    private_class_method :adoptable
  end
end
