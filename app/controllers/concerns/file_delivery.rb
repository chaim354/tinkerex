# The port's Delivery consumed in ONE place: FilesController#blob (session, any live node of the
# user) and Public::FilesController#show (no session, a node Maker::PublicProject permits). Three
# mechanisms, never a constructed path (CLAUDE.md §14a); inline only for the browser-safe image
# and video types and PDF, attachment for everything else and for ?download=1.
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

  # Content types safe to render inline in the app origin: raster images, and the two video
  # containers the file page plays (`Maker::FileAttachment::INLINE_VIDEO_EXTS`; Marcel answers
  # `video/mp4` for `.m4v` too). A browser decodes either kind as media and never runs it as page
  # script. Deliberately NO image/svg+xml (SVG can carry <script>) and NO text/html, which would be
  # stored XSS.
  SAFE_INLINE_TYPES = %w[
    image/png image/jpeg image/gif image/webp image/bmp
    image/x-icon image/vnd.microsoft.icon
    video/mp4 video/webm
  ].freeze

  private

  # `user` is the node's OWNER, which on the public side is not the person making the request and
  # on the private side always is. The port is asked in the owner's name either way — a public
  # visitor has no library of their own to resolve a node_id against.
  def deliver_file(user, node, download:)
    filename = node.name
    content_type = Marcel::MimeType.for(name: filename)
    # Serve user-uploaded bytes inline ONLY for a small allowlist of raster image and video types.
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
      response.headers["Accept-Ranges"] = "bytes"
      return if File.file?(path) &&
                answer_range(File.size(path), disposition:, content_type:, filename:) { |r| FileSlice.new(path:, range: r) }

      send_file path, disposition:, type: content_type, filename:
    in FileLayer::Delivery::Stream(enum:, size:, slice:)
      response.headers["X-Content-Type-Options"] = "nosniff"
      if size && slice
        response.headers["Accept-Ranges"] = "bytes"
        return if answer_range(size, disposition:, content_type:, filename:) { |r| slice.call(r) }
      end

      response.headers["Content-Type"] = content_type
      response.headers["Content-Disposition"] =
        ActionDispatch::Http::ContentDisposition.format(disposition:, filename:)
      self.response_body = enum
    end
  end

  # HTTP RANGE, ON THE TWO ARMS WHERE RAILS SERVES THE BYTES (2026-11-20, the video player). A
  # `<video>` asks for a byte range before it plays — Safari refuses to play at all when its
  # `bytes=0-1` gets a 200 — and every seek is another range. The Redirect arm needs nothing: the
  # store answers ranges itself, and S3 always has. ONE RULE FOR BOTH ARMS, so share and
  # chunk_remote cannot answer the same request two ways:
  #
  #   - one satisfiable range -> 206, Content-Range, exactly those bytes from the block;
  #   - a range wholly past the end -> 416 with `bytes */size`;
  #   - anything else -> false, and the caller serves the WHOLE file with a 200, which RFC 9110
  #     permits as the answer to any range request: no header, a malformed one, several ranges
  #     (no browser player asks for those), an empty file (`get_byte_ranges` declines size 0), or
  #     an If-Range — this app sends no validator for one to match, so the safe reading is
  #     "the representation changed".
  #
  # The disposition and nosniff policy is the same answer as the whole file's: a range of an
  # attachment is still an attachment.
  def answer_range(size, disposition:, content_type:, filename:)
    header = request.headers["Range"]
    return false if header.blank? || request.headers["If-Range"].present?

    ranges = Rack::Utils.get_byte_ranges(header, size)
    return false if ranges.nil? || ranges.size > 1

    if ranges.empty?
      response.headers["Content-Range"] = "bytes */#{size}"
      head :range_not_satisfiable
    else
      range = ranges.first
      response.headers["Content-Type"] = content_type
      response.headers["Content-Disposition"] =
        ActionDispatch::Http::ContentDisposition.format(disposition:, filename:)
      response.headers["Content-Range"] = "bytes #{range.begin}-#{range.end}/#{size}"
      response.headers["Content-Length"] = range.size.to_s
      self.status = :partial_content
      self.response_body = yield(range)
    end
    true
  end

  # A BYTE RANGE OF A FILE ON DISK, read in slices as the response is written — never the whole file
  # into memory. It has NO `to_path`, deliberately: Rack::Sendfile accelerates only a body that
  # answers one, and a proxy handed the PATH would send the whole file under our 206. So a range is
  # always served by Rails, even where a sendfile variation is configured; the whole file keeps
  # send_file and its acceleration (share_delivery_test.rb's two acceleration tests).
  FileSlice = Data.define(:path, :range) do
    def each
      File.open(path, "rb") do |file|
        file.seek(range.begin)
        left = range.size
        while left.positive? && (chunk = file.read([ left, 64.kilobytes ].min))
          left -= chunk.bytesize
          yield chunk
        end
      end
    end
  end
end
