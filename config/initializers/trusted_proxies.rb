# CLOUDFLARE'S RANGES ARE TRUSTED PROXIES (tinkerex#345). ActionDispatch::RemoteIp answers
# `request.remote_ip` with the RIGHT-most X-Forwarded-For address that is not a trusted proxy. The
# OVH box sits behind Cloudflare, which appends its own edge address after the visitor's, and the
# default trusted list is private ranges only — so remote_ip was the EDGE NODE, and every per-IP
# rate_limit keyed on Cloudflare (measured 2026-10-13: four edge addresses for ten probes from one
# machine; the 11th login attempt answered 401 where the LAN answers 429). Trusting the published
# ranges makes the visitor the answer there and changes nothing elsewhere: a direct request never
# carries a Cloudflare hop, and a forged header still loses to the right-most-untrusted rule.
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
