# Be sure to restart your server when you modify this file.
#
# REPORT-ONLY, ON PURPOSE, FOR NOW.
#
# This is defence in depth rather than the primary control: the obvious stored-XSS route in an
# app that serves user-uploaded bytes is already closed in the right place. FilesController#blob
# serves `inline` only for a raster allowlist plus application/pdf and forces everything else —
# naming SVG and HTML — to `attachment` with X-Content-Type-Options: nosniff. Action Text
# sanitises rich text and Maker::TextOnlyRichText strips attachments server-side. CSP is here to
# catch the NEXT inline-serving mistake, not today's.
#
# WHY NOT ENFORCING YET: the app ships a vendored Jspreadsheet grid, the Lexxy rich-text editor,
# and an importmap. `javascript_importmap_tags` emits an INLINE <script type="importmap">, so an
# enforcing `script-src :self` with no nonce takes every page's JavaScript down at once.
#
# VIOLATIONS ARE NOW COLLECTED, WHICH THEY WERE NOT. The plan used to be "read them from the
# browser console on the grid page, the editor, the file browser and all three /tools addons" —
# one person, one browser, four pages, and blind to what a real visitor's extension or a
# republished addon bundle triggers. `report_uri` below now POSTs every violation to
# CspReportsController, which logs it. Grep a week of `[csp-violation]` lines
# (`kamal app logs -g csp-violation`) before flipping the switch at the bottom of this file.
#
# ONE MORE THING TO CHECK BEFORE FLIPPING, because the addon platform changed the stakes since
# this comment was written: enforcing is the only egress control against a hostile addon bundle
# (a bundle runs same-origin with the session), so it matters more than it did — but a bundle
# needing `unsafe-eval` or a `blob:` worker will break the moment it is enforced. Confirm the
# collected reports are empty for /tools/* specifically, not just for the four host pages.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    # :data for inline preview thumbnails; :blob for the client-side SVG the generators addon
    # builds in the browser.
    policy.img_src     :self, :data, :blob
    # `connect-src` NAMES THE STORE A PRESIGNED DOWNLOAD REDIRECTS TO, AND THE PORT SAYS WHICH. On
    # the s3 backend `/files/:id/blob` answers 302 to a presigned URL at the bucket, and every
    # in-browser viewer — the 3D viewer, KiCanvas, the Gerber viewer, the public bundle — FETCHES
    # it: `'self'` alone reports each of those fetches today and would refuse them the day this
    # enforces, the gap S3-2 through S3-6 recorded as "the s3 follow-up". A Proc source is
    # instance_exec'd on the controller per response, where app constants resolve (an initializer
    # cannot autoload them — §14a's boot-guard lesson), so the policy asks `FileLayer.current` and
    # NEVER hand-writes a store address from LIBRARY_S3_ENDPOINT: the adapter reads the SDK's
    # resolved endpoint, so this names what the wire will carry, and nil — `'self'` only — on the
    # two backends that stream from Rails (share, chunk_remote). The OTHER half is the bucket's
    # CORS rule, which Rails cannot set: docs/DEPLOY.md. Pinned per leg by
    # test/integration/web/content_security_policy_test.rb.
    #
    # `respond_to?` IS FOR THE TEST DOUBLES, not for a real adapter: controller tests install a
    # port that stands in for ONE failure mode (`UnreachablePort`, `MissingBytesPort`, a bare
    # Object with a single `download`) and answers nothing else, and this middleware runs on every
    # HTML response those tests render. The three real adapters are contract-bound to answer
    # (`adapter_contract.rb`), and the s3 leg's CSP test goes red if this ever yields nothing there.
    policy.connect_src :self, lambda {
      port = FileLayer.current
      port.presigned_origin if port.respond_to?(:presigned_origin)
    }
    policy.object_src  :none
    # `'wasm-unsafe-eval'` BUYS THE WEBASSEMBLY IMPORTERS AND NOTHING ELSE, which is the whole
    # reason it exists as a source separate from `'unsafe-eval'`. Chrome refuses
    # `WebAssembly.instantiate` under an enforcing `script-src` that carries neither, and the 3D
    # viewer's OpenCascade (STEP/IGES/BREP/FCStd) and Draco importers are wasm — so without this,
    # flipping report_only to false would take STEP previews down while leaving every mesh format
    # working, a failure shaped exactly like a broken CAD file. It does NOT permit `eval`,
    # `new Function` or a string timer, so the XSS surface `'unsafe-eval'` would open stays closed.
    #
    # ONE IMPORTER THIS DOES NOT COVER: rhino3dm (3DM). Its emscripten embind glue builds
    # constructors with `new Function` at module load (two sites, probed in the review), so under an
    # ENFORCING policy `.3dm` alone degrades to the poster — and it has no F3D thumbnail either, so
    # that page would show nothing. Harmless while report-only; re-check `.3dm` before flipping
    # `content_security_policy_report_only`, and do not reach for `'unsafe-eval'` to keep it.
    #
    # TODAY IT ONLY STOPS THE REPORTS (the policy is report-only, see the bottom of this file), and
    # that is worth having on its own: a directory of noise in the [csp-violation] log is what the
    # "clear the violations, then flip" plan above has to read through.
    #
    # NOTHING NEW IS NEEDED FOR THE OCCT *WORKER*. `worker-src` falls back to `child-src` and then
    # to `script-src`, and bin/build-o3dv patches upstream's fetched `blob:` worker into a plain
    # same-origin one served from public/o3dv/<version>/ — which `'self'` already covers. A blob:
    # worker would have needed a `worker-src blob:` widening; not doing that was the point.
    policy.script_src  :self, :wasm_unsafe_eval
    # 'unsafe-inline' because the vendored grid and the editor set style attributes at runtime.
    # Narrowing this is the follow-up, and it is why style-src is NOT in the nonce directives
    # below: a nonce plus 'unsafe-inline' means the nonce wins and inline styles break, which is
    # the opposite of what we want while still measuring.
    policy.style_src   :self, :unsafe_inline
    policy.base_uri    :self
    policy.form_action :self

    # :self, NOT :none — and the browser is what settled this. The app embeds its own PDF previews
    # in same-origin iframes (app/views/files/show.html.erb, app/views/models/show.html.erb), and
    # Rails' own default is already X-Frame-Options: SAMEORIGIN. `frame-ancestors 'none'` is
    # stricter than the app's own behaviour, so enforcing it would refuse to let OUR page frame OUR
    # blob endpoint — PDF previews would go blank. The system tests logged the report-only
    # violation on the first run; no integration test could have.
    policy.frame_ancestors :self

    # REPORT-ONLY WITHOUT A report-uri MEASURES NOTHING, which is what this policy did until now.
    # Every violation landed in the console of whichever visitor triggered it and nowhere else, so
    # the "read the violations, then tighten and flip" plan above had no data to read: the manual
    # sweep it describes is one person, one browser, four pages, and it cannot see what a real
    # visitor's extension or a republished addon bundle does. Collect first, then flip.
    #
    # A LITERAL, AND NOT FOR WANT OF TRYING TO DERIVE IT. This path is written twice — here and in
    # config/routes.rb — which is exactly the shape this repo distrusts, because a report-uri
    # pointing at a 404 fails SILENTLY: the browser stops reporting and says nothing, which is
    # indistinguishable from a clean policy. The obvious fix,
    # `Rails.application.routes.url_helpers.csp_violation_report_path`, DOES NOT BOOT: this block is
    # `instance_exec`'d EAGERLY inside ActionDispatch::ContentSecurityPolicy#initialize, i.e. while
    # config/initializers runs, and routes are not drawn until the finisher — so the helper is
    # undefined and the whole app dies at boot with `undefined method 'csp_violation_report_path'`.
    # Same family as §14a's `Library` boot guard, and found the same way: by booting, not by
    # reading. Do not "clean this up" back into a helper call.
    #
    # The duplication is therefore guarded by a TEST instead of by construction —
    # test/integration/csp_report_test.rb asserts this literal both resolves to CspReportsController
    # and is what the response header actually carries. Change one, that test fails.
    #
    # `_path`-shaped, not a full URL: the report is same-origin, and a hard-coded host would be
    # wrong on at least two of the three backend hostnames and on OVH's domain.
    #
    # `report-uri` is formally deprecated in favour of `report-to`, which additionally needs a
    # `Reporting-Endpoints` response header and a named endpoint group. Deliberately not used yet:
    # report-uri is what current browsers still honour, and the point of this change is to get data
    # now, not to be standards-current. Revisit when flipping to enforcing.
    policy.report_uri "/csp-violation-report"
  end

  # The importmap tag is inline and needs a nonce.
  #
  # `.presence ||` IS LOAD-BEARING, and this is the second thing the browser caught. `session.id`
  # is nil until a session exists, so an ANONYMOUS visitor — every sign-in, sign-up and reset page
  # — got `'nonce-'`, which Chrome reports as "an invalid source" and then IGNORES THE WHOLE
  # script-src DIRECTIVE. Report-only made that harmless; enforcing it would have shipped a policy
  # that silently protects nothing on exactly the pages an attacker reaches without credentials.
  # A random nonce is correct for those pages: it only has to match the tags in the same response.
  config.content_security_policy_nonce_generator = lambda do |request|
    request.session.id.to_s.presence || SecureRandom.base64(16)
  end
  config.content_security_policy_nonce_directives = %w[script-src]

  # MEASURE, DO NOT ENFORCE — but measurement is now real rather than aspirational (see the
  # report_uri above). Flip this to false only after a stretch of production traffic produces no
  # `[csp-violation]` log lines, /tools/* included.
  config.content_security_policy_report_only = true
end
