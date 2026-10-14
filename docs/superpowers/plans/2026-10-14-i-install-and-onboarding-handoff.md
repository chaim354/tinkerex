# I — Install and onboarding, second pass: handoff for the next agent

> **For agentic workers:** this is a BRIEF, not yet an implementation plan. It records what the
> 2026-10-14 review of the demo, the onboarding flow, the hero page and the install path found,
> what has since shipped, what the owner still has to decide, and the order the rest should go in.
> Start from it with `superpowers:brainstorming` → a spec → `superpowers:writing-plans`; do not
> re-audit what is verified here. Facts carry file:line against `origin/main` 86308876 plus
> `claude/hero-page` (the landing), both on 2026-10-14. Re-measure anything older than that.

**Goal:** a stranger who reaches tinkerex.com understands what Tinkerex is within a minute, can
try it without an account, and can install it on their own box from the guide without a sibling
checkout, a `chown` of their NAS, or a build from source.

**Where the program stands (the record, §11, has every arc):** A–H are merged. The live
deployments: the three Unraid destinations run 9296213a (E), the sync accessory runs the Rust
binary with `SYNC_SCHEDULER=true`; OVH (tinkerex.com) runs 097c04e5 (H) with the public demo live
and its first nightly reset due 2026-10-15 04:00 UTC. The landing (this branch) is the sign-in
view at `/` with the pitch, three screenshots and the card: `app/views/users/sessions/new.html.erb`,
`app/assets/stylesheets/pages/landing.css`, `config/routes.rb` (`unauthenticated_root`),
`test/integration/web/landing_test.rb`, `test/system/landing_test.rb`, design-system.md rule 15.

---

## 1. The owner's items (nothing below can do these)

