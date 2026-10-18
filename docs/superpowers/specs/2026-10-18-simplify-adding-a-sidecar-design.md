# Simplify adding a sidecar — one definition, a generator, one build script, one-command publish

**Date:** 2026-10-18 · **Repo:** `chaim354/tinkerex` · **Scope:** sub-project C of "simplify adding
tools". A and B — writing and publishing a browser-only tool — are `docs/superpowers/specs/2026-10-17-simplify-adding-tools-design.md`
(chaim354/tinkerex#410, chaim354/tinkerex-addons#18).

## 1. The problem, counted

A sidecar is a GPL service an addon reaches over HTTP through the host's proxy (§9, §14c). Adding a
third one, `foo`, today:

| # | Edit | Guarded today? |
|---|---|---|
| 1 | `sidecar/foo/` — Dockerfile that COPYs its LICENSE, the app, a README | yes — licence (`deploy_hygiene_test`, directory-driven) |
| 2 | copy `bin/build-boxes-sidecar` → `bin/build-foo-sidecar` and edit three names | yes — revision label (directory-driven over `bin/build-*-sidecar`). The two existing scripts are **byte-identical apart from names and comments** |
| 3 | `config/deploy.yml` — an `accessories: foo:` block, and `FOO_SIDECAR_URL: http://tinkerex-foo:8000` in `env.clear` | **no** |
| 4 | `config/deploy.ovh.yml` — `FOO_SIDECAR_URL: ""` | yes, once #3 exists (derived from #3's keys) |
| 5 | `docker-compose.yml` — a `foo:` service pinned to `linux/amd64`, and `FOO_SIDECAR_URL: http://foo:8000` in `web`'s env | partly — and `compose_hygiene_test` **hard-codes** "four ghcr images" and "three Tools images", so the TEST must be edited too |
| 6 | `docker-compose.build.yml` — a `foo:` build entry | yes ("every service" is derived) |
| 7 | `docs/INSTALL.md` — the sidecar-URL row names `FOO_SIDECAR_URL` | yes, via #5 (`install_docs_test`) |
| 8 | `app/views/help/show.html.erb` — the operator list of `*_SIDECAR_URL` names | **no** |
| 9 | deploy: build + push, `kamal accessory boot foo` the first time (`reboot` after), then **redeploy the three app legs** so they carry `FOO_SIDECAR_URL` | by hand; nothing verifies what is running |

`deploy.share.yml` and `deploy.s3.yml` also repeat `BOXES_SIDECAR_URL`, which they would inherit from
the base anyway (Kamal deep-merges `env.clear`) — historical, and left alone here.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| Approach | **One definition + a generator + a completeness guard** | The owner's choice over ERB-generating `deploy.yml` (compose, INSTALL and Help cannot template, and `deploy.yml` would stop being a literal record of what is deployed) and over a guard-only approach (still ~6 hand pastes). |
| Generator form | **A Rails generator** (`bin/rails generate sidecar`) | Templates, `inject_into_file`, `--pretend` and `bin/rails destroy` come with it; the repo already boots in development without library env (measured 0.8 s). |
| A sidecar's URL | **Stays explicit per deployment** — no convention fallback | A convention (`http://tinkerex-<name>:8000` when unset) would make every declared service read "available" before its accessory exists, and on OVH every call would fail instead of greying out — the deep-merge bug from a new direction. The cost kept is #9's app redeploy on a NEW sidecar, which publish names. |
| Deploy | **`bin/publish-sidecar <name>`** | The owner's choice; the sidecar twin of tinkerex-addons' `bin/publish`. |
| Revision readable without the host's IP | **`/revision` inside the image**, beside the OCI label | The label needs `docker inspect` on the host; `/revision` is read through `kamal accessory exec`, as `bin/publish` reads `version.json`. |

## 3. `Tinkerex::Sidecars` — the one definition

`lib/tinkerex/sidecars.rb`. Pure Ruby over files in a checkout; constructed with `root:` (default
`Rails.root`) so tests point it at a temp tree.

- **`names`** — the basenames of `sidecar/*/` that contain a `Dockerfile`, sorted. The same discovery
  as the licence guard. (In the production image `/sidecar/` is dockerignored, so `names` is `[]`
  there; nothing at runtime calls this — it is for tests, tasks and the generator.)
- **Conventions, as methods of the name:** `image(name)` = `ghcr.io/chaim354/<name>-sidecar:latest`;
  `container(name)` = `tinkerex-<name>`; `kamal_url(name)` = `http://tinkerex-<name>:8000`;
  `compose_url(name)` = `http://<name>:8000`; `env_key(name)` = `Maker::Addons::Services.env_key_for(name)`
  (the ONE env-name derivation, §14c — never a second `"#{name.upcase}_SIDECAR_URL"`).
- **`problems` → `[{sidecar:, file:, missing:, snippet:}]`**, for every name:
  1. `config/deploy.yml` — `accessories.<name>.image == image(name)`
  2. `config/deploy.yml` — `env.clear[env_key] == kamal_url`
  3. `config/deploy.ovh.yml` — `env.clear[env_key] == ""`
  4. `docker-compose.yml` — `services.<name>.image == image(name)` and `platform == "linux/amd64"`
  5. `docker-compose.yml` — `services.web.environment[env_key] == compose_url`
  6. `docker-compose.build.yml` — `services.<name>.build == "sidecar/<name>"`
  7. `docs/INSTALL.md` — names `` `<env_key>` ``
  8. `docs/INSTALL.md` — names `` `<compose_url>` `` in the row's "set by compose" list (added in
     review: the generator wrote it and nothing checked it)
  9. `app/views/help/show.html.erb` — names `<code><env_key></code>`

  and, **in reverse**, a stray: any `*_SIDECAR_URL` key in `deploy.yml`'s or `web`'s env, any
  accessory or compose service whose image ends `-sidecar:latest`, with no `sidecar/<name>/` behind it.
  `snippet` is the exact text to add, so a failure message is the fix.
