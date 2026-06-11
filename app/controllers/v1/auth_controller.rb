module V1
  # Unauthenticated bootstrap. Placeholder: create/find a user by email and register
  # the first device. Real OAuth/OIDC replaces this; everything downstream only needs
  # a device token.
  class AuthController < ActionController::API
    rescue_from ActiveRecord::RecordInvalid do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # POST /v1/auth/register { email, device_name }
    def register
      user = User.find_or_create_by!(email: params.require(:email))
      device = Device.register!(user:, name: params[:device_name].presence || "device")
      render json: {
        user_id: user.id,
        device_id: device.id,
        device_token: device.plaintext_token,
        head_seq: user.head_seq
      }, status: :created
    end
  end
end
