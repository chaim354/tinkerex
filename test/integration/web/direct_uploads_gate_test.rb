require "test_helper"

module Web
  # `POST /rails/active_storage/direct_uploads` was live and UNAUTHENTICATED: an anonymous request
  # minted a real ActiveStorage::Blob and got a signed upload URL back — an anonymous write surface
  # into storage through Rails, the exact shape CLAUDE.md §15 exists to prevent.
  # ActiveStorage::DirectUploadsController descends from ActiveStorage::BaseController, not this app's
  # ApplicationController, so no amount of app-level auth reaches it.
  #
  # The route is REMOVED, not authenticated. `direct_upload` appears nowhere in app/, config/ or lib/,
  # and both editors run attachments-off, so nothing in this app calls it.
  class DirectUploadsGateTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    # Derived, not literal: the engine scopes this route under `ActiveStorage.routes_prefix`
    # (default "/rails/active_storage", operator-configurable) — see the matching route in
    # config/routes.rb for why a hard-coded path here would silently stop testing anything the
    # moment that prefix changes.
    PATH = "#{ActiveStorage.routes_prefix}/direct_uploads".freeze

    def blob_params
      { blob: { filename: "a.txt", byte_size: 3, checksum: "eB5eJF1ptWaXm4bijSPyxw==",
                content_type: "text/plain" } }
    end

    test "an anonymous direct upload is refused and mints no blob" do
      before = ActiveStorage::Blob.count
      post PATH, params: blob_params, as: :json
      assert_response :not_found, "expected the direct-upload route to be gone, got #{response.status}"
      assert_equal before, ActiveStorage::Blob.count
    end

    # This is what pins REMOVED rather than AUTH-GATED. Without it, a future change to
    # "authenticate instead of remove" would leave this file green while reopening the write surface
    # to every signed-in user — which is not what was decided.
    test "a signed-in direct upload is refused too" do
      user = User.create!(email: "du-#{SecureRandom.hex(4)}@example.com",
                          password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: user.email, password: PASSWORD } }
      assert_response :redirect, "sign-in did not take — this test proves nothing without it"

      before = ActiveStorage::Blob.count
      post PATH, params: blob_params, as: :json
      assert_response :not_found, "expected the direct-upload route to be gone, got #{response.status}"
      assert_equal before, ActiveStorage::Blob.count
    end

    # The gate must be SURGICAL. Maker::Preview uses has_one_attached :asset and is served with
    # url_for(p.asset), so Active Storage's blob routes are load-bearing — this is why
    # `config.active_storage.draw_routes = false` was rejected in the design. If a future edit reaches
    # for the blunt instrument, this test is what fails.
    test "the rest of the Active Storage routes are intact" do
      assert Rails.application.routes.url_helpers.respond_to?(:rails_blob_path),
             "rails_blob_path is gone — the gate took more than the one route with it"
      # Derived from the same prefix as PATH above, not the literal "active_storage/blobs" — that
      # string only matches because the DEFAULT prefix happens to end in "active_storage". Under a
      # reconfigured prefix the real blob path no longer contains it and this would false-fail on a
      # working deployment (or worse, false-pass a broken one under some other coincidence).
      assert Rails.application.routes.routes.any? { |r| r.path.spec.to_s.include?("#{ActiveStorage.routes_prefix}/blobs") },
             "the blob routes are gone — previews will not resolve"
    end
  end
end
