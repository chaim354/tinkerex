# Phase B — the addons repo and its static container — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the addon bundles out of the Rails image into their own private repo and static container, so republishing a bundle deploys an addon change **without redeploying Rails** — the goal the whole arc exists for.

**Architecture:** A new private repo `chaim354/tinkerex-addons` holds the bundles and a tiny nginx image that serves them. The image is built and pushed to ghcr from that repo, and booted on the Unraid host as a Kamal accessory named `addons` (so `tinkerex-addons` on the Kamal network, matching the existing `tinkerex-boxes`/`tinkerex-openscad` pattern). The Rails app reaches it via `ADDON_SOURCE_URL`, which takes precedence over the on-disk `ADDON_SOURCE_PATH` default that Phase A shipped.

**Tech Stack:** nginx (alpine), Docker/buildx, Kamal 2, Rails 8.1, Minitest.

---

## Scope

Phase B of `docs/superpowers/specs/2026-08-02-addons-runtime-bundle-design.md`.

**In scope:** the addons repo, the static container, the Kamal accessory, repointing `ADDON_SOURCE_URL`, removing `public/addons` from the Rails image, extending the OVH-blanking guard, and **proving independent deploy actually works**.

**NOT in scope, deliberately:**

- **Moving the GPL sidecars.** `app/controllers/tools/boxes_controller.rb` and `openscad_controller.rb` still call `BoxesClient`/`OpenscadClient` directly, so those sidecars are still invoked from the main repo. Moving them now would split a live call path across two repos for no benefit. They move when their addons migrate. Spec §4.3 only requires they stay *out of the permissive bundle container*, which this satisfies by never putting them in it.
- **`openscad` and `boxes` migrations.** Separate plans.

**Repo naming:** the repo is `tinkerex-addons`. `docs/roads-not-taken.md` §8 calls the abandoned engine-gem repo `maker-addons`; that reference is historical and correct for what *that* plan proposed, but §8 must gain a line noting the repo that actually exists is `tinkerex-addons`.

---

## Task 1: Create the addons repo

**Files:** all in a new repo at `~/Desktop/tinkerex-addons` (working copy), pushed to `chaim354/tinkerex-addons` (private).

- [ ] **Step 1: Create the repo and working copy**

```bash
gh repo create chaim354/tinkerex-addons --private --description "Addon bundles for Tinkerex — manifest + plain-ESM, served as a static container" --clone
```

Confirm it cloned to `~/Desktop/tinkerex-addons` (adjust the following paths if `gh` put it elsewhere) and that `gh repo view chaim354/tinkerex-addons --json visibility` reports `PRIVATE`.

- [ ] **Step 2: Move the bundles across**

From the Rails repo (`~/Desktop/tinkerex`, branch `claude/addons-repo-phase-b`):

```bash
mkdir -p ~/Desktop/tinkerex-addons/addons
cp -R public/addons/. ~/Desktop/tinkerex-addons/addons/
```

Copy, don't move — the Rails repo's copy is deleted in Task 3, after the container is proven to work. Deleting it first would leave no working state if the container turns out to be wrong.

Verify: `~/Desktop/tinkerex-addons/addons/manifests.json` plus `addons/generators/` with all seven files.

- [ ] **Step 3: Write the Dockerfile**

`~/Desktop/tinkerex-addons/Dockerfile`:

```dockerfile
# Serves addon bundles as static files, nothing else. Internal-only: the Kamal accessory declares no
# `port:`, so this is reachable on the Kamal network as `tinkerex-addons` and never from the internet.
#
# PERMISSIVE BY CONSTRUCTION. The GPL sidecars (boxes, openscad) must never be added to this image —
# it is built and pushed to a registry, which is redistribution, and CLAUDE.md §9 keeps copyleft out
# of shipped artifacts. Guarded by test/no_gpl_in_bundle_image_test.rb.
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY addons/ /usr/share/nginx/html/

# Fail the build rather than serve an empty index if the bundles didn't copy.
RUN test -f /usr/share/nginx/html/manifests.json || (echo "manifests.json missing" && exit 1)
```

`~/Desktop/tinkerex-addons/nginx.conf`:

```nginx
server {
  listen 80;
  server_name _;
  root /usr/share/nginx/html;

  # The Rails app fetches manifests.json and each addon's assets. Everything here is public static
  # JS; there is nothing to authenticate, and the container is not internet-reachable.
  location / {
    autoindex off;
    add_header Cache-Control "no-cache";
    try_files $uri =404;
  }

  # `no-cache` above is deliberate: Rails does not cache proxied assets (Phase A left that out on
  # purpose), so a stale copy here would be the only stale copy — and a stale bundle reads as
  # "my fix didn't deploy", which is worse than a slow one.

  location = /health { return 200 "ok\n"; add_header Content-Type text/plain; }
}
```

