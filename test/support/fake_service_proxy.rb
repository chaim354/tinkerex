# Test double for Maker::Addons::ServiceProxy, mirroring test/support/fake_addon_source.rb. Injected
# via `Maker::Addons::ServiceProxy.stub = FakeServiceProxy.new`; reset in teardown. This is the seam
# the controller test uses instead of stubbing Net::HTTP globally (this repo has no `Object#stub` —
# minitest 6 dropped minitest/mock; test/test_helper.rb:147).
#
# Keyed by the FULL request URL (base + path), not just the path, so a test can assert exactly which
# sidecar and endpoint got hit, and so a test that wires up a response for one host cannot
# accidentally satisfy a call meant to prove a DIFFERENT host was never reachable in the first place.
class FakeServiceProxy
  Call = Data.define(:method, :url, :path, :params)

  attr_reader :calls

  def initialize
    @responses = {}
    @calls = []
  end

  def ok(full_url, body:, content_type: "application/octet-stream", status: 200)
    @responses[full_url] = Maker::Addons::ServiceProxy::Response.new(status: status, content_type: content_type, body: body)
  end

  def call(method:, url:, path:, params: {})
    @calls << Call.new(method: method, url: url, path: path, params: params)
    key = "#{url.to_s.chomp('/')}/#{path}"
    @responses.fetch(key) { raise Maker::Addons::ServiceProxy::Error, "no stub registered for #{key}" }
  end
end
