require "test_helper"
require "open3"

# CLOUDFLARE_ONLY (config/initializers/trusted_proxies.rb): an origin behind Cloudflare refuses every
# request whose peer at kamal-proxy, the X-Forwarded-For entry kamal-proxy appended, is not one of
# Cloudflare's pinned ranges. Driven through the real middleware with the app's real pin.
#
# THE CHAINS BELOW ARE THE ONES MEASURED ON OVH (2026-10-26), not the ones the design assumed. The
# first version took the right-most entry to be kamal-proxy's and passed every test here written in
# that shape, then failed its deploy: Thruster, in front of Puma inside the image, appends kamal-proxy's
# container address (THRUSTER_HOP) after it and reaches Puma over loopback. A direct IPv6 request
# arrives at kamal-proxy from Docker's gateway (V6_RELAY), not from the client.
class CloudflareOnlyTest < ActiveSupport::TestCase
  EDGE   = "104.23.190.84".freeze   # a measured Cloudflare edge node (tinkerex#345)
  EDGE6  = "2606:4700:10::6816:4c80".freeze
  STRANGER = "198.51.100.7".freeze  # TEST-NET-2: public, not Cloudflare
  THRUSTER_HOP = "172.18.0.3".freeze # kamal-proxy's container, as Thruster sees it
  V6_RELAY = "172.18.0.1".freeze     # what kamal-proxy sees for a direct IPv6 request
  THRUSTER = "127.0.0.1".freeze      # REMOTE_ADDR when Thruster hands the request to Puma

  def respond_to(forwarded_for, remote_addr: THRUSTER)
    reached = false
    app = ->(_env) { reached = true; [ 200, {}, [ "app" ] ] }
    headers = forwarded_for.nil? ? {} : { "HTTP_X_FORWARDED_FOR" => forwarded_for }
    status, = CloudflareOnly.new(app, Rails.application.config.x.cloudflare_ranges)
                            .call(Rack::MockRequest.env_for("/", "REMOTE_ADDR" => remote_addr, **headers))
    [ status, reached ]
  end

  test "a request Cloudflare forwarded reaches the app, over either family" do
    assert_equal [ 200, true ], respond_to("203.0.113.9, #{EDGE}, #{THRUSTER_HOP}")
    assert_equal [ 200, true ], respond_to("2001:db8::9, #{EDGE6}, #{THRUSTER_HOP}")
    assert_equal [ 200, true ], respond_to("::ffff:#{EDGE}, #{THRUSTER_HOP}"), "an IPv4-mapped peer is still the edge"
    assert_equal [ 200, true ], respond_to("203.0.113.9, #{EDGE}, #{THRUSTER_HOP}", remote_addr: "::1"),
                 "Thruster may reach Puma over IPv6 loopback"
  end

  test "a request straight at the origin is refused before the app sees it" do
    assert_equal [ 403, false ], respond_to("#{STRANGER}, #{THRUSTER_HOP}")
    assert_equal [ 403, false ], respond_to("#{V6_RELAY}, #{THRUSTER_HOP}"), "the measured shape of a direct IPv6 request"
    assert_equal [ 403, false ], respond_to("not-an-address, #{THRUSTER_HOP}")
  end

  # THE CHAIN TO THE LEFT OF kamal-proxy's ENTRY IS THE CLIENT'S TO WRITE. The IPv6 case is the one a
  # "skip private addresses from the right" rule gets wrong: past the relay's private address it would
  # judge the forged edge and let it in.
  test "a forged Cloudflare hop ahead of the real peer is refused, over IPv4 and IPv6" do
    assert_equal [ 403, false ], respond_to("#{EDGE}, #{STRANGER}, #{THRUSTER_HOP}")
    assert_equal [ 403, false ], respond_to("#{EDGE}, #{V6_RELAY}, #{THRUSTER_HOP}")
  end

  # NOT THROUGH kamal-proxy's FORWARDING: its health probe carries no chain, so it arrives as
  # Thruster's one entry over loopback (the measured shape that refused the first deploy), and a
  # `kamal app exec curl localhost` arrives as Thruster's own loopback entry.
  test "the deploy health check and an in-container request pass" do
    assert_equal [ 200, true ], respond_to(THRUSTER_HOP)
    assert_equal [ 200, true ], respond_to("127.0.0.1")
    assert_equal [ 200, true ], respond_to(nil)
  end

  # WITHOUT THRUSTER kamal-proxy talks to Puma itself: REMOTE_ADDR is its container, not loopback, and
  # its own entry is already the right-most one, so nothing is dropped.
  test "with no proxy inside the container, kamal-proxy's entry is the last one" do
    assert_equal [ 200, true ], respond_to("203.0.113.9, #{EDGE}", remote_addr: THRUSTER_HOP)
    assert_equal [ 403, false ], respond_to(STRANGER, remote_addr: THRUSTER_HOP)
    assert_equal [ 200, true ], respond_to(nil, remote_addr: THRUSTER_HOP), "kamal-proxy's health probe, straight to Puma"
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
