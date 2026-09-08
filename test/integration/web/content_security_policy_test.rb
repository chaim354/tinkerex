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

    # `'wasm-unsafe-eval'` IS WHAT KEEPS THE 3D VIEWER'S CAD IMPORTERS WORKING WHEN THE POLICY IS
    # ENFORCED. Chrome refuses `WebAssembly.instantiate` under a `script-src` carrying neither this
    # nor `'unsafe-eval'`, and OpenCascade (STEP/IGES/BREP/FCStd) and the Draco glTF decoder are
    # both wasm — so without it, flipping report_only to false would take STEP previews down while
    # every mesh format kept working, a failure shaped exactly like a broken CAD file rather than
    # like a policy. (rhino3dm's 3DM importer is the one this does NOT cover: its embind glue uses
    # `new Function`, so `.3dm` is the importer to re-check before the policy enforces — the
    # initializer says so.)
    #
    # AND `'unsafe-eval'` MUST STAY OUT, which is the half worth asserting rather than assuming:
    # the two are separate sources precisely so a page can run WebAssembly without also being
    # allowed to `eval` a string, and reaching for the wrong one would hand back the XSS surface
    # this policy exists to remove.
    test "script-src permits WebAssembly and still refuses eval" do
      get files_path
      csp = response.headers["Content-Security-Policy-Report-Only"]

      assert_match(/script-src[^;]*'wasm-unsafe-eval'/, csp)
      assert_no_match(/script-src[^;]*'unsafe-eval'/, csp)
    end

    # NO `blob:` AND NO `worker-src` WIDENING, and that is a claim about bin/build-o3dv rather than
    # about this file: upstream Online3DViewer builds its OpenCascade worker out of a `blob:` URL,
    # which `'self'` refuses, and the vendoring script patches it into a plain same-origin worker
    # served from public/o3dv/<version>/ instead. `worker-src` falls back to `child-src` and then
    # to `script-src`, so `'self'` already covers that — reverting the patch would be invisible
    # here and visible only as a violation report, which is why it is written down.
    test "the policy still has no blob: script source and no worker-src of its own" do
      get files_path
      csp = response.headers["Content-Security-Policy-Report-Only"]

      assert_no_match(/script-src[^;]*blob:/, csp)
      assert_no_match(/worker-src/, csp)
    end

    # `connect-src` NAMES THE STORE A PRESIGNED DOWNLOAD REDIRECTS TO, and the port is what says
    # which. On s3 `/files/:id/blob` answers 302 to the bucket and every in-browser viewer fetches
    # that URL; a policy of `'self'` alone reports each fetch today and refuses it the day it
    # enforces (S3-2's "s3 follow-up"). Branches on the CAPABILITY, not the backend's name, so the
    # three legs each pin their own answer: the s3 leg must carry the adapter's origin, and the
    # other two must carry nothing but 'self' — a store address hand-written into the initializer
    # fails on those two, and a dropped source fails on s3.
    # THE SAME QUESTION FOR A PUBLIC PAGE, ON THE AMBIENT LEG (stage 4, S4-5, found in review). Every
    # public suite pins a fresh SHARE library for its bytes, so a presignable-arm assertion written
    # there is dead on all three legs; /explore needs no fixture at all, and Public::BaseController is
    # where the anonymous-nonce path and the policy meet. The s3 leg is the one that carries the origin.
    test "a public page's connect-src names the presigned origin on a presignable backend and only 'self' elsewhere" do
      get public_explore_path
      assert_response :success
      sources = response.headers["Content-Security-Policy-Report-Only"][/connect-src ([^;]+)/, 1]
      port = FileLayer.current

      if port.capabilities.presignable?
        assert_equal "'self' #{port.presigned_origin}", sources
      else
        assert_equal "'self'", sources
      end
    end

    test "connect-src names the presigned origin on a presignable backend and only 'self' elsewhere" do
      get files_path
      csp = response.headers["Content-Security-Policy-Report-Only"]
      sources = csp[/connect-src ([^;]+)/, 1]
      port = FileLayer.current

      if port.capabilities.presignable?
        assert_match(%r{\Ahttps?://[^/\s]+\z}, port.presigned_origin.to_s)
        assert_equal "'self' #{port.presigned_origin}", sources
      else
        assert_equal "'self'", sources
      end
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
