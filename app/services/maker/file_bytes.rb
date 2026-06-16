module Maker
  # Read-only file-layer seam: assemble a file VERSION's bytes from its manifest chunks.
  # Bytes come from the same content-addressed chunk store the sync engine uses; this runs
  # server-side (a preview job), so it reads chunks directly rather than via presigned URLs.
  class FileBytes
    NotFound = Class.new(StandardError)

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
    def self.fetch(store, user_id, hash)
      if store.respond_to?(:read_blob)
        store.read_blob(user_id, hash)
      elsif store.respond_to?(:read)
        store.read(user_id, hash)
      else
        url = store.presign_get(user_id, hash)
        require "open-uri"
        URI.parse(url).open(&:read)
      end
    rescue OpenURI::HTTPError
      nil
    end
  end
end
