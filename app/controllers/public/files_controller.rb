module Public
  # GET /u/:handle/:slug/files/:id(/*filename) — the BYTES of one file a published project shows.
  # GET /u/:handle/:slug/files/:id/view        — the PAGE, with the same viewers the maker gets.
  # GET /u/:handle/:slug/files/:id/geometry    — the Measure payload's location, report-only.
  #
  # THE SAME DELIVERY SWITCH AS THE PRIVATE PAGE (`FileDelivery`, CLAUDE.md §14a's three
  # mechanisms), pointed at a node THE PROJECT PERMITS rather than one the session owns. The
  # permission is `Maker::PublicProject#deliverable!` — the same object the page asked, which is
  # what stops a link on the page from 404ing and, more importantly, stops this route from
  # delivering something the page would never have linked.
  #
  # THE OWNER, NOT THE VISITOR, IS WHO THE PORT IS ASKED IN THE NAME OF: a visitor has no library.
  #
  # THE PAGE AND THE BYTES ASK ONE OBJECT (stage 4, S4-5). `#view` permits through the same
  # `Maker::PublicProject#deliverable!` `#show` does — not a second check that agrees today — so a
  # page that renders is a page whose viewer's fetch will succeed, and a node with no page has no
  # bytes either.
  #
  # NO SESSION, NO CAPABILITY GATE, NO EDITING. The viewer partials take every URL as a strict local
  # (app/views/files/viewers/), which is what lets this controller hand them public routes without
  # any of them knowing which page they are on; `editable: false` is what keeps `codeview` and not
  # `editor` on a visitor's page, and `save: false` is what keeps the Measure bar's two library
  # saves off a page with nowhere to save to.
  class FilesController < BaseController
    include FileDelivery
    include FilePreview

    def show
      pub = public_project!
      node = pub.deliverable!(params[:id])
      deliver_file(pub.owner, node, download: params[:download].present?)
    end

    def view
      @pub = public_project!
      @node = @pub.deliverable!(params[:id])
      owner = @pub.owner
      @info = FileLayer.current.stat(owner, node_id: @node.node_id)
      @kind = preview_kind(@node.name)
      # ONE MAP FOR ONE NODE, not the project page's whole listing: `Maker::PublicProject#thumbs`
      # covers `listing.node_ids + page_nodes.keys`, and loading `page_nodes` here would pull the
      # build log, the BOM and every release onto a page that shows one file. `.for` backfills, which
      # is what makes a poster appear on a file nobody has opened before — the same write-on-GET the
      # public project page already does.
      @thumbnail = Maker::Previews::ThumbnailMap.for(owner, [ @node.node_id ]).thumb(@node.node_id)
      # A ZIP IS A BOARD WHEN ITS CONTENTS SAY SO, and a 3MF's colours/unit come from its manifest —
      # both are ONE bounded port read in the OWNER's name, judged on the catalog's `size` column
      # BEFORE any read and cached by content token, nil included. That bound is what makes them safe
      # on a route a stranger can issue.
      @gerber_archive = Maker::GerberArchive.archive?(@node.name) &&
                        Maker::GerberArchive.for(user: owner, node: @node)
      @kind = :gerber if @gerber_archive
      @viewer_manifest = Maker::ThreeMfManifest.for(user: owner, node: @node)
      # THE LAYER LIST IS THE SHARED WALK'S, AND ONLY THE URL BUILDER IS PUBLIC. `layer_url_for`
      # answers nil for a sibling this project does not permit, which `gerber_layers_for`'s
      # `filter_map` drops — so a board renders without a layer the byte route would refuse rather
      # than linking a visitor at a 404.
      @gerber_layers =
        if @gerber_archive
          [ helpers.gerber_archive_entry(name: @node.name,
                                         url: @pub.file_url_for(@node.node_id, filename: @node.name),
                                         members: @gerber_archive.stacked) ]
        elsif @kind == :gerber
          gerber_layers_for(user: owner, node: @node, url: ->(n) { @pub.layer_url_for(n) })
        end
      @gerber_single = @kind == :gerber && !gerber_job?(@node.name) && !@gerber_archive
      enqueue_geometry(owner) if @kind == :measure
    end

    # THE POLL, AND IT NEVER WRITES. FilesController#geometry enqueues when it finds no current row,
    # which is right for a door only the file's owner can open and wrong for one anybody can: a
    # `failed` row is re-enqueued by `Enqueue.call` on EVERY call (§14h), so a stranger reloading a
    # broken file would enqueue a doomed render per poll. The enqueue lives on the page render above
    # instead, guarded by `current_preview` so it fires once per (content, renderer build) — the same
    # split `Maker::Previews::ThumbnailMap`'s required `backfill:` flag draws between `#index`
    # (self-heals) and `#thumbnails` (polled every 2 s, must not write).
    #
    # `head :not_found` RATHER THAN THE PAGE'S 404, and rescued LOCALLY for FilesController#geometry's
    # reason: a JSON poller handed an HTML body reads neither a status key nor a 404.
    def geometry
      pub = public_project!
      node = pub.deliverable!(params[:id])
      token = FileLayer.current.stat(pub.owner, node_id: node.node_id)&.content_token
      return render json: { status: "pending" } if token.nil?

      preview = Maker::Previews::Enqueue.current_preview(user: pub.owner, node_id: node.node_id,
                                                         name: node.name, version_id: token,
                                                         kind: "geometry")
      # NO ROW YET IS `pending`, TRUTHFULLY: the page render that sent this poller here enqueued one.
      return render json: { status: "pending" } if preview.nil?

      case preview.status
      when "ready"
        render json: { status: "ready", url: (url_for(preview.asset) if preview.asset.attached?) }
      when "failed", "unsupported"
        render json: { status: preview.status, error: preview.error }
      else
        render json: { status: "pending" }
      end
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    private

    # ONE JOB PER (node, content token, renderer build), and the `current_preview` guard is what
    # makes that true rather than "one job per page view": `Enqueue.call` resets a `failed` row to
    # pending and re-enqueues whenever it is called. `FilesController#current_thumbnail` is this
    # method's shape, with kind "thumbnail".
    def enqueue_geometry(owner)
      token = @info&.content_token
      return if token.blank?
      return if Maker::Previews::Enqueue.current_preview(user: owner, node_id: @node.node_id,
                                                         name: @node.name, version_id: token,
                                                         kind: "geometry")

      Maker::Previews::Enqueue.call(user: owner, node_id: @node.node_id, name: @node.name,
                                    version_id: token, kind: "geometry")
    rescue FileLayer::NotFound, FileLayer::FetchError
      nil
    end
  end
end
