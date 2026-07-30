require "test_helper"

module Web
  # The CSP is REPORT-ONLY, and that is a decision this test exists to defend.
  #
  # An enforcing `script-src 'self'` breaks `javascript_importmap_tags`, which emits an INLINE
  # <script type="importmap"> — so flipping report_only to false without first clearing the
  # violations takes every page's JavaScript down at once, silently, with a 200 response. Nothing
  # else in the suite would notice: the HTML still renders, the tests still pass, and only a
  # browser sees the failure.
  class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      email = "csp@example.com"
      User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
    end

    test "a page sends the report-only header and NOT the enforcing one" do
      get files_path
      assert_response :success

      assert response.headers["Content-Security-Policy-Report-Only"].present?,
             "the report-only CSP header must be sent"
      assert_nil response.headers["Content-Security-Policy"],
                 "the ENFORCING header must not be sent — an enforcing script-src breaks the " \
                 "inline importmap. Clear the violations before flipping report_only to false."
    end

    test "the policy carries the directives that matter" do
      get files_path
      csp = response.headers["Content-Security-Policy-Report-Only"]

      assert_match(/object-src 'none'/, csp, "object-src none blocks plugin embedding")
      assert_match(/base-uri 'self'/, csp, "base-uri self blocks <base> href injection")
      assert_match(/form-action 'self'/, csp, "form-action self blocks form hijacking")
      assert_match(/script-src[^;]*'self'/, csp)
    end

    test "frame-ancestors is 'self', not 'none' — the app frames its own PDF previews" do
      # files/show and models/show embed blob_file_path in a same-origin <iframe>. 'none' would
      # refuse to let our own page frame our own endpoint, blanking every PDF preview the moment
      # the policy is enforced. Rails' default X-Frame-Options is SAMEORIGIN, so 'self' is also
      # the consistent answer.
      get files_path
      csp = response.headers["Content-Security-Policy-Report-Only"]

      assert_match(/frame-ancestors 'self'/, csp)
      assert_no_match(/frame-ancestors 'none'/, csp)
    end

    test "the nonce is never empty, including for an anonymous visitor" do
      # session.id is nil until a session exists, so a nonce of `request.session.id.to_s` renders
      # as `'nonce-'` on every sign-in / sign-up / reset page. Chrome calls that an invalid source
      # and IGNORES THE ENTIRE script-src DIRECTIVE — a policy that protects nothing on exactly
      # the pages reachable without credentials. Caught by the system tests' console-error check;
      # pinned here so it does not need a browser next time.
      reset!  # drop the signed-in session from setup

      get new_user_session_path
      assert_response :success
      csp = response.headers["Content-Security-Policy-Report-Only"]

      assert_no_match(/'nonce-'/, csp,
                      "an empty nonce makes Chrome discard the whole script-src directive")
      nonce = csp[/script-src[^;]*'nonce-([^']+)'/, 1]
      assert nonce.present?, "an anonymous page must still carry a usable nonce"
    end

    test "the inline importmap is nonced, so the policy can be enforced later" do
      # The nonce is what makes flipping to enforcing possible at all. If script-src is in the
      # nonce directives but the importmap tag does not carry one, the enforcing flip fails at
      # exactly the moment it is hardest to debug.
      get files_path
      csp = response.headers["Content-Security-Policy-Report-Only"]
      nonce = csp[/script-src[^;]*'nonce-([^']+)'/, 1]

      assert nonce.present?, "script-src must carry a nonce for the inline importmap"
      assert_select "script[type=?][nonce=?]", "importmap", nonce, { count: 1 },
                    "the importmap tag must carry the same nonce the policy names"
    end
  end
end
