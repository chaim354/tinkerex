module Maker
  # Which subfolder of `Projects/<slug>/` a file belongs in.
  #
  # DERIVED FROM THE ONE VOCABULARY, not a second extension table beside it. The key is a
  # Maker::FileAttachment ROLE, and the lookup goes through `role_for`, so adding an extension is
  # still a one-line edit to ROLE_BY_EXT and nothing here has to hear about it. A hand-written
  # ext => folder hash is the exact drift `FilesHelper::EXT_FAMILIES` was rewritten to end
  # (2026-07-29): two independent lists that disagreed about `.svg` for months.
  #
  # THE ANSWER COMES FROM THE FILENAME, NEVER FROM A STORED `role` COLUMN. An attachment row's role
  # is a snapshot taken when the row was written; a file can be swept before any row exists, and a
  # stale row would misfile it. `role_for` is pure and current.
  #
  # `fetch` WITH NO DEFAULT IS THE GUARD. It is LOUD if ever reached — an unmapped role raises
  # KeyError, not a swallowed default. What makes the totality test in
  # test/services/maker/project_folders_test.rb necessary is that the raise is normally
  # UNREACHABLE: `role_for` can only return a role once some extension in ROLE_BY_EXT is wired to
  # it, so a role added to ROLES without a folder decision can sit here completely unexercised —
  # no test failure, no crash, nothing to notice — until the day an extension is wired to it and a
  # real file finally reaches the fetch, at which point the loud raise becomes a production
  # incident. The totality test is what catches the gap before that day arrives. The genuinely
  # SILENT failure is the rejected alternative, `fetch(role, "other")`: it would misfile an
  # unmapped role into "other" and never raise at all — a wrong answer nobody could see. Don't add
  # it.
  #
  # THE FOLDER NAMES ARE NOT ROLE_LABELS, even where six of the ten happen to match it
  # lowercased (models, images, laser, code, archives, other) — that agreement is coincidental, not
  # derived, and must stay that way: a UI wording tweak to ROLE_LABELS (capitalization, clarity)
  # must never rename a directory on someone's NAS. The other four folder names are deliberate
  # renames to plainer workflow words: `cnc` (not "G-code"), `design` (not "Vector"), `cad` (not
  # "CAD source"), and `docs`, which uniquely folds two roles — `instructions` ("Instructions")
  # and `document` ("Documents") — into one folder. These become real directories in the user's
  # Finder and on their NAS, where `cnc` reads better than `G-code`.
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
      "other"          => "other"
    }.freeze

    def folder_for(name)
      ROLE_FOLDERS.fetch(Maker::FileAttachment.role_for(name))
    end
  end
end