- Readers: `test/sidecar_hygiene_test.rb` (in `bin/ci`), `bin/rails sidecars:check` (exits 1 naming
  each problem with its snippet; publish runs it), and the generator, last.
- `test/compose_hygiene_test.rb`'s "four images" / "three Tools images" become derived from
  `Sidecars.names` (+ `web` + `addons`), so adding a sidecar needs no test edit.

The existing OVH-blanking test in `deploy_hygiene_test.rb` stays (it also covers `ADDON_SOURCE_URL`
and `CHUNK_REMOTE_URL`, which are not sidecars); #3 above duplicates its sidecar half deliberately,
so `sidecars:check` alone is a complete pre-publish answer.

## 4. `bin/rails generate sidecar <name> --license <path>`

`lib/generators/sidecar/sidecar_generator.rb`, templates beside it in `templates/` (NOT under
`sidecar/`, where a template Dockerfile would be discovered as a sidecar).

- **Refuses**, writing nothing: a name not matching `\A[a-z][a-z0-9-]*\z`; an existing `sidecar/<name>/`;
  a missing or unreadable `--license` file; any insertion marker (below) absent.
- **`--license` is required**: a sidecar exists to run GPL code this app must not link, and its image
  redistributes that code, so the licence is the UPSTREAM project's — the generator cannot invent it.
  It is copied to `sidecar/<name>/LICENSE`.
- **Scaffolds `sidecar/<name>/`** from the boxes pattern: `Dockerfile` (python:3.12-slim,
  `requirements.txt`, `app.py`, `COPY LICENSE README.md`, the `/revision` lines of §5, `EXPOSE 8000`,
  gunicorn on `0.0.0.0:8000`), `requirements.txt` (flask 3.0.\*, gunicorn 22.0.\*), `app.py` (`GET /up`
  → `ok`; an example `POST /render` reading a JSON body and answering JSON; errors as
  `{"error": <prose>, "code": <machine code>}` with 422 for a refused value — §14c: a consumer branches
  on `code`, never the prose), `README.md` (what it wraps, its licence, how an addon reaches it —
  `services: ["<name>"]` + `host.service.post`, how to publish).
- **Inserts** at marker comments added once by this work — one per insertion point, each a distinct
  `# bin/rails generate sidecar inserts sidecar <URLs|accessories|services|builds> above this line`
  (`Tinkerex::Sidecars::MARKERS`), present exactly once: `deploy.yml` env and accessories,
  `deploy.ovh.yml`, `docker-compose.yml` web env and services, `docker-compose.build.yml`. The
  `INSTALL.md` row and the Help list are prose, so those two insert after the LAST existing
  `_SIDECAR_URL` in their sentence (regex anchored to that row / that `<p>`). Every insertion point is
  checked BEFORE the first write; a missing one refuses the whole run.
