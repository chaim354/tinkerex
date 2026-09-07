module Library
  # DIRECTORIES WHOSE CONTENTS ARE BUILD OUTPUT — hidden from every listing, and NOTHING ELSE.
  #
  # A DISPLAY RULE, NEVER A SCAN SKIP, AND THE DISTINCTION IS THE ONE §14b IS BUILT AROUND. DO NOT
  # WIRE THIS INTO `Library::Scanner`, `Library::S3Observer`, `FileLayer::Share#observable!`,
  # `FileLayer::S3#observable!` or `Library::ReservedNames`. That is `Library::OsClutter`'s job, and
  # its list is a different list for a different reason: OsClutter names things NO maker put in
  # their library on purpose, so it is safe to make them unobservable AND to refuse them as write
  # destinations, together. These are the maker's own directories. The instant a name becomes
  # unobservable, a live node still pointing there is a ghost the Reconciler can never pair, whose
  # tombstone trips the mass-deletion guard and refuses that scan AND EVERY SCAN AFTER IT,
  # permanently — four wedges so far, each found after the previous explanation said it could not
  # happen.
  #
  # HIDING THE ENTRY, NOT ITS SUBTREE. `Node.visible_entries` filters ROWS BY NAME, so a `main.o`
  # under `node_modules/` is still listed by the flat by-extension view. That is the identical
  # limitation `.git` already carries on chunk_remote and node.rb records: closing it needs a
  # recursive CTE on a page in the hot path, which that comment refuses on cost. What this DOES
  # close is every listing that walks parents — the folder view, the project's Files panel, the
  # chooser, search — which is where the clutter is actually in the way.
  #
  # GATED ON `show_hidden`, LIKE A DOT-DIR AND UNLIKE `.git`. There is a real reason to open a
  # build directory (a linker map, a generated header), and "Show hidden" is already the way in.
  #
  # TWO NAMES, EXACT AND LOWERCASE — the same exact match `Library::RepoMetadata.marker?` makes.
  # `node_modules` is npm's convention and `__pycache__` CPython's; a maker who genuinely names a
  # folder `Node_Modules` keeps it, because the match is exact, and one who names it `node_modules`
  # gets it hidden and one click from visible.
  #
  # `build` IS DELIBERATELY NOT HERE, and it is the name a later reader will reach for first. It is
  # the C/CMake/PlatformIO convention AND a folder a maker plausibly made themselves — assembly
  # photos for a build. It never appeared in the measured share library (2026-09-07: the ~440
  # object files were under `.pio/`, already hidden as a dot-dir), so it would buy nothing real;
  # and the project page has no "Show hidden" control, so hiding a maker's own folder there has no
  # way back. Adding a name here is a change to what every listing shows, so it is a decision, not
  # a net to widen on a hunch — the same sentence OsClutter's SCOPE note makes about Windows
  # clutter. node_test.rb pins `build`'s absence so that decision cannot be undone by accident.
  module BuildOutput
    NAMES = %w[node_modules __pycache__].freeze

    # Is THIS DIRECTORY's name build output? Callers that already know they hold a directory ask
    # this; `Node.visible_entries` asks the same question in SQL, off the same constant.
    def self.dir?(name) = NAMES.include?(name.to_s)
  end
end
