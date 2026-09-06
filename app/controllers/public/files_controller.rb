module Public
  # GET /u/:handle/:slug/files/:id(/*filename) — the bytes of one file a published project shows.
  #
  # THE SAME DELIVERY SWITCH AS THE PRIVATE PAGE (`FileDelivery`, CLAUDE.md §14a's three
  # mechanisms), pointed at a node THE PROJECT PERMITS rather than one the session owns. The
  # permission is `Maker::PublicProject#deliverable!` — the same object the page asked, which is
  # what stops a link on the page from 404ing and, more importantly, stops this route from
  # delivering something the page would never have linked.
  #
  # THE OWNER, NOT THE VISITOR, IS WHO THE PORT IS ASKED IN THE NAME OF: a visitor has no library.
  class FilesController < BaseController
    include FileDelivery

    def show
      pub = public_project!
      node = pub.deliverable!(params[:id])
      deliver_file(pub.owner, node, download: params[:download].present?)
    end
  end
end
