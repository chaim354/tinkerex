module Maker
  # ONE README, READ THEN RENDERED — the repo card's `readme_facts` (stage 3, S3-2) with the two
  # things a second caller needs to vary pulled out as parameters: WHICH rows to search (a repo
  # dir's own files vs the project folder's loose files) and WHERE a resolved relative link points
  # (the private `/files/:id` page vs the public project URL). Extracted for the public project
  # page (stage 3, S3-4); `Maker::RepoCard` is now its first caller, not a second copy. SINCE THE
  # LIVE REGIONS (2026-11-05) THE READER IS TWO STEPS: `.source` finds, reads and parses the file,
  # `.render` expands its regions and renders the markdown, and `.for` is both in one call for a
  # caller with no ordering between them to respect (the project page has one — spec §5).
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

    # STEP ONE OF TWO (2026-11-05, live regions; spec §5): find and READ the README, capped, and parse
    # its regions — but render nothing yet. The project page needs the `image` regions' node ids
    # BEFORE it builds its one thumbnail query and the rendered HTML AFTER, so the two steps are two
    # calls; `.for` below is both in one for every caller with no such ordering to respect. nil means
    # "this listing holds no README". `text` is nil, and `note` says why, when the file was not read.
    Source = Data.define(:row, :text, :note, :regions) do
      def image_node_ids = regions.select(&:recognised?).filter_map(&:node_id)
    end

    # WHAT "WRITE A README" STARTS FROM (stage 4, S4-4). Short on purpose: a template a maker has to
    # delete half of is worse than a blank page. The two headings are the two things the project
    # page already has and the README cannot see — the folder's files and the build log — so the
    # template's job is to say "these are the sections worth writing", not to write them.
    #
    # `NAMES.first` IS THE NAME A CREATE USES, read from the preference order rather than spelled
    # again: the list is the preference order, so the first entry is what this app would rather find.
    def self.template_for(project)
      <<~MD
        # #{project.name}

        #{project.description.presence || "One line about what this is."}

        ## Files

        ## Build log
      MD
    end

    # `rows` are Maker::ProjectFolderListing::Row objects already in memory — the same rows the
    # caller is about to render as tiles — so finding the README costs no query. nil means "this
    # listing holds no README", which a caller renders as nothing at all rather than as a note.
    # WHICH ROW IS THE README, as its own answer — `NAMES` is a PREFERENCE ORDER, so "the first
    # name in the list that this listing holds" is a rule and not a lookup, and a second caller
    # spelling it out again is a pair that can drift. `Maker::PublicProject#readme_row` is that
    # second caller (stage 3, S3-6: the bundle manifest names the README so the button can label
    # it), and it wants the ROW rather than the rendered card this method returns.
    def self.row_in(rows)
      NAMES.filter_map { |name| rows.find { |r| r.node.name == name } }.first
    end

    # WHERE A PICTURE IN THE MAKER'S OWN README LOADS FROM (2026-11-02, the UX audit's C2). The
    # maker's `link` is the file's PAGE (Maker::RepoCard::DEFAULT_LINK), which is the right target
    # for `[base](models/base.stl)` and the wrong one for `![plate](docs/plate.svg)`: an `<img>`
    # pointed at an HTML page is a broken picture, which is what the hub drew while the public page
    # — whose one link is the BYTE url, Maker::PublicProject#file_url_for — drew the same image. A
    # picture takes the blob route the hero and an image block already load from.
    MAKER_IMAGE_LINK = ->(id) { Rails.application.routes.url_helpers.blob_file_path(id) }

    # The image arm a caller gets when it names none: the maker's page link implies the maker's
    # picture link; any other link (the public page's byte url) already serves a picture, so nil.
    # IDENTITY, NOT EQUALITY: RepoCard.for passes its default straight through, and
    # ProjectsController#show names the same constant, so both maker callers are this one object.
    def self.default_image_link(link) = link.equal?(Maker::RepoCard::DEFAULT_LINK) ? MAKER_IMAGE_LINK : nil

    # Markdown under one folder, with relative links resolved by `link` and the PICTURES among them
    # by `image_link` when one is given. Public so a content block (projects/_block_panel) renders
    # through the same two arms as a README rather than a copy of them.
    #
    # Maker::Markdown yields an href without saying which element asked for it, so the image arm
    # is applied AFTER rendering, and only to a `src` this resolver itself handed out — never to an
    # href the author wrote. That pass parses the SANITISED output with the sanitiser's own HTML5
    # parser and changes one attribute to a path this app built; it adds no element and keeps no
    # id, so it cannot reopen what Maker::Markdown's single pass closes.
    def self.render_markdown(text, base_path:, index:, link:, image_link: nil)
      issued = {}
      resolve = Maker::Markdown.folder_resolver(base_path, index) { |id| link.call(id).tap { |url| issued[url] = id } }
      html = Maker::Markdown.render(text, &resolve)
      return html if image_link.nil? || issued.empty?

      fragment = Nokogiri::HTML5.fragment(html)
      pictures = fragment.css("img[src]").select { |img| issued.key?(img["src"]) }
      return html if pictures.empty?

      # nil FROM THE ARM DROPS THE PICTURE (2026-11-05): the node-aware maker arm answers nil for a
      # non-image file with no ready thumbnail, and an <img> with a blank src is a broken picture
      # that also fetches the page itself.
      pictures.each do |img|
        url = image_link.call(issued.fetch(img["src"]))
        url ? img["src"] = url : img.remove
      end
      fragment.to_html.html_safe # sanitised by Maker::Markdown.render; only a src changed since
    end

    def self.source(user:, rows:)
      row = row_in(rows)
      return nil if row.nil?
      if row.node.size.to_i > READ_LIMIT
        return Source.new(row:, text: nil, regions: [],
                          note: "README too large to show here (#{row.node.size.to_i / 1024} KB); open the file instead.")
      end

      bytes = FileLayer.current.read(user, node_id: row.node_id)
      truncated = bytes.bytesize > CAP
      # `.scrub` after forcing UTF-8: a byte cap can split a multi-byte character at the tail, and a
      # NAS file is not guaranteed to be valid UTF-8 to begin with (§14b makes the same point about
      # filenames) — either way this must degrade to a replacement character, never raise
      # Encoding::InvalidByteSequenceError out of a panel into a 500 for the whole page.
      text = (truncated ? bytes.byteslice(0, CAP) : bytes).dup.force_encoding(Encoding::UTF_8).scrub
      Source.new(row:, text:, regions: Live.regions(text),
                 note: (truncated ? "Showing the first #{CAP / 1024} KB of this README." : nil))
    # TWO ARMS, ONE NOTE. The store not answering is an outage the layout's banner names
    # (app/models/current.rb); a README that is gone is not, so its arm raises nothing.
    rescue FileLayer::FetchError
      Current.library_unreachable = true
      Source.new(row:, text: nil, regions: [], note: "README unavailable.")
    rescue FileLayer::NotFound
      Source.new(row:, text: nil, regions: [], note: "README unavailable.")
    end

    # STEP TWO: expand the live regions against `context` (Maker::Readme::Live::Context; nil is a
    # caller with nothing to expand against — a nested repository's card, the file page — and then
    # the markers go and the saved bodies stay) and render the markdown. THE ONE FOLDER RESOLVER
    # (Maker::Markdown.folder_resolver, through #render_markdown): a content block resolves against the
    # project folder with the same arithmetic, so the two cannot drift.
    def self.render(source, base_path:, index:, link:, image_link: default_image_link(link), context: nil)
      return new(html: nil, note: source.note) if source.text.nil?

      text = Live.expand(source.text, context:, mode: :page)
      new(html: render_markdown(text, base_path:, index:, link:, image_link:), note: source.note)
    end

    def self.for(user:, rows:, base_path:, listing:, link:, image_link: default_image_link(link), context: nil)
      source = source(user:, rows:)
      return nil if source.nil?

      render(source, base_path:, index: listing.path_index, link:, image_link:, context:)
    end
  end
end
