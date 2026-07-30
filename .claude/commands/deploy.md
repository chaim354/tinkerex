---
description: Deploy the merged main to the three Unraid backends (chunk, share, s3) and verify
---

Deploy to **the three Unraid backends only** — `chunk` (base), `share`, `s3`.

**Never deploy OVH unless the user explicitly says "OVH" or "-d ovh" in this request.** Bare
"deploy" means Unraid. OVH is a separate, prod-like box serving a real domain; assuming it is a
one-word difference with real consequences.

## 1. Pre-flight — do all of this before building anything

**Sync main first. This is the step that actually bites.** Merging a PR on GitHub does not move
your local checkout, so the working copy is routinely one or more commits behind right after a
merge, and `kamal` will happily build and ship whatever is on disk.

```bash
cd /Users/charlesschwartz/Desktop/tinkerex
git checkout main && git pull --ff-only origin main
git log --oneline -3
```

Confirm the commits you intend to ship are in that log. Then:

- `git status --short` must be **empty**. Kamal builds the working tree, not `HEAD` — uncommitted
  edits ship silently. Stop if anything is dirty.
- Secrets. `.kamal/secrets` passes two variables through from the shell, and neither is set by
  default. Resolve them from 1Password **without printing the values**:
  ```bash
  export KAMAL_REGISTRY_PASSWORD="$(op item get 'ghcr.io' --fields password --reveal)"
  export CHUNK_SECRET_ACCESS_KEY="$(op item get 'seaweednew' --fields 'secret key' --reveal)"
  ```
  Check them with `${#VAR}` (a length), never by echoing. `RAILS_MASTER_KEY` comes from
  `config/master.key`, which must exist.
- Reachability and the current state, so you can prove afterwards that something changed:
  ```bash
  ssh -o BatchMode=yes kamal1@192.168.1.95 "docker ps --format '{{.Names}}' | grep '^tinkerex-web'"
  ```
  The container names carry the deployed git SHA. Note it.

## 2. Build once, deploy three times

Build and push a single image, then roll each backend against it — do **not** let kamal rebuild
per destination:

```bash
kamal build push
kamal deploy --skip-push            # base = chunk
kamal deploy -d share --skip-push
kamal deploy -d s3    --skip-push
```

**Run each `kamal deploy` as its own command.** Do not loop with an unquoted variable holding
`-d share`: this shell is **zsh**, which does not word-split unquoted parameters the way bash
does, so kamal receives `-d share` as one argument and errors with
`"kamal deploy" was called with arguments ["-d share"]`. (Use `${=var}` if you must loop.)

If a destination fails, **stop** and report which ones already rolled — the backends are
independent, so a partial deploy is a real state worth naming, not something to paper over.

## 3. Verify on the box, not from the exit code

A zero exit means kamal finished, not that the app works. Check all three:

```bash
# Every container should now carry the NEW git SHA
ssh kamal1@192.168.1.95 "docker ps --format '{{.Names}}\t{{.Status}}' | grep '^tinkerex-web'"

# Health per backend, through the proxy's host routing
for h in chunk share s3; do
  ssh kamal1@192.168.1.95 "curl -s -o /dev/null -w '$h %{http_code}\n' -H 'Host: $h.tinkerex.local' http://localhost/up"
done
```

Then prove the **change itself** shipped, not merely that containers booted — booting is
compatible with having deployed the old code. Pick something specific from this deploy and look
for it inside the running image, e.g.:

```bash
ssh kamal1@192.168.1.95 "docker exec <container> sed -n '1,20p' /rails/<path/to/changed/file>"
```

## 4. Report

Give the user: the image SHA now running, a per-backend table (container, image, `/up`), and the
direct evidence that the change is live. If anything was skipped or only partly rolled, say so
explicitly.

Optionally offer to add a STATUS.md entry — deploys are usually worth recording there, but that is
the user's call, not automatic.

## Never

- Deploy OVH on a bare "deploy"
- Build from a dirty or unsynced tree
- Print a secret value
- Report success from an exit code alone
