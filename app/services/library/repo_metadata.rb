module Library
  # Where a git repository keeps its own state, and the ONE place `.git` is spelled.
  #
  # THE ASYMMETRY IS THE DESIGN, and it is the opposite of every other skip in this codebase.
  # Scanner::TRASH_PREFIX and Library::OsClutter skip the ENTRY — the observers never look, so no
  # node exists at all. The `.git` rule keeps the entry and skips what is under it:
  #
  #   .git            observed, indexed, one dir node   <- the MARKER
  #   .git/**         never observed, never writable    <- the contents
  #
  # The marker is kept because it is the evidence that a directory IS a working tree. Delete it and
  # Maker::AttachToProject's :in_working_tree has nothing to detect, and the intake sweep goes back
  # to filing a repo's root files away by category — README.md into docs/, main.py into other/ —
  # which git sees as a delete plus an untracked add. It also has to exist on `chunk_remote`, where
  # the `nodes` table mirrors the sync server's tree and the desktop client syncs `.git` whether
  # this app likes it or not (§14j): a marker present on all three backends makes the working-tree
  # question answerable uniformly, rather than one condition having two answers (§14a).
  #
  # THE CONTENTS HALF IS ONLY HALF-WIRED TODAY, and the missing half is named here so the second
  # line of that table is not mistaken for something the code already enforces. The OBSERVERS skip
  # the contents: Library::Scanner declines the DESCENT (it meets a real directory and observes
  # it), Library::S3Observer drops the keys and SYNTHESIZES the marker (it has no directory to
  # meet). The WRITE refusal is not here yet, and it is not optional — OsClutter's header states
  # the law it owes: a path the observers skip must ALSO be refused as a write destination, or a
  # write lands a live node at a path no observation can ever pair, whose tombstone trips the
  # mass-deletion guard and refuses that scan and every scan after it, permanently. Its home is the
  # adapters' own `observable!` guards, beside the clutter refusal that already pins the same
  # coupling.
  #
  # A DIRECTORY, NEVER A FILE. A real repo can carry a `.git` FILE — a submodule or a linked
  # worktree stores a `gitdir:` pointer there — and treating that as a marker would be right by
  # accident and wrong by construction, since nothing here reads the pointer. The rule is "a
  # directory named .git"; a submodule's real `.git` directory, wherever it actually lives, does
  # its own work.
  #
  # ONE BACKEND CANNOT HONOUR THAT RULE, and it is named here rather than left to be discovered.
  # Library::Scanner holds an lstat and asks the kind. Library::S3Observer holds a key in a FLAT
  # KEYSPACE, where there is no kind to ask about — so a `.git` OBJECT is the marker there, and its
  # bytes go unindexed. That observer's own comment argues why the fallout is the tolerable side of
  # the trade; what belongs here is that the rule above describes what a caller may ASSUME (a
  # marker node is a directory node, on every backend) and not what every observer could check.
  #
  # SCOPE: git only. `.svn`, `.hg` and friends are deliberately absent — adding one is a real
  # indexing change and a new write refusal, the same explicit decision OsClutter's header demands,
  # not a net to widen on a hunch.
  module RepoMetadata
    DIR_NAME = ".git".freeze

    # Is this LEAF name the marker directory itself? Takes a leaf, never a path — a caller holding
    # a path uses #marker_prefix. Non-strings answer false rather than raising: a door's input is
    # JSON a browser bundle sent, and a nil name must reach that door's own routine refusal instead
    # of a NoMethodError 500 (the rule Library::ReservedNames states in its own header).
    def self.marker?(name)
      name.is_a?(String) && name == DIR_NAME
    end

    # The path up to and INCLUDING the first `.git` segment, or nil when there is none.
    # Library::S3Observer uses it to emit one dir observation for a repo whose keys it is dropping
    # — S3 has no directories, so the marker has to be synthesized from the keys beneath it or it
    # would not exist on that backend at all.
    #
    # WHOLE SEGMENTS, NEVER A PREFIX MATCH: `.gitignore` is an ordinary file and `notes/git/` is an
    # ordinary folder. A `start_with?` here would drop both from the catalog.
    #
    # OUTERMOST WINS (`index`, not `rindex`): a submodule's `a/.git/modules/b/.git` must resolve to
    # `a/.git`, so the whole outer subtree is dropped rather than only the inner one — otherwise a
    # nested repo hides everything between the two markers back in the catalog.
    def self.marker_prefix(rel)
      return nil unless rel.is_a?(String)

      segments = rel.split("/")
      idx = segments.index(DIR_NAME)
      idx && segments[0..idx].join("/")
    end
  end
end
