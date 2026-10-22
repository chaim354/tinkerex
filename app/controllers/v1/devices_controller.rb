module V1
  class DevicesController < BaseController
    # DELIBERATELY NOT capability-gated, and it is the one non-gate on this API that has to be
    # argued rather than assumed -- "a share deployment has no devices to sync" is true and is
    # the wrong reading. A Device is not only a sync participant: its token is the ONLY
    # credential the whole v1 API accepts (see Authentication), including /v1/maker/*. Gating
    # enrollment on `syncable` would make a share deployment's API unauthenticatable, taking the
    # maker layer -- the entire product in that mode -- down with it, at the login endpoint,
    # where nobody would look for it.
    #
    # `syncable` IS READ BELOW, AND IT IS STILL NOT A GATE: every deployment enrols a device; a
    # syncable one also hands it a sync grant, and the others answer `sync: null` (D1, 2026-10-13).
    #
    # Device-login enrollment is the ONE v1 endpoint that authenticates by human
    # credentials, not a device token — so skip the Bearer gate here.
    skip_before_action :authenticate_device!, only: :login

    # THE SAME TWO THROTTLES AS THE WEB SIGN-IN (users/sessions_controller.rb), from the same
    # numbers (Tinkerex::SignInThrottle), so the two human-credential doors agree: per SOURCE, and per
    # ACCOUNT PER SOURCE. THEY REPLACED DEVISE :lockable's LOCK, AND THIS COMMENT USED TO CLAIM THE
    # PER-IP LIMIT ALONE STOPPED "an attacker from locking a known account over and over". It did
    # not. The limit allowed ten attempts per window, and the lock fired at ten, so one IP locked
    # any known account, here and on the web, and could re-lock it every hour (pentest M4b). Nothing
    # locks now, and a stranger's misses cost only the stranger's own source. They gate the ACTION,
    # not just failures: a correct guess on attempt 11 is still refused. Pinned by
    # test/integration/v1/device_login_throttle_test.rb and device_login_test.rb.
    TOO_MANY = -> { render json: { error: "too_many_attempts" }, status: :too_many_requests }
    rate_limit(**Tinkerex::SignInThrottle::PER_SOURCE, only: :login, name: "per-source",
               by: -> { Tinkerex::SignInThrottle.source(request.remote_ip) }, with: TOO_MANY)
    rate_limit(**Tinkerex::SignInThrottle::PER_ACCOUNT, only: :login, name: "per-account",
               by: -> { Tinkerex::SignInThrottle.account_key(params[:email], request.remote_ip) },
               with: TOO_MANY)

    # A GRANT THAT CANNOT BE BROKERED ANSWERS 503 AND MINTS NO MAKER DEVICE -- the sync server
    # unreachable, erroring, or rejecting a credential, all FileLayer::FetchError (SyncGrant#call).
    # Both actions broker the grant BEFORE Device.register!, so the raise lands first: a device
    # holding a maker token and no way to sync must sign in again anyway, and a clear retry beats a
    # half-enrolled device. The body names no cause -- the message can carry the sync server's
    # internal address -- so the cause goes to the log. Pinned by
    # test/integration/v1/device_login_test.rb.
    rescue_from FileLayer::FetchError, with: :sync_unavailable

    # THE SHARED DEMO ACCOUNT ENROLS NO DEVICE (Tinkerex::Demo). A device token is a credential to the
    # whole v1 API that outlives the visitor's browser session until the nightly reset destroys the
    # row, and on a syncable deployment enrolling brokers a sync grant onto a library every visitor
    # shares. Refused on both doors BEFORE anything is brokered or minted -- and, at login, before the
    # password is even checked, so a stranger learns nothing about the demo's password here. 403
    # with its own code rather than the generic 401: the demo address is public, so naming it hides
    # nothing, and a client can tell the visitor why. Pinned by device_login_test.rb.
    DEMO_REFUSAL = { error: "demo_account" }.freeze

    # POST /v1/devices/login { email, password, device_name } -> a device token, the library it
    # opens, and a sync grant where there is something to sync.
    # Authenticates the human credentials via Devise (confirmable enforced; no account locks), then
    # mints a Device. One generic 401 for unknown/bad/unconfirmed (no enumeration). The password
    # crosses the wire once (TLS); the client stores only the returned token.
    def login
      email    = params.require(:email)
      password = params.require(:password)
      user = User.find_for_authentication(email: email)
      return render(json: DEMO_REFUSAL, status: :forbidden) if Tinkerex::Demo.demo?(user)

      # valid_for_authentication? runs the password check (lockable's bookkeeping is off:
      # lock_strategy :none). active_for_authentication? enforces confirmable. Both must pass.
      authed =
        user&.valid_for_authentication? { user.valid_password?(password) } &&
        user.active_for_authentication?

      unless authed
        return render json: { error: "invalid_credentials" }, status: :unauthorized
      end

      # authenticate -> grant -> register -> render. The order is the 503 rule above.
      name = params[:device_name].presence || "device"
      sync = sync_grant_for(user, name)
      # The sibling's id is kept so a later revoke can reach the sync server (Device.register!).
      device = Device.register!(user:, name:, sync_device_id: sync&.fetch(:device_id))
      render json: {
        user_id: user.id, device_id: device.id,
        device_token: device.plaintext_token, head_seq: user.head_seq,
        library: library_info, sync:
      }, status: :created
    end

    # POST /v1/devices { name } -> register an additional device for the current user, with the
    # same two extra fields, in the same order.
    def create
      return render(json: DEMO_REFUSAL, status: :forbidden) if Tinkerex::Demo.demo?(current_user)

      name = params[:name].presence || "device"
      sync = sync_grant_for(current_user, name)
      device = Device.register!(user: current_user, name:, sync_device_id: sync&.fetch(:device_id))
      render json: { device_id: device.id, device_token: device.plaintext_token, library: library_info, sync: },
             status: :created
    end

    private

    # WHICH LIBRARY THIS DEPLOYMENT KEEPS -- so the desktop app can tell a maker on share or s3 that
    # there is nothing for it to sync, rather than mounting nothing. Asked of the adapter actually
    # SERVING, never re-read from ENV; the names are the LIBRARY_BACKEND values FileLayer.build
    # selects each adapter by, and test/integration/v1/device_login_test.rb holds every leg to the
    # value it was launched with.
    def library_info
      adapter = FileLayer.current
      backend = case adapter
      when FileLayer::Share then "share"
      when FileLayer::S3 then "s3"
      when FileLayer::ChunkRemote then "chunk_remote"
      end
      { backend:, syncable: adapter.capabilities.syncable? }
    end

    # nil where there is nothing to sync; otherwise a fresh grant per enrolment, never cached
    # (FileLayer::ChunkRemote::SyncGrant -- chunk_remote is the one syncable backend, and its sync
    # server is the separate process a device is pointed at).
    def sync_grant_for(user, device_name)
      return nil unless FileLayer.current.capabilities.syncable?

      FileLayer::ChunkRemote::SyncGrant.new.call(user, device_name:)
    end

    def sync_unavailable(error)
      Rails.logger.warn("V1::DevicesController##{action_name}: no sync grant: #{error.message}")
      render json: { error: "sync_unavailable" }, status: :service_unavailable
    end
  end
end
