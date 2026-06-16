# Research: Authentication providers & libraries for the Maker Server

**Date:** 2026-06-15 · **Status:** research / decision input (not a unilateral call) ·
**Scope:** the *human-identity* auth layer that sits **in front of** the existing
device-token + `DevicePairing` bootstrap. The device-token mechanism stays underneath
every option here — this is the top box only.

This document compares managed identity providers, self-hostable OSS identity servers, and
in-process Rails libraries against this project's hard constraints, then recommends a
path. It complements (and goes wider than) the options sketch in
[`docs/parity-roadmap.md`](parity-roadmap.md) §A. Every nontrivial claim is cited; see
[Sources](#sources).

---

## 1. The constraints every option is judged against

Pulled straight from [`CLAUDE.md`](../CLAUDE.md) §7/§8/§9 and the parity roadmap's gating
filters. These are non-negotiable.

1. **Dual deployment (§7).** Must work for BOTH self-hosted (a maker's own Unraid box —
   offline-capable, no vendor lock-in) AND managed SaaS. The whole architecture's selling
   point is "**Rails + Postgres + S3, nothing exotic**." Anything that forces a self-hoster
   to call out to a vendor, or to stand up a heavyweight extra service, erodes that.
2. **Permissive licensing (§9).** Shipped/depended-on auth code must be MIT / Apache-2.0 /
   BSD. **GPL/AGPL is disqualifying** for anything we bundle or hard-depend on. (Running an
   AGPL service *over a network boundary* that we don't redistribute is a grayer question,
   but the project's stance is to avoid the copyleft surface entirely — and forcing a
   self-hoster to run an AGPL service is exactly the friction §9 wants to avoid.)
3. **Layering, not rip-and-replace (§8).** The goal is *real OAuth/OIDC + verified email*
   **on top of** the existing two-layer design:

   ```
   [ human identity layer ]   ← what this doc chooses
       email+password / OAuth-OIDC / magic link → proves a PERSON owns an account
           │  (on success → an authenticated browser/app session)
           ▼
   [ device bootstrap layer ] ← UNCHANGED
       register-new-account + DevicePairing single-use code → issues a device token
           │
           ▼
   [ device token ]           ← the durable credential the sync client uses
   ```

   The codebase already has the seam for this: `has_secure_password validations: false`,
   `User.from_omniauth` (with a careful anti-takeover email-linking guard),
   `app/controllers/omniauth_callbacks_controller.rb`, and routes gated by
   `OMNIAUTH_ENABLED`. So the bar for any option is: *how cleanly does it bolt onto that
   seam without owning the device bootstrap?*
4. **Cost & operational burden.** For managed providers: per-MAU pricing at realistic
   scale. For self-host: how much extra a maker has to run.

A useful framing from the OSS landscape: these tools are not all the same *kind* of thing.
**Full IAM platforms** (Keycloak, Zitadel) replace your whole identity layer as a separate
service; **developer auth libraries/services** (SuperTokens, Logto, Supabase) embed via
SDKs; **modular toolkits** (Ory Kratos/Hydra) are assembled from parts; and **forward-auth
proxies** (Authelia, Authentik's proxy mode) gate apps at the reverse proxy. Only some of
these fit an *in-process Rails app that is itself the relying party*.
([skycloak.io](https://skycloak.io/blog/open-source-authentication-comparison-2026/),
[Cerbos](https://www.cerbos.dev/blog/best-open-source-auth-tools-and-software-for-enterprises-2026))

---

## 2. Managed identity providers (hosted SaaS)

These are evaluated mainly for the **managed tier** (and as optional "bring-your-own-OIDC"
add-ons). For all of them the **self-host story is "none"** — you cannot run them on a
maker's box, so none can be the *baseline* auth path (constraint #1). They plug into our
OmniAuth/OIDC seam as a login *method*, never as the only one.

| Provider | OIDC / social | Email verify | Self-host | Pricing headline (2026) | Lock-in |
|---|---|---|---|---|---|
| **Auth0 / Okta CIC** | Full OIDC + social + enterprise SSO | Yes | None | Free ≤25k MAU; B2C Essentials ~$35/mo entry, **~$1,750/mo @ 50k MAU**, ~$5,250/mo @ 100k | High |
| **Clerk** | OIDC, social, passkeys, prebuilt UI | Yes | None | Free **≤50k MAU** (raised from 10k in 2026); then ~$0.02/MAU after first 10k on Pro | Medium-High (UI components) |
| **WorkOS (AuthKit)** | OIDC, social; enterprise SSO/SCIM focus | Yes | None | **AuthKit free ≤1M MAU**; charge starts at SSO/SCIM **$125/connection/mo** | Medium |
| **Stytch** | OIDC, passwordless, B2B | Yes | None | Free ≤1k MAU + 5 connections; **+$200 / extra 1k MAU**, +$125/connection | Medium |
| **Supabase Auth (GoTrue)** | OIDC client + social | Yes | **Yes** (OSS) | Hosted free ≤50k MAU; **self-host = free/unlimited** | Low (OSS core) |
| **Firebase Auth** | OIDC client + social | Yes | None (GCP) | Free ≤50k MAU; ~$275/mo @ 100k | High (GCP) |
| **AWS Cognito** | OIDC + social, user pools | Yes | None (AWS) | Free ≤50k MAU (in AWS); ~$275/mo @ 100k | High (AWS) |

Notes per option:

- **Auth0/Okta** — the most full-featured, but pricing scales brutally for a B2C product:
  ~$1,750/mo at 50k MAU where Firebase/Supabase/Cognito are $0, and ~$5,250/mo at 100k MAU.
  ([saasworthy](https://www.saasworthy.com/blog/auth0-pricing-plans-guide),
  [getmonetizely](https://www.getmonetizely.com/articles/how-do-okta-auth0-and-firebase-auth-compare-identity-management-pricing-analysis),
  [zuplo](https://zuplo.com/learning-center/api-authentication-pricing)) Strong OIDC, but a
  poor fit as a *baseline* given self-host and cost.
- **Clerk** — excellent DX and prebuilt React UI, free tier raised to 50k MAU in 2026.
  ([saasprices](https://saasprices.net/blog/clerk-free-plan-changes),
  [SuperTokens](https://supertokens.com/blog/clerk-pricing-the-complete-guide)) But Clerk's
  value *is* its hosted components — adopting it as the baseline would pull a hosted
  dependency into the UX, which self-host can't have.
- **WorkOS (AuthKit)** — unusually generous: free auth up to **1M MAU**, monetized on
  enterprise SSO/SCIM connectors at $125/connection/mo.
  ([scalekit](https://www.scalekit.com/blog/workos-alternatives),
  [buildmvpfast](https://www.buildmvpfast.com/alternatives/workos)) A strong **managed-tier
  enterprise-SSO** add-on if we ever sell to teams; still not self-hostable.
- **Stytch** — passwordless/B2B focus; free tier is small (1k MAU) and per-MAU overage is
  steep (+$200/1k). ([Zuplo](https://zuplo.com/learning-center/api-authentication-pricing))
- **Supabase Auth** — the interesting one: its core (GoTrue) **is open source and
  self-hostable**, so it doesn't strictly violate constraint #1. But adopting it means
  pulling in the Supabase/GoTrue stack (a separate Postgres-coupled service) rather than
  staying in-process — heavier than this Rails app needs, and it duplicates user storage we
  already own. Reasonable as a *managed* convenience; not the in-process baseline.
  ([dev.to/zuplo](https://dev.to/zuplo/auth-pricing-wars-cognito-vs-auth0-vs-firebase-vs-supabase-2jkb))
- **Firebase Auth / AWS Cognito** — both cheap at scale (≈$275/mo @ 100k MAU) and both
  **hard-locked to their cloud** (GCP / AWS). ([Zuplo](https://zuplo.com/learning-center/api-authentication-pricing),
  [metacto](https://www.metacto.com/blogs/the-complete-guide-to-firebase-auth-costs-setup-integration-and-maintenance))
  Cloud lock-in disqualifies them as a baseline; both break the self-host promise.

**Managed-provider verdict:** none is a baseline (no self-host, lock-in, or per-MAU cost).
The only one worth wiring is **WorkOS/AuthKit (or an OIDC IdP generically) as an
*optional* managed-tier enterprise-SSO method** behind the existing OmniAuth seam. Keep the
seam; don't make it mandatory.

---

## 3. Self-hostable / open-source identity servers

These *can* run on a maker's box, so the questions are (a) **license** (constraint #2 is
where several die) and (b) **operational weight** (constraint #1 — every extra service
erodes "Rails + Postgres + S3, nothing exotic"). All of these are consumed by Rails as an
**OIDC client** (via `omniauth_openid_connect`), so Rails integration is uniform; the
differentiators are license and burden.

| Server | License | Self-host burden | OIDC for Rails | Managed cloud option |
|---|---|---|---|---|
| **Keycloak** | **Apache-2.0** ✅ | Heavy (JVM/Quarkus service) | Standard OIDC IdP | Self-managed; various 3rd-party hosts |
| **Ory Hydra** (OAuth/OIDC) | **Apache-2.0** ✅ | Medium (Go); Hydra needs an identity store alongside | OIDC provider | Ory Network (managed) |
| **Ory Kratos** (identity) | **Apache-2.0** ✅ | Medium (Go); headless, you build UI | Pairs with Hydra for OIDC | Ory Network |
| **Authentik** | **MIT** ✅ (core; enterprise add-ons separate) | Medium (Python/Django + workers/redis) | Standard OIDC IdP | authentik Cloud |
| **Authelia** | **Apache-2.0** ✅ | Light, but it's a **forward-auth proxy**, not a full app IdP | Limited as an app-level OIDC provider | none (self-host only) |
| **Logto** | **MPL-2.0** ⚠️ (weak copyleft, file-level) | Medium (Node) | OIDC provider | Logto Cloud |
| **SuperTokens** | **Apache-2.0** core ✅ (`ee/` enterprise dir separate) | Medium (core service + SDK) | OIDC + SDKs | SuperTokens managed |
| **Zitadel** | **AGPL-3.0** ❌ (since v3, Aug 2025) | Medium (Go) | Standard OIDC IdP | Zitadel Cloud |

License details (the load-bearing constraint):

- **Keycloak — Apache-2.0.** Clean license; the catch is purely operational: it's a
  heavyweight Java/Quarkus IdP.
  ([bmaupin gist](https://gist.github.com/bmaupin/6878fae9abcb63ef43f8ac9b9de8fafd),
  [skycloak](https://skycloak.io/blog/open-source-authentication-comparison-2026/))
- **Ory Kratos & Hydra — both Apache-2.0.** Clean. Modular (Kratos = identity, Hydra =
  OAuth2/OIDC, Keto = authz), so a *full* login experience is several services assembled.
  ([ory/kratos LICENSE](https://github.com/ory/kratos/blob/master/LICENSE),
  [ory.com/hydra](https://www.ory.com/hydra))
- **Authentik — MIT** for the core (enterprise features under a separate license).
  Cleanest license of the full IdPs; Python/Django + workers stack.
  ([skycloak](https://skycloak.io/blog/open-source-authentication-comparison-2026/),
  [wz-it](https://wz-it.com/en/blog/authentik-vs-zitadel-identity-provider-comparison/))
- **Authelia — Apache-2.0**, but it is a **reverse-proxy forward-auth companion**, not a
  full app-level identity provider — it gates apps behind nginx/Traefik. That's a different
  shape than "OIDC IdP our Rails app federates to," so it's a poor structural fit here even
  though the license is clean.
  ([SuperTokens: Authelia vs Keycloak](https://supertokens.com/blog/authelia-vs-keycloak))
- **Logto — MPL-2.0.** Weak/file-level copyleft (not as viral as GPL/AGPL: it triggers per
  modified file, doesn't infect your whole app), but it is **not** in the MIT/Apache/BSD set
  §9 prefers. Running it as a separate service we don't modify is low-risk, but it's a yellow
  flag against the "permissive only" rule.
  ([Logto blog](https://blog.logto.io/top-oss-iam-providers-2025),
  [openalternative](https://openalternative.co/compare/logto/vs/supertokens))
- **SuperTokens — Apache-2.0** for the core; enterprise features live in a separately
  licensed `ee/` directory. Core is clean; just don't depend on `ee/`.
  ([supertokens-core LICENSE.md](https://github.com/supertokens/supertokens-core/blob/master/LICENSE.md))
- **Zitadel — AGPL-3.0 since v3 (announced Aug 29 2025).** It previously was Apache-2.0;
  the relicense makes it **disqualified** under §9 as a bundled/hard dependency, and forcing
  a self-hoster to run an AGPL service cuts against the project's copyleft-avoidance stance.
  ([Zitadel licensing FAQ](https://help.zitadel.com/zitadel-licensing-faqs))
  **This is the single most important "don't pick this" finding in the OSS column** — older
  comparisons still list Zitadel as Apache, which is now stale.

**Self-hostable-server verdict:** license-wise Keycloak / Ory / Authentik / SuperTokens /
Authelia all *pass* (Apache/MIT); **Zitadel fails (AGPL)** and **Logto is a yellow flag
(MPL-2.0)**. But the real problem for *all* of them as a **baseline** is **operational
weight**: asking a maker to stand up Keycloak/Ory/Authentik *next to* Rails + Postgres +
SeaweedFS roughly doubles the self-host surface and directly undercuts the "nothing exotic"
promise. So these belong in the **"bring-your-own-OIDC" optional** slot (enterprise
self-host / power users), federated via our OmniAuth seam — **not** the default every
self-hoster must run.

---

## 4. In-process Rails libraries (no separate service)

This is where the baseline should live: auth that runs **inside the Rails app**, so
self-host stays "Rails + Postgres + S3" and managed is identical code. All are permissive.

| Option | License | Adds over current baseline | OIDC role | Maturity |
|---|---|---|---|---|
| **Rails 8 built-in** (current) | MIT | — (baseline: signup/confirm/login/reset, `Session`, OmniAuth seam) | OIDC *client* via OmniAuth (add-on) | Ships with Rails 8 |
| **Devise** + `:omniauthable` | MIT | `:confirmable`, `:recoverable`, `:lockable`, OmniAuth — for free | OIDC *client* | Very mature, heavy |
| **Rodauth** | MIT | Email verify, reset, MFA/TOTP/WebAuthn, account lockout, audit | OIDC *client*; `rodauth-oauth` can make it a *provider* | Mature, Sequel-based |
| **OmniAuth** (+ `omniauth_openid_connect`) | MIT | Social/OIDC login strategies on top of any of the above | OIDC *client* | Mature, the standard seam |
| **Doorkeeper** (+ `-openid_connect`) | MIT | Makes *us* an OAuth2/OIDC **provider** | OIDC *provider* | Mature |

- **Rails 8 built-in (current baseline).** `bin/rails generate authentication`:
  `has_secure_password` (bcrypt), a `Session` model with a signed cookie, password-reset
  mailer wiring. The repo already extends it with **email confirmation**, reset, and the
  `User.from_omniauth` seam. **Zero new dependency, zero new self-host moving parts, MIT.**
  Email verification isn't in the generator but is a ~half-day one-token mailer step (already
  present in `app/models/user.rb`: `generate_confirmation_token!` / `confirm!`). This is the
  *only* option that is simultaneously zero-license-risk, zero-extra-service, and native to
  Rails 8.
- **Devise** — MIT; `:confirmable`/`:recoverable`/`:lockable`/`:omniauthable` out of the box.
  The fallback if we want those features without writing them. Cost: it owns more of the
  request cycle (its controllers, routes, Warden middleware), and it's heavier than an
  API-first sync server needs. ([listicler](https://listicler.com/best/best-open-source-authentication-solutions))
- **Rodauth** — MIT; the most *feature-complete* in-process option (email verify, reset,
  TOTP/WebAuthn MFA, lockout, audit logging), and uniquely it can *also* be an OIDC
  **provider** via `rodauth-oauth` if we ever want to issue tokens to third parties. Cost:
  it's Sequel-based (a second ORM seam next to ActiveRecord) and a bigger conceptual jump
  from the existing Rails-native code.
  ([honeyryderchuck](https://honeyryderchuck.gitlab.io/2021/03/15/oidc-provider-on-rails-using-rodauth-oauth.html))
- **OmniAuth + `omniauth_openid_connect`** — MIT; this is the *complement*, not an
  alternative. It's the strategy layer that turns "email+password" into "+ Google / + any
  OIDC IdP," and it's exactly what the existing `OmniauthCallbacksController` /
  `OMNIAUTH_ENABLED` seam expects.
  ([omniauth/omniauth_openid_connect](https://github.com/omniauth/omniauth_openid_connect))
- **Doorkeeper (+ `-openid_connect`)** — MIT; relevant only if **we** want to become an
  OAuth/OIDC *provider* (e.g. third-party apps logging in *with* a Maker Server account).
  That's a different goal than "verify our users' email + offer social login," so it's out
  of scope for the baseline but worth knowing exists.
  ([doorkeeper wiki](https://github.com/doorkeeper-gem/doorkeeper/wiki))

---

## 5. Comparison table (all options)

`Self-host?` = can run on the maker's box without a vendor call-out. `Rails-fit` = how
cleanly it bolts onto the existing `User`/OmniAuth seam without owning the device bootstrap.

| Option | Self-host? | Managed? | License | OIDC | Email-verify | Rails-fit | Lock-in | Cost |
|---|---|---|---|---|---|---|---|---|
| **Rails 8 built-in** (current) | ✅ in-proc | ✅ | MIT ✅ | client (via OmniAuth) | ✅ (added) | ★★★★★ native | none | $0 |
| Devise | ✅ in-proc | ✅ | MIT ✅ | client | ✅ built-in | ★★★★ | none | $0 |
| Rodauth | ✅ in-proc | ✅ | MIT ✅ | client (+provider) | ✅ built-in | ★★★ (Sequel) | none | $0 |
| OmniAuth + OIDC strategy | ✅ (complement) | ✅ | MIT ✅ | client | n/a | ★★★★★ (the seam) | none | $0 |
| Doorkeeper (OIDC *provider*) | ✅ in-proc | ✅ | MIT ✅ | **provider** | n/a | ★★★ (different goal) | none | $0 |
| Keycloak | ✅ heavy svc | self-mgd | Apache-2.0 ✅ | IdP | ✅ | ★★★ via OIDC | low | ops cost |
| Ory Kratos+Hydra | ✅ medium svc | Ory Network | Apache-2.0 ✅ | IdP/provider | ✅ | ★★★ via OIDC | low | ops cost |
| Authentik | ✅ medium svc | authentik Cloud | **MIT** ✅ | IdP | ✅ | ★★★ via OIDC | low | ops cost |
| Authelia | ✅ light proxy | none | Apache-2.0 ✅ | proxy (weak app-IdP) | ✅ | ★★ (proxy shape) | low | ops cost |
| Logto | ✅ medium svc | Logto Cloud | **MPL-2.0** ⚠️ | IdP | ✅ | ★★★ via OIDC | low | ops cost |
| SuperTokens | ✅ medium svc | managed | Apache-2.0 ✅ (`ee/` separate) | IdP/SDK | ✅ | ★★★ | low | ops cost |
| **Zitadel** | ✅ medium svc | Zitadel Cloud | **AGPL-3.0** ❌ | IdP | ✅ | ★★★ via OIDC | low | **license-disqualified** |
| Auth0 / Okta | ❌ | ✅ | proprietary | ✅ | ✅ | ★★★★ via OmniAuth | **high** | ~$1,750/mo @50k MAU |
| Clerk | ❌ | ✅ | proprietary | ✅ | ✅ | ★★★ (hosted UI) | med-high | free ≤50k MAU |
| WorkOS / AuthKit | ❌ | ✅ | proprietary | ✅ | ✅ | ★★★★ via OmniAuth | med | free ≤1M MAU; $125/conn SSO |
| Stytch | ❌ | ✅ | proprietary | ✅ | ✅ | ★★★ | med | free ≤1k MAU; +$200/1k |
| Supabase Auth | ✅ (GoTrue svc) | ✅ | MIT/Apache (GoTrue) ✅ | client | ✅ | ★★ (separate stack) | low (OSS) | free self-host |
| Firebase Auth | ❌ (GCP) | ✅ | proprietary | client | ✅ | ★★★ via OmniAuth | **high (GCP)** | free ≤50k; ~$275/mo @100k |
| AWS Cognito | ❌ (AWS) | ✅ | proprietary | ✅ | ✅ | ★★★ via OmniAuth | **high (AWS)** | free ≤50k; ~$275/mo @100k |

---

## 6. Recommendation

The lowest-friction path to "**real OAuth/OIDC + verified email**" that **preserves the
device-token/pairing bootstrap**, **works in both deployment modes**, and **stays
permissive** is to keep the baseline *in-process* and add OIDC as an *optional method on the
existing seam* — never to adopt a separate identity service as the default.

### Primary recommendation — keep the Rails 8 built-in baseline; add OmniAuth-OIDC on the existing seam

1. **Baseline (both modes, mandatory): Rails 8 built-in auth** — already in the repo
   (`has_secure_password`, `Session`, confirmation/reset). It is MIT, adds **zero** new
   self-host services, and is the authenticated context from which the unchanged
   `register` / `DevicePairing` flow runs. This satisfies all four constraints with the
   least surface. (Matches parity-roadmap §A Option 1.)
2. **Email verification:** finish/keep the one-token mailer confirmation already wired in
   `User#generate_confirmation_token!` / `confirm!`. SMTP creds are the only new
   operational dependency on self-host — standard and acceptable.
3. **OAuth/OIDC (additive login method): `omniauth` + `omniauth_openid_connect`** (both
   MIT) wired into the **existing** `OmniauthCallbacksController` / `OMNIAUTH_ENABLED`
   route. `User.from_omniauth` already exists *with* the correct anti-takeover guard (only
   auto-links a provider-*verified* email to an existing account that has **no** local
   password). This is the clean, additive layer — no rip-and-replace.
4. **Deployment split (they can differ):**
   - **Managed tier:** enable a couple of OIDC/social providers (e.g. Google, GitHub via
     OmniAuth) for convenience, and optionally **WorkOS/AuthKit** as an enterprise-SSO
     connector behind the same seam if/when selling to teams. All of this is *behind*
     `OMNIAUTH_ENABLED` and changes only the top box.
   - **Self-host tier:** ship with **email+password+verification only** (no mandatory
     external IdP). Social/OIDC is *opt-in* — a power user or enterprise self-hoster can
     point `OMNIAUTH_ENABLED` at their **own** OIDC IdP (Keycloak/Ory/Authentik —
     "bring-your-own-OIDC"). The default self-host build depends on nothing exotic.

Why this wins: it is the only configuration that is simultaneously (a) zero new licensing
risk, (b) zero new self-host moving parts, (c) native to Rails 8, and (d) a clean base to
bolt OIDC onto per-deployment. The device token + `DevicePairing` mechanism is untouched —
the sync engine never sees the identity provider.

### Fallback — Devise (or Rodauth) if we want richer account features without writing them

If, as the product grows, we want `:confirmable` / `:lockable` / MFA without building them:

- **Devise + `:omniauthable`** (MIT) — first-class email verification, lockout, and the
  same OmniAuth seam, at the cost of a heavier framework that owns more of the request
  cycle. The straightforward "don't write it yourself" fallback.
- **Rodauth** (MIT) — pick this instead of Devise *only if* we specifically want
  built-in TOTP/WebAuthn MFA now, or anticipate needing to be an **OIDC provider**
  ourselves (via `rodauth-oauth`). The cost is the Sequel seam alongside ActiveRecord.

Both are permissive, in-process, and dual-mode — so either is a safe fallback that doesn't
violate any constraint.

### Explicitly *not* recommended as a baseline

- **Zitadel** — AGPL-3.0 since v3 (Aug 2025); fails §9. (Watch for stale comparisons that
  still call it Apache.)
- **Logto** — MPL-2.0; weak copyleft, a yellow flag against "permissive only." Usable only
  as an external optional IdP if a self-hoster *chooses* it, never bundled.
- **Auth0 / Okta / Clerk / Firebase / Cognito** — no self-host (cloud lock-in) and/or
  steep per-MAU cost; managed-only add-ons at most, never the baseline.
- **Keycloak / Ory / Authentik** — license-clean (Apache/MIT) but operationally heavy; the
  "bring-your-own-OIDC" optional slot, not the default self-hoster's burden.

---

## Sources

- [Open Source Authentication in 2026: Complete Comparison — skycloak.io](https://skycloak.io/blog/open-source-authentication-comparison-2026/)
- [Comparison of open-source SSO implementations — bmaupin (GitHub gist)](https://gist.github.com/bmaupin/6878fae9abcb63ef43f8ac9b9de8fafd)
- [Best Open Source Auth Tools 2026 — Cerbos](https://www.cerbos.dev/blog/best-open-source-auth-tools-and-software-for-enterprises-2026)
- [Zitadel Licensing FAQs (Apache-2.0 → AGPL-3.0 from v3, Aug 29 2025) — zitadel.com](https://help.zitadel.com/zitadel-licensing-faqs)
- [Authentik vs Zitadel — wz-it.com](https://wz-it.com/en/blog/authentik-vs-zitadel-identity-provider-comparison/)
- [Authelia vs Keycloak — SuperTokens](https://supertokens.com/blog/authelia-vs-keycloak)
- [Top OSS IAM providers 2025 — Logto blog](https://blog.logto.io/top-oss-iam-providers-2025)
- [Logto vs SuperTokens — openalternative.co](https://openalternative.co/compare/logto/vs/supertokens)
- [SuperTokens core LICENSE.md (Apache-2.0; `ee/` separate) — GitHub](https://github.com/supertokens/supertokens-core/blob/master/LICENSE.md)
- [ory/kratos LICENSE (Apache-2.0) — GitHub](https://github.com/ory/kratos/blob/master/LICENSE)
- [Ory Hydra — ory.com](https://www.ory.com/hydra)
- [6 Best Open-Source Authentication Solutions 2026 — Listicler](https://listicler.com/best/best-open-source-authentication-solutions)
- [Auth Pricing Wars: Cognito vs Auth0 vs Firebase vs Supabase — Zuplo](https://zuplo.com/learning-center/api-authentication-pricing)
- [Auth Pricing Wars — DEV/Zuplo](https://dev.to/zuplo/auth-pricing-wars-cognito-vs-auth0-vs-firebase-vs-supabase-2jkb)
- [Auth0 Pricing Guide 2026 — SaaSworthy](https://www.saasworthy.com/blog/auth0-pricing-plans-guide)
- [Okta / Auth0 / Firebase pricing analysis — getmonetizely](https://www.getmonetizely.com/articles/how-do-okta-auth0-and-firebase-auth-compare-identity-management-pricing-analysis)
- [Firebase Auth Pricing 2026 — metacto](https://www.metacto.com/blogs/the-complete-guide-to-firebase-auth-costs-setup-integration-and-maintenance)
- [Clerk free plan changes (50k MAU, 2026) — saasprices.net](https://saasprices.net/blog/clerk-free-plan-changes)
- [Clerk pricing complete guide — SuperTokens](https://supertokens.com/blog/clerk-pricing-the-complete-guide)
- [WorkOS alternatives / AuthKit free ≤1M MAU — scalekit](https://www.scalekit.com/blog/workos-alternatives)
- [Best WorkOS alternatives 2026 — buildmvpfast](https://www.buildmvpfast.com/alternatives/workos)
- [omniauth/omniauth_openid_connect (MIT) — GitHub](https://github.com/omniauth/omniauth_openid_connect)
- [Doorkeeper wiki (OAuth2/OIDC provider) — GitHub](https://github.com/doorkeeper-gem/doorkeeper/wiki)
- [Building an OIDC provider with rodauth-oauth on Rails — honeyryderchuck](https://honeyryderchuck.gitlab.io/2021/03/15/oidc-provider-on-rails-using-rodauth-oauth.html)
