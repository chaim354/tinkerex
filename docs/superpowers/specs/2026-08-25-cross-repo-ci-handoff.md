# Cross-repo CI handoff: sync↔client suites leave `tinkerex`

**From:** `chaim354/tinkerex` (the maker app)
**Date:** 2026-08-25
**Why:** After Arc D Part 2 these suites test `tinkerex-sync` against `tinkerex-client` with **no
`tinkerex` code involved**. They were deleted from `tinkerex` on this date. This document carries
the CORRECTED recipes — the versions here were broken, and copying them verbatim reproduces the
bug.

## The bug you must not copy

`tinkerex` no longer routes the sync API. Probed on `main` at deletion time:

```
recognize_path("/v1/commit", :post) -> ActionController::RoutingError
```

Its only non-maker `/v1` routes are `POST /v1/test/users`, `POST /v1/devices/login`,
`POST /v1/devices`. Every job below used to boot `bin/rails server` from `tinkerex` and point
`SYNC_IT_SERVER_URL` at it. Those jobs now get through signup and device login, then **404 on the
first commit**. The server to boot is **`tinkerex-sync`**.

Also drop, everywhere: `STORAGE_BACKEND`, `CHUNK_PUBLIC_URL`, `CHUNK_LOCAL_DIR`. No code in
`tinkerex` reads them any more; they are inert, not load-bearing.

---

## Part A → `chaim354/tinkerex-sync`

**Lands beside** the existing `ci.yml` `test` and `conformance` jobs, both already
`[self-hosted, macos]`.

**Source:** `tinkerex`'s deleted `.github/workflows/client-contract.yml`, job
`engine-integration`.

**Four changes from the original:**

1. **`runs-on: [self-hosted, linux]` → `[self-hosted, macos]`.** The original never ran once:
   linux is not a registered runner in any of the three repos, so the job was `if:`-gated off and
   the workflow reported success in ~8s having run only `preflight`. macos is registered in all
   three.
2. **Delete the `ruby/setup-ruby@v1` step.** It assumes the GitHub-hosted `/Users/runner` layout
   the self-hosted Mac lacks; the runner's PATH already carries mise ruby matching
   `.ruby-version`. `bundle install --quiet` is all the job needs.
3. **Delete the `apt-get install libfuse-dev` step.** Linux-only, and unnecessary: `fuser` is
   `cfg(linux)`, so `sync-engine` builds on mac without FUSE. `tinkerex`'s `nightly.yml`
   `e2e-macos` job proved this on real hardware.
4. **Boot your own app directly** instead of through `tinkerex`'s `bin/sync-server`. That script
   exists to boot a *sibling* checkout from `tinkerex`; inside your own repo it is a detour.

**Keep, with its argument intact:** `SYNC_VERIFY_FINALIZE=0`. Finalize's verify-the-bytes-landed
check is on by default, but `integration.rs` deliberately moves chunk bytes through `SharedDirIO`
— a shared-dir stand-in for the cloud — so the server legitimately cannot see them. The genuine
verify-ON proof is `two_device_e2e`, in Part B.

**Keep** `STORAGE_BACKEND=local` **only if your own app still reads it** — `two_device_e2e` moves
bytes via `PresignedIO`, and a memory store presigns relative `/dev/blobs/...` paths a Rust HTTP
client cannot follow. Verify against your own code rather than trusting this line.

```yaml
  engine-integration:
    runs-on: [self-hosted, macos]
    steps:
      - uses: actions/checkout@v7
        with: { clean: false }
      - name: Check out tinkerex-client
        uses: actions/checkout@v7
        with:
          repository: chaim354/tinkerex-client
          ssh-key: ${{ secrets.TINKEREX_CLIENT_DEPLOY_KEY }}
          path: tinkerex-client
          clean: false
      # tinkerex-client keeps the `client/` prefix in its OWN layout, so `tinkerex-client/client/...`
      # is the real path. Symlinking it to `client` means `--manifest-path client/...` and every
      # conformance script's own `cd "$(dirname "$0")/../.."` resolve with zero edits on either
      # side: bash's logical `cd` strips `..` TEXTUALLY against the invoking path, so it lands at
      # this checkout's root rather than the symlink's physical target.
      # `rm -rf` first because self-hosted runners are PERSISTENT (`clean: false`) and a real
      # client/ directory on disk would make `ln -s` refuse.
      - name: Symlink client/ to the second checkout
        run: |
          rm -rf client
          ln -s tinkerex-client/client client
      - uses: dtolnay/rust-toolchain@stable
      - name: Install gems (the runner's own Ruby — NOT ruby/setup-ruby)
        run: bundle install --quiet
      - name: Boot this app + run the integration suite (one step keeps the server alive)
        env:
          SYNC_IT_SERVER_URL: http://localhost:3002
          SYNC_VERIFY_FINALIZE: "0"
        run: |
          (lsof -ti tcp:3002 | xargs kill -9 2>/dev/null) || true
          sleep 1
          bin/rails db:prepare
          bin/rails server -p 3002 &
          SRV=$!
          trap 'kill "$SRV" 2>/dev/null || true' EXIT
          for i in $(seq 1 60); do
            curl -sf http://localhost:3002/up >/dev/null && { echo "server up"; break; }
            sleep 1
          done
          curl -sf http://localhost:3002/up >/dev/null || { echo "server failed to start"; exit 1; }
          cargo test --manifest-path client/sync-engine/Cargo.toml --test integration
          cargo test --manifest-path client/sync-engine/Cargo.toml --test two_device_e2e
```

