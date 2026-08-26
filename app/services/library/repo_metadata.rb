module Library
  # Where a git repository keeps its own state, and the ONE place `.git` is spelled.
  #
  # THE ASYMMETRY IS THE DESIGN, and it is the opposite of every other skip in this codebase.
  # Scanner::TRASH_PREFIX and Library::OsClutter skip the ENTRY — the observers never look, so no
  # node exists at all. The `.git` rule keeps the entry and skips what is under it:
  #
  #   .git            observed, indexed, one dir node; never minted   <- the MARKER
  #   .git/**         never observed, never writable                  <- the contents
  #
  # The marker is kept because it is the evidence that a directory IS a working tree. Delete it and
  # Maker::AttachToProject's :in_working_tree has nothing to detect, and the intake sweep goes back
  # to filing a repo's root files away by category — README.md into docs/, main.py into other/ —
  # which git sees as a delete plus an untracked add. It also has to exist on `chunk_remote`, where
  # the `nodes` table mirrors the sync server's tree and the desktop client syncs `.git` whether
  # this app likes it or not (§14j): a marker present on all three backends makes the working-tree
  # question answerable uniformly, rather than one condition having two answers (§14a).
  #
  # BOTH HALVES ARE WIRED, and they are wired in the two places OsClutter's header demands, which
  # is why this module is a predicate and not a list anyone copies. The OBSERVERS skip the contents:
  # Library::Scanner declines the DESCENT (it meets a real directory and observes it),
  # Library::S3Observer drops the keys and SYNTHESIZES the marker (it has no directory to meet). The
  # WRITE GUARDS refuse them: FileLayer::Share#observable! and FileLayer::S3#observable! ask
  # #marker_prefix, beside the clutter refusal that already pins the same coupling, so a write can
  # never land a live node at a path no observation can pair — the ghost whose tombstone trips the
  # mass-deletion guard and refuses that scan and every scan after it, permanently.
  #
  # THE WRITE GUARDS REFUSE AT-OR-BENEATH THE MARKER, WHICH IS ONE SEGMENT STRICTER THAN THE SKIP,
  # and the asymmetry is deliberate rather than a sloppy predicate. Refusing the marker creates no
  # ghost, because the marker is observed. What it stops is MINTING one: you cannot create a
  # repository by creating the folder, so a `.git` written through this app is never a repo — it is
  # a folder that silently switches off the intake sweep for everything under it, since
  # Maker::AttachToProject's :in_working_tree reads exactly this marker and asks nothing else. The
  # real marker arrives on disk from git itself and is OBSERVED, never written by us, so the refusal
  # costs nothing real. Library::ReservedNames says the same thing at the web doors, for the doors
  # that mint a leaf name before any adapter is asked.
  #
  # A DIRECTORY, NEVER A FILE. A real repo can carry a `.git` FILE — a submodule or a linked
  # worktree stores a `gitdir:` pointer there — and treating that as a marker would be right by
  # accident and wrong by construction, since nothing here reads the pointer. The rule is "a
  # directory named .git"; a submodule's real `.git` directory, wherever it actually lives, does
  # its own work.
  #
  # THAT RULE HOLDS ON ALL THREE BACKENDS, and on one of them it is a question rather than a look.
  # Library::Scanner holds an lstat and asks the kind outright. Library::S3Observer holds a key in
  # a FLAT KEYSPACE, which permits an OBJECT exactly AT the marker path — what a submodule or a
  # linked worktree writes — so it asks `internal?` instead, and the pointer falls through to be
  # indexed as the ordinary file the Scanner also makes it. Recorded because the first draft of
  # this file asserted the flat keyspace "cannot" tell the two apart and wrote the divergence down
  # as a decision: the rule was right and its evidence was invented, which is the failure
  # CLAUDE.md's own preamble records about its `§` reference counts.
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
    # THE WRITE GUARDS ASK IT TOO, and they want a different shade of the same answer: they need
    # "is this destination at or beneath a marker?", which is `.present?` on this return rather than
    # the prefix itself. One predicate serves both because the marker's own path satisfies it — see
    # the header for why refusing AT the marker is right and not merely convenient.
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

    # Is `rel` STRICTLY BENEATH a marker? The observers' question, and the exact complement of the
    # write guards', which is `marker_prefix(rel).present?` — AT or beneath. The two differ on
    # precisely one path, the marker itself, and that path is the entire design: it is indexed
    # (so `internal?` is false for it) and it is not writable (so the guards' question is true).
    #
    # ONE QUESTION MUST NOT BE SPELLED TWO WAYS, which is why this is DERIVED from marker_prefix
    # rather than re-deriving segments. It began life inline in Library::S3Observer as
    # `marker_prefix(rel) && marker_prefix(rel) != rel`, with a paragraph explaining why the second
    # term was not redundant — and a term defended by a comment is one a later reader deletes,
    # while a NAME is not. Deriving it also makes the two questions provably consistent: they
    # cannot drift into disagreeing about which paths have a marker at all.
    #
    # WHY THE MARKER PATH ITSELF MATTERS, since `!= rel` still looks like a no-op: a flat keyspace
    # permits an OBJECT exactly at the marker path. That object is a `gitdir:` POINTER FILE, what a
    # submodule or a linked worktree writes where a plain repo has a directory. Answer true for it
    # and s3 alone calls it the marker and drops its bytes, while Library::Scanner — which holds an
    # lstat and sees a file — indexes it: one condition with two answers across backends (§14a).
    def self.internal?(rel)
      prefix = marker_prefix(rel)
      !prefix.nil? && prefix != rel
    end
  end
end
