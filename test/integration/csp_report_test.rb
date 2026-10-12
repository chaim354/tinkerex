require "test_helper"

# THE CSP REPORT PIPELINE, END TO END — the header advertises a path, that path routes, and what
# lands there gets logged.
#
# WHY THIS FILE EXISTS AT ALL: the policy's `report_uri` is a LITERAL string that also appears in
# config/routes.rb, because deriving it from the named route does not boot (the CSP block is
# instance_exec'd while initializers run, before routes are drawn — see the comment there). A path
# written twice can desync, and the failure is SILENT: a browser posting to a 404 simply stops
# reporting, which looks exactly like a policy with no violations. So the property "these two
# agree" is asserted here instead of being guaranteed by construction.
class CspReportTest < ActionDispatch::IntegrationTest
  REPORT_PATH = "/csp-violation-report".freeze

  setup { ActionController::Base.cache_store.clear }

  # The literal in the initializer must be a route that exists. `recognize_path` is the right
  # instrument here (unlike the Active Storage shadow, where the endpoint is a proc carrying no
  # controller/action and recognize_path reports the engine's route instead).
  test "the report_uri the policy advertises actually routes to the collector" do
    advertised = Rails.application.config.content_security_policy.directives["report-uri"]
    assert_equal [ REPORT_PATH ], advertised, "the policy must advertise exactly this path"

    route = Rails.application.routes.recognize_path(advertised.sole, method: :post)
    assert_equal "csp_reports", route[:controller]
    assert_equal "create", route[:action]
  end

  # And the header a real response carries must contain it — the config object agreeing with
  # itself proves nothing about what a browser is told.
  test "an anonymous page's report-only header carries the report-uri" do
    get new_user_session_path
    assert_response :success

    header = response.headers["Content-Security-Policy-Report-Only"]
    assert header.present?, "report-only is the mode this app ships; enforcing has its own header"
    assert_includes header, "report-uri #{REPORT_PATH}"
  end

  # Anonymous, because the violations most worth catching happen on pages with no session — the
  # `'nonce-'` bug lived on exactly these. A collector behind authentication would miss them.
  test "a violation report from an anonymous visitor is accepted and logged" do
    report = {
      "csp-report" => {
        "document-uri" => "https://chunk.tinkerex.local/files",
        "violated-directive" => "script-src",
        "blocked-uri" => "https://evil.test/x.js",
        "line-number" => 12
      }
    }

    logged = capture_csp_logs do
      post REPORT_PATH, params: report.to_json, headers: { "CONTENT_TYPE" => "application/csp-report" }
    end

    assert_response :no_content
    assert_equal 1, logged.size, "the whole point of the endpoint is that this line exists"
    assert_includes logged.first, "script-src"
    assert_includes logged.first, "https://evil.test/x.js"
  end

  # THE FIELD LIST IS AN ALLOWLIST, NOT A DUMP. The report is attacker-supplied JSON of unbounded
  # shape: logging it whole lets anyone write arbitrary text into our logs, and `blocked-uri` can
  # carry a full URL with query parameters off whatever page the visitor was on — a violation
  # report is an easy accidental PII sink.
  test "only the allowlisted fields are logged, and long values are truncated" do
    logged = capture_csp_logs do
      post REPORT_PATH,
           params: { "csp-report" => { "violated-directive" => "img-src",
                                       "script-sample" => "SHOULD-NOT-BE-LOGGED",
                                       "document-uri" => "https://x.test/#{'a' * 900}" } }.to_json,
           headers: { "CONTENT_TYPE" => "application/csp-report" }
    end

    line = logged.sole
    assert_includes line, "img-src"
    assert_not_includes line, "SHOULD-NOT-BE-LOGGED", "unlisted fields must not be echoed"
    assert_not_includes line, "a" * 400, "a long value must be truncated, not logged whole"
  end

  test "a URL field's query string is not logged — it can carry the unlisted-project token" do
    # A same-origin document-uri is the page's own URL, and for an unlisted project that URL
    # carries the credential (`?k=<token>`, Public::BaseController). A blocked-uri can carry a
    # signed URL. The path is what a violation needs; the query must never reach the log.
    logged = capture_csp_logs do
      post REPORT_PATH,
           params: { "csp-report" => { "violated-directive" => "img-src",
                                       "document-uri" => "https://x.test/u/ada/rig?k=SECRETTOKEN",
                                       "blocked-uri"  => "https://y.test/img.png?sig=SECRETSIG" } }.to_json,
           headers: { "CONTENT_TYPE" => "application/csp-report" }
    end

    line = logged.sole
    assert_includes line, "/u/ada/rig", "the path is still logged"
    assert_not_includes line, "SECRETTOKEN"
    assert_not_includes line, "SECRETSIG"
  end

  # Every malformed shape answers 204 and logs nothing. 204 rather than 4xx because the browser
  # discards the response anyway, and an error status only tells a prober that bad input is
  # interesting. What must NOT happen is a 500 — an unauthenticated endpoint that can be crashed
  # by a POST is worse than no endpoint.
  test "malformed, empty and oversized bodies are refused quietly, never 500" do
    cases = {
      "not json at all"     => "<<<not json>>>",
      "json but not an obj" => "[1,2,3]".to_json,
      "no csp-report key"   => { "something" => "else" }.to_json,
      "csp-report not hash" => { "csp-report" => "nope" }.to_json,
      "empty body"          => "",
      "over the size cap"   => { "csp-report" => { "blocked-uri" => "x" * (CspReportsController::MAX_BODY_BYTES + 100) } }.to_json
    }

    cases.each do |name, body|
      logged = capture_csp_logs do
        post REPORT_PATH, params: body, headers: { "CONTENT_TYPE" => "application/csp-report" }
      end
      assert_response :no_content, "#{name}: expected a quiet 204"
      assert_empty logged, "#{name}: nothing should be logged"
    end
  end

  # Unauthenticated and public, so it is a log-flood target. The throttle is only observable
  # because config/environments/test.rb sets action_controller.cache_store to a REAL store —
  # NullStore#increment returns nil and would make `rate_limit` fire never (CLAUDE.md §14e).
  test "the collector is rate limited per IP" do
    body = { "csp-report" => { "violated-directive" => "img-src" } }.to_json
    headers = { "CONTENT_TYPE" => "application/csp-report" }

    31.times { post REPORT_PATH, params: body, headers: }

    assert_response :too_many_requests,
                    "an unauthenticated endpoint that writes to the log must be capped"
  end

  private

  # Captures only this endpoint's lines, so an unrelated warn elsewhere cannot make a test pass or
  # fail for the wrong reason.
  def capture_csp_logs
    io = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string.lines.select { |l| l.include?("[csp-violation]") }
  ensure
    Rails.logger = previous
  end
end
