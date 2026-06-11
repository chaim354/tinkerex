module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      device = Device.authenticate(request.params[:token])
      reject_unauthorized_connection unless device
      self.current_user = device.user
    end
  end
end
