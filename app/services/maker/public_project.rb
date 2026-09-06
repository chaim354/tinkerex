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

    # [[section_name, rows]] — the folder's own loose files first (under the project's name), then
    # every subfolder in tree order by its path. Backups are left out: a public page is not a
    # recovery tool, and a LightBurn rescue copy is noise to everyone but the maker.
    # Rows are Maker::ProjectFolderListing::Row.
    def sections
      @sections ||= begin
        out = []
        out << [ project.name, listing.loose ] if listing.loose.any?
        # FOLDER-RELATIVE NAMES: `dir.path` is the LIBRARY path ("Projects/desk-lamp/models/deep"),
        # which is the owner's filing, not the visitor's vocabulary -- seen live on the dev server
        # as a column of "Projects/desk-lamp/…" headings. Strip the folder's own path once.
        prefix = "#{listing.path}/"
        walk = lambda do |dirs|
          dirs.each do |dir|
            out << [ dir.path.delete_prefix(prefix), dir.files ] if dir.files.any?
            walk.call(dir.children)
          end
        end
        walk.call(listing.tree)
        out
      end
    end

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

    def entries
      @entries ||= project.build_log_entries.includes(:file_attachments, :rich_text_body)
                          .reorder(logged_at: :desc).to_a
    end

    def bom_lines
      @bom_lines ||= (bom = project.current_bom) ? bom.lines.includes(:inventory_item).to_a : []
    end

    def connections = @connections ||= project.connections.to_a

    # Every KiCad schematic/board anywhere in the folder, name-ordered — the private page's own
    # rule (projects/_schematics.html.erb), reading the SAME extension list so the two surfaces can
    # never name a different set of formats.
    def kicad_rows
      @kicad_rows ||= listing.all_rows
                             .select { |row| FilesController::KICANVAS_EXTS.include?(File.extname(row.node.name).delete(".").downcase) }
                             .sort_by { |row| row.node.name }
    end

    # Repo cards for every working tree in the folder, keyed by dir node_id (the private page's
    # collect_repo_dirs shape). ONE batched query for every repo on the page, never one per repo —
    # the same argument ProjectsController#show's own comment makes. The card's README links are
    # resolved through THIS page's file route, not `/files/:id`, which a visitor cannot open.
    def repo_cards
      @repo_cards ||= begin
        dirs = flatten_dirs(listing.tree).select(&:repo?)
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
    def photo_rows
      @photo_rows ||= (listing.all_rows.select { |r| r.role == "image" } +
                       entries.flat_map(&:file_attachments).filter_map { |a| page_nodes[a.node_id] }
                              .map { |node| Maker::ProjectFolderListing::Row.new(node:, attachment: nil, linked: true, section: nil) })
                      .uniq(&:node_id).sort_by { |r| r.node.name }
    end

    # Live nodes for everything the page shows that is not in the listing: entry photos and BOM
    # file targets. ONE query, regardless of how many of either there are.
    def page_nodes
      @page_nodes ||= begin
        ids = entries.flat_map { |e| e.file_attachments.map(&:node_id) } + bom_lines.filter_map(&:node_id)
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

    # READY THUMBNAILS ONLY on a public page — `ThumbnailMap.for` still backfills, which is what
    # makes a first visit start the renders, but nothing here polls: `files/_thumb` renders the
    # spinner markup for a pending row and `pages/public.css` stops its animation, so it reads as a
    # static badge rather than a promise the page will never keep (files-preview.md).
    def thumbs
      @thumbs ||= Maker::Previews::ThumbnailMap.for(owner, listing.node_ids + page_nodes.keys)
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

      if listing.available?
        # The parent itself first, then its ancestors: `ancestors_of` may or may not include its
        # argument, and a file DIRECTLY inside `.git/` must fail the name check either way.
        lineage = [ node.parent_node_id, *Array(tree.ancestors_of(node.parent_node_id)) ].compact.uniq
        return false if lineage.any? { |id| tree.name_of(id) == Library::RepoMetadata::DIR_NAME }
        return true if lineage.include?(project.folder_node_id)
      end

      attached_ids.include?(node.node_id)
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

    private

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
