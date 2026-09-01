> **HISTORICAL — RESCUED.** Recovered from the deleted branch
> `claude/tinkerex-ovh-kamal-domain-b57d10` (tip `524cd41`) on 2026-09-01. The CONFIG this
> design produced did land — `config/deploy.ovh.yml` and `.kamal/secrets.ovh` are both on `main`
> — but the design document itself was never merged. Kept for the why; read the live files for
> the what. OVH deploys only on explicit request (CLAUDE.md §7).

# Connect `tinkerex.com` to the OVH Kamal box (Cloudflare-proxied, Full-strict, Origin cert)

**Date:** 2026-07-26
**Status:** Design — approved decisions captured; pending spec review → implementation plan.
**Scope:** Config-only. This repo prepares the wiring; the operator sets Cloudflare DNS/cert
and runs `kamal deploy -d ovh`.

---

## 1. Goal

Serve the OVH prod-like test box (`15.204.216.249`, `config/deploy.ovh.yml`) on the real
domain **`tinkerex.com`** over HTTPS, keeping Cloudflare in front of it.

Today `tinkerex.com` lives on Cloudflare nameservers (`dora`/`giancarlo.ns.cloudflare.com`)
with **no A record** — it points nowhere. The OVH box is already live on `:80` (`HTTP 200`
on `/up`) but `:443` has no working certificate. The base `config/deploy.yml` gives every
deployment `proxy: host: chunk.tinkerex.local` (a `.local` host, HTTP-only), which the OVH
overlay currently inherits.

## 2. Approved decisions

| Decision | Choice |
|---|---|
| Canonical hostname | **Apex `tinkerex.com`** (optional `www` → apex redirect at the edge) |
| TLS model | **Cloudflare-proxied (orange cloud) + Full (strict) + Cloudflare Origin certificate** on kamal-proxy |
| Origin cert storage | **1Password** (`op read` in a destination secrets file) |
| `boxes` accessory | **Fix** the mis-pinned host for the `ovh` destination (point it at the OVH box) |
| Delivery | Config-only; operator sets DNS + deploys |

### Why this TLS model (not Let's Encrypt)

Behind Cloudflare's orange cloud, kamal-proxy's Let's Encrypt HTTP-01 challenge is intercepted
by the Cloudflare edge, so `ssl: true`'s auto-cert **cannot** complete. Instead kamal-proxy
serves a **static Cloudflare Origin certificate** (a 15-year cert Cloudflare issues for your
origin and trusts under Full-strict). Two consequences worth stating:

- **No DNS-propagation race.** A static Origin cert doesn't depend on DNS resolving to the box
  at deploy time (unlike an ACME challenge), so cert install and DNS cut-over are independent.
- **End-to-end encryption + hidden origin.** Browser↔CF uses CF's edge cert; CF↔origin uses the
  Origin cert; the OVH IP stays behind Cloudflare (DDoS, caching, IP hiding).

## 3. Traffic flow

```
Browser ──HTTPS──▶ Cloudflare edge ──HTTPS (Full-strict)──▶ OVH box :443 ──HTTP──▶ Rails app
        (CF edge cert)             (CF Origin cert on          kamal-proxy   (internal
                                    kamal-proxy)                              docker net)
```

kamal-proxy terminates the CF↔origin TLS and forwards to the app container over plain HTTP on
the internal docker network. Rails is told TLS was terminated upstream **only on this
deployment** (env-gated), so the HTTP-only LAN Unraid boxes are untouched.

## 4. The core constraint (why everything is env-gated)

One Docker image and one `config/environments/production.rb` serve **both** the new public
HTTPS OVH box **and** the existing HTTP-only LAN Unraid boxes (`chunk`/`s3`/`share` on
`192.168.1.95`, reached by `.local` hosts). Therefore SSL and host-authorization must **not**
be hardcoded on — they are switched on by env vars that only the `ovh` overlay sets:

- `FORCE_SSL=true` → `assume_ssl` + `force_ssl`
- `APP_DOMAIN=tinkerex.com` → host authorization + mailer host

LAN boxes set neither → their behavior is byte-identical to today. This is the load-bearing
design property; do not replace it with an unconditional `config.force_ssl = true`.

## 5. Changes

### 5.1 `config/deploy.ovh.yml` — proxy, env, accessory

Add a `proxy:` block (deep-merges over the base, overriding `host` and adding a custom cert),
two `env.clear` vars, and an accessory host override:

```yaml
proxy:
  host: tinkerex.com
  ssl:
    certificate_pem: TINKEREX_ORIGIN_CERT_PEM   # secret NAMES, resolved from .kamal/secrets.ovh
    private_key_pem: TINKEREX_ORIGIN_KEY_PEM
  forward_headers: true            # behind Cloudflare (trusted): forward X-Forwarded-For/Proto so
                                   # Rails logs the real client IP, not the CF edge IP

env:
  clear:
    # ...existing R2 / STORAGE_BACKEND vars unchanged...
    APP_DOMAIN: tinkerex.com
    FORCE_SSL: "true"

# Fix the inherited boxes accessory (base pins host: 192.168.1.95, the Unraid box). For -d ovh
# this must be the OVH box, or `kamal accessory boot boxes -d ovh` / `kamal setup -d ovh` try to
# reach ubuntu@192.168.1.95 (wrong box AND wrong user). Deep-merges over the base accessory, so
# image/env are inherited; only host changes.
accessories:
  boxes:
    host: 15.204.216.249
```

- `proxy` is a hash → deep-merged; `host` (string) is replaced by `tinkerex.com`, `ssl` is
  added. When `ssl` is a hash with both PEM keys, Kamal 2.11 passes
  `--tls --tls-certificate-path/--tls-private-key-path` to kamal-proxy (custom cert; Let's
  Encrypt is bypassed). Verified in `kamal-2.11.0` `configuration/proxy.rb`.
