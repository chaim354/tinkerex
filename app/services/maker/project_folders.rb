module Maker
  # Which subfolder of `Projects/<slug>/` a file belongs in.
  #
  # STAGE 3, S3-1: THE MAP IS NOW PER USER, AND ROLE_FOLDERS IS ITS SEED, NOT ITS ANSWER.
  # `folder_for(user, name)` reads `Maker::FilingRules.for(user)` — the user's own rows, seeded
  # once from ROLE_FOLDERS over `Maker::FileAttachment::ROLE_BY_EXT` and edited from then on at
  # /settings/filing (spec §5). `default_folder_for(name)` is the OLD pure function, kept for the
  # one caller that still needs an answer with no user in hand: the seed itself, which cannot ask
  # `Maker::FilingRules.for` the very map it is about to build. A hand-written ext => folder hash
  # beside ROLE_BY_EXT is the exact drift `FilesHelper::EXT_FAMILIES` was rewritten to end
  # (2026-07-29: two independent lists that disagreed about `.svg` for months) — ROLE_FOLDERS stays
  # keyed on ROLE, derived from the one vocabulary, and it is `Maker::FilingRules.seed!` that turns
  # it into one row per EXTENSION.
  #
  # THE ANSWER COMES FROM THE FILENAME, NEVER FROM A STORED `role` COLUMN. An attachment row's role
  # is a snapshot taken when the row was written; a file can be swept before any row exists, and a
  # stale row would misfile it. `role_for` is pure and current, and so is `ext_of` below.
  #
  # `default_folder_for`'S `fetch` WITH NO DEFAULT IS THE GUARD ROLE_FOLDERS STILL NEEDS. It is
  # LOUD if ever reached — an unmapped role raises KeyError, not a swallowed default. What makes
  # the totality test in test/services/maker/project_folders_test.rb necessary is that the raise is
  # normally UNREACHABLE: `role_for` can only return a role once some extension in ROLE_BY_EXT is
  # wired to it, so a role added to ROLES without a folder decision can sit here completely
  # unexercised — no test failure, no crash, nothing to notice — until the day an extension is
  # wired to it and `Maker::FilingRules.seed!` finally reaches the fetch for some user's first
  # visit, at which point the loud raise becomes a production incident. The totality test is what
  # catches the gap before that day arrives.
  #
  # `folder_for(user, name)` ITSELF DEFAULTS TO "other" FOR AN UNMAPPED EXTENSION, AND THAT IS NOT
  # THE SAME REJECTED SHAPE. The rejected `fetch(role, "other")` this file used to warn against
  # would have misfiled an unmapped ROLE — a fixed, developer-owned vocabulary where an omission is
  # a code bug that should be loud. An extension with no row in a user's own map is a routine,
  # expected occurrence — the user has simply never told this app an opinion about it — and "other"
  # is the honest, PER-USER routing spec §5 asks for, not a silently wrong answer to a question
  # with a knowable right one.
  #
  # THE FOLDER NAMES ARE NOT ROLE_LABELS, even where seven of the twelve happen to match it
  # lowercased (models, images, laser, code, archives, pcb, other) — that agreement is coincidental, not
  # derived, and must stay that way: a UI wording tweak to ROLE_LABELS (capitalization, clarity)
  # must never rename a directory on someone's NAS. The other four folder names are deliberate
  # renames to plainer workflow words: `cnc` (not "G-code"), `design` (not "Vector"), `cad` (not
  # "CAD source"), and `docs`, which uniquely folds two roles — `instructions` ("Instructions")
  # and `document` ("Documents") — into one folder. These become real directories in the user's
  # Finder and on their NAS, where `cnc` reads better than `G-code`. `Maker::FilingRule`'s own
  # validation is what keeps a user-edited folder name to the same shape (one lowercase segment,
  # never reserved) — the totality test also checks every SEED folder passes that same validation,
  # so the seed can never write a row the settings form would itself refuse.
  module ProjectFolders
    module_function

    # The library folder every project's own folder lives under: `Projects/<slug>/`.
    #
    # ONE READER TODAY — Maker::Project#ensure_library_folder!. It was two from the day this
    # constant was extracted until Maker::ProjectIntake#place stopped rebuilding a project's
    # folder path from ROOT + slug — a path that could disagree with folder_node_id, the
    # project's ACTUAL folder; #place's own comment has the full argument — and started
    # resolving the destination from folder_node_id directly instead. Maker::ProjectDiscovery (a
    # later task) becomes the second reader, minting a project's folder from a name the user
    # chose rather than a generated slug.
    #
    # THE GUARD SCANS THREE FILES REGARDLESS OF HOW MANY CURRENTLY READ THE CONSTANT —
    # Maker::Project, Maker::ProjectIntake and Maker::ProjectDiscovery, in
    # project_folders_test.rb — because those are the files that HANDLE project folder paths, so
    # a future edit to any of them is exactly where "Projects" would get re-spelled as a bare
    # literal, whether or not that file reads ROOT today. project_intake.rb keeps its place on
    # that list precisely because it once spelled the literal out: dropping a file the moment it
    # stops reading the constant is how a convention nothing else enforces starts drifting again
    # (this repo's own recorded case — FilesHelper::EXT_FAMILIES vs ROLE_BY_EXT disagreeing about
    # .svg for months).
    ROOT = "Projects".freeze

    ROLE_FOLDERS = {
      "gcode"          => "cnc",
      "laser"          => "laser",
      "vector"         => "design",
      "model"          => "models",
      "cad_source"     => "cad",
      "code"           => "code",
      "instructions"   => "docs",
      "document"       => "docs",
      "image"          => "images",
      "source_archive" => "archives",
      # The board's fabrication set — Gerber layers, drill files and the `.gbrjob` that names them
      # — in one folder, which is the whole point of the role: a board house is handed a directory,
      # not a scattering. `pcb` rather than `gerber` because the folder holds the Excellon drill
      # files too, and it is the word on the workbench.
      "pcb"            => "pcb",
      "other"          => "other"
    }.freeze

    # TODAY'S PURE FUNCTION, WITH NO USER IN HAND. Used by `Maker::FilingRules.seed!` to build the
    # per-extension seed rows (ROLE_BY_EXT's extension -> role -> this), and available to any
    # future caller that genuinely has no user — there is none today; every web door in this app
    # has a current_user, and the seed is what stands in until a user's own rules exist to read.
    def default_folder_for(name)
      ROLE_FOLDERS.fetch(Maker::FileAttachment.role_for(name))
    end

    # THE PER-USER LOOKUP (stage 3, S3-1). `Maker::FilingRules.for(user)` seeds the twelve-role map
    # into this user's own rows on first read and answers from the user's own edited map ever
    # after — "other" for an extension with no rule (see the header for why that default is right
    # here and was wrong for `default_folder_for`'s role-keyed fetch).
    #
    # NOT CALLED BY Maker::ProjectIntake#place — see that class for why: this method pays
    # `Maker::FilingRules.for`'s query pair (an `exists?` guard plus a `pluck`) on EVERY call, so
    # using it inside #file_all's per-file loop would be a query pair per file across a run bounded
    # at MAX_MOVES (500). #place keeps its own memoized rules hash instead and re-derives this same
    # two-line lookup locally. This method is for callers OUTSIDE a large loop —
    # ProjectIntake.destination_for (one call per addon-output file, never hundreds) and
    # ProjectFolderIntake#project_intake_sentence (one call per flash message).
    def folder_for(user, name)
      Maker::FilingRules.for(user).fetch(ext_of(name), "other")
    end

    # `File.extname(...).downcase.delete(".")` — THE SAME EXTRACTION Maker::FileAttachment.role_for
    # uses, so an extension is read identically whether it is about to become a ROLE or looked up
    # directly in a per-user rules hash. Exposed so Maker::ProjectIntake's own memoized lookup does
    # not have to re-spell it.
    def ext_of(name)
      File.extname(name.to_s).downcase.delete(".")
    end
  end
end
