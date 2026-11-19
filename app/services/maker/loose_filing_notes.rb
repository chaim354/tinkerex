module Maker
  # WHY A LOOSE FILE WILL STILL BE LOOSE AFTER THE NEXT SCAN (2026-11-02, the UX audit's C3). The
  # Files panel's Loose group promised "filed on the next sweep" over `harbor-number-v4.svg`, which
  # the filing pass refuses every time because `design/harbor-number-v4.svg` already exists
  # (Maker::ProjectIntake#place's `:conflict`) — so the file sat under a promise that never came
  # true, and nothing said why. This answers, per loose row, the one refusal a maker can act on: the
  # destination is taken. The row then says so ("design/harbor-number-v4.svg already exists —
  # rename one to file it") instead of the panel promising the next pass.
  #
  # A PREDICTION, AND IT READS WHAT THE FILING PASS READS. The destination folder comes from the
  # user's filing rules exactly as ProjectIntake#folder_for takes it — the rules HASH fetched once
  # (Maker::FilingRules.for, an `exists?` and a `pluck`) and asked per name with
  # Maker::ProjectFolders.ext_of, never Maker::ProjectFolders.folder_for per row, which would pay
  # that pair per file (docs/invariants/project-intake.md, "#place DOES NOT CALL folder_for"). The
  # occupant is looked for in the listing's own tree — the depth-one folder of that name and what
  # it holds — so the check costs no query beyond the rules. Two things it deliberately does not
  # predict, both failing toward the panel's ordinary caption rather than a wrong sentence: a
  # `.zip`, because whether it files with the board is a CONTENT question (#board_folder_for reads
  # the archive), and a destination past the listing's FILE_CAP, which the tree does not hold.
  #
  # IT NEVER FILES, MOVES OR CREATES ANYTHING, and never calls the port.
  class LooseFilingNotes
    def self.for(user:, listing:, rows:)
      return {} if rows.empty?

      rules = Maker::FilingRules.for(user)
      dirs = listing.tree.index_by(&:name)
      rows.each_with_object({}) do |row, notes|
        name = row.node.name
        # A README at the root is never filed (ProjectIntake's `:project_readme`), so a second one
        # beside the card's says that rather than wearing the "filed on the next scan" caption.
        if Maker::Readme::NAMES.include?(name)
          notes[row.node_id] = "A README stays at the project's root."
          next
        end
        next if Maker::GerberArchive.archive?(name)

        folder = rules.fetch(Maker::ProjectFolders.ext_of(name), Maker::ProjectFolders::OTHER)
        dir = dirs[folder]
        next unless dir && (dir.files.any? { |f| f.node.name == name } || dir.children.any? { |c| c.name == name })

        notes[row.node_id] = "#{folder}/#{name} already exists — rename one to file it."
      end
    end
  end
end