- [ ] **Step 4: Write the build script**

`~/Desktop/tinkerex-addons/bin/build-push`:

```bash
#!/usr/bin/env bash
# Build and push the addon bundle image. Publishing this IS the addon deploy — no Rails redeploy is
# needed, because the Rails app fetches from this container at runtime via ADDON_SOURCE_URL.
#
# After pushing, roll the accessory from the TINKEREX repo:
#   kamal accessory reboot addons
set -euo pipefail

IMAGE="ghcr.io/chaim354/tinkerex-addons"
TAG="$(git rev-parse HEAD)"

: "${KAMAL_REGISTRY_PASSWORD:?set KAMAL_REGISTRY_PASSWORD (op item get 'ghcr.io' --fields password --reveal)}"
echo "$KAMAL_REGISTRY_PASSWORD" | docker login ghcr.io -u chaim354 --password-stdin

docker buildx build --platform linux/amd64 -t "$IMAGE:$TAG" -t "$IMAGE:latest" --push .
echo "pushed $IMAGE:$TAG"
```

`chmod +x bin/build-push`.

**`--platform linux/amd64` is required** — the build box is arm64 (Apple Silicon) and the Unraid host is amd64. The Rails image already handles this; check `config/deploy.yml`'s `builder:` block in the tinkerex repo and match whatever it does.

- [ ] **Step 5: Write the licence guard**

`~/Desktop/tinkerex-addons/test/no_gpl_in_bundle_image_test.sh`:

```bash
#!/usr/bin/env bash
# CLAUDE.md §9: this image is built and pushed to a registry, which is redistribution, so no GPL may
# enter it. The GPL sidecars live in the tinkerex repo today and move here only when their addons
# migrate — at which point they must sit OUTSIDE the Dockerfile's COPY, in their own images.
#
# This guard is directory-driven, not a hard-coded list, so a sidecar added later is covered the day
# it appears rather than the day someone remembers.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
for d in sidecar/*/; do
  [ -d "$d" ] || continue
  if grep -qE "^COPY ${d%/}|^COPY \./?${d%/}" Dockerfile; then
    echo "FAIL: Dockerfile COPYs $d into the permissive bundle image (CLAUDE.md §9)"
    fail=1
  fi
done

# The bundle tree itself must not acquire a GPL licence file.
if find addons -iname 'COPYING*' -o -iname 'LICENSE*' | grep -qi .; then
  if grep -rliE "gnu general public|gpl-[23]" addons/ >/dev/null 2>&1; then
    echo "FAIL: GPL-licensed content found under addons/ (CLAUDE.md §9)"
    fail=1
  fi
fi

[ "$fail" -eq 0 ] && echo "ok: no GPL in the bundle image"
exit "$fail"
```

`chmod +x test/no_gpl_in_bundle_image_test.sh` and run it; expect `ok: no GPL in the bundle image`.

**Mutation-check it (§15):** temporarily create `sidecar/fake/` with a file, add `COPY sidecar/fake /tmp/x` to the Dockerfile, re-run, confirm **FAIL**. Remove both, confirm ok. A guard that has never failed has not been shown to work.

- [ ] **Step 6: README and licence**

`~/Desktop/tinkerex-addons/README.md` — state: what this repo is (addon bundles for Tinkerex, manifest + plain-ESM, no build step), how an addon is structured (manifest fields, `mount(element, context)` contract), how to deploy (`bin/build-push` then `kamal accessory reboot addons` from the tinkerex repo), and that **publishing a bundle is the deploy — Rails is not redeployed**. Cross-reference `docs/superpowers/specs/2026-08-02-addons-runtime-bundle-design.md` in the tinkerex repo.

Add an MIT `LICENSE` (permissive, per §9 — this repo must stay permissive).

- [ ] **Step 7: Commit and push**

```bash
cd ~/Desktop/tinkerex-addons
git add -A && git commit -m "feat: addon bundles + static container

Serves manifests.json and each addon's plain-ESM bundle over HTTP on the Kamal
network. Publishing this image is the addon deploy; Rails is not redeployed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push -u origin main
```

- [ ] **Step 8: Build and push the image**

```bash
export KAMAL_REGISTRY_PASSWORD="$(op item get 'ghcr.io' --fields password --reveal)"
cd ~/Desktop/tinkerex-addons && bin/build-push
```

Never print the secret; check with `${#KAMAL_REGISTRY_PASSWORD}`.

