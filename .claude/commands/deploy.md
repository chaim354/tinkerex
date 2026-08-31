---
description: Deploy the merged main to the three Unraid backends (chunk_remote, share, s3) and verify
---

Deploy to **the three Unraid backends only** — `chunk_remote` (base), `share`, `s3`.

The chunk-family destination is the BASE one (no `-d` flag) and runs `LIBRARY_BACKEND=chunk_remote`
against the `sync` accessory. It was briefly a separate fourth destination called `remote`; Arc D
Part 2 retired embedded chunk and folded it into the base, so a bare "deploy" covers it again.

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
- Secrets. **Do not `export` anything** (CLAUDE.md §13). `.kamal/secrets*` resolve every credential
  through `bin/secret`, which reads 1Password itself. Run the preflight and read its output:
  ```bash
  bin/secrets-preflight --all
  ```
  It must end `All secrets resolved for: base, s3, share, ovh. Safe to deploy.` **This is not
  optional politeness** — kamal expands `$(…)` through Ruby **backticks, which discard exit
  status**, so an unreadable secret becomes an **empty** one and `Kamal::Secrets#[]` returns it
  **without raising** (a *missing* key raises; an *empty* one does not). An empty credential
  deploys silently and surfaces later as a confusing `docker login` error. `RAILS_MASTER_KEY` comes
  from `config/master.key`, which must exist — **git worktrees do not have it** (gitignored +
  untracked), so `cp <main-checkout>/config/master.key .` first if you are deploying from one.

  > ⚠️ **THIS STEP USED TO SAY "export two secrets first", WITH COMMANDS THAT NO LONGER WORK.** It
  > gave `op item get 'ghcr.io' --fields password` and `op item get 'seaweednew' --fields 'secret
  > key'`; **both now return the empty string**, because agent shells authenticate as a service
  > account scoped to the `tinkerex` vault (PR #123) and those unqualified item names no longer
  > resolve. Observed 2026-08-07: both returned length 0 while `bin/secrets-preflight --all`
  > resolved all four destinations in the same session.
  >
  > **The export is obsolete rather than dangerous, and the distinction is worth stating exactly,
  > because the scary version of this warning is wrong.** `bin/secret` prefers an exported value —
  > but its guard is `[ -n "${!name:-}" ]`, which tests for **non-empty**, so an exported EMPTY
  > string falls **through** to 1Password and resolves correctly. Verified by probe, not reasoned:
  > `KAMAL_REGISTRY_PASSWORD="" bin/secret KAMAL_REGISTRY_PASSWORD op://tinkerex/ghcr.io/password`
  > returns the real value. So following the old step did not poison anything — it just did nothing,
  > while producing a `${#VAR}` of 0 that reads as a broken vault and sends you debugging the wrong
  > thing.
  >
  > What an export CAN still do is win with a **non-empty wrong** value, which is precisely why the
  > override exists (the OVH leg reuses `CHUNK_SECRET_ACCESS_KEY` for a different credential). Use
  > it deliberately or not at all.

  If the preflight reports failures, read which ones: **every secret failing at once means the
  service-account token expired** — re-mint per `docs/DEPLOY.md`, and do not go looking for a
  repo change, since the token arrives through the environment and nothing in this tree can affect
  it. **One secret failing is the opposite diagnosis** — a wrong ref or field in that single
  `.kamal/secrets*` line.
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

# Health per backend, through the proxy's host routing. BOTH suffixes, not just .local: each
# deployment registers two names (deploy.yml's `proxy:` comment says why), and a missing or
# fat-fingered `.home` entry deploys perfectly green — kamal-proxy simply 404s that name later,
# when someone tries to reach it over Tailscale from a phone. Probe what you rely on.
for h in chunk share s3; do
  for d in local home; do
    ssh kamal1@192.168.1.95 "curl -s -o /dev/null -w '$h.$d %{http_code}\n' -H 'Host: $h.tinkerex.$d' http://localhost/up"
  done
done
```

Then prove the **change itself** shipped, not merely that containers booted — booting is
compatible with having deployed the old code. Reading the changed file inside the image is the
floor:

```bash
ssh kamal1@192.168.1.95 "docker exec <container> sed -n '1,20p' /rails/<path/to/changed/file>"
```

**Prefer EXERCISING the change over reading it**, where the change has an observable output. Source
being present proves the copy happened; it does not prove a compiled artifact was rebuilt from it,
which is a different question and the one that bites. Feed the deployed container a fixture and look
at what comes back — e.g. for the STL thumbnailer, pipe a tall test model through the binary in the
running image and inspect the PNG:

```bash
ssh kamal1@192.168.1.95 "docker exec -i <container> sh -c \
  'cat > /tmp/t.stl && stl-thumbnailer /tmp/t.stl /tmp/t.png 320 320 >/dev/null 2>&1 && base64 -w0 /tmp/t.png'" \
  < fixture.stl | base64 -d > out.png
```

And where a change spans a compiled artifact AND server code that depends on it (a renderer plus its
`*_REVISION` bump), **verify both halves**: they ship in one image but fail independently, and each
half alone is worse than neither.

## 4. Report

Give the user: the image SHA now running, a per-backend table (container, image, `/up`), and the
direct evidence that the change is live. If anything was skipped or only partly rolled, say so
explicitly.

**RECORD THE DEPLOY AS THE LAST STEP OF THE DEPLOY — NOT AS A SEPARATE PR LATER.**

```bash
bin/log deploy --image <sha> --dest <destinations actually rolled>
```

This used to read "optionally offer", which quietly guaranteed the opposite of what CLAUDE.md §15
wants. It then said to commit the record straight to `main`, because a deploy happens AFTER the
merge and its record could never live in the work's own PR. **As an issue in the record that whole
exception evaporates** — there is no file to commit, so there is nothing to push to `main`. §15's
named exception is gone with it.

- **Check `bin/log status` FIRST.** It exits 4 if an earlier record was never filed, and a deploy is
  a bad moment to discover a backlog.
- Record what you PROVED, not that kamal exited 0: the image SHA and the destinations that actually
  rolled. **Pass `--dest` explicitly whenever fewer than all three rolled** — the default names all
  three, and a record naming destinations nobody deployed is the stale claim this move exists to end.
- **Take the pre-deploy baseline from `docker ps` on the box, never from a record claiming a deploy
  happened.** That mistake produced a false "this deploy will drop eight tables" warning on
  2026-08-25; the migration was already an ancestor of the running image.

## Never

- Deploy OVH on a bare "deploy"
- Build from a dirty or unsynced tree
- Print a secret value
- **`export` a secret as a matter of routine** — `.kamal/secrets*` resolve their own; an export is
  a deliberate per-run override (a non-empty one wins), not a setup step
- Deploy without `bin/secrets-preflight` — it is the only thing that catches a silent empty
- Report success from an exit code alone
