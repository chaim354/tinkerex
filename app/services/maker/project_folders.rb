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
  # `fetch` WITH NO DEFAULT IS THE GUARD, and it is unreachable on purpose. `role_for` only ever
  # answers a member of ROLES (it fetches with an "other" default), so a raise here cannot happen
  # from real input — which is precisely why the totality test in
  # test/services/maker/project_folders_test.rb is the only thing that can catch a role added
  # without a folder. Silence is the failure mode being guarded: an unmapped role would be a file
  # that is never filed, with no error, no log and no node moved. A `fetch(..., "other")` default
  # would turn that into a wrong answer nobody could see.
  #
  # THE NAMES ARE LOWERCASE AND ARE NOT ROLE_LABELS. These strings become real directories in the
  # user's Finder and on their NAS, where `cnc` reads better than `G-code`. ROLE_LABELS are UI
  # headings; the one place they win here is `archives`, which has no better plain-language name.
  module ProjectFolders
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

    # Every distinct folder name. `instructions` and `document` share `docs`, so this is shorter
    # than ROLE_FOLDERS — the dedupe is the point, not an accident of the literal.
    NAMES = ROLE_FOLDERS.values.uniq.freeze

    module_function

    def folder_for(name)
      ROLE_FOLDERS.fetch(Maker::FileAttachment.role_for(name))
    end
  end
end
