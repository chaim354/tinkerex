# The port's Delivery consumed in ONE place: FilesController#blob (session, any live node of the
# user) and Public::FilesController#show (no session, a node Maker::PublicProject permits). Three
# mechanisms, never a constructed path (CLAUDE.md §14a); inline only for the browser-safe image
# types and PDF, attachment for everything else and for ?download=1.
#
# THE SPLIT THIS CONCERN EXISTS TO KEEP, unchanged from the method it was extracted from: the
# disposition policy below is the CONTROLLER's and must not vary by backend — the same button
# gives the same answer on share, s3 and chunk_remote, or the shared adapter contracts are pinning
# behaviour the web layer then diverges anyway. HOW the bytes travel does vary, and that is
# FileLayer#download's answer, not ours. The controller owns the policy; the adapter owns the
# mechanism.
#
# IT IS A CONCERN RATHER THAN A SHARED SUPERCLASS BECAUSE THE TWO CALLERS CANNOT SHARE ONE:
# FilesController descends from ApplicationController (session, `authenticate_user!`) and
# Public::FilesController from ActionController::Base, deliberately (§14d). A module is the only
# shape that reaches both, and the alternative — a second copy of the policy on the public side —
# is exactly the one-condition-two-answers divergence §14a forbids.
module FileDelivery
  extend ActiveSupport::Concern

  # Content types safe to render inline in the app origin. Raster images only — deliberately
  # NO image/svg+xml (SVG can carry <script>) and NO text/html, which would be stored XSS.
  SAFE_INLINE_TYPES = %w[
    image/png image/jpeg image/gif image/webp image/bmp
    image/x-icon image/vnd.microsoft.icon
  ].freeze

  private

  # `user` is the node's OWNER, which on the public side is not the person making the request and
  # on the private side always is. The port is asked in the owner's name either way — a public
  # visitor has no library of their own to resolve a node_id against.
  def deliver_file(user, node, download:)
    filename = node.name
    content_type = Marcel::MimeType.for(name: filename)
    # Serve user-uploaded bytes inline ONLY for a small allowlist of raster image types.
    # Everything else — notably SVG and HTML, which the browser would execute in the app
    # origin (stored XSS in the viewer's session) — is forced to a download. `nosniff`
    # stops the browser second-guessing the declared type. `?download=1` always attaches.
    # PDF is inline-safe too, even though SAFE_INLINE_TYPES is raster-only: the browser hands
    # application/pdf to its built-in viewer (PDFium/pdf.js), which sandboxes any embedded PDF
    # JavaScript — a PDF is never executed as page script in the app origin the way SVG/HTML are.
    inline_ok = !download && (SAFE_INLINE_TYPES.include?(content_type) || content_type == "application/pdf")
    disposition = inline_ok ? "inline" : "attachment"

    delivery = FileLayer.current.download(user, node_id: node.node_id, disposition:, content_type:)

    # No `else`: an unhandled variant raises NoMatchingPatternError, which is what a new
    # Delivery variant with no consumer here should do. A silent fallthrough would serve a
    # blank 200 with the right filename.
    case delivery
    in FileLayer::Delivery::Redirect(url:)
      # NO Content-Disposition / Content-Type / nosniff on this branch, and the asymmetry is
      # deliberate rather than an omission: they would be headers on a 302 that the browser
      # discards on its way to the store. The policy travels SIGNED INTO THE URL instead
      # (FileLayer::S3#download) — the same answer, applied by the only party that can apply it.
      redirect_to url, allow_other_host: true
    in FileLayer::Delivery::SendFile(path:)
      # `path` is CONSUMED, never built and never re-validated: it was resolved through
      # Share#absolute_path's escape guard, which is the single choke point #read uses too.
      # A File.join / Pathname / ".." check here would either bypass that guard or become a
      # second copy of it that drifts (§9a-3). See share_delivery_test.rb's poisoned-row tests.
      response.headers["X-Content-Type-Options"] = "nosniff"
      send_file path, disposition:, type: content_type, filename:
    in FileLayer::Delivery::Stream(enum:)
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Type"] = content_type
      response.headers["Content-Disposition"] =
        ActionDispatch::Http::ContentDisposition.format(disposition:, filename:)
      self.response_body = enum
    end
  end
end
