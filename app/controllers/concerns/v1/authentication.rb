# frozen_string_literal: true

# BEARER DEVICE-TOKEN AUTH FOR THE HOST'S OWN v1 API — the fourteen v1/maker/* controllers plus
# devices and test_users.
#
# THIS IS A SECOND COPY OF Sync::V1::Authentication, AND THE DUPLICATION IS STRUCTURAL RATHER THAN
# LAZY. Neither side can require the other in the case that matters: on share/s3 the engine is not
# loaded, so the host cannot include the engine's concern; and in a bare engine mount there is no
# host application, so the engine cannot include this one. A shared third home would have to be a
# gem that both depend on, for twelve lines whose only real dependency — `Device` — the HOST
# already owns (CLAUDE.md §14j: Device stays host-side precisely because its token is the only
# credential the v1 API accepts).
#
# So the answer is the one this repo uses wherever a second copy is forced: duplicate, then make
# the copies unable to drift quietly. `test/v1_auth_parity_test.rb` compares the two
# implementations and fails when they stop agreeing — the same shape as
# test/engine_schema_test.rb's check against the gem's own db/engine_schema.rb.
module V1
  module Authentication
    extend ActiveSupport::Concern

    included do
      before_action :authenticate_device!
    end

    private

    def authenticate_device!
      token = request.authorization.to_s.delete_prefix("Bearer ").strip
      @current_device = Device.authenticate(token)
      return render(json: { error: "unauthorized" }, status: :unauthorized) unless @current_device

      @current_user = @current_device.user
      @current_device.touch_seen!
    end

    def current_user = @current_user
    def current_device = @current_device
  end
end
