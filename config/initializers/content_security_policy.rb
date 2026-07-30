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
    policy.frame_ancestors :none
  end

  # The importmap tag is inline and needs the nonce. session.id is stable per session, which is
  # what Rails' own generated template recommends.
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src]

  # MEASURE, DO NOT ENFORCE. Flip this to false only after the violation list is empty across the
  # grid page, the rich-text editor, the file browser and all three /tools addons.
  config.content_security_policy_report_only = true
end
