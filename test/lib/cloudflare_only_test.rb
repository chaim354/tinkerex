require "test_helper"
require "open3"

# CLOUDFLARE_ONLY (config/initializers/trusted_proxies.rb): an origin behind Cloudflare refuses every
# request whose real peer, the right-most X-Forwarded-For entry kamal-proxy appends, is not one of
# Cloudflare's pinned ranges. Driven through the real middleware with the app's real pin.
class CloudflareOnlyTest < ActiveSupport::TestCase
  EDGE   = "104.23.190.84".freeze   # a measured Cloudflare edge node (tinkerex#345)
  EDGE6  = "2606:4700:10::6816:4c80".freeze
  STRANGER = "198.51.100.7".freeze  # TEST-NET-2: public, not Cloudflare

  def respond_to(forwarded_for)
    reached = false
    app = ->(_env) { reached = true; [ 200, {}, [ "app" ] ] }
    headers = forwarded_for.nil? ? {} : { "HTTP_X_FORWARDED_FOR" => forwarded_for }
    status, = CloudflareOnly.new(app, Rails.application.config.x.cloudflare_ranges)
                            .call(Rack::MockRequest.env_for("/", "REMOTE_ADDR" => "172.18.0.2", **headers))
    [ status, reached ]
  end

  test "a request Cloudflare forwarded reaches the app, over either family" do
    assert_equal [ 200, true ], respond_to("203.0.113.9, #{EDGE}")
    assert_equal [ 200, true ], respond_to("2001:db8::9, #{EDGE6}")
    assert_equal [ 200, true ], respond_to("::ffff:#{EDGE}"), "an IPv4-mapped peer is still the edge"
  end

  test "a request straight at the origin is refused before the app sees it" do
    assert_equal [ 403, false ], respond_to(STRANGER)
    assert_equal [ 403, false ], respond_to("172.17.0.1"), "a private peer (docker's IPv6 proxy) is not Cloudflare"
    assert_equal [ 403, false ], respond_to("not-an-address")
  end

  # THE CHAIN TO THE LEFT IS THE CLIENT'S TO WRITE. A direct visitor who forges a Cloudflare hop
  # still arrives with kamal-proxy's real peer appended after it, and that is the entry asked about.
  test "a forged Cloudflare hop ahead of the real peer is refused" do
    assert_equal [ 403, false ], respond_to("#{EDGE}, #{STRANGER}")
  end

  # NO CHAIN AT ALL IS NOT kamal-proxy's FORWARDING PATH: its health check and a `kamal app exec
  # curl` reach the container without one, and the container publishes no port of its own.
  test "a request with no forwarding chain passes, so the deploy health check does" do
    assert_equal [ 200, true ], respond_to(nil)
  end

  # ONLY WHERE IT IS SET. The suite boots without CLOUDFLARE_ONLY, the way every Unraid box does, so
  # the guard must be absent here; a separate boot with it set must put it first in the stack,
  # ahead of every middleware that could answer with something of the app's.
  # MUTATION (§15): the initializer's `insert_before 0` line deleted reds the second assertion.
  test "the guard is in the stack only when CLOUDFLARE_ONLY is set, and then it is first" do
    refute Rails.application.middleware.include?(CloudflareOnly), "unset here, as on the Unraid boxes"

    out, err, status = Open3.capture3({ "CLOUDFLARE_ONLY" => "1", "RAILS_ENV" => "test" },
                                      Rails.root.join("bin/rails").to_s, "runner",
                                      "puts Rails.application.middleware.first.klass.name",
                                      chdir: Rails.root.to_s)
    assert status.success?, "the CLOUDFLARE_ONLY boot failed: #{err.lines.last(5).join}"
    assert_equal "CloudflareOnly", out.lines.last.to_s.strip
  end
end
