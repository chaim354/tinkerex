module Maker
  # EVERYTHING A PUBLIC PAGE MAY SHOW, DERIVED ONCE (stage 3, S3-4; spec §2.5, §2.6). The page and
  # the file route both ask this object, so "is this file public" has ONE answer. That is the whole
  # reason it exists: a page that decided what to render and a route that decided what to deliver
  # would be two spellings of one rule, and the pair that drifts is the pair where a file is
  # linked on the page and 404s, or worse is delivered while nothing links it.
  #
  # PERMISSION IS BY ANCESTRY OR BY ATTACHMENT, NEVER BY THE CAPPED LISTING. A file past
  # ProjectFolderListing::FILE_CAP, or inside a repository the DIR_CAP walk never entered, is not
  # rendered on the page — but a README's own link to it must still resolve, and a visitor who was
  # handed that URL must still get the bytes. Ancestry (a live file whose parent chain reaches the
  # project folder) is what says so; attachment (a maker_file_attachments row on the project or on
  # one of its build-log entries) covers the Linked file and the entry photo that live ELSEWHERE in
  # the library and are still the project's.
  #
  # IT READS THE OWNER'S LIBRARY IN THE OWNER'S NAME. Every port call and every query below is
  # scoped to `project.user`, who is not the person making the request — a visitor has no library
  # of their own for a node_id to resolve against. Nothing here consults a session; the controllers
  # above it cannot (Public::BaseController stands on ActionController::Base).
  class PublicProject
    # THE FEED IS CAPPED AND THE CAP IS NOT A PAGE SIZE — there is no "older entries" link and
    # there will not be one: a reader polls the newest N, and a project with 4000 build-log lines
    # must not hand every poll 4000 rendered rich-text bodies. 50 is what a reader shows.
    FEED_CAP = 50

    # One thing that happened, whatever kind of thing it was (stage 3, S3-6). A `Data` rather than
    # the records themselves BECAUSE the two kinds are merged: a build-log entry has `logged_at`
    # and a release has `published_at`, and a sort that had to ask which it was holding is the
    # shape that gets one kind's ordering wrong. `html` is already-rendered, already-sanitized
    # markup (Action Text's own, §15's text-only rule applied on the way in), never raw user text.
    FeedItem = Data.define(:kind, :id, :title, :time, :html, :url)

    # One file the browser will fetch and zip (stage 3, S3-6). `path` is FOLDER-RELATIVE, because
    # that is the path inside the zip — the owner's library filing ("Projects/desk-lamp/models") is
    # not the visitor's vocabulary, the same argument `#sections` makes for its headings. `url` is
    # the public file route, which is the whole point: the bundle is assembled in the visitor's
    # browser out of the same downloads the page already links, so no byte passes through Rails
    # that a plain download would not already have moved (§15).
    BundleFile = Data.define(:path, :size, :url)

    attr_reader :project, :owner, :listing, :tree

    def initialize(project)
      @project = project
      @owner = project.user
      @tree = Maker::LibraryTree.new(@owner)
      # ONE tree shared with the listing: it already indexes every live dir the owner has, which is
      # what `permits?`'s ancestry walk needs, and building a second would double the dir pluck.
      @listing = Maker::ProjectFolderListing.new(@owner, project, tree: @tree)
    end

    def handle = owner.handle

    # What EVERY link this page renders must carry for an unlisted project: the token IS the
    # credential, so a link without it leads to a 404 (Public::BaseController#public_project!).
    # Empty for a public project, so the same call site works for both.
    def link_params = project.unlisted? ? { k: project.unlisted_token } : {}

    # ONE FOLDER PANEL'S CONTENT (2026-09-08, folder panels; spec §5): the dir's OWN files under a
    # nil label — the panel head already names the folder — then every nested subfolder that holds
    # files, labelled RELATIVE TO THIS PANEL ("deep", never "models/deep" and never the library
    # path). Depth one is a panel, everything below it is a sub-heading inside that panel (spec
    # decision 3), which is what this walk draws.
    #
    # An EMPTY answer is what makes the panel omit itself (public/projects/_folder_panel): a folder
    # holding nothing but backups counts as empty here, because `#bucket` already diverted those
    # out of `Dir#files` and a public page does not render them at all.
    #
    # Memoised per dir: the partial asks once for the emptiness test and once to render, and both
    # must be the same list.
    def folder_sections(dir)
      (@folder_sections ||= {})[dir.node_id] ||=
        (dir.files.any? ? [ [ nil, dir.files ] ] : []) + sections_under(dir.children, prefix: "#{dir.path}/")
    end

    # The folder's OWN root files — what the Files panel shows now that every subfolder is a panel
    # of its own (spec decision 4: the Files panel keeps the folder ROOT).
    def loose_rows = listing.loose

    # The Dir behind one `folder:<node_id>` key. NEVER nil for a key this page renders: `#layout`
    # is built from `listing.panel_folders`, which is this same `listing.tree`, and the layout
    # drops every key outside that vocabulary (Maker::ProjectKind's totality rule) — so a branch
    # here would be dead code standing in for an argument.
    def folder_dir(key) = listing.tree.find { |dir| dir.node_id == layout.folder_id(key) }

    # THE OWNER'S OWN PANEL LAYOUT, HONOURED FOR A VISITOR (stage 4, S4-7; story 6.5). Delegated
    # rather than recomputed, so the maker's page and a visitor's cannot disagree about what is
    # hidden — the same argument #photo_rows makes for delegating to Maker::ProjectPhotos. Reads two
    # columns off a row this object already holds: no query, and no session (Public::BaseController
    # stands on ActionController::Base and has none to read).
    #
    # WHICH OF THESE HAVE A PUBLIC FACE IS THE TEMPLATE'S QUESTION, not this one's — see
    # public/projects/_page.html.erb's partial map, whose absent keys (tasks, sheets, publish) are
    # the whole definition of "private only".
    #
    # ONE LAYOUT PER PAGE, MEMOISED, AND IT KNOWS THE FOLDERS (2026-09-08, folder panels). Every
    # question this object answers about the arrangement — which panels render, which folders are
    # hidden, which view a folder opens in, whether a side document exists — comes off this one
    # value, so the page, the manifest, the feed and the CSV cannot disagree about an arrangement
    # the maker saved once. `listing.panel_folders` is the tree the constructor already built plus
    # ONE query for the OWNER's shelves (2026-10-20: a shelf's default view and group shape the
    # visitor's page too), memoised on the listing, so asking here costs one constant query.
    #
    # AND IT KNOWS THE BLOCKS (2026-09-09, content blocks): a block is a panel of the layout, so its
    # key has to be in the vocabulary here or the maker's own order would be filtered down to the
    # panels alone on the page a visitor sees — every block dropped, silently, by the totality rule.
    def layout = @layout ||= project.panel_layout(folders: listing.panel_folders,
                                                  blocks: blocks.map { |b| [ b.key, b.kind ] })

    # THE PROJECT'S CONTENT BLOCKS, ONE QUERY, memoised for the page like everything else here. Read
    # BEFORE `layout` needs them and indexed for the loop, one read for both — a block created
    # between two reads would otherwise reach the template as a key with no row.
    def blocks = @blocks ||= project.blocks.to_a

    def blocks_by_key = @blocks_by_key ||= blocks.index_by(&:layout_key)

    # AN IMAGE BLOCK IS DERIVED CONTENT (spec §6), so it answers to all three of the page's rules
    # at once: the node must be LIVE (it comes from `page_nodes`), and `#shown?` — PERMITTED
    # (`permits?` is the one answer to "is this file public") and not under a folder the maker hid,
    # at any depth. Hiding a folder takes its pictures off this page, and an image block naming one
    # would be the Photos leak with a caption under it. nil is the whole answer: the block then
    # renders nothing at all, like a cover that is not permitted.
    def block_image_node(block)
      node = page_nodes[block.node_id]
      node if node && shown?(node)
    end

    def visible_panels = layout.visible

    # WHAT THIS PAGE SHOWS OUT OF THE FOLDER: every listed row except the backups and whatever sits
    # under a folder the maker hid (2026-10-19, F-S14-1; spec decisions 2 and 10). A hidden folder
    # leaves the visitor's page AND the bundle — the page because `visible_panels` never yields its
    # key, everything else because it reads this list.
    #
    # ONE LIST, AND EVERY DERIVED READER STARTS FROM IT. A derived reader is anything a visitor gets
    # because the app walked the folder. `bundle_files`, `bundle_path_for`, `kicad_rows` and `thumbs`
    # read this list. `photo_rows`, `repo_cards`, `cover_node` and `block_image_node` resolve their
    # nodes elsewhere and ask the same ancestry question: `hidden?`, or `#shown?` where the node must
    # also be permitted. Before this there were seven inline filters over two Sets, and the first two
    # readers that forgot theirs (the repo cards and the KiCad rows) were found by review, not by the
    # rule. A new derived reader is now right because of what it reads.
    # AUTHORED prose does not start here. A README's own links and images, a text block and a BOM
    # line's file link are things the maker wrote that name a file, so they read `listing` and
    # `permits?` (decision 2: hidden is not unpermitted).
    #
    # HIDDEN IS DECIDED BY ANCESTRY, walking up from a file to the project folder and no further
    # (`.depth_one_dir`), NEVER BY THE CAPPED LISTING. `permits?` refuses the capped listing as its
    # basis for the same reason. The Sets this replaced were built from the listing, which stops at
    # FILE_CAP in name order across the whole folder. A picture in a hidden folder whose name sorted
    # past the cap was in neither Set, so the hero (`find_by`) and an image block (`page_nodes`),
    # which resolve nodes outside the listing, showed it as the page's largest image
    # (public_project_test.rb drives it). Backups are out because a visitor's page renders none: a
    # rescue copy is noise to everyone but the maker.
    def shown_rows = @shown_rows ||= listing.all_rows.reject { |row| row.backup? || hidden?(row.node) }

    # The same answer for ONE node resolved outside the listing (the hero, an image block): permitted,
    # and not under a folder the maker hid. A hidden file stays PERMITTED. It still answers its own
    # link, and this page only stops showing it.
    def shown?(node) = permits?(node) && !hidden?(node)

    # The FOLDER's own README, rendered, or nil when it holds none. `defined?` rather than `||=`
    # because nil is a real answer here and `||=` would re-read the port on every call for a folder
    # that has no README at all.
    def readme
      return @readme if defined?(@readme)

      # `base_path` IS THE FOLDER'S OWN LIBRARY PATH, NOT "": `listing.path_index` keys on full
      # library paths ("Projects/desk-lamp/models/base.stl"), so a README at the folder root
      # resolves `models/base.stl` against `listing.path` ("Projects/desk-lamp"). A base that is
      # not the README's real directory resolves NOTHING and the links quietly become plain text —
      # pinned in test/services/maker/readme_test.rb ("a base_path that is not the README's own
      # directory resolves nothing").
      @readme = Maker::Readme.for(user: owner, rows: listing.loose, base_path: listing.path, listing:,
                                  link: ->(id) { file_url_for(id) })
    end

    # The README's own ROW, or nil — the same row `#readme` renders, asked for as a row so the
    # bundle manifest can name it (`readme_path`) without rendering anything. `Maker::Readme.row_in`
    # owns the preference order; see its comment for why this is not a second `find` here.
    def readme_row
      return @readme_row if defined?(@readme_row)

      @readme_row = Maker::Readme.row_in(listing.loose)
    end

    def entries
      @entries ||= project.build_log_entries.includes(:file_attachments, :rich_text_body)
                          .reorder(logged_at: :desc).to_a
    end

    def bom_lines
      @bom_lines ||= (bom = project.current_bom) ? bom.lines.includes(:inventory_item).to_a : []
    end

    def connections = @connections ||= project.connections.to_a

    # RELEASES (stage 3, S3-5), newest first -- the association's own order. `:rich_text_notes` is
    # the association Action Text gives `has_rich_text :notes`; without it a page of ten releases
    # costs ten extra round-trips, which is exactly what page_query_budget_test.rb measures.
    def releases
      @releases ||= project.releases.includes(:files, :rich_text_notes).to_a
    end

    # ONE `stat_all` over every file of every release shown, so "changed since this release" is
    # constant in N -- the private panel's own rule (ProjectsController#show), asked here in the
    # OWNER's name, since a visitor has no library for a node_id to resolve against. An absent key
    # is the port's answer for a node that is no longer live (§14a).
    def release_tokens
      @release_tokens ||= begin
        ids = releases.flat_map { |r| r.files.map(&:node_id) }.uniq
        ids.empty? ? {} : FileLayer.current.stat_all(owner, node_ids: ids)
      end
    end

    # THE FEED (stage 3, S3-6): the build log and the releases as ONE list, newest first, capped.
    #
    # `page_url` IS PASSED IN RATHER THAN BUILT HERE, and that is not squeamishness about a service
    # naming a route — `#file_url_for` right below names one happily. It is that an ATOM feed needs
    # ABSOLUTE urls and this app configures no `default_url_options` for the routes (only for the
    # mailer), so `url_helpers.public_project_url` raises "Missing host to link to!" outside a
    # request. The controller has the request and knows the host the visitor actually reached; this
    # object does not, and inventing one would put a wrong hostname in every reader's history.
    #
    # THE TWO KINDS ARE MERGED AND SORTED ONCE, never rendered as two sections: a reader shows one
    # stream, and "what happened to this project, newest first" is one question. The sort key
    # carries the id after the time so two things logged in the same second have a stable order
    # rather than a database-dependent one.
    # ITS OWN BOUNDED READERS, NOT THE PAGE'S. `entries` and `releases` are the page's unbounded
    # memos; a feed that mapped over them loaded every build-log entry and every release, Action
    # Text bodies included, and then kept fifty (S3-6's review). Each side takes the newest
    # FEED_CAP, so the merge can never need more than that from either, and the query count stays
    # what the budget test pins.
    #
    # A HIDDEN PANEL'S ITEMS ARE ABSENT FROM THE FEED, NOT MERELY OFF THE PAGE (hardening,
    # 2026-09-08; tinkerex#283). The feed is one click from the page that hides them — a maker who
    # hid the build log and still fed every entry to any reader who subscribed would have published
    # exactly what they said not to publish, and a feed is the surface that keeps a copy. Each kind
    # is gated separately because the two panels are hidden separately: hiding `releases` must not
    # take the build log with it. An empty relation rather than a branch around the map, so the
    # merge, the sort and the cap below stay one path with one shape.
    def feed_items(page_url:)
      newest_entries = panel_visible?("build_log") ? feed_entries : []
      newest_releases = panel_visible?("releases") ? feed_releases : []
      items = newest_entries.map do |entry|
        FeedItem.new(kind: :entry, id: entry.id, time: entry.logged_at, html: entry.body.to_s,
                     title: "Build log — #{entry.logged_at.strftime("%Y-%m-%d")}",
                     url: "#{page_url}#entry-#{entry.id}")
      end
      items += newest_releases.map do |release|
        count = release.files.size
        FeedItem.new(kind: :release, id: release.id, time: release.published_at,
                     title: "Release #{release.version}",
                     html: "#{release.notes}<p>#{count} #{count == 1 ? "file" : "files"} in this release.</p>",
                     url: "#{page_url}#release-#{release.id}")
      end
      items.sort_by { |item| [ item.time, item.id ] }.reverse.first(FEED_CAP)
    end

    # EVERY FILE THE BUNDLE BUTTON WILL FETCH (stage 3, S3-6) — `#shown_rows`, the listing's own
    # rows minus the backups the page already leaves out (a rescue copy is noise to everyone but
    # the maker, and a visitor did not ask for two copies of a LightBurn file).
    #
    # NO `permits?` PER ROW, AND THAT IS AN ARGUMENT RATHER THAN AN OMISSION: every listing row is
    # a live, visible file beneath the project folder, which is exactly the ancestry arm of
    # `permits?`. Asking again would be a second authority over the same fact, the thing this class
    # exists to prevent. The dot-files and `.git` internals a visitor must never get are already
    # gone — `ProjectFolderListing` filters on `Node.visible_entries` and never descends into a
    # dot-dir or a build-output dir (`Library::BuildOutput`, stage 4, S4-2, which is why a bundle
    # no longer carries a `node_modules/` tree) — which is the same reason the Files and folder
    # panels can render their rows without a check.
    #
    # THE LIST IS THE LISTING'S, SO IT IS CAPPED (FILE_CAP) and the manifest says so with
    # `truncated`. A bundle that silently held the first 300 files of a 900-file folder would be a
    # lie the visitor cannot detect; one that says "first 300" is a partial answer they can.
    #
    # NO `panel_visible?("attachments")` GATE HERE, AND ITS ABSENCE IS THE ARGUMENT (hardening,
    # 2026-09-08; tinkerex#283). The rule the feed and the BOM CSV follow — a hidden panel's
    # document is absent, not empty-but-present — has nothing to bite on for the bundle, because
    # `attachments` is in Maker::ProjectKind::ALWAYS: no preset and no override may hide the folder
    # panel (`layout_for` subtracts ALWAYS from `hidden`), so `panel_visible?("attachments")` is
    # true for every project that can exist and a gate on it could never be false. Writing one
    # anyway would be a guard no mutation can drive red (§15) that reads to the next person as
    # protection the layout does not actually offer. IF `attachments` EVER LEAVES `ALWAYS`, ADD THE
    # GATE HERE AND TO the manifest's `truncated` — public_bundle_test.rb asserts that membership
    # directly so this comment goes red rather than quietly becoming wrong.
    #
    # A HIDDEN FOLDER'S FILES ARE NOT IN IT (2026-09-08, folder panels; spec decision 2). That IS a
    # panel gate, and it does not contradict the paragraph above: `attachments` cannot be hidden, a
    # SUBFOLDER can, and a maker who took a folder off their public page did not mean to leave it in
    # the zip that page's own button builds. `#shown_rows` has already dropped them, at any depth
    # and past FILE_CAP alike, so there is nothing to reject here.
    #
    # THE FILE ITSELF STILL ANSWERS ITS DIRECT LINK, and that is the same decision: permission is by
    # folder claim (`#permits?`), never by panel, so `#deliverable!` is untouched and a URL a README
    # or a BOM row already handed out keeps working. What changes is only what this page ADVERTISES.
    # Maker::BomCsv agrees by construction. Its `file` column names `#bundle_path_for`, which reads
    # this same list, so a BOM line pointing at a hidden folder's file or at a backup names the bare
    # file. It never names a path the zip does not carry.
    def bundle_files
      @bundle_files ||= shown_rows.map { |row| BundleFile.new(path: bundle_path(row), size: row.node.size.to_i,
                                                              url: file_url_for(row.node_id, download: true)) }
                                  .sort_by(&:path)
    end

    # The path this node has INSIDE the bundle, or nil when the bundle does not carry it: outside the
    # folder, past FILE_CAP, in a repository DIR_CAP never entered, under a hidden folder, or a
    # backup. `Maker::BomCsv` names it in the `file` column so a row of the CSV points at a file in
    # the same zip, and on nil it writes the bare name. Hidden is not unpermitted, and the name is
    # not a secret. It reads `#shown_rows`, the list `#bundle_files` is built from, because when it
    # read the listing it named zip paths for backups the bundle never carries.
    def bundle_path_for(node_id)
      row = shown_row(node_id)
      row && bundle_path(row)
    end

    # Every KiCad schematic/board anywhere in the folder, name-ordered — the private page's own
    # rule (projects/_schematics.html.erb), reading the SAME extension list so the two surfaces can
    # never name a different set of formats.
    def kicad_rows
      # FROM `#shown_rows`, SO NEVER A HIDDEN FOLDER'S BOARD (folder panels, decision 2; found in
      # review): the first row is the file the page's KiCanvas embed loads, so a hidden folder's
      # board was the picture on the page.
      @kicad_rows ||= shown_rows
                      .select { |row| FilesController::KICANVAS_EXTS.include?(File.extname(row.node.name).delete(".").downcase) }
                      .sort_by { |row| row.node.name }
    end

    # Repo cards for every working tree in the folder, keyed by dir node_id (the private page's
    # collect_repo_dirs shape). ONE batched query for every repo on the page, never one per repo —
    # the same argument ProjectsController#show's own comment makes. The card's README links are
    # resolved through THIS page's file route, not `/files/:id`, which a visitor cannot open.
    def repo_cards
      @repo_cards ||= begin
        # NOT A HIDDEN FOLDER'S REPOSITORY (folder panels, decision 2; found in review): the maker's
        # page renders the card INSIDE the folder panel, so hiding the folder hid the card there
        # while this page went on rendering it after the panel loop — the owner's library path, the
        # README and a public link into the folder they had hidden.
        dirs = flatten_dirs(listing.tree).select(&:repo?).reject { |dir| hidden_dir?(dir.node_id) }
        roots = owner.nodes.present.where(node_id: dirs.map(&:node_id), kind: "dir").index_by(&:node_id)
        dirs.index_by(&:node_id).transform_values do |dir|
          Maker::RepoCard.for(user: owner, dir:, root_node: roots[dir.node_id], listing:,
                              capabilities: FileLayer.current.capabilities,
                              link: ->(id) { file_url_for(id) })
        end
      end
    end

    # Photos: every image-role row in the folder plus every live entry photo, deduped, in name
    # order. An entry photo usually lives OUTSIDE the folder (the upload door puts it wherever the
    # user pointed it), which is why it is fetched from `page_nodes` rather than the listing.
    # THE DEFINITION MOVED TO Maker::ProjectPhotos when the PRIVATE project page grew the same
    # gallery (stage 4, S4-1): two pages showing "this project's photos" must not drift about what
    # counts as one, so this reads the shared answer rather than keeping a second copy of it.
    def photo_rows
      # MINUS WHATEVER SITS UNDER A HIDDEN FOLDER, ON THE VISITOR'S PAGE ONLY (folder panels,
      # decision 2). The Photos panel cannot be hidden (`ALWAYS`), so without this a folder the
      # maker hid would keep showing its pictures one panel down. The maker's own page keeps every
      # photo, since hiding a panel there arranges the page rather than publishing it. An entry
      # photo is asked the same question as a folder image. One that lives outside the folder is
      # never under a hidden one, so it stays.
      @photo_rows ||= Maker::ProjectPhotos.rows(listing:, entries:, page_nodes:).reject { |row| hidden?(row.node) }
    end

    # THE COVER, PERMITTED (stage 4, S4-5; story 5.7). `Maker::Project#cover_node_id` derives one
    # from the attachments when none is chosen, and a CHOSEN cover is a raw column nothing
    # validates (ProjectsController#project_params) — so it can name a node outside the folder, a
    # tombstone, or a file this project has no claim on at all. `permits?` is the ONE answer to "is
    # this file public" and it answers here too: an unpermitted cover renders NOTHING rather than
    # becoming the page's largest picture. nil is a real answer, hence `defined?` and not `||=`.
    def cover_node
      return @cover_node if defined?(@cover_node)

      id = project.cover_node_id
      node = id && owner.nodes.present.find_by(node_id: id)
      # SHOWN, NOT MERELY PERMITTED (folder panels, decision 2): the hero is the page's largest
      # picture, and a hidden folder's image as the hero is the Photos leak in its biggest frame.
      # `#shown?` decides that by ancestry, so a cover past FILE_CAP is refused like any other.
      @cover_node = (node if node && shown?(node))
    end

    # Live nodes for everything the page shows that is not in the listing: entry photos and BOM
    # file targets. ONE query, regardless of how many of either there are.
    def page_nodes
      @page_nodes ||= begin
        ids = entries.flat_map { |e| e.file_attachments.map(&:node_id) } + bom_lines.filter_map(&:node_id) +
              # RELEASE FILES JOIN THIS UNION, AND THE PANEL CANNOT RENDER A LINK WITHOUT IT
              # (stage 3, S3-5). public/projects/_releases resolves each row's node HERE and only
              # then asks `permits?`, so a release file left out of this list is not merely
              # un-batched: MEASURED, every download link disappears and a file sitting in the
              # folder reads "no longer available", while page_query_budget_test.rb stays green,
              # because a check that is never reached costs no queries. What the index buys on TOP
              # of that is the batching -- `permits?` answers `visible_entry?` from
              # `visible_page_ids` for a node it finds here and with its own one-row query for one
              # it does not, the per-line cost the BOM's own comment records above.
              releases.flat_map { |r| r.files.map(&:node_id) } +
              # AN IMAGE BLOCK'S PICTURE JOINS FOR THE SAME REASON A RELEASE FILE DOES (2026-09-09,
              # content blocks): `block_image_node` resolves the node HERE and only then asks
              # `permits?`, so a block left out of this list renders nothing at all — and the file
              # is usually IN the listing, which is exactly what makes the omission invisible until
              # someone looks at the page.
              blocks.filter_map(&:node_id)
        ids.empty? ? {} : owner.nodes.present.where(node_id: ids.uniq).index_by(&:node_id)
      end
    end

    # WHICH OF `page_nodes` ARE VISIBLE ENTRIES, IN ONE QUERY FOR THE WHOLE PAGE.
    # `public/projects/_bom` asks `permits?` for every design-file line — that is how it chooses
    # between a link and plain text — and each of those nodes came from `page_nodes`, so the
    # per-node `exists?` in `visible_entry?` below was one query PER LINE: measured at 18 queries
    # for the small seed against 22 for the large one, exactly the four extra file lines
    # (test/integration/web/page_query_budget_test.rb, "public projects#show").
    #
    # A CACHE, NOT A SECOND AUTHORITY. It asks the SAME `owner.nodes.visible_entries` scope, over
    # ids this page already holds, and a node outside that population still asks for itself — which
    # is what keeps `deliverable!` right for a file past FILE_CAP that is deliberately not on the
    # page. The file route never reaches this: nothing on it loads `page_nodes`, so a download still
    # costs the single existence check it always did rather than the build log and the BOM as well.
    def visible_page_ids
      @visible_page_ids ||= owner.nodes.visible_entries.where(node_id: page_nodes.keys).pluck(:node_id).to_set
    end

    # THE THUMBNAIL MAP IS WHAT THIS PAGE PAINTS, one term per painting surface, the hero first
    # (2026-10-19, F-S14-1):
    #   * the hero                                → `#cover_node`
    #   * the Files panel and every folder panel  → `#shown_rows` (the Photos panel's folder images too)
    #   * the build log and the Photos panel      → the entry photos still live, out of `page_nodes`
    #   * an image block                          → `#block_image_node`
    # It was `listing.node_ids + page_nodes.keys`: everything the page might REFERENCE. That was wrong
    # in both directions. `ThumbnailMap.for` backfills on an anonymous GET, so it queued renders for
    # backups, for a hidden folder's files and for BOM and release targets, none of which this page
    # draws. And a cover attached from outside the folder was in neither source, so that hero never
    # showed a ready thumbnail. The build log paints its photos wherever they live, because an entry
    # is authored, so that term is not filtered by folder. Whether a PANEL is hidden is not asked
    # here, so a hidden build log's photos and a hidden block's picture stay in the map. Both are
    # permitted, and there are few of them. The order is the backfill budget's walk order
    # (Maker::Previews::ThumbnailMap), so the hero renders first. It is all in memory over rows the
    # page already loaded, and `.for` costs the same queries for one more id.
    #
    # READY THUMBNAILS ONLY on a public page — `ThumbnailMap.for` still backfills, which is what
    # makes a first visit start the renders, but nothing here polls: `files/_thumb` renders the
    # spinner markup for a pending row, and a spinner turns only inside a poll cell (components.css),
    # so with none here it reads as a static badge rather than a promise the page will never keep
    # (files-preview.md).
    def thumbs
      @thumbs ||= Maker::Previews::ThumbnailMap.for(
        owner,
        [ cover_node&.node_id ] + shown_rows.map(&:node_id) +
          entries.flat_map(&:file_attachments).map(&:node_id).select { |id| page_nodes.key?(id) } +
          blocks.select { |block| block.kind == "image" }.filter_map { |block| block_image_node(block)&.node_id }
      )
    end

    # THE ONE PERMISSION CHECK. A live, visible FILE node that either descends from the project
    # folder or is attached to the project / one of its entries. Directories, tombstones, dot-files
    # and OS clutter never deliver — `Node.visible_entries` is the display rule the folder listing
    # already applies, asked here so a `.env` sitting beside the models is not a public download.
    #
    # `Array(...)` AROUND `ancestors_of`: it answers an array ENDING IN nil for a resolvable chain
    # and plain `nil` for a broken one, so an unguarded `#include?` is a NoMethodError on exactly
    # the row a corrupt catalog produces. A nil `parent_node_id` (a node at the library root) walks
    # to `[nil]` and correctly matches no folder.
    #
    # `listing.available?` GATES THE TWO ANCESTRY ARMS AND ONLY THOSE. A project with no folder
    # (`folder_node_id` is nullable and publishing requires only a handle) or whose folder was
    # deleted still owns its attachments — an entry photo living elsewhere in the library is the
    # project's by the attachment row, and the page renders it — so the attachment arm answers
    # regardless. The gate must stay on the ancestry arms: `Array(ancestors_of(x)).include?(nil)`
    # is TRUE for every resolvable chain, so with a nil `folder_node_id` an ungated ancestry arm
    # would permit EVERY file in the owner's library (probed by S3-4's review, not reasoned).
    #
    # NOTHING BENEATH A `.git` MARKER DELIVERS. The listing never descends into one, but this walk
    # is the LibraryTree's, which indexes every live dir — and on chunk_remote the catalog mirrors
    # whatever a client synced, so `.git/config` has a plain name, sits under the folder, and would
    # pass both checks above. Share and s3 never index those keys; this is the one door that must
    # not depend on that.
    def permits?(node)
      return false unless node && node.kind == "file" && !node.deleted
      return false unless visible_entry?(node)

      self.class.claimed?(node, tree:, folder_node_id: project.folder_node_id, attached: attached_ids)
    end

    # THE FOLDER-OR-ATTACHED RULE, WRITTEN ONCE, for `permits?` (one node against this project) and
    # for `permitted_cover_ids` (one cover per project across a whole page). Stage 4, S4-5's review
    # found the two surfaces disagreeing: the project page's hero asked `permits?` and refused a
    # cover chosen from outside the folder, while /u/:handle's card asked nobody and rendered it. A
    # second spelling of this rule is how that happens again.
    #
    # The parent itself first, then its ancestors: `ancestors_of` may or may not include its
    # argument, and a file DIRECTLY inside `.git/` must fail the name check either way. The folder
    # arm applies only when the project HAS a folder the tree knows (`ProjectFolderListing#available?`
    # is the same two checks); a project with none falls to its attachments alone.
    def self.claimed?(node, tree:, folder_node_id:, attached:)
      if folder_node_id && tree.dir?(folder_node_id)
        lineage = [ node.parent_node_id, *Array(tree.ancestors_of(node.parent_node_id)) ].compact.uniq
        return false if lineage.any? { |id| tree.name_of(id) == Library::RepoMetadata::DIR_NAME }
        return true if lineage.include?(folder_node_id)
      end

      attached.include?(node.node_id)
    end

    # THE DEPTH-ONE FOLDER A DIR SITS UNDER, or the dir itself when it is one. nil at the folder's
    # own root, outside the folder, or when the walk breaks before it reaches the folder. Depth one is
    # where a panel is (spec decision 3), so this is the folder whose `folder:` key hides everything
    # beneath it (`#hidden_dir?`).
    #
    # IT WALKS UP FROM THE DIR AND STOPS AT THE PROJECT FOLDER, so nothing ABOVE the folder takes part
    # (review of #430). `ancestors_of` is the wrong walk here: it answers nil for the whole chain when
    # any ancestor is missing. A tombstoned `Projects/` above a live project folder therefore read
    # every hidden folder as shown, while the listing, which walks DOWN from the folder, still held
    # their files for the bundle, the Photos and Schematics panels and the repo cards
    # (public_project_test.rb). A break BELOW the folder still reads as not hidden: a missing dir, or a
    # cycle, which the `seen` set stops. A file there is neither listed nor permitted by ancestry, so
    # only an attachment can show it, and `permits?` still gates that.
    #
    # It is a class method beside `claimed?` so that a caller with no listing in hand can ask it too.
    # `permitted_cover_ids` would be that caller, and does not ask it yet (see the note there).
    def self.depth_one_dir(dir_id, tree:, folder_node_id:)
      return nil unless folder_node_id

      seen = Set.new
      below = nil
      current = dir_id
      while current && seen.add?(current)
        return below if current == folder_node_id

        below = current
        current = tree.parent_of(current)
      end
      nil
    end

    # EVERY PROJECT'S PERMITTED COVER ON ONE OWNER'S PAGE, IN A CONSTANT NUMBER OF QUERIES. One
    # PublicProject per card would ask `cover_node` at a tree, a listing and two attachment queries
    # PER PROJECT — the growth /u/:handle's budget forbids — so the page asks once: the cover nodes
    # in one query, their visibility in one, one tree for the owner, and the attachments of every
    # project and every build-log entry in two more (the entry query runs even when there are no
    # entries, so the count is the same for a maker with one project and one with fifty). Returns
    # `project.id => node_id` for the covers `claimed?` admits, and nothing for the rest — the view
    # renders the placeholder for an absent key, never the picture.
    #
    # PERMITTED, NOT SHOWN: THIS DOES NOT READ THE LAYOUT, AND THAT IS KNOWN (2026-10-19, F-S14-1). A
    # cover under a folder the maker hid still shows on this card, while the project page's hero
    # (`#cover_node`, which asks `#shown?`) refuses it. Closing that changes an existing surface, so
    # it is left for the owner to decide, and this change's arc records the question. The fix is one
    # `next if` here: ask `.depth_one_dir` of the cover's parent, then ask the project's own
    # `panel_layout(folders:)`, built over that one folder, whether its key is hidden. Both inputs
    # are already in hand, so it adds no query.
    def self.permitted_cover_ids(owner, projects)
      wanted = projects.filter_map { |p| [ p.id, p.cover_node_id ] if p.cover_node_id }.to_h
      return {} if wanted.empty?

      ids = wanted.values.uniq
      nodes = owner.nodes.present.where(node_id: ids, kind: "file").index_by(&:node_id)
      visible = owner.nodes.visible_entries.where(node_id: ids).pluck(:node_id).to_set
      tree = Maker::LibraryTree.new(owner)
      attached = Hash.new { |h, k| h[k] = Set.new }
      Maker::FileAttachment.where(user: owner, attachable_type: "Maker::Project", attachable_id: wanted.keys, node_id: ids)
                           .pluck(:attachable_id, :node_id).each { |pid, nid| attached[pid] << nid }
      entry_project = Maker::BuildLogEntry.where(project_id: wanted.keys).pluck(:id, :project_id).to_h
      Maker::FileAttachment.where(user: owner, attachable_type: "Maker::BuildLogEntry", attachable_id: entry_project.keys, node_id: ids)
                           .pluck(:attachable_id, :node_id).each { |eid, nid| attached[entry_project[eid]] << nid }

      projects.each_with_object({}) do |project, out|
        node = nodes[wanted[project.id]]
        next unless node && visible.include?(node.node_id)

        out[project.id] = node.node_id if claimed?(node, tree:, folder_node_id: project.folder_node_id,
                                                         attached: attached[project.id])
      end
    end

    # The file route's whole authorization: resolve in the OWNER's library, then ask `permits?`.
    # A refusal and a nonexistent node are the SAME answer on purpose — a public visitor must not
    # be able to tell "this project has a private file with that id" from "no such file".
    def deliverable!(node_id)
      node = owner.nodes.find_by(node_id:)
      raise ActiveRecord::RecordNotFound unless permits?(node)

      node
    end

    # `filename:` rides the route's optional glob so the URL's own trailing extension is the real
    # one — KiCanvas reads a file's type off the URL, not the bytes (S3-2's rule). `download: true`
    # adds the ?download=1 the delivery concern turns into an attachment.
    def file_url_for(node_id, filename: nil, download: false)
      params = link_params
      params = params.merge(download: 1) if download
      Rails.application.routes.url_helpers.public_file_path(handle, project.slug, node_id, filename:, **params)
    end

    # THE VIEW PAGE'S URL, beside #file_url_for's byte URL (stage 4, S4-5). Same link_params, same
    # reason: on an unlisted project the token IS the credential and a link without it is a 404.
    # SEPARATE FROM #file_url_for RATHER THAN A FLAG ON IT, because the two answer different
    # questions and one of them is load-bearing elsewhere — Maker::Readme resolves a README's `<a>`
    # AND its `<img src>` through #file_url_for, so a flag defaulting the wrong way would point
    # every inline README image at an HTML page.
    def view_url_for(node_id)
      Rails.application.routes.url_helpers.public_file_view_path(handle, project.slug, node_id,
                                                                 **link_params)
    end

    # A DERIVED ASSET'S URL — the thumbnail by default, or the Measure payload — beside the byte and
    # view URLs above (hardening, 2026-09-08; tinkerex#278). It names Public::FilesController#preview,
    # which asks `deliverable!` and then redirects to a service URL that expires, so the picture of a
    # file dies with the project's publication instead of outliving it the way `url_for(asset)` did.
    # Same link_params, same reason as its two siblings.
    def preview_url_for(node_id, kind: "thumbnail")
      Rails.application.routes.url_helpers.public_file_preview_path(handle, project.slug, node_id, kind,
                                                                    **link_params)
    end

    # WHETHER ONE PANEL HAS A PUBLIC FACE ON THIS PROJECT (hardening, 2026-09-08; tinkerex#283) — the
    # same layout `visible_panels` renders from, asked one key at a time by the documents that ride
    # beside the page: the feed (build_log, releases), the bundle manifest (attachments, bom) and the
    # BOM CSV (bom). A panel the maker hid is hidden from those too, or it is one click away from the
    # page that hides it.
    def panel_visible?(key) = layout.visible?(key.to_s)

    # ONE LAYER'S FETCH URL FOR A .gbrjob's BOARD, filtered by THIS project's permission (stage 4,
    # S4-5). The sibling walk itself is FilePreview's, shared with the maker's own page; what is
    # public here is only the URL builder, which answers nil for a sibling the project does not
    # permit — so a job file sitting next to a layer that is somehow outside the folder renders the
    # board WITHOUT it rather than handing a visitor a URL the byte route would refuse. `permits?`
    # is the same call #deliverable! makes, which is what keeps the two from disagreeing.
    def layer_url_for(node)
      permits?(node) ? file_url_for(node.node_id, filename: node.name) : nil
    end

    private

    # THE ONE SECTION WALK, for `#sections` (the whole folder) and `#folder_sections` (one panel).
    # Depth-first, a dir before its children, dirs with no files of their own skipped — the order
    # both readers publish.
    #
    # FOLDER-RELATIVE NAMES: `dir.path` is the LIBRARY path ("Projects/desk-lamp/models/deep"),
    # which is the owner's filing, not the visitor's vocabulary — seen live on the dev server as a
    # column of "Projects/desk-lamp/…" headings. The caller says what to strip, which is the only
    # difference between the two: the project folder for `#sections`, the panel's own dir for
    # `#folder_sections`.
    def sections_under(dirs, prefix:)
      dirs.flat_map do |dir|
        (dir.files.any? ? [ [ dir.path.delete_prefix(prefix), dir.files ] ] : []) +
          sections_under(dir.children, prefix:)
      end
    end

    # THE FEED'S OWN TWO READERS, extracted only so `#feed_items` can put each behind its panel gate
    # on one line (hardening, 2026-09-08; tinkerex#283). Each is a RELATION and each stays lazy: the
    # gate above decides whether it is ever loaded, so a hidden panel costs no query rather than
    # loading fifty rows and discarding them.
    def feed_entries
      project.build_log_entries.includes(:rich_text_body)
             .reorder(logged_at: :desc, id: :desc).limit(FEED_CAP)
    end

    def feed_releases = project.releases.includes(:files, :rich_text_notes).limit(FEED_CAP)

    # Is this file under a folder the maker hid? A file asks about the dir it sits in.
    def hidden?(node) = hidden_dir?(node.parent_node_id)

    # IS THIS DIRECTORY UNDER (OR ITSELF) A DEPTH-ONE FOLDER WHOSE PANEL THE MAKER HID? Asked of the
    # saved layout, the one `visible_panels` renders from. The layout's vocabulary is this page's own
    # depth-one folders, so no other key can be hidden. Memoised per dir, because the rows of one
    # folder share the answer. `listing.folder_id` and not the raw column: it is nil unless the tree
    # knows the folder, which is the gate `claimed?` applies.
    def hidden_dir?(dir_id)
      @hidden_dirs ||= {}
      return @hidden_dirs[dir_id] if @hidden_dirs.key?(dir_id)

      depth_one = self.class.depth_one_dir(dir_id, tree:, folder_node_id: listing.folder_id)
      @hidden_dirs[dir_id] = !depth_one.nil? && layout.hidden?(Maker::ProjectKind.folder_key(depth_one))
    end

    # `#shown_rows`' own row for one node_id, or nil. Built once, never per lookup, the same shape
    # as `ProjectFolderListing#row_for`.
    def shown_row(node_id) = (@shown_rows_by_id ||= shown_rows.index_by(&:node_id))[node_id]

    # FOLDER-RELATIVE, from the row's OWN `section` — the display path the listing computed while
    # it built the tree, never re-derived by walking node_id chains a second time (that class's own
    # rule). "" is the folder's root, so a README lands at the top of the zip as `README.md`.
    def bundle_path(row)
      section = row.section.to_s
      section.empty? ? row.node.name : "#{section}/#{row.node.name}"
    end

    # `visible_entries` for ONE node — from the page's primed set when it is one of the page's own
    # nodes, and from its own one-row query otherwise. `@page_nodes` rather than `page_nodes`
    # deliberately: reading the ivar asks "has the page already loaded these?" WITHOUT loading them,
    # which is what keeps the file route at one query (see `visible_page_ids`).
    def visible_entry?(node)
      return visible_page_ids.include?(node.node_id) if @page_nodes&.key?(node.node_id)

      owner.nodes.visible_entries.where(node_id: node.node_id).exists?
    end

    # Every node attached to the project itself or to one of its build-log entries, in TWO queries
    # regardless of how many entries there are — never one per entry. The second is expressed as a
    # subselect on the entries rather than loading their ids, so it stays one statement.
    def attached_ids
      @attached_ids ||= (project.file_attachments.pluck(:node_id) +
                         Maker::FileAttachment.where(user: owner, attachable_type: "Maker::BuildLogEntry",
                                                     attachable_id: project.build_log_entries.select(:id)).pluck(:node_id)).to_set
    end

    def flatten_dirs(dirs) = dirs.flat_map { |d| [ d ] + flatten_dirs(d.children) }
  end
end
