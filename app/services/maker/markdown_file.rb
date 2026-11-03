module Maker
  # A MARKDOWN FILE, RENDERED FOR ITS OWN PAGE (2026-11-02, the UX audit's D8). The file page showed
  # a `.md` only as source; FilesController#show now asks this for the Rendered view it offers beside
  # the Source one, and renders the source view alone whenever this has no html to give.
  #
  # THE SAME RENDERER AND THE SAME TWO ARMS AS THE PROJECT'S README CARD: Maker::Readme.render_markdown
  # with the maker's page link (Maker::RepoCard::DEFAULT_LINK) for a link and the blob route
  # (Maker::Readme::MAKER_IMAGE_LINK) for a picture, so `[base](models/base.stl)` opens that file's
  # page and `![plate](plate.svg)` loads its bytes, and raw HTML is stripped by Maker::Markdown's one
  # sanitising pass. Nothing here renders Markdown itself.
  #
  # ONE PORT READ, OF THE FILE THE MAKER ASKED TO SEE — which is what makes it allowed on a GET. §2
  # and §14a forbid a CATALOG pull in a read path (the WAN in the metadata path, paid per request);
  # this is the bytes of the one file the page is about, the same read the source view's blob fetch
  # makes, bounded by LIMIT on the catalog's size before anything is read. Nothing here touches the
  # changelog or refreshes the mirror.
  #
  # IT MUST NEVER TAKE THE PAGE DOWN, Maker::Readme's promise: an unreachable store answers
  # `problem: :unreachable` and raises Current.library_unreachable for the layout's banner, an
  # over-cap file answers `problem: :too_large` without a read, and a file gone between the stat and
  # the read answers nil. In every one of those the page renders the source view exactly as before.
  class MarkdownFile < Data.define(:html, :problem)
    # WHAT WILL BE READ AT ALL — the README card's own read limit (256 KB), the same bound for the
    # same reason: the port's `read` takes no byte limit, so the catalog's size is the gate.
    LIMIT = Maker::Readme::READ_LIMIT

    # HOW FAR A RELATIVE LINK REACHES. The file's own folder and the folders beneath it, breadth
    # first, so `docs/plate.svg` and `models/base.stl` resolve the way they do on the project's
    # README card, whose index is the whole project folder. The folders come off the LibraryTree the
    # page already built for the Path row (no query); their files are ONE query, capped, so the cost
    # is constant in the size of the folder (page_query_budget_test.rb). Past either cap a link
    # renders as its own text, Maker::Markdown's answer for a path it cannot resolve.
    LINK_DIRS = 200
    LINK_ROWS = 2_000

    def self.for(user:, node:, size:, tree:)
      return new(html: nil, problem: :too_large) if size.to_i > LIMIT

      bytes = FileLayer.current.read(user, node_id: node.node_id)
      # THE CATALOG CAN LAG THE STORE (a share file grown since the last scan), so the bytes are
      # measured too; the read already happened, but nothing past the limit is parsed.
      return new(html: nil, problem: :too_large) if bytes.bytesize > LIMIT

      # `.scrub` after forcing UTF-8, Maker::Readme.for's reason: a NAS file is not guaranteed to be
      # valid UTF-8, and this must degrade to a replacement character, never raise into a 500.
      text = bytes.dup.force_encoding(Encoding::UTF_8).scrub
      # `base` IS THE FILE'S OWN FOLDER AS A FULL LIBRARY PATH ("" at the root), the shape the index
      # keys on. A broken ancestor chain has no path, and then nothing resolves: every relative link
      # becomes its text rather than a guess at where it points.
      base = tree.path_for(node.parent_node_id)
      index = base ? link_index(user, node.parent_node_id, tree) : {}
      html = Maker::Readme.render_markdown(text, base_path: base.to_s, index:,
                                                 link: Maker::RepoCard::DEFAULT_LINK,
                                                 image_link: Maker::Readme::MAKER_IMAGE_LINK)
      new(html:, problem: nil)
    # TWO ARMS, Current's rule: the store not answering is an outage the banner names; a file that
    # is gone is not, so its arm raises nothing.
    rescue FileLayer::FetchError
      Current.library_unreachable = true
      new(html: nil, problem: :unreachable)
    rescue FileLayer::NotFound
      nil
    end

    # Catalog path ("Projects/lamp/models/base.stl", or "base.stl" at the root) → node id, for every
    # live FILE in the folder and the folders beneath it, up to the two caps. `.git` is never walked
    # into: on chunk_remote its contents are mirrored, and nothing links into a repository's object
    # store. The first row for a path wins, which only matters for a corrupt catalog.
    def self.link_index(user, folder_id, tree)
      dirs = [ folder_id ]
      queue = [ folder_id ]
      # `until queue.empty?`, NEVER `while (id = queue.shift)`: the library root's id is nil, so that
      # spelling ended before its first pass and a root file's links into subfolders resolved to text.
      until queue.empty? || dirs.size >= LINK_DIRS
        id = queue.shift
        tree.children_of(id).each do |child|
          next if Library::RepoMetadata.marker?(child.name)
          break if dirs.size >= LINK_DIRS

          dirs << child.node_id
          queue << child.node_id
        end
      end

      rows = user.nodes.present.where(kind: "file", parent_node_id: dirs).limit(LINK_ROWS)
                 .pluck(:parent_node_id, :name, :node_id)
      rows.each_with_object({}) do |(parent, name, id), index|
        dir = tree.path_for(parent)
        next if dir.nil?

        index[[ dir.presence, name ].compact.join("/")] ||= id
      end
    end
    private_class_method :link_index
  end
end
