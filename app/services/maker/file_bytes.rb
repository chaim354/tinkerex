module Maker
  # Back-compat shim over the FileLayer port.
  #
  # The maker layer's byte access used to reach through version.manifest_chunks into
  # Storage::ChunkStore — the one place the maker layer knew the file layer's internals. That
  # logic now lives in FileLayer::Chunk, so the maker layer works over ANY backend (share,
  # S3) without change.
  #
  # This shim stays because GeneratePreviewJob does `retry_on Maker::FileBytes::FetchError`
  # and rescues these constants. Prefer FileLayer.current.read in new code.
  class FileBytes
    NotFound   = FileLayer::NotFound
    FetchError = FileLayer::FetchError
    MAX_BYTES  = FileLayer::MAX_BYTES

    # `version_id` is the caller-facing name for what the port calls a content_token: in chunk
    # mode a version UUID, in share/S3 mode a content hash.
    def self.read(user, node_id:, version_id: nil)
      FileLayer.current.read(user, node_id:, content_token: version_id)
    end
  end
end
