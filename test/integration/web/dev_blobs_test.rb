require "test_helper"

module Web
  # The DEV/TEST-ONLY chunk-bytes endpoint standing in for object storage.
  #
  # In production (STORAGE_BACKEND=s3) presigned URLs point straight at the store and this
  # controller is not even routed — config/routes.rb mounts it only when !Rails.env.production?.
  # Locally there is nothing off-box to presign to, so MemoryChunkStore presigns to these routes
  # and the browser's PUT-then-GET upload actually moves bytes through them.
  #
  # WHY TEST DEV-ONLY INFRASTRUCTURE: it is the local upload path. If it breaks, uploads fail in
  # development and in the browser-driven system tests with nothing pointing at the cause — and it
  # was the last of the 85 web actions that no test drove.
  class DevBlobsTest < ActionDispatch::IntegrationTest
    setup do
      pin_file_layer_backend("chunk")
      Sync::Storage::ChunkStore.reset!
    end

    test "a PUT then GET round-trips the exact bytes" do
      key = "chunks/1/deadbeef"
      body = "\x00\x01\xFF binary chunk \xFE".b

      put "/dev/blobs/#{key}", params: body, headers: { "CONTENT_TYPE" => "application/octet-stream" }
      assert_response :ok

      get "/dev/blobs/#{key}"
      assert_response :ok
      assert_equal body, response.body.b, "the bytes must survive the round-trip unchanged"
      assert_equal "application/octet-stream", response.media_type
    end

    test "a GET for a key that was never written is a 404, not an empty 200" do
      # An empty 200 would let a hydrate silently succeed with zero bytes, which is the shape of
      # a corruption bug rather than a missing-object bug.
      get "/dev/blobs/chunks/1/never-written"
      assert_response :not_found
    end

    test "the endpoint refuses to serve when the store is not the memory store" do
      # The guard that keeps this dev seam inert on a real store. Not merely decorative: the route
      # is mounted in EVERY non-production environment, and the controller re-checks the store
      # rather than trusting the route condition.
      #
      # Swapped via STORAGE_BACKEND + reset! — the same seam the app itself uses — rather than by
      # stubbing, so this exercises the real ChunkStore.build path.
      prior = ENV["STORAGE_BACKEND"]
      begin
        ENV["STORAGE_BACKEND"] = "local"
        Sync::Storage::ChunkStore.reset!
        get "/dev/blobs/chunks/1/anything"
        assert_response :not_found
      ensure
        ENV["STORAGE_BACKEND"] = prior
        Sync::Storage::ChunkStore.reset!
      end
    end
  end
end
