module Library
  # OS-generated clutter the library never indexes AND never accepts as a write destination.
  #
  # THE SINGLE SOURCE OF TRUTH FOR TWO LISTS THAT MUST BE ONE. Both halves of that are load-bearing,
  # and pulling them apart is the exact bug this file exists to make impossible:
  #
  #   1. The OBSERVERS skip these so they never become nodes — Library::Scanner (the share walk)
  #      and Library::S3Observer (the bucket listing). A `.DS_Store` beside every real file, an
  #      `__MACOSX/` tree from a zip extraction, and the macOS volume-metadata folders are noise no
  #      maker put in their library on purpose.
  #   2. The WRITE GUARDS reject these — FileLayer::Share#observable! and FileLayer::S3#observable!,
  #      which every write verb (write/move/undelete) already calls to refuse `.trash`/`.maker-tmp-`.
  #
  # Why they MUST be the same list: the instant a name becomes UNOBSERVABLE (skipped by the
  # observers), letting the write path create a live node there manufactures a ghost the Reconciler
  # can NEVER pair — pairing needs an observation as the partner, and a skipped path produces none.
  # The resulting tombstone trips the mass-deletion guard, refusing that scan and every scan after
  # it, PERMANENTLY. That blind spot cost phase 2b/4 four separate wedges, each found only after
  # the previous explanation said it couldn't happen (Scanner::TEMP_PREFIX documents the shape at
  # length; Share#observable! and S3#observable! document the `.trash` instance). Adding a skipped
  # name without adding it to the write guard is shipping the fifth. One predicate, consulted from
  # both sides, is how the two cannot drift.
  #
  # SCOPE: macOS only, on purpose — that is the OS the deployment's users run. Windows clutter
  # (`Thumbs.db`, `desktop.ini`) is deliberately NOT here; adding a name to this list is a real
  # indexing-behavior change and a new write refusal, so it is a decision to make explicitly, not a
  # net to widen on a hunch.
  module OsClutter
    # Exact-match segment names. `__MACOSX` and the volume-metadata folders are directories whose
    # whole subtree is clutter; because #ignore? matches ANY segment, naming the directory here
    # skips everything beneath it without a separate rule.
    NAMES = Set.new(%w[
      .DS_Store
      __MACOSX
      .Spotlight-V100
      .Trashes
      .fseventsd
      .TemporaryItems
      .DocumentRevisions-V100
      .apdisk
    ]).freeze

    # AppleDouble resource forks: a `._`-prefixed sidecar the Finder writes next to a real file on
    # non-native filesystems (SMB/NFS/FAT). Matched by PREFIX because the suffix is the real file's
    # name (`._bracket.stl`), so there is no fixed set to enumerate.
    APPLE_DOUBLE_PREFIX = "._".freeze

    # True if any path segment is OS clutter. Checked over EVERY segment, not just the leaf, so the
    # write guards catch a destination like `__MACOSX/foo.stl` (the leaf is innocent; the parent is
    # not) and the observers skip a whole clutter subtree. The observers happen to only ever have a
    # newly-clutter leaf — they never descend into a skipped directory — but consulting the full
    # path here is what lets the ONE predicate serve both callers without a second variant.
    def self.ignore?(rel)
      rel.to_s.split("/").any? { |segment| clutter_segment?(segment) }
    end

    def self.clutter_segment?(segment)
      NAMES.include?(segment) || segment.start_with?(APPLE_DOUBLE_PREFIX)
    end
  end
end
