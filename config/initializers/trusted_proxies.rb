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

pinned = YAML.safe_load_file(Rails.root.join("config/cloudflare_ips.yml"))
cloudflare = (pinned.fetch("ipv4") + pinned.fetch("ipv6")).map { |range| IPAddr.new(range) }
Rails.application.config.action_dispatch.trusted_proxies =
  ActionDispatch::RemoteIp::TRUSTED_PROXIES + cloudflare
