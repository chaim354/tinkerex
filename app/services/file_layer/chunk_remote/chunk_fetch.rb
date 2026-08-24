# frozen_string_literal: true

require "net/http"

module FileLayer
  class ChunkRemote
    # THE CONVERSATION WITH OBJECT STORAGE -- both directions of it. Separate from Transport
    # because it is a different conversation: Transport talks to the sync server with a device
    # token and expects JSON; this talks to OBJECT STORAGE with no credential of ours at all (the
    # signature is in the URL) and expects opaque bytes. Giving Transport a "sometimes binary,
    # sometimes unauthenticated" mode would make its error mapping answer for two different
    # servers. `.put` (CLAUDE.md §14a's `#put_chunk` port verb) shares this module with `.get`
    # rather than starting a third one, for the identical reason: same server, same credential-less
    # shape, same rescue list -- the direction of the bytes is the only thing that differs.
    module ChunkFetch
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 60

      # Returns bytes, or raises FetchError. A storage blip must be RETRYABLE (503), never NotFound:
      # the chunk exists, the network did not cooperate -- §14a's share rule again.
      def self.get(url)
        uri = URI.parse(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.request(Net::HTTP::Get.new(uri))
        end
        return response.body.to_s.b if response.is_a?(Net::HTTPSuccess)

        # A 404 from STORAGE is not the same as a 404 from the sync server. The server told us this
        # chunk exists (it presigned it); storage disagreeing is an inconsistency, not a deletion we
        # should report as a missing file.
        raise FileLayer::FetchError, "chunk storage answered #{response.code} for a presigned URL"
      rescue Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET,
             SocketError, OpenSSL::SSL::SSLError, IOError => e
        raise FileLayer::FetchError, "chunk storage unreachable (#{e.class}): #{e.message}"
      end

      # PUTS ONE CHUNK'S BYTES TO A PRESIGNED URL -- `FileLayer::ChunkRemote#put_chunk`'s whole
      # implementation. Returns nothing; raises FetchError on anything short of success, matching
      # `.get`'s classification exactly: a rejected PUT is a storage-side condition (an expired
      # signature, a full disk, a blip), never evidence about whether the file this chunk belongs
      # to exists, so it is never NotFound. Content-Type is deliberately generic -- object storage
      # does not interpret it, and this module has no business knowing what the maker layer decided
      # to store (`Maker::Addons::LibraryOutput`'s own header: bytes are ROUTED, never inspected).
      def self.put(url, bytes)
        uri = URI.parse(url)
        req = Net::HTTP::Put.new(uri)
        req["Content-Type"] = "application/octet-stream"
        req.body = bytes
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.request(req)
        end
        return if response.is_a?(Net::HTTPSuccess)

        raise FileLayer::FetchError, "chunk storage answered #{response.code} for a presigned PUT"
      rescue Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET,
             SocketError, OpenSSL::SSL::SSLError, IOError => e
        raise FileLayer::FetchError, "chunk storage unreachable (#{e.class}): #{e.message}"
      end
    end
  end
end
