# CLOUDFLARE'S RANGES ARE TRUSTED PROXIES (tinkerex#345). ActionDispatch::RemoteIp walks the
# X-Forwarded-For chain from the RIGHT, skipping trusted proxies, and answers the first address
# left standing (REMOTE_ADDR is consulted only after the whole chain). The OVH box sits behind
# Cloudflare: Cloudflare puts the VISITOR in X-Forwarded-For and kamal-proxy appends its own peer,
# the Cloudflare edge node. With only Rails' private ranges trusted, that edge node was the first
# untrusted address from the right — so remote_ip was the EDGE NODE and every per-IP rate_limit
# keyed on Cloudflare (measured 2026-10-13: four edge addresses for ten probes from one machine;
# the 11th login attempt answered 401 where the LAN answers 429). Trusting the published ranges
# makes the visitor the answer there and changes nothing elsewhere: a direct request never carries
# a Cloudflare hop.
#
# WHAT STOPS A FORGED HEADER IS kamal-proxy APPENDING THE REAL PEER, NOT THIS LIST. A request
# straight at the origin can carry any X-Forwarded-For it likes, and if that chain reached Rails
# unchanged, its left-most entry would win once the fake Cloudflare hop beside it is filtered —
# exactly as a bare forged header already won before this change (found in review, by driving the
# middleware). kamal-proxy appends the TCP peer as the right-most entry, which is public and
# untrusted for a direct request, so the peer wins; and a visitor coming THROUGH Cloudflare cannot
# forge either, because Cloudflare appends the visitor after anything the client sent. Both shapes
# are pinned in test/lib/trusted_proxies_test.rb. TWO DEPLOYMENT FACTS THIS DEPENDS ON: the app is
# never reachable except through kamal-proxy (no published port), and the OVH proxy block sets
# `forward_headers: true` — with `ssl:` set kamal-proxy otherwise DROPS the incoming chain and the
# app sees the edge node alone (config/deploy.ovh.yml, pinned by deploy_hygiene_test).
#
# NEVER key a throttle on CF-Connecting-IP alone: any request straight at the origin can forge it.
#
# Pinned, not fetched at boot: a boot must not depend on a third party being reachable (§14a's
# rule for the S3 guard). `bin/rails trusted_proxies:refresh` rewrites the pin and its date.
# Top-level initializer on purpose: nothing here needs an app constant, and the middleware reads
# this setting when the stack is built.
require "ipaddr"

# CLOUDFLARE_ONLY: AN ORIGIN BEHIND CLOUDFLARE ANSWERS NOTHING THAT DID NOT COME THROUGH IT
# (2026-10-26, before the repos went public). The OVH box answered tinkerex.com straight at its own
# address, so Cloudflare's DDoS and firewall shield was one `--resolve` away, and the address is in
# config/deploy.ovh.yml (and, since the mail host on that box is DNS-only, in public DNS too).
#
# HERE AND NOT IN THE HOST FIREWALL, because the box is shared: kamal-proxy serves four other sites
# on the same 80/443, and mail.charlesjschwartz.com is not behind Cloudflare at all (its clients and
# its Let's Encrypt renewals arrive directly). A port rule cannot tell tinkerex's traffic from
# theirs; this can, and it binds only the app that sets it.
#
# THE ENTRY TO JUDGE IS THE ONE kamal-proxy APPENDED: the TCP peer it accepted, which no client can
# forge, and which is Cloudflare's edge for everything Cloudflare forwards. Anything to its left is
# the client's to write. It is NOT the right-most entry, and the first version of this guard took
# it to be and failed its first deploy: the image runs Thruster in front of Puma, Thruster appends
# ITS peer too (kamal-proxy's container, 172.18.0.3), and every request including the deploy's own
# health check answered 403 (measured on OVH, 2026-10-26; kamal kept the old container serving).
#
# REMOTE_ADDR IS WHAT SAYS WHETHER THAT EXTRA HOP IS THERE, because nothing upstream can forge it:
# loopback means a proxy inside this container (Thruster) handed the request to Puma, so the
# right-most entry is its addition and is dropped; anything else means kamal-proxy talked to Puma
# directly and its entry is already last. NEVER "skip private addresses from the right" instead:
# the box has a public IPv6 address and Docker relays IPv6 to the container from its own gateway,
# so a direct IPv6 request reaches kamal-proxy from 172.18.0.1 (measured), and skipping privates
# would judge whatever the client wrote further left — a forged Cloudflare address, waved through.
#
# NO ENTRY LEFT means the request never went through kamal-proxy's forwarding: its own health
# probe (which Thruster then tags, so it arrives as one private entry over loopback) or a
# `kamal app exec curl`. The container publishes no port, so that passes.
#
# A REFUSAL IS A 403 WITH NOTHING OF THE APP IN IT, ahead of every other middleware, so a direct
# visitor learns no session, redirect or page. Cloudflare adding a range means refreshing the pin
# (`bin/rails trusted_proxies:refresh`); until then its new edges would be refused, loudly.
# Pinned in test/lib/cloudflare_only_test.rb; set per destination, and on OVH alone
# (test/deploy_hygiene_test.rb), because behind any other proxy every request is refused.
class CloudflareOnly
  REFUSAL = [ 403, { "content-type" => "text/plain", "cache-control" => "no-store" }, [ "Forbidden\n" ] ].freeze

  def initialize(app, ranges)
    @app = app
    @ranges = ranges
  end

  def call(env)
    hops = env["HTTP_X_FORWARDED_FOR"].to_s.split(",").map(&:strip).reject(&:empty?)
    hops.pop if loopback?(env["REMOTE_ADDR"])
    return @app.call(env) if hops.empty? || cloudflare?(hops.last)

    status, headers, body = REFUSAL
    [ status, headers.dup, body ]
  end

  private
    def loopback?(address)
      IPAddr.new(address.to_s).loopback?
    rescue IPAddr::Error
      false
    end

    # `native` turns an IPv4-mapped IPv6 peer (::ffff:104.16.0.1) back into IPv4, which is the family
    # the IPv4 ranges answer for; IPAddr#include? across families is always false.
    def cloudflare?(address)
      ip = IPAddr.new(address).native
      @ranges.any? { |range| range.family == ip.family && range.include?(ip) }
    rescue IPAddr::Error
      false
    end
end

pinned = YAML.safe_load_file(Rails.root.join("config/cloudflare_ips.yml"))
cloudflare = (pinned.fetch("ipv4") + pinned.fetch("ipv6")).map { |range| IPAddr.new(range) }
Rails.application.config.action_dispatch.trusted_proxies =
  ActionDispatch::RemoteIp::TRUSTED_PROXIES + cloudflare
Rails.application.config.x.cloudflare_ranges = cloudflare
Rails.application.config.middleware.insert_before 0, CloudflareOnly, cloudflare if ENV["CLOUDFLARE_ONLY"].present?
