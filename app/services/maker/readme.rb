module Maker
  # ONE README, RENDERED FOR A CARD — the repo card's `readme_facts` (stage 3, S3-2) with the two
  # things a second caller needs to vary pulled out as parameters: WHICH rows to search (a repo
  # dir's own files vs the project folder's loose files) and WHERE a resolved relative link points
  # (the private `/files/:id` page vs the public project URL). Extracted for the public project
  # page (stage 3, S3-4); `Maker::RepoCard` is now its first caller, not a second copy.
  #
  # READS THROUGH THE PORT, NEVER `File.read` — a README is a catalog file like any other
  # (git-editing.md), so this works on share, s3 and chunk_remote alike, and is NOT gated on
  # `local_worktree?` the way the card's git facts are.
  #
  # IT MUST NEVER TAKE A PAGE DOWN. A missing README, an unmounted share, a corrupt encoding or a
  # README the size of a firmware image degrades to `nil` or to a note in its own card — the
  # caller renders the note, and every other panel on the page is untouched (RepoCard's own class
  # comment makes the same promise, and this is one of the two places it was always held).
  #
  # `base_path` IS THE README'S OWN DIRECTORY, AS A FULL LIBRARY PATH, because that is the shape
  # `Maker::ProjectFolderListing#path_index` keys on ("Projects/lamp/models/base.stl", the
  # catalog's own path, never a path relative to anything). A relative href in the README is
  # joined onto it and `cleanpath`ed, so `[base](models/base.stl)` inside `Projects/lamp/README.md`
  # asks the index for `Projects/lamp/models/base.stl`. A base that is not the README's real
  # directory resolves NOTHING — the links quietly become plain text — which is why the caller
  # passes `dir.path` / `listing.path` rather than a constant.
  # SUBCLASSED RATHER THAN `Data.define(…) do … end`, AND THE REASON IS THE CONSTANTS. A constant
  # assigned inside a `do … end` block is scoped LEXICALLY, so it lands on the enclosing MODULE —
  # `Maker::RepoCard`'s three README constants have always been `Maker::README_CAP` and friends,
  # and `Maker::RepoCard::README_CAP` raises NameError (probed, 2026-09-05, while writing this).
  # A class body puts them where every caller expects: `Maker::Readme::CAP`.
  class Readme < Data.define(:html, :note)
    # First match wins, so the order is the preference order. Wider than the three names the repo
    # card shipped with: a project folder's README is written by a human in Finder, not by a
    # `git init` template, and `README.txt` is what a Windows toolchain produces. THE REPO CARD
    # INHERITS THE WIDER LIST ON PURPOSE (`RepoCard::README_NAMES` is this constant, not a copy):
    # a repository root holding `README.txt` or `Readme.md` now renders it where S3-2 showed
    # nothing, and `README.txt` outranks a bare `README`. That is the better behaviour and the
    # only way the two callers cannot drift; do not give the card its own three-name array back.
    NAMES = %w[README.md README.markdown README.txt README readme.md Readme.md].freeze
    CAP = 64 * 1024 # what a card RENDERS; a longer README is cut here with a note
    # WHAT WILL BE READ AT ALL. The port's `read` takes no byte limit and answers the whole object
    # (up to FileLayer::MAX_BYTES, 256 MB) — on chunk_remote a full WAN stream — so the cap on the
    # RENDER above bounded nothing by itself (review, S3-2). The catalog already knows the size; a
    # README past this is never read, and the card says so.
    READ_LIMIT = CAP * 4

    # `rows` are Maker::ProjectFolderListing::Row objects already in memory — the same rows the
    # caller is about to render as tiles — so finding the README costs no query. nil means "this
    # listing holds no README", which a caller renders as nothing at all rather than as a note.
    def self.for(user:, rows:, base_path:, listing:, link:)
      row = NAMES.filter_map { |name| rows.find { |r| r.node.name == name } }.first
      return nil if row.nil?
      if row.node.size.to_i > READ_LIMIT
        return new(html: nil, note: "README too large to show here (#{row.node.size.to_i / 1024} KB); open the file instead.")
      end

      bytes = FileLayer.current.read(user, node_id: row.node_id)
      truncated = bytes.bytesize > CAP
      # `.scrub` after forcing UTF-8: a byte cap can split a multi-byte character at the tail, and a
      # NAS file is not guaranteed to be valid UTF-8 to begin with (§14b makes the same point about
      # filenames) — either way this must degrade to a replacement character, never raise
      # Encoding::InvalidByteSequenceError out of a card into a 500 for the whole page.
      text = (truncated ? bytes.byteslice(0, CAP) : bytes).dup.force_encoding(Encoding::UTF_8).scrub
      base = Pathname.new(base_path.to_s)
      index = listing.path_index
      html = Maker::Markdown.render(text) do |href|
        target_id = index[base.join(href).cleanpath.to_s]
        target_id && link.call(target_id)
      end
      new(html:, note: (truncated ? "Showing the first #{CAP / 1024} KB of this README." : nil))
    rescue FileLayer::NotFound, FileLayer::FetchError
      new(html: nil, note: "README unavailable.")
    end
  end
end
