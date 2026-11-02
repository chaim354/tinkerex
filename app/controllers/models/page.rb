module Models
  # THE MODEL PAGE'S ASSEMBLY, shared by the two controllers that render it: ModelsController#show,
  # and Models::PrintRunsController when it refuses a print and re-renders the page with the
  # composer open and what was typed (UX audit 2026-11-01, B3) rather than redirecting it away.
  # Moved here verbatim from ModelsController (where the history in these comments happened), so the
  # two doors cannot drift about what the page needs; both set @model before calling in.
  module Page
    extend ActiveSupport::Concern

    included do
      # The page's ONE live-node index — `#show` renders attachments by role, a cover hero and a 3D
      # switcher off the same rows, and every one of them must skip a tombstone.
      include PageNodes
      # The pane's viewer: the file page's own chain (files/_viewer), fed by the same one method, so the
      # two pages cannot disagree about which viewer a file gets.
      include FileViewer
    end

    private

    # The pane: the live attachments, which pane opens (`requested` is `?file=`), and that pane's data.
    def load_model_stage(requested)
      # A FILE DELETED FROM THE LIBRARY LEAVES THIS MODEL TOO, on exactly the terms ProjectsController
      # #show has always used — `Library::Reconciler` tombstones rather than destroys, so the
      # attachment row outlives the file and every surface below has to skip it. It did not: this
      # action built the index and then handed `@by_role` and `@cover_att` the UNFILTERED list, so a
      # tombstoned attachment painted a broken gallery <img>, an <iframe> whose src 302s to the user's
      # whole Files listing under a heading reading "Instructions", and a hero cell polling a node
      # /files/thumbnails omits — a spinner that resolves never. The cover id joins the union because
      # it need not be an attachment at all.
      all_attachments = @model.file_attachments.order(:position).to_a
      @page_nodes = live_nodes_for(all_attachments.map(&:node_id) + [ @model.cover_node_id ])
      @attachments, missing = all_attachments.partition { |a| @page_nodes.key?(a.node_id) }
      # NOT SILENT, same sentence and same reason as the project panel's: a user who deleted a file by
      # accident and watched this page change otherwise has no thread to pull.
      @missing_attachment_count = missing.size
      @stage = stage_for(requested)
      # THE DETAILS DATA IS DETAILS' ALONE: the hero's covers, the 3D switcher's manifests, the print log
      # and its composer choices render only in that pane, so a page opening on a file (every model
      # with instructions, by default) pays none of it.
      if @stage == :details
        load_details
      else
        @viewer = viewer_state_for(@stage)
      end
    end

    # The list on the left. A frame request (the pane alone) skips it.
    def load_model_files
      # The model's files as a folder TREE (preserves the imported zip's structure) for the detail
      # page, instead of a flat role-grouped list.
      #
      # A MODEL WITH NO FOLDER FALLS BACK TO ITS ATTACHMENTS, AND THE PANEL IS A LIE WITHOUT IT. This
      # walked `folder_node_id`'s subtree and answered `[]` otherwise -- so a model holding live
      # attachments and no folder rendered "Files (0) / No files yet." Maker::ModelIntake makes that
      # the ordinary case rather than an edge: a ONE-FILE auto model is keyed on a FILE node, so it
      # has no folder by construction, and roughly half of what the sweep creates is one of those.
      # It was reachable before the sweep too -- `ensure_library_folder!` is best-effort at import
      # time and the controller rescues it -- just rarely.
      #
      # Found by opening the page, not by a test: every assertion here reads the tree the fixture's
      # folder produced, so none of them could see a model that has no folder at all.
      @file_tree  = file_tree_for_model
      @file_count = count_files(@file_tree)
    end

    # WHICH PANE THE PAGE OPENS ON: `?file=details`, `?file=<one of this model's LIVE attachments>`,
    # or — for anything else, a foreign node, a tombstone, a folder, garbage, a non-string — the
    # default, never an error: the first live instructions attachment by position, else Details. The
    # tree on the left lists a subset of the live attachments (file_tree_for_model), and the gallery
    # can name an image outside the folder, so the attachments are the set to validate against.
    def stage_for(requested)
      return :details if requested == "details"

      live = @attachments.index_by(&:node_id)
      return @page_nodes[requested] if requested.is_a?(String) && live.key?(requested)

      first = @attachments.find { |a| a.role == "instructions" }
      first ? @page_nodes[first.node_id] : :details
    end

    # What the Details pane and the hero read: by-role groups, the cover, the covers map, the 3D
    # switcher's files, the print log. Everything that was #show's body below the attachments.
    def load_details
      @by_role = @attachments.group_by(&:role)
      @cover_att = @attachments.find { |a| a.node_id == @model.cover_node_id }
      # COVER ONLY, DELIBERATELY NOT THE UNION. This page paints exactly ONE thumbnail — the hero;
      # `_file_tree` is plain link_to's — so merging the way projects#show does would save no query
      # (there is no second call here) while spending ThumbnailMap::BACKFILL_LIMIT on up to 100 rows
      # and 100 jobs per view for images nothing renders. Pinned as a budget in page_nodes_test.rb.
      # PLUS THE GALLERY'S NON-INLINE IMAGES (tinkerex#285): a .heic photo renders as a thumbnail cell
      # there, not as bytes, and the cell reads this map. Bounded by the model's own photos.
      # (The pane, when it shows a file instead of Details, asks FileViewer#current_thumbnail for that
      # ONE file, the file page's own door — never this map, so this argument is unchanged by it.)
      gallery = Array(@by_role["image"]).filter_map do |a|
        a.node_id unless Maker::FileAttachment.inline_image?(@page_nodes[a.node_id]&.name.to_s)
      end
      @covers = Maker::Previews::ThumbnailMap.for(current_user, ([ @model.cover_node_id ] + gallery).compact.uniq)
      # The model's browser-viewable 3D files, in position order, for the hero's "View in 3D"
      # switcher. Default selection = the cover file if it's viewable, else the first one.
      #
      # FILTERED BY EXTENSION, NOT BY ROLE, and the two are genuinely different questions: `.fcstd`
      # is `cad_source` and IS viewable, `.f3d`/`.sldprt` are `cad_source` and are not, and `.svg` is
      # `vector` and is deliberately left out (§14d — Maker::FileAttachment::VIEWABLE_3D_EXTS says
      # why for each). This read the SAME literal `%w[stl 3mf obj]` that FilesController carried
      # until 2026-09-06; one constant now, so the file page and this page cannot drift about which
      # of a model's files open in the viewer.
      # THE MANIFEST IS PER FILE, WHICH IS WHY IT IS BUILT HERE AND NOT ON THE ELEMENT: the switcher
      # swaps one model for another, so the slicer colours and the unit factor have to travel on each
      # `<option>` (§14d — modelviewer_controller.js reads them beside `url`/`format`). `for` refuses
      # by name first, so the non-3MF entries cost nothing; a 3MF costs ONE bounded port read (one
      # query on share; on chunk_remote a chunk download through the sync server) the first time this
      # model is viewed and nothing after, cached by content token. THAT COST IS PER 3MF ATTACHMENT,
      # AND page_query_budget_test.rb DOES NOT SEE IT: its growing fixture is all `.stl`, which `for`
      # refuses by name, so the constancy it asserts is over files that never reach a read. A model
      # holding N 3MFs pays N reads on a cold cache — the same per-file shape the page's thumbnails
      # already have, stated here rather than hidden behind a guard that cannot fail for it.
      @viewable_3d = @attachments.filter_map do |a|
        node = @page_nodes[a.node_id]
        ext = File.extname(node.name).downcase.delete(".")
        next unless Maker::FileAttachment::VIEWABLE_3D_EXTS.include?(ext)
        { node_id: a.node_id, name: node.name, format: ext,
          manifest: Maker::ThreeMfManifest.for(user: current_user, node:) }
      end
      @viewable_3d_default = @viewable_3d.find { |f| f[:node_id] == @model.cover_node_id } || @viewable_3d.first
      @print_runs = @model.print_runs.reorder(printed_on: :desc, id: :desc).to_a
      @printers, @materials = Maker::PrintRun.composer_choices(current_user)
      # THE "IN PROJECTS" ROW (2026-10-21, attach-a-model spec), Details' like the rest of this list —
      # the folder strip renders the same partial off the same object, so the two offer the same projects.
      @project_choices = Maker::ModelProjectChoices.for(current_user, @model)
    end

    # Fetch the whole present subtree under a folder node (BFS — one query per depth level, not per
    # node), then nest into [{dir:, children:[...]}, {file:}] with dirs first, alphabetical. Scoped
    # to current_user's nodes, so it can never reach another user's tree.
    # The model's folder subtree, or -- when it has no folder -- its own live attachments, flat.
    # See the comment at the assignment for why the fallback is the ordinary case, not an edge.
    def file_tree_for_model
      return build_file_tree(@model.folder_node_id) if @model.folder_node_id.present?

      @attachments.map { |a| { file: @page_nodes[a.node_id] } }
    end

    # THE FOLDER'S SHAPE, THE MODEL'S FILES. Walking the subtree gives the nesting an imported zip
    # had; `@attachments` says which of those files the model actually claims, and since 2026-09-02
    # those are NOT the same set — Maker::ModelIntake stopped giving a folder model every file
    # beneath it (§14k), so the unfiltered walk went on listing the .dxf drawings the catalog had
    # just let go, under a heading counting them.
    #
    # IT READS `@attachments`, ALREADY PARTITIONED AGAINST THE LIVE-NODE INDEX, so this adds no query
    # (the page's budget is asserted constant in N — §14e) and inherits PageNodes' tombstone rule for
    # free rather than re-deriving it. Its own walk is `.present`, so a tombstone is absent from both
    # sides and cannot come back through this door.
    def build_file_tree(root_node_id)
      collected = []
      frontier  = [ root_node_id ]
      until frontier.empty?
        kids = current_user.nodes.present.where(parent_node_id: frontier).to_a
        collected.concat(kids)
        frontier = kids.reject(&:file?).map(&:node_id)
      end
      nest_tree(root_node_id, collected.group_by(&:parent_node_id), @attachments.map(&:node_id).to_set)
    end

    # A DIRECTORY WITH NOTHING SURVIVING UNDER IT GOES TOO. Keeping it renders a folder that opens
    # onto nothing — and `docs/` holding one unclaimed `names.txt` is the ordinary case, not an edge.
    # The recursion is what makes that hold at depth: an empty branch collapses from the leaves up.
    def nest_tree(parent_node_id, by_parent, claimed)
      (by_parent[parent_node_id] || [])
        .sort_by { |n| [ n.file? ? 1 : 0, n.name.to_s.downcase ] }
        .filter_map do |n|
          if n.file?
            { file: n } if claimed.include?(n.node_id)
          else
            children = nest_tree(n.node_id, by_parent, claimed)
            { dir: n, children: } if children.any?
          end
        end
    end

    def count_files(tree)
      tree.sum { |item| item[:file] ? 1 : count_files(item[:children]) }
    end
  end
end
