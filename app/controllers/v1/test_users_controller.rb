module V1
  # TEST/DEV-ONLY signup seam. Creates a CONFIRMED password account directly so the Rust
  # integration tests (which run against a real Rails server) can then enroll devices via
  # POST /v1/devices/login. Gated SOLELY on the explicit ENABLE_TEST_SIGNUP flag (off by
  # default) — deliberately NOT on RAILS_ENV, so a self-hosted NON-production test/dev deploy
  # (e.g. the Unraid box, which runs as RAILS_ENV=production for deploy reasons) can opt in.
  # The flag IS the gate: NEVER set ENABLE_TEST_SIGNUP on the real managed SaaS production —
  # it bypasses email confirmation. A boot warning fires whenever it's on (see the initializer).
  class TestUsersController < ActionController::API
    rescue_from ActionController::ParameterMissing do |e|
      render json: { error: e.message }, status: :bad_request
    end

    def create
      unless ENV["ENABLE_TEST_SIGNUP"].present?
        return render json: { error: "not_found" }, status: :not_found
      end

      email    = params.require(:email)
      password = params.require(:password)
      user = User.find_by(email:) ||
             User.create!(email:, password:, confirmed_at: Time.current)
      render json: { user_id: user.id, email: user.email }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end
end
