require "test_helper"

# Behind Cloudflare the visitor's address is the LEFT-most X-Forwarded-For entry (Cloudflare puts
# it there) and kamal-proxy appends its peer, the edge node, after it; Rails' RemoteIp walks the
# chain from the right skipping trusted proxies, so with only the default (private-range) proxies
# trusted, `request.remote_ip` was the edge node — every per-IP throttle keyed on Cloudflare
# (tinkerex#345, measured: four edge IPs for ten probes). Trusting Cloudflare's published ranges
# makes the visitor the answer there and changes nothing elsewhere: a direct request never carries
# a Cloudflare hop.
#
# WHAT DEFEATS A FORGED HEADER IS THE PEER kamal-proxy APPENDS, not the trusted list — the last
# two tests pin that shape, and the one before them records the shape that would be forgeable if
# the proxy ever stopped appending (config/initializers/trusted_proxies.rb has the argument).
class TrustedProxiesTest < ActiveSupport::TestCase
  PINNED = Rails.root.join("config/cloudflare_ips.yml")

  def configured_proxies = Rails.application.config.action_dispatch.trusted_proxies

  # Runs the real middleware with the app's real trusted-proxy list and returns what the app
  # would see as request.remote_ip.
  def remote_ip_for(remote_addr:, forwarded_for:)
    app = ->(env) { [ 200, {}, [ env["action_dispatch.remote_ip"].to_s ] ] }
    middleware = ActionDispatch::RemoteIp.new(app, false, configured_proxies)
    env = Rack::MockRequest.env_for("/", "REMOTE_ADDR" => remote_addr,
                                         "HTTP_X_FORWARDED_FOR" => forwarded_for)
    middleware.call(env).last.first
  end

  test "the pinned list is Cloudflare's, dated, and parses" do
    pinned = YAML.safe_load_file(PINNED)
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, pinned["fetched_on"].to_s, "the pin carries the date it was fetched")
    assert_operator pinned["ipv4"].size, :>=, 14, "Cloudflare publishes 14+ IPv4 ranges"
    assert_operator pinned["ipv6"].size, :>=, 6,  "Cloudflare publishes 6+ IPv6 ranges"
    (pinned["ipv4"] + pinned["ipv6"]).each { |range| IPAddr.new(range) } # raises on junk
    assert_includes pinned["ipv4"], "173.245.48.0/20"
    assert_includes pinned["ipv6"], "2606:4700::/32"
  end

  test "the app trusts the pinned ranges beside Rails' own defaults" do
    assert configured_proxies.any? { |p| p.include?(IPAddr.new("104.23.190.84")) }, "a measured edge node"
    assert configured_proxies.any? { |p| p.include?(IPAddr.new("127.0.0.1")) }, "Rails' defaults survive"
    assert configured_proxies.any? { |p| p.include?(IPAddr.new("192.168.1.7")) }, "the LAN front proxy stays trusted"
  end

  test "behind Cloudflare the visitor is the client, not the edge node" do
    assert_equal "203.0.113.9", remote_ip_for(remote_addr: "172.18.0.5",
                                              forwarded_for: "203.0.113.9, 104.23.190.84")
  end

  test "a non-Cloudflare hop is still the client — nothing else became trusted" do
    assert_equal "198.51.100.7", remote_ip_for(remote_addr: "172.18.0.5",
                                               forwarded_for: "203.0.113.9, 198.51.100.7")
  end

  test "a request straight at the origin is attributed to the peer kamal-proxy appends, not to its forged chain" do
    # The attacker sends "203.0.113.9, <a Cloudflare address>" directly; kamal-proxy appends the
    # real peer. The Cloudflare entry is filtered as a proxy, the peer is public and untrusted, and
    # it is the right-most survivor — the forgery never reaches the answer.
    assert_equal "198.51.100.7", remote_ip_for(remote_addr: "172.18.0.5",
                                               forwarded_for: "203.0.113.9, 104.23.190.84, 198.51.100.7")
  end

  test "RECORDED, NOT RELIED ON: without the appended peer the forged chain would win" do
    # This is why kamal-proxy must stay the only door and must keep forwarding AND appending
    # (config/deploy.ovh.yml `forward_headers: true`, no published port). Rails consults
    # REMOTE_ADDR only after the whole chain, and a bare forged header won before this change too.
    assert_equal "203.0.113.9", remote_ip_for(remote_addr: "198.51.100.7",
                                              forwarded_for: "203.0.113.9, 104.23.190.84")
  end
end
