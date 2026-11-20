module FileLayer
  # How a backend hands a file's bytes to a browser. `FileLayer#download` returns one of these,
  # and the controller consumes it without ever learning which backend it came from.
  #
  # THREE VARIANTS BECAUSE THERE ARE THREE MECHANISMS, not three styles. Each is the only thing
  # its backend can honestly do:
  #
  #   Redirect(url) -> the store has a URL signer, so the browser fetches the bytes from it and
  #                    Rails is never in the data path. CLAUDE.md §15, and the reason S3 answers
  #                    presignable: true. Chunk uses it too, for the one case #blob already did.
  #   SendFile(path) -> a mounted directory has nothing to presign, so Rails serves the file.
  #                    §15 genuinely cannot hold here (spec §9's deliberate departure, scoped to
  #                    storage we do not own). It carries the PATH, not the bytes, which is what
  #                    lets the controller keep a 2GB file off the Rails heap — and what makes
  #                    x_sendfile_header able to hand it to a proxy where one exists.
  #   Stream(enum)  -> a lazy enumerator of byte chunks. Chunk mode's multi-chunk read: Rails
  #                    stitches presigned GETs together but never holds the whole file.
  #
  # THE DISPOSITION IS NOT CARRIED HERE, and that absence is deliberate. Each transport applies
  # it somewhere different — Redirect SIGNS it into the URL, SendFile passes it to send_file,
  # Stream sets a response header — so a `disposition` field on these objects would be a value
  # every consumer had to re-apply, i.e. the second copy of a rule that §9a-3 already complains
  # about. It goes IN to #download (which the adapter needs at mint time to sign it) and comes
  # out APPLIED. The controller owns the policy; the adapter owns the mechanism.
  #
  # NO GUARANTEE TRAVELS WITH THE TYPE. SendFile is a Data object anyone can construct with any
  # path, so it does not certify that its path is inside the library root — `Share#download` does,
  # by resolving through the same #absolute_path #read uses. The controller must never construct
  # one, and must never validate one either: one choke point, or two that drift.
  #
  # A STREAM MAY ALSO NAME ITS SIZE AND HAND BACK ANY BYTE RANGE OF ITSELF (2026-11-20, the video
  # player), and the two travel together. A `<video>` element asks for ranges before it will play
  # (Safari refuses a file whose server answers its `bytes=0-1` with a 200) and every seek is another
  # one, so FileDelivery answers an HTTP Range request from `slice.call(first..last)` — an enumerator
  # of exactly those bytes — instead of reading everything before them. chunk_remote's manifest knows
  # every chunk's length, so it can say which chunks a range covers and fetch only those. Both nil
  # means "the whole file only", which is what a Stream built without them still is. The other two
  # variants need neither: a Redirect's store answers ranges itself, and a SendFile's path is a file
  # the controller can seek in.
  module Delivery
    Redirect = Data.define(:url)
    SendFile = Data.define(:path)
    Stream = Data.define(:enum, :size, :slice) do
      def initialize(enum:, size: nil, slice: nil) = super
    end
  end
end
