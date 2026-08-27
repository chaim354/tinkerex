# Invariants — deploy secrets (CLAUDE.md §14g)

> **This is CLAUDE.md's §14g, moved out of the always-loaded file on 2026-08-25.** It binds when you
> touch `.kamal/secrets*`, `bin/secret`, `bin/secrets-preflight`, `config/deploy*.yml`, or an
> accessory's env — and not at all otherwise. **The rules did not change and nothing was dropped.**
>
> **The `§14g` anchor still exists in CLAUDE.md** and any code or doc citing it resolves to the stub
> there, which points here. `docs/DEPLOY.md` is the operator-facing companion.

- **KAMAL CANNOT NOTICE AN UNREADABLE SECRET, SO `bin/secrets-preflight` IS NOT OPTIONAL.** It
  expands `$(…)` in `.kamal/secrets*` through Ruby **backticks, which discard exit status** — a
  locked vault makes `bin/secret` exit 1, the substitution yields `""`, and `Kamal::Secrets#[]`
  returns that empty string **without raising**. A *missing* key raises; an *empty* one does not,
  so the failure surfaces later and elsewhere (an empty `KAMAL_REGISTRY_PASSWORD` becomes a
  confusing `docker login` error — once reported as exit 0 here). Verified against kamal 2.12.0.
- **SECRETS ARE PER-DESTINATION, AND `.kamal/secrets` IS THE *BASE* FILE, NOT A SHARED ONE.** Kamal
  reads `[secrets-common, secrets.<dest>]`, so anything added to `.kamal/secrets` is invisible
  under `-d`. Required, not tidiness: the case that earned this rule was `CHUNK_SECRET_ACCESS_KEY`
  resolving to **SeaweedFS in `.kamal/secrets` and Cloudflare R2 in `.kamal/secrets.ovh`** — one
  name, two credentials, which `secrets-common` cannot tell apart. Both definitions are gone now
  (the chunk store left with the sync engine), so the rule has no live example in the tree; that
  is a reason to keep the argument written down, not to relax it.
- **ONLY UNIVERSALLY-REQUIRED KEYS MAY LIVE IN `secrets-common`.** `InlineCommandSubstitution` runs
  every `$(…)` in a parsed file **eagerly**, not lazily per key, so a credential parked there makes
  `-d share` shell out for something a share container never holds. Guarded, mutation-checked, in
  `test/deploy_hygiene_test.rb` — which is **static** (no vault needed, passes on a bare runner).
- **`op read` NEEDS NO SECOND CODE PATH FOR UNATTENDED RUNS** — it uses `OP_SERVICE_ACCOUNT_TOKEN`
  when set and desktop/biometric auth when not. Items live in the **`tinkerex` vault, never
  `Personal`**: 1Password *refuses* to grant a service account access to a Personal/Private vault,
  so `op://Personal/…` failing is by design, not a broken vault.
- **EVERY SECRET FAILING AT ONCE MEANS THE TOKEN EXPIRED — DON'T DEBUG THE REPO.** The token
  reaches the process through the environment and so is invisible to this tree: nothing here can
  be edited to fix it, and `git log` will show nothing that broke it. Re-mint per `docs/DEPLOY.md`.
  **ONE secret failing is the opposite diagnosis** — a wrong ref or field name in that single
  `.kamal/secrets*` line. `bin/secrets-preflight --all` tells the two apart at a glance, and prints
  which auth path is in use.
- **NEVER `op read "$ref" 2>&1 >/dev/null`** — the redirection order LEAKS the value (`2>&1` points
  fd2 at the captured stdout *before* `>/dev/null` moves fd1). It printed a live ghcr PAT into a
  transcript and forced a rotation. `bin/secret` keeps the value on fd1 only.
- **`kamal deploy` WARNS ON AN UNCOMMITTED TREE, IT DOES NOT REFUSE** (`say "Building with
  uncommitted changes"`, yellow), and this repo sets no `builder: clone:` — so the image is built
  from the **working tree** and whatever is half-finished in it ships. Check `git status` first.

- **AN ACCESSORY'S SECRETS ARE REQUIRED BY EVERY DESTINATION, BECAUSE `accessories:` IS NEVER
  OVERLAID.** A destination overlay (`deploy.<dest>.yml`) can override `env:`, `servers:` and the
  rest, but the `accessories:` block is merged from the base file for ALL of them — so
  `SECRET_KEY_BASE` and `SYNC_ADMIN_TOKEN` on the `sync` accessory are structurally required by
  base, share, s3 AND ovh alike (verified against `Kamal::Configuration.raw_config` for all four,
  not assumed — it read "all five" while a `remote` destination existed, and Arc D Part 2 folded
  that one into the base). That is what makes `.kamal/secrets-common` the right home for an
  accessory-only secret — the same argument `builder:`'s `TINKEREX_SYNC_DEPLOY_KEY` already had.
  **`SYNC_ADMIN_TOKEN` is the deliberate exception and is repeated per-destination instead**, on
  instruction: it also has a genuine per-destination story, since the BASE maker app SENDS it (it
  is the `chunk_remote` destination) as well as the accessory receiving it, and both sides must
  resolve the SAME 1Password item or the far side answers 503. **The corollary bites when an
  overlay redeclares `env.secret`:** that array REPLACES the base's, dropping `SYNC_ADMIN_TOKEN`
  from the app's own env — which is correct for a destination whose app does not send it, but the
  key must stay DEFINED in that destination's `.kamal/secrets.<dest>`, because the accessory still
  requires it. Removing it from the secrets file is what goes red.
- **AN ACCESSORY HAS NO PROXY REGISTRATION UNLESS YOU GIVE IT ONE, AND THAT BREAKS ANY TOOL THAT
  PROBES HEALTH BY HOST HEADER.** `sync` declares no `port:` and no `proxy:` — correct, since only
  another container on the kamal network talks to it — but `bin/restore-db` verified a restore with
  `curl -H "Host: <dest>.tinkerex.local" http://localhost/up`, which for this destination 404s
  thirty times, sleeps 60 s and reports "no answer" **for a perfectly healthy server**. Probe an
  accessory from INSIDE it (`docker exec tinkerex-sync curl localhost:3000/up`). The general shape:
  a health check written for the app tier silently means something else at the accessory tier.