---

## Task 2: Wire the accessory into the Rails deploy

**Files (all in `~/Desktop/tinkerex`, branch `claude/addons-repo-phase-b`):**
- Modify: `config/deploy.yml`
- Modify: `config/deploy.ovh.yml`
- Modify: `test/deploy_hygiene_test.rb`

- [ ] **Step 1: Write the failing guard test first**

The existing OVH-blanking guard greps `/_SIDECAR_URL\z/`, which `ADDON_SOURCE_URL` does not match — so it is unprotected. Extend the guard rather than adding a second one.

In `test/deploy_hygiene_test.rb`, change the key selection in the "OVH overlay clears every sidecar URL it cannot reach" test from:

```ruby
    sidecar_url_keys = base.dig("env", "clear").to_h.keys.grep(/_SIDECAR_URL\z/)
    assert sidecar_url_keys.any?, "expected deploy.yml to define at least one *_SIDECAR_URL"
```

to:

```ruby
    # Every env var naming a service that runs as an accessory on the UNRAID host. `_SIDECAR_URL` was
    # the original pattern; ADDON_SOURCE_URL joined it in Phase B and does NOT match that suffix, so
    # it was silently unguarded until this line was widened. Any future accessory URL must be added
    # here — the failure mode is identical for all of them: OVH deep-merges the Unraid hostname, the
    # service reports configured, and every call fails.
    host_only_url_keys = base.dig("env", "clear").to_h.keys.grep(/_SIDECAR_URL\z|\AADDON_SOURCE_URL\z/)
    assert_equal 3, host_only_url_keys.size,
                 "expected BOXES_SIDECAR_URL, OPENSCAD_SIDECAR_URL and ADDON_SOURCE_URL in deploy.yml"
```

and rename the loop variable accordingly. Also update the test's name and comment to say "every Unraid-host-only service URL" rather than "sidecar URL".

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/deploy_hygiene_test.rb`

Expected: **RED** — `ADDON_SOURCE_URL` is not yet in `deploy.yml`, so the count is 2, not 3.

- [ ] **Step 3: Add the accessory and the URL**

In `config/deploy.yml`, add to the `accessories:` block, after `openscad:`:

```yaml
  # The addon bundle host (repo: chaim354/tinkerex-addons) — a tiny nginx image serving each addon's
  # manifest + plain-ESM bundle. NO `port:` -> internal-only, reachable on the Kamal network as
  # `tinkerex-addons`, exactly like the two sidecars. THIS ACCESSORY IS WHY ADDON CHANGES DO NOT NEED
  # A RAILS DEPLOY: rebuild + push from that repo, `kamal accessory reboot addons`, done.
  addons:
    image: ghcr.io/chaim354/tinkerex-addons:latest
    host: 192.168.1.95
```

and to `env: clear:` in the same file, beside the sidecar URLs:

```yaml
    ADDON_SOURCE_URL: http://tinkerex-addons
```

- [ ] **Step 4: Blank it in the OVH overlay**

In `config/deploy.ovh.yml`'s `env: clear:` block, alongside the existing blanked sidecar URLs, add:

```yaml
    # The addons accessory runs on the Unraid host too, so `tinkerex-addons` does not resolve here.
    # Blank -> the Rails app falls back to production.rb's ADDON_SOURCE_PATH default, which points at
    # public/addons — a directory Phase B removes from the image. So OVH renders an EMPTY tools
    # gallery until it gets its own addons accessory. That degrades gracefully (Registry rescues to
    # []), it is not a 500, and it is the honest state: OVH has no addon host.
    ADDON_SOURCE_URL: ""
```

Match the surrounding style — read the existing blanked entries first.

- [ ] **Step 5: Run the guard**

Run: `bin/rails test test/deploy_hygiene_test.rb`

Expected: green.

- [ ] **Step 6: Mutation-check the widened guard (§15)**

Temporarily delete the `ADDON_SOURCE_URL: ""` line from `config/deploy.ovh.yml`. Run the test.

Expected: **RED** — the overlay no longer clears a key `deploy.yml` defines. Restore and confirm green. This is the exact bug the guard exists for, and the reason the widening was necessary.

- [ ] **Step 7: Commit**

```bash
git add config/deploy.yml config/deploy.ovh.yml test/deploy_hygiene_test.rb
git commit -m "feat(deploy): boot the addon bundle host as a Kamal accessory

ADDON_SOURCE_URL points Rails at tinkerex-addons on the Kamal network, taking
precedence over the on-disk fallback. The OVH-blanking guard is widened to cover
it — it did not match the _SIDECAR_URL suffix and was silently unguarded.
Mutation-checked.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: Remove the in-image bundles and deploy

