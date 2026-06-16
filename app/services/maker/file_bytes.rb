module Maker
  # Read-only file-layer seam: assemble a file VERSION's bytes from its manifest chunks.
  # Bytes come from the same content-addressed chunk store the sync engine uses; this runs
  # server-side (a preview job), so it reads chunks directly rather than via presigned URLs.
  class FileBytes
    # The version/chunk genuinely isn't there (no version row, or a 404 from storage).
    # Terminal: retrying won't help, so the preview job marks the preview "failed".
    NotFound = Class.new(StandardError)

    # A TRANSIENT failure reaching the byte store: a 403 (auth/creds blip), a 5xx, or a
    # network error on the presigned GET. Distinct from NotFound on purpose — the chunk
    # may well exist; we just couldn't read it right now. The caller should RETRY rather
    # than mark the file permanently broken. (This is exactly the prod failure mode where
    # a 403 during a chunk-store creds outage was being swallowed as "missing chunk".)
    FetchError = Class.new(StandardError)

    # Cap to protect the job host; large CAD/mesh files stream to disk in later phases.
    MAX_BYTES = 256 * 1024 * 1024

    def self.read(user, node_id:, version_id: nil)
      version =
        if version_id.present?
          user.versions.find_by(node_id:, version_id:)
        else
          node = user.nodes.find_by(node_id:)
          node&.current_version
        end
      raise NotFound, "no version for node #{node_id.inspect}" unless version

      store = Storage::ChunkStore.current
      buf = +"".b
      version.manifest_chunks.each do |mc|
        bytes = fetch(store, user.id, mc.chunk_hash)
        raise NotFound, "missing chunk #{mc.chunk_hash}" if bytes.nil?
        buf << bytes.b
        raise NotFound, "file exceeds #{MAX_BYTES} bytes" if buf.bytesize > MAX_BYTES
      end
      buf
    end

    # Normalize over the chunk-store backends.
    #   - memory store exposes read_blob (tests/dev)
    #   - local filesystem store exposes read
    #   - S3 store exposes presign_get → pull the bytes over the presigned GET
    #
    # Returns the bytes, or nil ONLY when the chunk is genuinely absent (a 404 from the
    # presigned GET). A non-404 HTTP error (403 auth, 5xx) or a network error is a
    # TRANSIENT failure → raise FetchError so the caller can retry instead of treating it
    # as a permanently-missing chunk.
    def self.fetch(store, user_id, hash)
      if store.respond_to?(:read_blob)
        store.read_blob(user_id, hash)
      elsif store.respond_to?(:read)
        store.read(user_id, hash)
      else
        http_get(store.presign_get(user_id, hash))
      end
    rescue OpenURI::HTTPError => e
      # io.status is ["404", "Not Found"]; a 404 means the object isn't there (terminal,
      # nil → NotFound upstream). Anything else (403/5xx) is transient → FetchError.
      status = e.io.status.first.to_i rescue 0
      return nil if status == 404
      raise FetchError, "chunk GET #{hash}: HTTP #{status} (#{e.message})"
    rescue OpenURI::HTTPError
      nil
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout,
           Net::ReadTimeout, Timeout::Error => e
      raise FetchError, "chunk GET #{hash}: #{e.class} (#{e.message})"
    end

    # The HTTP fetch seam (presigned GET → bytes). Extracted so it can be exercised/faulted
    # in isolation. open-uri raises OpenURI::HTTPError for non-2xx, carrying the status.
    def self.http_get(url)
      require "open-uri"
      require "net/http"
      URI.parse(url).open(&:read)
    end
  end
end
