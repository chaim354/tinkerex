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
      assert_match(/frame-ancestors 'none'/, csp, "frame-ancestors none blocks clickjacking")
      assert_match(/base-uri 'self'/, csp, "base-uri self blocks <base> href injection")
      assert_match(/form-action 'self'/, csp, "form-action self blocks form hijacking")
      assert_match(/script-src[^;]*'self'/, csp)
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
