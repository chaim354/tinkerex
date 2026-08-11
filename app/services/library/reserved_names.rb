module Library
  # MAY A WEB DOOR MINT A NODE WITH THIS LEAF NAME? The door-side half of the reserved-name rule,
  # and the half with no adapter behind it.
  #
  # FileLayer::Share#observable! and FileLayer::S3#observable! already answer this question about a
  # REL PATH inside a store they own, and every write verb calls them. CHUNK HAS NO SUCH GUARD AND
  # CANNOT HAVE ONE: it is not port_writable, so its writes never touch an adapter at all
  # (Maker::Addons::LibraryOutput#write_chunk drives Sync::Commit directly; FilesController's
  # two-phase upload drives it from the browser; Maker::LibraryFolder#chunk_mkdir writes the dir
  # row itself). Sync::Commit validates the manifest exhaustively and the name not at all, and Node
  # validates `name` for presence only — so on the product's MAIN deployment a reserved name was a
  # live node bound for the changelog and every device's real mount, while the same request was a
  # routine 422 on share and s3. Probed, one save per name, through the real doors:
  #
  #   name                                       chunk   share   s3
  #   ok.txt                                      302     302    302
  #   .DS_Store ._x __MACOSX .Trashes .trash      302     422    422
  #   .maker-tmp-x                                302     422    302
  #
  # §14a: one condition must not have two answers across backends. §14c already records this exact
  # shape for Maker::MoveNode.valid_leaf_name? ("a guard that exists on two backends and silently
  # does not on the third"), and its conclusion is the one followed here: THE FIX IS THE DOOR,
  # never a third copy of the guard inside the chunk write path.
  #
  # THE UNION, NOT THE INTERSECTION — the one real design choice here, so the argument is written
  # down rather than left to be re-derived. FileLayer::S3#observable! deliberately OMITS
  # Scanner::TEMP_PREFIX (that adapter writes no temp keys, so a `.maker-tmp-x` object is genuinely
  # observable in ITS store, and that comment stays true and untouched). A door cannot know which
  # backend is deployed — LIBRARY_BACKEND is a per-deployment env var read long after this code is
  # written — so it has exactly two options:
  #
  #   union        refuse everything ANY adapter would refuse. A name accepted here is accepted by
  #                whichever adapter is actually deployed. Costs: an addon may not name its output
  #                with this app's own internal temp-file prefix. Nobody wants that name.
  #   intersection refuse only what ALL adapters refuse. Leaves `.maker-tmp-x` at chunk 302 /
  #                share 422 / s3 302 — the reported bug, narrowed rather than closed.
  #
  # The intersection is the same divergence with the sign flipped, so this is the union.
  #
  # NOT A SECOND COPY OF THE STRINGS. Composed from Scanner::TRASH_PREFIX, Scanner::TEMP_PREFIX and
  # Library::OsClutter — the same constants the observers skip on. Library::OsClutter's own header
  # states the rule this obeys: "adding a skipped name without adding it to the write guard is
  # shipping the fifth [wedge]. One predicate, consulted from both sides, is how the two cannot
  # drift." A fourth spelling of `.trash` here would be that bug, in the file written to prevent it.
  #
  # WHAT THIS IS NOT:
  #
  #   NOT Maker::MoveNode.valid_leaf_name?, and deliberately not folded into it. That answers a
  #   SYNTAX question (no separator, not `.`/`..`, bounded length) and every door pairs the two.
  #   Folding would have been one call instead of two — but valid_leaf_name? is also called by
  #   Maker::MoveNode#call, which validates a name that usually ALREADY EXISTS (`new_name.presence
  #   || node.name`). On chunk, `.DS_Store` nodes are a legitimate and common artifact: a real
  #   macOS device syncing its mount pushes them through Sync::Commit#finalize, which is the sync
  #   PROTOCOL (§6, the client is authoritative) and not a web door. Folding would therefore make
  #   a population the product creates by design permanently unmovable, to close a hole about
  #   MINTING a new name. Renaming stays available either way. So: two predicates, called together.
  #
  #   NOT a claim about the mount. This governs the web doors that mint a name (§14f names the
  #   doors); a device push is the sync protocol and answers to Sync::Commit, not to this.
  module ReservedNames
    # `name` is a LEAF — callers run Maker::MoveNode.valid_leaf_name? first, which is what makes
    # "contains no separator" true here. Non-strings answer false rather than raising: a door's
    # input is JSON a browser bundle sent, and a nil name must reach that door's own routine
    # refusal instead of a NoMethodError 500.
    def self.reserved?(name)
      return false unless name.is_a?(String)

      # TRASH_PREFIX is EXACT, matching Scanner#each_child's `rel == TRASH_PREFIX` — `.trashcan.svg`
      # is an ordinary file. TEMP_PREFIX is a PREFIX, matching `name.start_with?(TEMP_PREFIX)` there.
      name == Library::Scanner::TRASH_PREFIX ||
        name.start_with?(Library::Scanner::TEMP_PREFIX) ||
        Library::OsClutter.clutter_segment?(name)
    end
  end
end
