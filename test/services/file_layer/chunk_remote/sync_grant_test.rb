# frozen_string_literal: true

require "test_helper"

module FileLayer
  class ChunkRemote
    # THE SYNC GRANT ON A FAKE WIRE (D1, 2026-10-13). Nearly every assertion here is about WHICH
    # TOKEN carried WHICH request, so the fake stamps each call with the token its transport was
    # BUILT with -- the one fact a real Transport keeps private (transport_isolation_test.rb reaches
    # past it for the same reason). The real-server half is the chunk_remote journey
    # (test/integration/chunk_remote_journey_test.rb), which only that leg can run.
    class SyncGrantTest < ActiveSupport::TestCase
      # ONE RECORDING WIRE FOR THE WHOLE GRANT. `transport_for` is the (token) -> transport builder
      # SyncGrant takes; every transport it builds answers from the canned replies and records
      # [verb, token, path, payload]. A reply that is a Proc is CALLED, so a test raises what
      # Transport#interpret raises on a non-2xx -- never a returned error hash, which would leave the
      # propagation untested (provisioning_test.rb's FakeAdminTransport makes the same choice).
      class RecordingWire
        FakeTransport = Struct.new(:wire, :token) do
          def post(path, body = {}) = wire.answer(:post, token, path, body)
          def get(path, params = {}) = wire.answer(:get, token, path, params)
        end

        attr_reader :calls

        def initialize(replies)
          @replies = replies
          @calls = []
        end

        def transport_for = ->(token) { FakeTransport.new(self, token) }

        def answer(verb, token, path, payload)
          @calls << [ verb, token, path, payload ]
          reply = @replies.fetch([ verb, path ])
          reply.respond_to?(:call) ? reply.call : reply
        end
      end

      # What the sync server answers (crates/tinkerex-sync handlers.rs and host/'s DevicesController
      # agree): POST /v1/devices -> {device_id, device_token}; whoami -> {user_id, device_id, head_seq}.
      MINTED = { "device_id" => 7, "device_token" => "sibling-token" }.freeze
      WHOAMI = { "user_id" => 3, "device_id" => 7, "head_seq" => 42 }.freeze

      def happy_wire
        RecordingWire.new([ :post, "/v1/devices" ] => MINTED, [ :get, "/v1/devices/whoami" ] => WHOAMI)
      end

      def new_user(sync_device_token: "bootstrap-token")
        User.create!(email: "grant-#{SecureRandom.hex(4)}@example.com", password: "correct horse battery staple",
                     confirmed_at: Time.current, sync_device_token:)
      end

      setup do
        @prior_public_url = ENV["SYNC_PUBLIC_URL"]
        ENV["SYNC_PUBLIC_URL"] = "https://sync.example.test"
        # A token already present, so the DEFAULT Provisioning answers from the row and dials nothing.
        @user = new_user
      end

      teardown do
        @prior_public_url.nil? ? ENV.delete("SYNC_PUBLIC_URL") : ENV["SYNC_PUBLIC_URL"] = @prior_public_url
      end

      test "the grant is the devices' door, the NEW token, and the sync server's own ids and cursor" do
        grant = SyncGrant.new(transport_for: happy_wire.transport_for).call(@user, device_name: "Ada's laptop")

        assert_equal({ url: "https://sync.example.test", device_token: "sibling-token",
                       user_id: 3, device_id: 7, head_seq: 42 }, grant)
      end

      test "the sibling is minted with the bootstrap token and PROVED with the new one" do
        wire = happy_wire
        SyncGrant.new(transport_for: wire.transport_for).call(@user, device_name: "Ada's laptop")

        assert_equal [ [ :post, "bootstrap-token", "/v1/devices", { name: "Ada's laptop" } ] ],
                     wire.calls.select { |verb, *| verb == :post },
                     "the sibling must be minted in the user's OWN library -- the bootstrap token " \
                     "Provisioning holds for them -- under the name the device signed in with"
        assert_equal [ [ :get, "sibling-token", "/v1/devices/whoami", {} ] ],
                     wire.calls.select { |verb, *| verb == :get },
                     "head_seq must be read back with the NEW token: that request is the proof the " \
                     "server accepts the token before it is handed to a device"
      end

      test "a user with no library yet is provisioned first, and the sibling is minted with THAT token" do
        fresh = new_user(sync_device_token: nil)
        provisioning = Struct.new(:asked) do
          def call(user)
            self.asked = user
            "freshly-provisioned"
          end
        end.new
        wire = happy_wire

        SyncGrant.new(provisioning:, transport_for: wire.transport_for).call(fresh, device_name: "laptop")

        assert_equal fresh, provisioning.asked
        assert_equal "freshly-provisioned", wire.calls.first[1],
                     "the grant must ask Provisioning, not read the column: a first sign-in has none yet"
      end

      test "a sync server that cannot be reached or refuses the new token propagates FetchError" do
        unreachable = RecordingWire.new(
          [ :post, "/v1/devices" ] => -> { raise FileLayer::FetchError, "sync server unreachable (Errno::ECONNREFUSED)" }
        )
        assert_raises(FileLayer::FetchError) do
          SyncGrant.new(transport_for: unreachable.transport_for).call(@user, device_name: "laptop")
        end

        # Minted, then refused on the proof: the token is never handed out.
        refused = RecordingWire.new(
          [ :post, "/v1/devices" ] => MINTED,
          [ :get, "/v1/devices/whoami" ] => -> { raise FileLayer::FetchError, "sync server rejected this device (401)" }
        )
        assert_raises(FileLayer::FetchError) do
          SyncGrant.new(transport_for: refused.transport_for).call(@user, device_name: "laptop")
        end
      end

      # §14a's transport rule, applied here: nothing keyed on less than the user. One grant object,
      # two users -- each mint carries that user's own bootstrap token.
      test "nothing is cached across users: one grant object, two users, two bootstrap tokens" do
        other = new_user(sync_device_token: "other-bootstrap")
        wire = happy_wire
        grant = SyncGrant.new(transport_for: wire.transport_for)

        grant.call(@user, device_name: "a")
        grant.call(other, device_name: "b")

        assert_equal %w[bootstrap-token other-bootstrap],
                     wire.calls.select { |verb, *| verb == :post }.map { |_, token, *| token }
      end

      test "the devices' door is read before anything is minted" do
        ENV.delete("SYNC_PUBLIC_URL")
        wire = happy_wire

        err = assert_raises(KeyError) do
          SyncGrant.new(transport_for: wire.transport_for).call(@user, device_name: "laptop")
        end
        assert_match(/SYNC_PUBLIC_URL/, err.message)
        assert_empty wire.calls, "a deployment that cannot name the devices' door must mint nothing on the sync server"
      end

      # TWO ADDRESSES ON PURPOSE: this app dials CHUNK_REMOTE_URL (on a Kamal box, the internal alias),
      # devices are handed SYNC_PUBLIC_URL. The default wire must be the first, never the second.
      test "the default wire dials CHUNK_REMOTE_URL, not the address it hands out" do
        prior = ENV["CHUNK_REMOTE_URL"]
        ENV["CHUNK_REMOTE_URL"] = "http://tinkerex-sync:3000"

        transport = SyncGrant.new.instance_variable_get(:@transport_for).call("a-token")

        assert_kind_of Transport, transport
        assert_equal "http://tinkerex-sync:3000", transport.instance_variable_get(:@base_url)
        assert_equal "a-token", transport.instance_variable_get(:@token)
      ensure
        prior.nil? ? ENV.delete("CHUNK_REMOTE_URL") : ENV["CHUNK_REMOTE_URL"] = prior
      end
    end
  end
end
