module Library
  # Where a git repository keeps its own state, and the ONE place `.git` is spelled.
  #
  # TODAY THIS HOLDS ONE CONSTANT AND NO PREDICATES, on purpose. Its first caller is
  # Maker::AttachToProject's :in_working_tree rule, which asks the DATABASE whether a directory has
  # a live child by this name — it needs the name, not a path predicate. The `internal?` /
  # `marker_prefix` predicates arrive with the observers, which is the change that first has a path
  # to test. A module with one constant is still the right home: `.git` is about to be consulted
  # from five places, and five string literals is the drift Library::OsClutter's header exists to
  # prevent.
  #
  # THE ASYMMETRY THAT IS COMING, stated now because it explains why this file exists at all and
  # why the marker must never simply be skipped. Every other skip in this codebase
  # (Scanner::TRASH_PREFIX, Library::OsClutter) skips the ENTRY — the observers never look, so no
  # node exists. The `.git` rule will be the opposite:
  #
  #   .git            observed, indexed, one dir node   <- the MARKER
  #   .git/**         never observed, never writable    <- the contents
  #
  # The marker is kept because it is the evidence that a directory IS a working tree. Delete it and
  # :in_working_tree has nothing to detect, and the intake sweep goes back to filing a repo's root
  # files away by category — README.md into docs/, main.py into other/ — which git sees as a delete
  # plus an untracked add. It also has to exist on `chunk_remote`, where the `nodes` table mirrors
  # the sync server's tree and the desktop client syncs `.git` whether this app likes it or not
  # (§14j): a marker present on all three backends makes the working-tree question answerable
  # uniformly, rather than one condition having two answers (§14a).
  #
  # A DIRECTORY, NEVER A FILE. A real repo can carry a `.git` FILE — a submodule or a linked
  # worktree stores a `gitdir:` pointer there — and treating that as a marker would be right by
  # accident and wrong by construction, since nothing here reads the pointer. The rule is "a
  # directory named .git"; a submodule's real `.git` directory, wherever it actually lives, does
  # its own work.
  #
  # SCOPE: git only. `.svn`, `.hg` and friends are deliberately absent — adding one is a real
  # indexing change and a new write refusal, the same explicit decision OsClutter's header demands,
  # not a net to widen on a hunch.
  module RepoMetadata
    DIR_NAME = ".git".freeze
  end
end
