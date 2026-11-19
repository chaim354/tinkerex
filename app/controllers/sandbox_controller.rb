# GET /sandbox/:token/*path — an HTML file from the library, and the files beside it, served to RUN
# (2026-11-19, embedded files; docs/invariants/files-preview.md "The sandbox door").
#
# WHY A DOOR OF ITS OWN. `FileDelivery::SAFE_INLINE_TYPES` refuses `text/html` because user HTML at
# this app's origin is stored XSS: its scripts would read every page as the signed-in user. Here it is
# served under an ENFORCING `Content-Security-Policy: sandbox …` that never grants `allow-same-origin`,
# which gives the document an OPAQUE origin — it can run three.js off a CDN and draw, and it cannot
# read this app's cookies, pages or doors. The header holds even when the URL is opened in a tab on
# its own; the <iframe> that normally shows it carries the same `sandbox` attribute besides.
#
# ENFORCING, NEVER REPORT-ONLY, AND THE APP'S OWN POLICY IS OFF HERE. Browsers ignore `sandbox` in a
# `Content-Security-Policy-Report-Only` header, and this app's global policy is report-only
# (config/initializers/content_security_policy.rb) — so the sandbox policy is written by hand on every
# response that serves bytes. Rails' CSP middleware leaves alone a response that already carries a
# policy, so that header alone keeps the report-only one off a 200; `content_security_policy false`
# keeps it off the 404s and 304s too, which carry none — and with it the nonce generator, which reads
# the session (sandbox_test.rb pins both).
#
# NO SESSION. It stands on ActionController::Base like Public:: (§14d) and the token is the credential
# (Maker::HtmlSandbox says why a cookie cannot be). Nothing here reads the session, so the cookie store
# writes none, and no response from this door carries a Set-Cookie (pinned).
#
# THE BYTES COME THROUGH THE PORT'S `read` ON EVERY BACKEND — a deliberate departure from §15 for this
# one door, scoped by the size gate. The s3 delivery is a redirect to the bucket, and a redirect cannot
# carry the headers below; a relative `app.js` would also resolve against the bucket's key rather than
# the library folder. The catalog's size is checked BEFORE the read (Maker::HtmlSandbox::MAX_BYTES).
class SandboxController < ActionController::Base
  content_security_policy false

  # NO FORGERY PROTECTION, AND THE ONE CHECK IT WOULD RUN HERE IS WRONG FOR THIS DOOR. The door is GET
  # only and reads no session, so there is no state a forged request could change; what Rails WOULD do
  # is refuse a `.js` file with 422 ("cross-origin JavaScript embedding") — and a page loading its own
  # `<script src="app.js">` from an opaque origin is exactly that, by design.
  skip_forgery_protection

  # The public doors' budget: a public token is reachable by anyone who loaded the page.
  rate_limit to: Public::BaseController::ANONYMOUS_REQUESTS_PER_MINUTE, within: 1.minute,
             with: -> { head :too_many_requests }

  rescue_from FileLayer::NotFound do
    head :not_found
  end

  # An unmounted share or an unreachable store is RETRYABLE, never "gone" (§14a).
  rescue_from FileLayer::FetchError do
    head :service_unavailable
  end

  def show
    grant = Maker::HtmlSandbox.grant(params[:token])
    node = grant && Maker::HtmlSandbox.resolve(grant, params[:path])
    return head(:not_found) unless node

    info = FileLayer.current.stat(grant.owner, node_id: node.node_id)
    return head(:not_found) unless info&.content_token
    return head(:content_too_large) if info.size.to_i > Maker::HtmlSandbox::MAX_BYTES

    sandbox_headers!
    # THE CONTENT TOKEN IS THE ETAG: a reload of a 4 MB viewer whose file has not changed is a 304,
    # and a save is a new token. Rails then sends `max-age=0, private, must-revalidate` — `private`
    # because the token in the URL is a credential and no shared cache may keep the bytes, and
    # revalidated on every load so a save shows at once.
    return unless stale?(etag: info.content_token, public: false)

    bytes = FileLayer.current.read(grant.owner, node_id: node.node_id, content_token: info.content_token)
    send_data bytes, type: Marcel::MimeType.for(name: node.name), disposition: "inline"
  end

  private

  def sandbox_headers!
    response.headers["Content-Security-Policy"] = "sandbox #{Maker::HtmlSandbox::PERMISSIONS}"
    # THE TOKEN IS IN THE URL, so no request the page makes may carry it off-site in a Referer. The
    # browser's own default already strips a cross-origin Referer to the origin; this is the belt.
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Content-Type-Options"] = "nosniff"
  end
end
