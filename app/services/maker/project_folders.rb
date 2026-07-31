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
  # THE FOLDER NAMES ARE NOT ROLE_LABELS, even where five of the nine happen to match it
  # lowercased (models, images, laser, archives, other) — that agreement is coincidental, not
  # derived, and must stay that way: a UI wording tweak to ROLE_LABELS (capitalization, clarity)
  # must never rename a directory on someone's NAS. The other four folder names are deliberate
  # renames to plainer workflow words: `cnc` (not "G-code"), `design` (not "Vector"), `cad` (not
  # "CAD source"), and `docs`, which uniquely folds two roles — `instructions` ("Instructions")
  # and `document` ("Documents") — into one folder. These become real directories in the user's
  # Finder and on their NAS, where `cnc` reads better than `G-code`.
  module ProjectFolders
    module_function

    ROLE_FOLDERS = {
      "gcode"          => "cnc",
      "laser"          => "laser",
      "vector"         => "design",
      "model"          => "models",
      "cad_source"     => "cad",
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
