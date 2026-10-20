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
    # WHAT LETS `blob.url` BUILD AN ABSOLUTE DISK-SERVICE URL FROM THIS REQUEST (hardening,
    # 2026-09-08; tinkerex#278): it sets ActiveStorage::Current.url_options from the request in a
    # before_action, and the Disk service reads exactly that. Without it `#preview` raises
    # ArgumentError ("Cannot generate URL … without ActiveStorage::Current.url_options") — the
    # controllers that ship with Active Storage include it for the same reason, and this one cannot
    # inherit theirs because a public controller stands on ActionController::Base (§14d).
    include ActiveStorage::SetCurrent

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

    # GET /u/:handle/:slug/files/:id/preview/:kind — a file's DERIVED ASSET: its thumbnail, or the
    # Measure payload (hardening, 2026-09-08; tinkerex#278). THE SAME PERMISSION AS THE BYTES
    # (`deliverable!`), then a redirect to a service URL that EXPIRES
    # (ActiveStorage.service_urls_expire_in, 5 minutes) — where `url_for(preview.asset)` handed out a
    # signed blob URL with NO expiry at all, so a cover thumbnail kept answering after the project
    # went private, and forever. A global `urls_expire_in` was the alternative and is worse: it
    # breaks a `loading="lazy"` image a visitor scrolls to after the window, and still checks
    # nothing about the project.
    #
    # `current_preview` IS THE SAME "current content, current renderer build" RULE THE PAGE RENDERED
    # FROM, so this route cannot serve a picture of content the file no longer holds. A row with
    # nothing to serve is a 404 exactly as an unpermitted node is, because an <img> cannot use a
    # status — and because the two must be indistinguishable to a stranger for #deliverable!'s reason.
    #
    # ONE DOOR, TWO KINDS, TWO QUESTIONS — the split the maker's side draws across two doors. A
    # thumbnail is a PICTURE, served while `showable?` (an older build's picture of this content
    # stays up through its rebuild, as the page that names this URL renders it); the Measure
    # payload is DATA, served only as `current_build?`, because an older build's is wrong (§14h).
    def preview
      pub = public_project!
      node = pub.deliverable!(params[:id])
      token = FileLayer.current.stat(pub.owner, node_id: node.node_id)&.content_token
      row = token && Maker::Previews::Enqueue.current_preview(user: pub.owner, node_id: node.node_id,
                                                              name: node.name, version_id: token,
                                                              kind: params[:kind])
      servable = row && (row.kind == "geometry" ? row.current_build? : row.showable?)
      raise ActiveRecord::RecordNotFound unless servable

      # ONE MINUTE OF PRIVATE CACHE ON THE REDIRECT (tinkerex#291). Each image request costs the byte
      # route's whole permission path plus three queries, and a page of sixty covers is sixty of them
      # per view; a browser that may keep the 302 for a minute skips all of that on a reload. The
      # bound is what makes it safe: the target URL itself expires in `service_urls_expire_in` (five
      # minutes), so a cached redirect can never outlive the URL it names — the test below pins that
      # ordering — and a project that goes private is stale in a browser for at most a minute, the
      # same window the target already allowed. `private`, not `public`: nothing here is per-visitor,
      # but no shared cache on the deployment needs it and a CDN keeping redirects is a decision to
      # make deliberately, not by default.
      expires_in 1.minute
      redirect_to row.asset.url, allow_other_host: true
    end

    # THE POLL, AND IT NEVER WRITES. FilesController#geometry enqueues when it finds no current row
    # (or one whose job was lost), which is right for a door only the file's owner can open and wrong
    # for one anybody can: a `failed` row is re-enqueued by `Enqueue.call`'s default on EVERY call
    # (§14h), so a stranger reloading a broken file would enqueue a doomed render per poll. The
    # enqueue lives on the page render above instead, with `retry_failed: false` so it fires once per
    # (content, renderer build) and once per STALLED_AFTER for a lost job — the same split
    # `Maker::Previews::ThumbnailMap`'s required `backfill:` flag draws between `#index`
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

      # THE PUBLIC PREVIEW ROUTE, NOT `url_for(preview.asset)` (hardening, 2026-09-08;
      # tinkerex#278). The URL this poller hands measure_controller.js outlives the response, so a
      # blob URL here is the same never-expiring, permission-free link the thumbnails were — and
      # this one is the whole Measure payload. #preview re-asks `deliverable!` when it is fetched,
      # which is what makes a payload stop answering when its project stops being public.
      # `current_build?` for FilesController#geometry's reason: this is data, not a picture.
      if preview.current_build?
        return render json: { status: "ready", url: pub.preview_url_for(node.node_id, kind: "geometry") }
      end

      case preview.status
      when "failed", "unsupported"
        render json: { status: preview.status, error: preview.error }
      else
        render json: { status: "pending" }
      end
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    private

    # ONE JOB PER (node, content token, renderer build), plus at most one per STALLED_AFTER window
    # for a row whose job was lost — and `retry_failed: false` is what makes that true rather than
    # "one job per page view": `Enqueue.call`'s default resets a `failed` row to pending and
    # re-enqueues whenever it is called, which on a door a stranger can issue is a doomed render per
    # reload. ONE CALL, because this door does nothing with the row: `call` asks `needs_job?` of it,
    # so a current row costs the same single query the `current_preview` guard that stood here did.
    # That guard returned on ANY current row, which is why a visitor's Measure view could spin over
    # a lost job for good. `FilesController#current_thumbnail` keeps the two-step because it
    # RETURNS the row, including one for a name no renderer claims, where `call` answers nil.
    def enqueue_geometry(owner)
      token = @info&.content_token
      return if token.blank?

      Maker::Previews::Enqueue.call(user: owner, node_id: @node.node_id, name: @node.name,
                                    version_id: token, kind: "geometry", retry_failed: false)
    rescue FileLayer::NotFound, FileLayer::FetchError
      nil
    end
  end
end
