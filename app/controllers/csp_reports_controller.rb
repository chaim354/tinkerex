# THE COLLECTION HALF OF A REPORT-ONLY CSP, WITHOUT WHICH REPORT-ONLY MEASURES NOTHING.
#
# The policy ran report-only for weeks with no `report-uri`, which means every violation existed
# only in the console of whichever visitor happened to trigger it. The initializer's own plan —
# "read the violations from the browser console on the grid page, the editor, the file browser and
# all three /tools addons" — is a manual sweep of four surfaces by one person on one browser, and
# it cannot see what a real visitor's extension, browser version or addon bundle does. So the
# "collect, then flip to enforcing" step had no data to flip on. This endpoint is that data.
#
# DELIBERATELY NOT ApplicationController. Violations fire on pages an anonymous visitor reaches —
# sign-in, sign-up, password reset are exactly where the `'nonce-'` bug was found — so this must
# work with no session and no user. Inheriting ActionController::Base directly also keeps it clear
# of `allow_browser`, CurrentProject and the rest: a report is machine-to-machine, and the fewer
# app concerns it touches the fewer ways it can fail while reporting that something failed.
class CspReportsController < ActionController::Base
  # The browser POSTs this itself, with no CSRF token and no session — a token check would reject
  # every report. There is nothing to forge: the action authenticates nobody and changes no state,
  # it only writes a log line (which is why the caps below matter more than the token would).
  skip_forgery_protection

  # UNAUTHENTICATED AND PUBLIC BY NECESSITY, SO IT IS CAPPED TWICE.
  #
  # A report endpoint is a log-flood target: anyone can POST to it all day, and unlike the Devise
  # throttles this one protects disk and log volume rather than an account. `rate_limit` counts in
  # `config.action_controller.cache_store` (a real store in every env — see config/environments/
  # test.rb, which sets :memory_store precisely because NullStore#increment returns nil and makes a
  # throttle fire NEVER). 30/minute per IP is far above what a genuinely broken page produces in a
  # burst and far below what makes the log unreadable.
  rate_limit to: 30, within: 1.minute,
             with: -> { head :too_many_requests }

  # Chrome sends at most a few KB; anything larger is not a real report. Read and cap the RAW body
  # rather than letting Rails parse it: the content type is `application/csp-report`, which no
  # Rails parser is registered for, so `params` would be empty and a naive handler would log
  # nothing while returning 204 — silent, and indistinguishable from "no violations".
  MAX_BODY_BYTES = 16_384

  # Always 204, whatever happens. The browser discards the response either way, and answering an
  # error would only teach a scanner that malformed input is interesting. Failures are logged.
  def create
    body = request.raw_post.to_s
    return head(:no_content) if body.empty? || body.bytesize > MAX_BODY_BYTES

    report = JSON.parse(body)["csp-report"]
    return head(:no_content) unless report.is_a?(Hash)

    Rails.logger.warn("[csp-violation] #{summary(report).to_json}")
    head :no_content
  rescue JSON::ParserError
    head :no_content
  end

  private

  # A FIXED, TRUNCATED SUBSET — not the whole report. Two reasons, and the second is the one that
  # would bite later: the report is attacker-supplied JSON of unbounded shape, so logging it whole
  # lets anyone write arbitrary text into our logs; and `blocked-uri` can be a full URL carrying
  # query parameters from whatever page the visitor was on, which is how a violation report becomes
  # an accidental PII sink. Keep the fields that identify WHICH RULE broke WHERE, and truncate.
  FIELDS = %w[document-uri violated-directive effective-directive blocked-uri
              source-file line-number status-code disposition].freeze
  MAX_FIELD_CHARS = 300

  def summary(report)
    FIELDS.each_with_object({}) do |field, out|
      value = report[field]
      next if value.nil? || value == ""

      out[field] = value.is_a?(String) ? value.truncate(MAX_FIELD_CHARS) : value
    end
  end
end
