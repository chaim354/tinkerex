module V1
  class DevicesController < BaseController
    # POST /v1/devices { name } -> register an additional device for the current user
    def create
      device = Device.register!(user: current_user, name: params[:name].presence || "device")
      render json: { device_id: device.id, device_token: device.plaintext_token }, status: :created
    end
  end
end
