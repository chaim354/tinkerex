module V1
  class DevicesController < BaseController
    # POST /v1/devices { name } -> register an additional device for the current user.
    # (Direct path: the caller already holds a token and hands the new token off itself.)
    def create
      device = Device.register!(user: current_user, name: params[:name].presence || "device")
      render json: { device_id: device.id, device_token: device.plaintext_token }, status: :created
    end

    # POST /v1/devices/pairing -> issue a short-lived, single-use code that a *new*
    # device redeems via POST /v1/auth/pair. The new device never needs this device's
    # token — it proves authorization with the code instead.
    def pairing
      p = DevicePairing.issue!(user: current_user)
      render json: { code: p.plaintext_code, expires_at: p.expires_at }, status: :created
    end
  end
end