- `env.clear` is a hash → deep-merged, so the two new vars add to (not replace) the inherited
  clear vars. (Only `env.secret`, a list, would *replace* — untouched here.)

### 5.2 `.kamal/secrets.ovh` (new, tracked — references only)

Kamal 2.11 loads `["<path>-common", "<path>.<destination>"]` = **`.kamal/secrets-common` +
`.kamal/secrets.ovh`** for `-d ovh` (verified in `kamal/secrets.rb#secrets_filenames`). The
apex/base deploy loads `secrets-common + secrets` and never touches `.ovh`, so the Origin-cert
`op read` runs **only** on OVH deploys.

```sh
# .kamal/secrets.ovh — safe for git (no raw secrets; pulls from 1Password at deploy time).
# Loaded only for `kamal ... -d ovh` (alongside .kamal/secrets-common).
#
# Requires a 1Password item (Personal vault) named "tinkerex-origin" with two text fields
# holding the Cloudflare Origin certificate PEM and its private key PEM. Adjust the op:// refs
# below to match the item/field names you create.
TINKEREX_ORIGIN_CERT_PEM=$(op read "op://Personal/tinkerex-origin/certificate")
TINKEREX_ORIGIN_KEY_PEM=$(op read "op://Personal/tinkerex-origin/private key")
```

Nothing lands on disk. (The alternative — gitignored `config/certs/*.crt/.key` read via
`$(cat …)` — was declined in favor of 1Password.)

### 5.3 `config/environments/production.rb` — env-gated, additive

Replace the three commented placeholder blocks (`assume_ssl`/`force_ssl`, `ssl_options`,
`config.hosts`/`host_authorization`) and the mailer host with env-gated equivalents:

```ruby
# TLS is terminated upstream (kamal-proxy serving the Cloudflare Origin cert) ONLY on the
# public OVH deploy, which sets FORCE_SSL=true. The LAN test boxes run plain HTTP and set
# neither var, so this is a no-op there. Do NOT hardcode these on — it breaks the LAN boxes.
if ENV["FORCE_SSL"] == "true"
  config.assume_ssl = true
  config.force_ssl  = true
  # kamal-proxy health-checks /up over plain HTTP against the container by IP. An unexcluded
  # force_ssl 301 would fail that check and the deploy would roll back.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }
end

if ENV["APP_DOMAIN"].present?
  config.hosts << ENV["APP_DOMAIN"]          # exact apex
  config.hosts << ".#{ENV['APP_DOMAIN']}"    # leading dot: apex + all subdomains (www, …)
  # Same reason as the /up ssl exclude: the proxy healthcheck's Host is the container IP,
  # which won't match APP_DOMAIN and would 403 without this.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end

# Mailer links (confirmation/reset) must point at the real host on the public deploy; the LAN
# boxes keep the harmless default.
config.action_mailer.default_url_options = {
  host: ENV["APP_DOMAIN"] || "example.com",
  protocol: ENV["FORCE_SSL"] == "true" ? "https" : "http"
}
```

The `/up` excludes are load-bearing — without them the deploy's own health check fails.

## 6. Operator runbook (documented, not executed by this repo)

1. **Cloudflare → SSL/TLS → Origin Server → Create Certificate**, hostnames `tinkerex.com`
   and `*.tinkerex.com`. Paste the cert PEM and private-key PEM into a 1Password item
   `tinkerex-origin` (fields `certificate`, `private key`).
2. **Cloudflare → SSL/TLS → Overview → Full (strict)**.
3. **Cloudflare → DNS**: A `tinkerex.com` → `15.204.216.249`, **Proxied**. *(optional)* A
   `www` → same, Proxied, plus a Redirect Rule `www.tinkerex.com/* → https://tinkerex.com/$1`.
4. Deploy:
   ```sh
   export CHUNK_ACCESS_KEY_ID=…  CHUNK_SECRET_ACCESS_KEY=…  KAMAL_REGISTRY_PASSWORD=…
   kamal deploy -d ovh
   # optional — Box Generator sidecar on the OVH box (now correctly targets ubuntu@15.204.216.249):
   kamal accessory boot boxes -d ovh
   ```
5. Verify (§7).

## 7. Verification

- **Render check (no deploy):** `kamal config -d ovh` resolves the cert secrets and shows
  `proxy.host = tinkerex.com`, the custom cert paths, and `boxes.host = 15.204.216.249`.
- **LAN unaffected:** `kamal config` (no destination) still shows `proxy.host =
  chunk.tinkerex.local`, no `FORCE_SSL`/`APP_DOMAIN`, `boxes.host = 192.168.1.95`.
- **Rails suite** stays green (the production.rb change is env-gated; test env loads neither
  var, so `bin/rails test` behavior is unchanged). Note: env-gated *production* config is not
  exercised by the test env, so this is a no-regression check, not a positive test of the gate.
- **Post-deploy:** `curl -sI https://tinkerex.com/up` → `200`; browser padlock shows the
  Cloudflare edge cert; `http://tinkerex.com/` upgrades to HTTPS.

## 8. Caveats / out of scope

- **HSTS:** `force_ssl` emits HSTS with `includeSubDomains` by default. Fine for `tinkerex.com`;
  be aware before adding any non-HTTPS `*.tinkerex.com` subdomain later.
- **`§10`-style boundary:** this touches only deployment config + a public-host Rails concern.
  It does **not** touch the sync engine, changelog, chunk/library backends, or the maker layer.
- **No app-code behavior change** beyond SSL/host/mailer gating; no new tests of business logic.