| item | why it blocks | notes |
|---|---|---|
| Flip the four repos public | The landing links `https://github.com/chaim354/tinkerex` and `docs/INSTALL.md` there; both 404 for a stranger until then | Irreversible. Audit §6: per repo, in one sitting — `gh repo edit --visibility public`, fork-PR approval → `all_external_contributors`, branch protection on `main` with the CI jobs as required checks, runner network isolation FIRST (the four Linux runners on 192.168.1.146 run fork code otherwise). Fork guards are in: tinkerex #398, sync #25, client #14. |
| Make the ghcr packages public | Until then `docker compose up --build` compiles from source (several minutes; INSTALL.md:23, :293 `TINKEREX_IMAGE`) | Per package on GitHub's page, one-way. Then §2.1 below. |
| An NPM proxy host for `sync.tinkerex.home` | D1's device door is LAN-only until the name resolves beyond it | Memory: `*.tinkerex.home` is a wildcard to NPM; a new name needs a proxy host (operator) + `/etc/hosts` for `.local`. |
| `bin/build-and-push` in `tinkerex-sync`, then `kamal accessory reboot sync` | Ships the boolish `--scheduler` parser and drops two Ruby-only env lines (tinkerex#362) | A brief sync outage; if the proxy service is missing, `docker rm` + `kamal accessory boot sync` (memory: accessory-env-values-and-reboot-recovery). |
| Signing / notarization membership (D3, tinkerex#356) | No desktop release can ship unsigned | Owner decision; D2 (tinkerex#355) does not depend on it. |
| Deploy this branch | The landing is on tinkerex.com only once OVH redeploys (`kamal deploy -d ovh --skip-push --hosts 15.204.216.249` after `kamal build push`); bare deploy covers the Unraid three | Record each with `bin/log deploy --image <sha> [--dest ovh]`. |

## 2. Install — what a stranger hits, in order

Verified against `docs/INSTALL.md`, `docker-compose.yml`, `docker-compose.chunk_remote.yml` and
`unraid/tinkerex.xml` as of 86308876. `test/install_docs_test.rb` guards the env table (first-cell
rule: every variable the code reads has a row); `test/deploy_hygiene_test.rb` pins the Kamal side.

### 2.1 A published image instead of a build from source
- Today: `docker-compose.yml:11-12` runs `${TINKEREX_IMAGE:-tinkerex:local}` with `build: .`;
  INSTALL.md:23 warns the first build downloads renderers and compiles two Rust tools. The sync
  overlay builds from `TINKEREX_SYNC_PATH` (INSTALL.md:185, :295); the Tools profile builds the
  two GPL sidecars and the addons bundle from `TINKEREX_ADDONS_PATH` (INSTALL.md:124, :294).
- After the packages are public: flip the quick start to `docker compose pull` + `up -d`, keep
  `build:` as the documented fallback, point `TINKEREX_IMAGE`'s default at
  `ghcr.io/chaim354/tinkerex:latest` and give the sync server and the addons bundle the same
  treatment (their images already exist: the sync accessory runs `:38931307…-rust`, the addons
  accessory its own image). Pin tags, not `latest`, in the examples.
- Verify end to end the way C did: bring the stack up with compose on a Linux box, poll `/up`,
  sign up through the real form (fetch the page, take the authenticity token, POST), assert the
  second sign-up answers 403. The Mac's Docker Desktop is fine for the app; uid behaviour (2.2)
  needs real Linux.

### 2.2 The `chown` of the user's folder
- INSTALL.md:40-44 asks for `sudo chown -R 1000:1000 /path/to/files` because the container runs
  as uid 1000 and the boot probes writability by writing a file (INSTALL.md:285). Rewriting the
  ownership of a NAS folder is the step most likely to stop a careful person.
- Shape to decide in the spec: `user: "${TINKEREX_UID:-1000}:${TINKEREX_GID:-1000}"` on the `web`
  service in compose (a build-time `USER` in the Dockerfile cannot take an env value), with
  every path the process writes — `tmp/`, `log/`, `storage/`, the previews volume — owned or
  world-writable in the image, or a tiny entrypoint that `chown`s the volumes to the running uid.
  Two rows for the env table. Measure on Linux: the probe, an upload, a delete (`.trash/`), a
  scan after a file is dropped in by a different uid.

### 2.3 The sync server needs a sibling checkout and two secrets
- INSTALL.md:172-222: clone `../tinkerex-sync`, `SYNC_SECRET_KEY_BASE`, `SYNC_ADMIN_TOKEN` (the
  same value in both services), `SYNC_PUBLIC_URL`, port 3001, Compose ≥ 2.24 for `!override`.
  With a published sync image the clone goes away (2.1); the two secrets stay, so `.env.example`
  should generate-and-explain them beside `SECRET_KEY_BASE` rather than in section 5 alone.
- Not yet verified by anyone from a clean box: the chunk_remote overlay end to end on Linux with
  the desktop client signing in through D1. Do it once and record the numbers.

### 2.4 The Unraid template
- `unraid/tinkerex.xml` shipped in C (tinkerex#349). This session did not check whether it has been
  installed through Community Applications on a real Unraid; read #349's record before assuming,
  and if it has not, do it on the owner's box (the share backend is the natural first template).

### 2.5 Where the guide is
- The landing's "Install it yourself" goes to `docs/INSTALL.md` on GitHub (the only copy). That
  is right for now; a rendered docs site is not worth a sub-project until the repos are public and
  someone asks.

## 3. Onboarding — what the first hour still gets wrong

### 3.1 The empty state does not name the folder
- `app/views/shared/_where_files_come_from.html.erb:31-37` says "The library folder on the
  server is your library" without saying which folder. Inside the container it is always
  `/library` (INSTALL.md:285); the host path is only known to compose (`LIBRARY_HOST_PATH`,
  INSTALL.md:291). Options for the spec: show `LIBRARY_PATH` with "the folder you bound to it",
  or pass `LIBRARY_HOST_PATH` through as a display-only variable (one more env row, compose
  already has the value, Kamal destinations would set it by hand). The second reads better for a
  self-hoster; keep it display-only so a wrong value can only mislead a sentence.

### 3.2 "under More actions (⋯) on the Library page"
- The same partial (:31, :35) and Recent's getting-started panel name a control the reader cannot
  see from Recent (`app/views/files/index.html.erb:65` is the ⋯ summary). Either link straight to
  the rescan action with a sentence ("Rescan now"), or say where the control is ("the ⋯ button at
  the top right of the Library"). The copy is rendered in three places from one partial, so it is
  one edit; `where_files_come_from_test.rb` pins the sentences per backend.

### 3.3 The demo's first minute
- The banner (`app/views/layouts/_demo_banner.html.erb`) is two lines on every page; on a laptop it
  pushes the Recent page's first row under the fold. One line with a "what it can't do" tooltip or
  a Help anchor is enough; the sentence about resets is the part a visitor needs.
- Nothing tells a visitor what to try. A small card on Recent for the demo account only — open the
  Desk Lamp project, view a model in 3D, open Tools — would do; `Tinkerex::Demo.demo?(current_user)`
  already answers the condition with no query. Keep it out of the signed-in shell's accent budget
  (design-system.md rule 13; `accent_spend_test.rb` pins every page).

### 3.4 The seed's README image is broken on the project page
- `db/seeds/demo/Projects/Desk Lamp/README.md:9` references `docs/plate.svg`, and the owner's
  project page renders it as a broken image (seen on tinkerex.com, 2026-10-14). Two halves: the
  README renderer should resolve a relative image path against the project's folder (the owner's
  real repositories have README images, so this is a product bug, not a seed bug) — look at how the
  project page renders the README and `Maker::PublicProject#permits?` for the public side; and the
  seed should keep the image only once that works.

## 4. The demo on tinkerex.com — follow-ups

- **Tools is empty there.** `config/deploy.ovh.yml:120-125`: no addons accessory on the OVH host,
  so `ADDON_SOURCE_URL` is blank and the gallery says it has no tools. Either boot an addons
  accessory (plus the two GPL sidecars) on that host — Kamal accessories are per host — or accept
  it and make the landing's copy not promise Tools. The box generator is the single most-used
  feature of the real library (memory: real-library-is-files-first), so the demo should have it.
- **Seed quality.** `cube.3mf` is a copied fixture with no geometry (the viewer shows nothing);
  `lamp.kicad_sch` is a stub. The landing's screenshots were taken over a generated sample set
  (STLs with volume, SVGs with fills — the generator pattern is in this session's record) because
  the seed's thumbnails are hairline outlines that vanish at tile size. Give the seed the same
  kind of files, keep it small (the reset writes it every night through the port), and the demo
  will look like its screenshots.
- **tinkerex#368** (an s3 folder marker survives a delete: every folder a visitor creates comes
  back empty after the reset) and **tinkerex#369** (a folder holding more than 500 files makes the
  reset fail until cleared by hand). Both are adapter work in `FileLayer::S3`.
- **The first nightly reset** runs 2026-10-15 04:00 UTC; read `kamal app logs -d ovh` that morning
  for `DemoReset` and confirm the catalog is the seed set again (`Tinkerex::Demo.available?` true,
  one account).
- The demo account on the Unraid share box (`op://tinkerex/unraid demo account`) is the owner's
  own and is NOT the public demo; `DEMO_ACCOUNT_EMAIL` is set on OVH only (pinned by
  `deploy_hygiene_test.rb`).

## 5. Open record items touched by this work

tinkerex#355 (D2: prerequisite checks, offline indicator, client CI legs), #356 (D3: signing,
releases, updater), #359 (Postgres in the sync CI), #360 (device-auth parity pins across the three
implementations), #362 (the sync accessory rebuild + reboot), #368, #369 (above). New work is
`bin/log open "<title>"`; never a new row in CLAUDE.md §12.

