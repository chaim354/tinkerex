# Test double for Maker::Addons::ServiceProxy, mirroring test/support/fake_addon_source.rb. Injected
# via `Maker::Addons::ServiceProxy.stub = FakeServiceProxy.new`; reset in teardown. This is the seam
# the controller test uses instead of stubbing Net::HTTP globally (this repo has no `Object#stub` —
# minitest 6 dropped minitest/mock; test/test_helper.rb:147).
#
# Keyed by the FULL request URL (base + path), not just the path, so a test can assert exactly which
# sidecar and endpoint got hit, and so a test that wires up a response for one host cannot
# accidentally satisfy a call meant to prove a DIFFERENT host was never reachable in the first place.
class FakeServiceProxy
  # `read_timeout` is RECORDED, not honoured — nothing here blocks, so there is nothing to time out.
  # It is on the Call so a test can assert what the controller RESOLVED for a service (the manifest
  # value, the host cap, or the default), which is the only observable half of that decision.
  Call = Data.define(:method, :url, :path, :params, :read_timeout)

  attr_reader :calls

  def initialize
    @responses = {}
    @calls = []
  end

  def ok(full_url, body:, content_type: "application/octet-stream", status: 200)
    @responses[full_url] = Maker::Addons::ServiceProxy::Response.new(status: status, content_type: content_type, body: body)
  end

  # Mirrors the real signature INCLUDING its default, so a caller that passes no read_timeout is
  # recorded with the same 30 s the real proxy would have used — a fake that recorded `nil` there
  # would make "the default was applied" and "the argument was dropped" look identical (§14e).
  def call(method:, url:, path:, params: {},
           read_timeout: Maker::Addons::ServiceProxy::READ_TIMEOUT)
    @calls << Call.new(method: method, url: url, path: path, params: params,
                       read_timeout: read_timeout)
    key = "#{url.to_s.chomp('/')}/#{path}"
    @responses.fetch(key) { raise Maker::Addons::ServiceProxy::Error, "no stub registered for #{key}" }
  end
end
