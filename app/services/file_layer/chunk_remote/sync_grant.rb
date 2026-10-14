# frozen_string_literal: true

module FileLayer
  class ChunkRemote
    # THE SYNC GRANT A DEVICE RECEIVES WHEN IT SIGNS IN TO THE MAKER APP (D1, 2026-10-13).
    #
    # The desktop app signs in HERE (V1::DevicesController#login, email + password) and syncs against
    # the sync server, which has no password login of its own. So this app brokers. It holds each
    # user's bootstrap device token on the sync server (users.sync_device_token, minted by
    # Provisioning through the operator door), and with it mints a SIBLING device for the signing-in
    # machine (POST /v1/devices {name}), then reads head_seq back with the NEW token
    # (GET /v1/devices/whoami) -- which is also the proof the server accepts that token before it is
    # handed out. A token the server refuses never leaves this class.
    #
    # NOTHING IS CACHED, by §14a's transport rule: each call builds its transports from the tokens it
    # is handed, so one instance serving two users cannot carry the first user's credential into the
    # second's request. A device that signs in twice is two sync devices, as it is two maker devices.
    #
    # TWO ADDRESSES, ON PURPOSE. This app dials CHUNK_REMOTE_URL (on a Kamal box, the internal alias
    # http://tinkerex-sync:3000); the grant hands out SYNC_PUBLIC_URL, the address DEVICES reach the
    # same server at (lib/library_backend_check.rb). It is read FIRST, so a deployment that cannot
    # name the devices' door mints nothing on the sync server.
    #
    # `provisioning:` and `transport_for:` -- a (token) -> transport builder -- are injectable the way
    # Provisioning's own `admin_transport:` is, so a unit test can hand in a fake wire
    # (test/services/file_layer/chunk_remote/sync_grant_test.rb).
    class SyncGrant
      def initialize(provisioning: Provisioning.new, transport_for: nil)
        @provisioning = provisioning
        @transport_for = transport_for ||
                         ->(token) { Transport.new(base_url: ENV.fetch("CHUNK_REMOTE_URL"), token:) }
      end

      # -> { url:, device_token:, user_id:, device_id:, head_seq: }. The ids and the cursor are the
      # SYNC SERVER's, not this app's. Raises FileLayer::FetchError when the sync server cannot be
      # reached, errors, or rejects a credential (Transport#interpret's mapping), and when
      # Provisioning cannot provision the user's library. A 2xx missing a field is a contract
      # violation and raises KeyError, loudly, as Provisioning#provision_remote! does.
      def call(user, device_name:)
        url = ENV.fetch("SYNC_PUBLIC_URL")
        bootstrap = @provisioning.call(user)
        token = @transport_for.call(bootstrap).post("/v1/devices", { name: device_name }).fetch("device_token")
        who = @transport_for.call(token).get("/v1/devices/whoami")

        { url:, device_token: token, user_id: who.fetch("user_id"), device_id: who.fetch("device_id"),
          head_seq: who.fetch("head_seq") }
      end
    end
  end
end