- [ ] **Step 1: Boot the accessory**

```bash
cd ~/Desktop/tinkerex
export KAMAL_REGISTRY_PASSWORD="$(op item get 'ghcr.io' --fields password --reveal)"
export CHUNK_SECRET_ACCESS_KEY="$(op item get 'seaweednew' --fields 'secret key' --reveal)"
kamal accessory boot addons
```

Verify it is up and serving, from the host:

```bash
ssh kamal1@192.168.1.95 "docker ps --format '{{.Names}}\t{{.Status}}' | grep tinkerex-addons"
ssh kamal1@192.168.1.95 "docker run --rm --network kamal curlimages/curl:latest -s http://tinkerex-addons/manifests.json"
```

Expected: the manifest JSON with the `generators` entry. **If the network name is not `kamal`, find it** (`docker network ls`) — do not guess.

- [ ] **Step 2: Delete the in-image bundles**

```bash
git rm -r public/addons
```

In `config/environments/production.rb`, update the `ADDON_SOURCE_PATH` default's comment: the directory it names no longer ships in the image, so the default is now a fallback that yields an empty gallery rather than a working one. Keep the line — it still correctly yields to `ADDON_SOURCE_URL`, and removing it would make a URL-less deployment fail differently — but say plainly what it now does.

Check whether `config/environments/development.rb`'s equivalent still works for local dev **without** the accessory. It will not, since `public/addons` is gone. Point local dev at the addons repo working copy instead:

```ruby
  ENV["ADDON_SOURCE_PATH"] ||= File.expand_path("../../../tinkerex-addons/addons", __dir__) if ENV["ADDON_SOURCE_URL"].blank?
```

Verify that path actually resolves from `config/environments/` before committing it, and note in the comment that it assumes the addons repo is checked out beside this one.

- [ ] **Step 3: Confirm the test suite still passes**

Run: `bin/ci`

The system test `test/system/addon_bundle_test.rb` loads the bundle — it will now need the addons repo checked out beside this one (per the dev default above) or an explicit env var. **If it fails, that is a real finding**: it means CI on a fresh checkout would fail too, and the test needs its own fixture bundle rather than depending on a sibling repo. Report rather than working around; a CI job that depends on an unrelated repo being checked out is a trap.

- [ ] **Step 4: Deploy all three Unraid backends**

Use the `/deploy` skill. Do **not** deploy OVH.

- [ ] **Step 5: PROVE independent deploy — the point of the entire arc**

This is the acceptance test. In the addons repo, make a visible, harmless change to a bundle (e.g. change the Generators addon's `description` in `manifests.json`), then:

```bash
cd ~/Desktop/tinkerex-addons && git commit -am "test: prove independent deploy" && bin/build-push
cd ~/Desktop/tinkerex && kamal accessory reboot addons
```

**Without touching Rails at all**, confirm the change is live:

```bash
ssh kamal1@192.168.1.95 "docker run --rm --network kamal curlimages/curl:latest -s http://tinkerex-addons/manifests.json"
```

and confirm the Rails container still carries the **same** image SHA as before (`docker ps | grep tinkerex-web`). Both must be true: the addon changed, Rails did not move.

Note the manifest is cached for 5 minutes (`Registry::TTL`), so the *gallery* may lag; the container's served bytes will not. Report both observations.

Then revert the cosmetic change and republish.

- [ ] **Step 6: Docs**

- `CLAUDE.md` §14c: record that addon bundles are served by the `addons` accessory from `chaim354/tinkerex-addons`, that `ADDON_SOURCE_URL` takes precedence over the on-disk fallback, and that **the OVH overlay must blank it** — with the widened guard named.
- `docs/roads-not-taken.md` §8: note that the repo which actually exists is `tinkerex-addons`, not the `maker-addons` that abandoned plan proposed.
- `docs/STATUS.md`: narrate Phase B, including the independent-deploy proof from Step 5 and the OVH consequence.

---

## Done when

- [ ] `chaim354/tinkerex-addons` exists, private, with the bundles, container, build script, licence guard (mutation-checked) and README
- [ ] The `addons` accessory is booted on Unraid and serving `manifests.json`
- [ ] `public/addons` is gone from the Rails image; all three backends deployed and `/tools` still lists Generators
- [ ] **Step 5's proof passed**: a bundle change went live with Rails' image SHA unchanged
- [ ] `ADDON_SOURCE_URL` blanked in `deploy.ovh.yml`, guarded by the widened `deploy_hygiene_test`, mutation-checked
- [ ] `bin/ci` green, three legs identical
