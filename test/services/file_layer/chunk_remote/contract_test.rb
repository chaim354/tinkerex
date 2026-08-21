# frozen_string_literal: true

require "test_helper"
require "socket"
require "digest"
require_relative "../adapter_contract"

module FileLayer
  class ChunkRemote
    # THE SHARED ADAPTER CONTRACT, RUN AGAINST chunk_remote — the same twenty tests Chunk, Share and
    # S3 already pass. Until this file existed the adapter was measured only by its own tests, which
    # is not the same bar.
    #
    # THE FAKE SYNC SERVER IS A REAL SOCKET, and both halves of the round trip are real: it presigns
    # a hash into a URL pointing at itself, and then serves those bytes when the adapter fetches
    # them. Stubbing either half would leave the two-step hydrate (presign, then fetch from a
    # DIFFERENT host) asserting its own intent -- and that two-step shape is the entire reason
    # ChunkFetch is separate from Transport.
    class ContractTest < ActiveSupport::TestCase
      include FileLayerAdapterContract

      setup do
        @blobs = {}
        @server = TCPServer.new("127.0.0.1", 0)
        @port = @server.addr[1]
        @thread = Thread.new do
          loop do
            socket = begin
              @server.accept
            rescue IOError, Errno::EBADF
              break
            end
            serve(socket)
          end
        end

        @user = User.create!(email: "remote-contract-#{SecureRandom.hex(4)}@example.com",
                             password: "correct horse battery staple", confirmed_at: Time.current)
      end

      teardown do
        @server&.close
        @thread&.kill
      end

      def serve(socket)
        verb, path = socket.gets.to_s.split(" ")
        headers = {}
        while (line = socket.gets) && line != "\r\n"
          k, v = line.split(": ", 2)
          headers[k.to_s.downcase] = v.to_s.strip
        end
        body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : nil

        status, type, payload =
          if path == "/v1/chunks/download" && verb == "POST"
            hashes = JSON.parse(body.to_s)["hashes"] || []
            # Mirrors the real endpoint: a hash this user does not own is OMITTED, not nulled.
            urls = hashes.select { |h| @blobs.key?(h) }
                         .to_h { |h| [ h, "http://127.0.0.1:#{@port}/blob/#{h}" ] }
            [ 200, "application/json", { urls: }.to_json ]
          elsif path.to_s.start_with?("/blob/")
            hash = path.split("/").last
            if @blob_failure then [ 503, "text/plain", "try again" ]
            elsif @blobs.key?(hash) then [ 200, "application/octet-stream", @blobs[hash] ]
            else [ 404, "text/plain", "no" ]
            end
          else
            [ 404, "application/json", { error: "not_found" }.to_json ]
          end

        socket.write("HTTP/1.1 #{status} X\r\nContent-Type: #{type}\r\n" \
                     "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      rescue StandardError
        nil
      ensure
        socket.close rescue nil
      end

      # ── BEYOND THE CONTRACT: THE TRUNCATION CASE IT DOES NOT REACH ────────────────────────
      #
      # ADDED BECAUSE MUTATION-CHECKING STAYED GREEN. Making `fetch_chunk` return empty bytes for a
      # chunk the server declined to presign passed all 21 contract tests -- the fake server always
      # presigns what it holds, so the missing-URL branch was never taken. That mutation is SILENT
      # TRUNCATION: a short file delivered with a 200 and the right name, which is the precise
      # failure §14a records for redirecting a multi-chunk file.
      #
      # `chunks#download` OMITS a hash the user does not own rather than nulling it, so this is a
      # real wire condition and not a contrived one.
      test "a chunk the server declines to presign raises rather than truncating" do
        id = create_file!(name: "two-chunk.stl", bytes: "first-half")
        version_id = @user.nodes.find_by(node_id: id).current_version_id

        # A second chunk in the manifest whose bytes the server does not have, so it presigns only
        # the first -- exactly what an unowned or swept chunk looks like on the wire.
        RemoteManifestChunk.create!(user_id: @user.id, version_id:, seq: 1,
                                    chunk_hash: "f" * 64, offset: 10, length: 11)

        assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
        assert_raises(FileLayer::NotFound) do
          d = adapter.download(@user, node_id: id, disposition: "attachment")
          d.enum.each { |c| c }   # Stream is lazy: the enumerator has to be drained to fault
        end
      end

      test "a whole-file read concatenates its chunks in manifest order" do
        id = create_file!(name: "ordered.stl", bytes: "AAAA")
        version_id = @user.nodes.find_by(node_id: id).current_version_id
        tail = "BBBB"
        @blobs[Digest::SHA256.hexdigest(tail)] = tail.b
        RemoteManifestChunk.create!(user_id: @user.id, version_id:, seq: 1,
                                    chunk_hash: Digest::SHA256.hexdigest(tail), offset: 4, length: 4)

        assert_equal "AAAABBBB", adapter.read(@user, node_id: id)
      end

      def adapter
        @adapter ||= ChunkRemote.new(
          transport: Transport.new(base_url: "http://127.0.0.1:#{@port}", token: "device-token")
        )
      end

      # SEEDS EXACTLY WHAT ChangelogSync WOULD HAVE LEFT BEHIND: a node carrying size and a version
      # id, plus the version's manifest rows. Reaching for the applier here would test the applier;
      # this file is about the adapter reading what the applier produces.
      def create_file!(name:, bytes:)
        node_id = SecureRandom.uuid
        version_id = SecureRandom.uuid
        hash = Digest::SHA256.hexdigest(bytes)
        @blobs[hash] = bytes.b

        @user.nodes.create!(node_id:, name:, kind: "file", size: bytes.bytesize,
                            mtime: (Time.current.to_f * 1e9).to_i, current_version_id: version_id)
        RemoteManifestChunk.create!(user_id: @user.id, version_id:, seq: 0,
                                    chunk_hash: hash, offset: 0, length: bytes.bytesize)
        node_id
      end

      # The way a USER removes a file in remote mode: the server tombstones it and the changelog
      # carries `deleted: true`, which ChangelogSync applies. Both hooks are that same thing here --
      # unlike chunk/share, where trash and delete are genuinely different mechanisms.
      def delete_file!(node_id) = @user.nodes.find_by(node_id:).update!(deleted: true)
      def trash_file!(node_id) = delete_file!(node_id)

      # A BARE YIELD, for the reason Share's is: there is no store here to configure. The remote
      # already presigns off-box URLs -- that is what the fake server does -- and this adapter still
      # will not redirect to one, deliberately (see CAPABILITIES). Installing something to make it
      # redirect would fake the capability into existence and pin the fixture instead of the adapter.
      def with_off_box_presigning = yield

      # FAULTS THE TRANSPORT, NOT THE ADAPTER'S ERROR CLASSIFICATION -- the contract is explicit that
      # stubbing the latter is what this test exists to check. The blob host answers 503, which is a
      # storage blip: the chunk exists and the server presigned it, so the honest answer is a
      # RETRYABLE FetchError rather than NotFound.
      def with_transient_backend_failure
        @blob_failure = true
        yield
      ensure
        @blob_failure = false
      end
    end
  end
end