- **Then** runs `Tinkerex::Sidecars#problems` (must be empty) and prints the next steps: write the app;
  add `"services": ["<name>"]` to the addon's manifest; `bin/publish-sidecar <name>`; redeploy the
  three app legs (they must carry `<NAME>_SIDECAR_URL`).
- `bin/rails destroy sidecar <name>` reverses the inserts and removes the directory.

## 5. `bin/build-sidecar <name>` — one build script

- Replaces `bin/build-boxes-sidecar` and `bin/build-openscad-sidecar` (deleted). Their comments merge;
  openscad's note about `assert-capabilities.sh` moves to `sidecar/openscad/README.md`.
- **`bin/build-sidecar --revision <name>`** prints `<sha>` or `<sha>-dirty` — dirty when
  `git status --porcelain -- sidecar/<name>` is non-empty, today's rule — and nothing else. The build
  and `bin/publish-sidecar` both ask it: one definition.
- Builds with `--build-arg SIDECAR_REVISION=<revision>` and the existing OCI label. Each sidecar
  `Dockerfile` (both existing ones and the template) adds, as its last build step:
  `ARG SIDECAR_REVISION=unknown` then `RUN printf '%s\n' "$SIDECAR_REVISION" > /revision`.
- `deploy_hygiene_test`'s revision-label test now checks the one script; a directory-driven check adds
  that every `sidecar/*/Dockerfile` writes `/revision` from `SIDECAR_REVISION`.
- References updated: `config/deploy.yml` comments, `docs/DEPLOY.md`, `sidecar/openscad/Dockerfile`'s
  comment. Historical plans, specs and audits keep the old names.

## 6. `bin/publish-sidecar <name>`

Stops at the first failure:

1. `bin/rails sidecars:check`.
2. `bin/secrets-preflight` — kamal expands secrets through Ruby backticks, so an unreadable one becomes
   empty silently (`docs/invariants/deploy-secrets.md`).
3. `bin/build-sidecar <name>`.
4. **Boot the first time, reboot after**: probe `bin/kamal accessory exec <name> --reuse -q true`;
   success → `reboot`, failure → `boot`, remembering that this was a first boot. (A network failure
   makes the probe fail too; `boot` then fails as well, loudly — never a silent wrong branch.)
5. **Verify**: `kamal accessory exec <name> --reuse -q "cat /revision"` equals step 3's revision
   (the 2026-10-07 tag-revert failure), and `/up` answers `ok` — read with Python's `urllib` inside the
   container, since the slim image has no curl.
6. **On a first boot only**, print that the three app legs (chunk_remote, share, s3) need a redeploy
   to carry `<NAME>_SIDECAR_URL`. It does not run it — a three-destination deploy is its own decision.

The secret rules of tinkerex-addons' `bin/publish` apply verbatim: `{ set +x; } 2>/dev/null` before any
secret, presence tested with `${VAR:+set}`, no secret in a pipeline or after a redirection, and a
failure branch prints a pattern or a count, never a captured buffer.

## 7. Testing

- **`Tinkerex::Sidecars`** — a temp tree holding copies of the six touchpoint files and one sidecar;
  delete each touchpoint in turn and assert exactly that problem (with its snippet); plant a stray
  `*_SIDECAR_URL` and a stray `-sidecar` image; assert the real tree reports `[]`. Every arm
  mutation-checked.
- **The generator** — `Rails::Generators::TestCase` with the destination seeded by COPIES of the real
  six touchpoint files: after `generate`, `Sidecars.new(root: dest).problems == []` and the scaffold exists;
  `destroy` restores every file byte-identically; each refusal writes nothing. Mutation-checked.
- **`bin/build-sidecar` and `bin/publish-sidecar`** — hermetic runs with stub `docker`, `kamal`,
  `bin/secret` and a fake token, as tinkerex-addons' `bin/publish` was reviewed: the token never
  printed on any path (including `bash -x`), each step stops the run, boot vs reboot follows the
  probe, verify passes only on the exact revision.
- **Not run for real in this work.** No new sidecar is being added; a real `publish-sidecar` of an
  existing one redeploys a live service and needs the owner's go-ahead (and the box reachable).

## 8. Out of scope

- The redundant `BOXES_SIDECAR_URL` lines in `deploy.share.yml` / `deploy.s3.yml`.
- Async renders / a longer proxy timeout (§14c names those as their own problem).
- A sidecar in the tinkerex-addons repo — sidecars stay here; GPL never enters that image.
- Running the app-leg redeploy from `publish-sidecar`.