## 6. Suggested order

1. Owner: ghcr packages public and the visibility flip (§1) — everything in §2.1 waits on it, and
   the landing's links are dead until then.
2. §2.2 (uid) and §2.1 (pull instead of build) as one install sub-project with a Linux end-to-end
   check; then §2.3's clean-box run of the chunk_remote overlay.
3. §3.1–3.4 as one onboarding sub-project (four small edits, one of them a real bug).
4. §4's Tools-on-OVH and seed work as the demo's second pass, after the reset has run a few nights.

## 7. How to work in this repo (what cost time this week)

- Tests need the library env: `LIBRARY_PATH=<absolute>/tmp/lib LIBRARY_BACKEND=share bin/rails
  test <files>` with an empty `tmp/lib`; suites that include `PublicFixture` call
  `use_fresh_share_library!` first. `bin/ci` from a worktree needs
  `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync`; the three backend legs
  must report identical run counts (±2 assertions is the known flap).
- Commit BEFORE the first mutation check: `git checkout -- <file>` restores HEAD, not "before my
  edit", and has wiped uncommitted work three times. Clear `tmp/cache/bootsnap*` after a restore.
- The Bash harness in a worktree refuses heredocs and chains it cannot verify; the Write tool and
  plain single commands with literal paths get through. Ruby edits of files with em-dashes need
  `LANG=en_US.UTF-8 ruby -Eutf-8:utf-8`.
- To see the app locally with files in it: the dev-server recipe in memory (scratch library +
  `Library::ScanJob.perform_now` + `Maker::GeneratePreviewJob.perform_now`, `tools/stl-thumbnailer`
  built with `cargo build --release` and on PATH). Setting `DEMO_ACCOUNT_EMAIL` to the dev account
  lets the browser sign in by the demo button, so no password is typed.
- File the arc as the PR opens (`bin/log arc --from-pr <n>`), close it at merge, record deploys
  with `bin/log deploy`. Merging is the owner's word, every time.
