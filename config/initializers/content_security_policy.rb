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
# enforcing `script-src :self` with no nonce takes every page's JavaScript down at once. Run
# report-only, read the violations from the browser console on the grid page, the editor, the file
# browser and all three /tools addons, then tighten and flip. Tracked in docs/OPEN-WORK.md.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    # :data for inline preview thumbnails; :blob for the client-side SVG the generators addon
    # builds in the browser.
    policy.img_src     :self, :data, :blob
    policy.object_src  :none
    policy.script_src  :self
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

  # MEASURE, DO NOT ENFORCE. Flip this to false only after the violation list is empty across the
  # grid page, the rich-text editor, the file browser and all three /tools addons.
  config.content_security_policy_report_only = true
end
