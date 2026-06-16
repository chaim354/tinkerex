module V1
  class DevicesController < BaseController
    # Device-login enrollment is the ONE v1 endpoint that authenticates by human
    # credentials, not a device token — so skip the Bearer gate here.
    skip_before_action :authenticate_device!, only: :login

    # POST /v1/devices/login { email, password, device_name } -> a device token.
    # Authenticates the human credentials via Devise (confirmable + lockable enforced),
    # then mints a Device. One generic 401 for unknown/bad/unconfirmed/locked (no
    # enumeration). The password crosses the wire once (TLS); the client stores only the
    # returned token.
    def login
      email    = params.require(:email)
      password = params.require(:password)
      user = User.find_for_authentication(email: email)

      # valid_for_authentication? runs the password check AND the lockable bookkeeping
      # (increments failed_attempts on a miss; locks at maximum_attempts). active_for_
      # authentication? enforces confirmable (and not-locked). Both must pass.
      authed =
        user&.valid_for_authentication? { user.valid_password?(password) } &&
        user.active_for_authentication?

      unless authed
        return render json: { error: "invalid_credentials" }, status: :unauthorized
      end

      device = Device.register!(user:, name: params[:device_name].presence || "device")
      render json: {
        user_id: user.id, device_id: device.id,
        device_token: device.plaintext_token, head_seq: user.head_seq
      }, status: :created
    end

    # POST /v1/devices { name } -> register an additional device for the current user.
    def create
      device = Device.register!(user: current_user, name: params[:name].presence || "device")
      render json: { device_id: device.id, device_token: device.plaintext_token }, status: :created
    end
  end
end
