module V1
  # TEST/DEV-ONLY signup seam. Creates a CONFIRMED password account directly so the Rust
  # integration tests (which run against a real Rails server) can then enroll devices via
  # POST /v1/devices/login. Mounted only outside production AND only when ENABLE_TEST_SIGNUP
  # is set (mirrors the STORAGE_BACKEND=memory test-server pattern). NEVER ships active in
  # production — there device enrollment requires a real, email-confirmed Devise account.
  class TestUsersController < ActionController::API
    rescue_from ActionController::ParameterMissing do |e|
      render json: { error: e.message }, status: :bad_request
    end

    def create
      unless ENV["ENABLE_TEST_SIGNUP"].present? && !Rails.env.production?
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
