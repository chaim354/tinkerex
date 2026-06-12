module V1
  # Unauthenticated bootstrap.
  #
  # `register` creates a *new* account + its first device. It deliberately refuses an
  # email that already exists — handing out a device token for any known email was an
  # account-takeover hole. Additional devices join an existing library via a pairing
  # code issued by an already-authenticated device (`POST /v1/devices/pairing` →
  # `POST /v1/auth/pair`). Real OAuth/OIDC can later replace the email bootstrap; the
  # device-token + pairing mechanism downstream stays.
  class AuthController < ActionController::API
    rescue_from ActionController::ParameterMissing do |e|
      render json: { error: e.message }, status: :bad_request
    end

    # POST /v1/auth/register { email, device_name } — new account + its first device.
    def register
      email = params.require(:email)
      if User.exists?(email:)
        return render json: {
          error: "account_exists",
          detail: "An account with this email already exists. Add this device by pairing it " \
                  "from a signed-in device (POST /v1/devices/pairing -> POST /v1/auth/pair)."
        }, status: :conflict
      end
      user = User.create!(email:)
      device = Device.register!(user:, name: device_name)
      render json: payload(user, device), status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # POST /v1/auth/pair { email, code, device_name } — redeem a pairing code to add a
    # new device to an existing library. One generic error for unknown email OR bad code
    # (no account enumeration).
    def pair
      user = User.find_by(email: params.require(:email))
      unless user && DevicePairing.claim!(user:, code: params.require(:code))
        return render json: { error: "invalid_pairing" }, status: :unauthorized
      end
      device = Device.register!(user:, name: device_name)
      render json: payload(user, device), status: :created
    end

    private

    def device_name = params[:device_name].presence || "device"

    def payload(user, device)
      { user_id: user.id, device_id: device.id, device_token: device.plaintext_token, head_seq: user.head_seq }
    end
  end
end