**You will need** a `TINKEREX_CLIENT_DEPLOY_KEY` secret in `tinkerex-sync`. `GITHUB_TOKEN` is
scoped to one repo and cannot check out another, even same-owner private. Use a read-only deploy
key, not a PAT: `gh repo deploy-key add` gives one repo, read-only, no expiry, and needs no
browser (GitHub sunset `POST /authorizations` in 2020, so a fine-grained PAT is an irreducibly
manual step that also expires).

---

## Part B → `chaim354/tinkerex-client`

**Read this first: `two-device-fuse-linux` already exists in your `rust-client.yml` and is
broken.** It runs `bin/rails db:prepare` and then `client/test-conformance/two-device-fuse.sh`,
whose line 71 is `… bin/rails server -p "$PORT"`. **`tinkerex-client` has no `bin/rails`.** That
job could only ever have worked when run from `tinkerex`'s root — which is exactly why `tinkerex`
kept a duplicate of it in `nightly.yml` with a symlink. Both copies are linux-gated, so neither
has ever run. **Replace the existing job; do not add a second.**

**B1 — the two conformance scripts each need one line changed.**

`client/test-conformance/two-device-fuse.sh:71` and
`client/test-conformance/two-device-webdav-macos.sh:66` both read:

```bash
STORAGE_BACKEND=local ENABLE_TEST_SIGNUP=true CHUNK_LOCAL_DIR="$WORK/chunk-store" bin/rails server -p "$PORT" >"$WORK/server.log" 2>&1 &
```

The `bin/rails` they resolve comes from `cd "$(dirname "$0")/../.."`, i.e. the *invoking* repo's
root. Post-separation that must be a `tinkerex-sync` checkout. Give each script an explicit
server-root variable rather than relying on the enclosing repo:

```bash
SYNC_ROOT="${SYNC_ROOT:?set SYNC_ROOT to a tinkerex-sync checkout}"
( cd "$SYNC_ROOT" && ENABLE_TEST_SIGNUP=true bin/rails server -p "$PORT" ) >"$WORK/server.log" 2>&1 &
```

Drop `STORAGE_BACKEND` and `CHUNK_LOCAL_DIR` unless `tinkerex-sync`'s own code reads them — check,
do not assume. Keep `ENABLE_TEST_SIGNUP=true`: the scripts create users through
`POST /v1/test/users`, which is gated solely on that flag.

**B2 — the five jobs.** Each needs a `tinkerex-sync` checkout and boot in place of the `tinkerex`
Rails server. `SYNC_IT_SERVER_URL` must point at it.

| job | family | cargo invocation |
|---|---|---|
| `e2e-linux` | linux | `--test two_device_e2e -- --nocapture` |
| `e2e-macos` | macos | `--test two_device_e2e -- --nocapture` |
| `stress-load-and-multifiletype-linux` | linux | `--test concurrency_load` then `--test multifiletype_conformance`, both `-- --nocapture` |
| `two-device-fuse-linux` | linux | script: `client/test-conformance/two-device-fuse.sh` |
| `two-device-webdav-macos` | macos | script: `client/test-conformance/two-device-webdav-macos.sh` |

All manifests are `client/sync-engine/Cargo.toml`.

**Keep** `continue-on-error: true` on `two-device-webdav-macos` and its reason: macOS
`/sbin/mount_webdav` needs an INTERACTIVE desktop login session and will not hold a mount from a
headless launchd/ssh context. The script self-detects and exits 0 with a `BLOCKED` notice rather
than a false failure.

**Keep** the `needs: preflight` + `if: ${{ needs.preflight.outputs.<family> == 'true' }}` gating on
every linux and windows job. A job matching no online runner does **not** fail — it queues 24h at
0 elapsed and is auto-cancelled, leaving the PR UNSTABLE and merging needing `--admin`. That is
how CI went dark for five weeks on 2026-06-24.

**B3 — the signal gap.** In `tinkerex`, four consecutive nightly failures (2026-08-21 → 08-24,
all `Input required and not supplied: token` from a secret referenced on extraction day and never
created) notified nobody, because a scheduled workflow has no PR to turn red. If these land on a
schedule in `tinkerex-client`, give them a notification path.

---

## What `tinkerex` keeps

`ci.yml` only — seven jobs, all `[self-hosted, macos]`: `preflight` plus one per gate, each
invoking `bin/ci <gate>`. Its
`test-chunk-remote` gate still boots a real `tinkerex-sync` via `bin/sync-server` and runs the
full suite against it — that is `tinkerex`'s half of the wire contract and it is not moving.
`TINKEREX_SYNC_DEPLOY_KEY` stays for it. `TINKEREX_CLIENT_DEPLOY_KEY` was deleted; recreate it in
whichever repo now needs it.
