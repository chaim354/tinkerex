# The CI runner image for chaim354/tinkerex — built NATIVELY on the Unraid Docker host
# (192.168.1.146, x86_64), never cross-built on the ARM64 Mac. Emulated builds of Ruby, Chrome and a
# Rust crate are slow enough that nobody rebuilds, and an image nobody rebuilds drifts from this
# file — the same failure ops/kaneo-stack.yml's header describes for a compose file.
#
# Build:  ssh root@192.168.1.146 'docker build -t tinkerex-ci-runner:<tag> -f ci/runner/Dockerfile .'
# Deploy: ops/ci-runner-stack.yml, through Portainer.
#
# PRUNE THE BUILD CACHE AFTERWARDS — `docker builder prune -af` ON THE BOX. This is not tidiness.
# Docker's storage there is a **50 GB loop device** (`/dev/loop2` on /var/lib/docker), and on Unraid
# a full docker.img takes down EVERY container on the box, not just CI. Measured 2026-08-31: the box
# sat at 30 G used / 20 G free before this image existed; five builds took it to 41 G / 9.0 G free
# (82%), of which **3.765 GB was build cache alone**. Pruning returned it to 39 G / 12 G. The image
# itself is 4.39 GB and is the part you keep.
#
# The runner WORK DIRS deliberately do not land here at all — they are bind-mounted to the array
# (ops/ci-runner-stack.yml), which is what keeps a CI checkout from competing with this loop.
#
# LICENSING (CLAUDE.md §9). myoung34/github-runner and actions/runner are MIT; resvg is MPL-2.0
# (already sanctioned in ci/ensure-resvg.sh); pdfium-cli is MIT wrapping BSD-3 pdfium;
# stl-thumbnailer is our own Apache-2.0. libvips is LGPL and Chrome is proprietary — NEITHER IS
# LINKED AND NEITHER IS SHIPPED: both are subprocesses on a build box, the same footing on which
# Maker::Previews::ImageThumb already shells out to the vipsthumbnail BINARY rather than binding
# ruby-vips (§14e). No artifact this repo distributes is affected; the Rails image is untouched.
#
# PINNED, NOT :latest — the same rule ops/kaneo-stack.yml states as its first deliberate departure
# from upstream. A floating base tag upgrades CI without anyone deciding to, and the first anyone
# would know is a green run that means something different.
#
# THE `-ubuntu-noble` SUFFIX IS LOAD-BEARING: THE BARE `2.336.0` TAG IS UBUNTU 20.04 FOCAL, GLIBC
# 2.31, AND TWO OF THE FOUR PREVIEW BINARIES WILL NOT RUN ON IT. Measured on the box, 2026-08-31,
# on the first two real builds — both failed, each naming the same cause:
#
#     resvg:  /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.32' not found  (also 2.33, 2.34)
#     pdfium: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.34' not found  (also 2.32)
#
# That is a CLASS, not two incidents: modern Go and Rust release binaries are increasingly built
# against a newer glibc than Focal's, and Focal is EOL for standard support besides. So the base
# moves rather than each binary being patched around one at a time — the same
# close-the-class-instead-of-enumerating-instances reasoning ci.yml's paths filter and
# ci_hygiene_test's self-hosted-label check both record.
#
#   base                             ubuntu   glibc   runner uid:gid
#   2.336.0        (was)             20.04    2.31    1001:121
#   2.336.0-ubuntu-jammy             22.04    2.35    1001:121
#   2.336.0-ubuntu-noble  (this)     24.04    2.39    1001:121
#
# ANY REPLACEMENT BASE MUST CARRY GLIBC >= 2.34 for the pdfium prebuilt below. The runner uid:gid is
# 1001:121 on all three — NOT the 1000:1000 the usual first-user convention suggests — and
# ops/ci-runner-stack.yml chowns the bind-mounted work dirs to it, so **re-measure it if this tag
# ever moves** (`docker run --rm --entrypoint sh <image> -c 'id runner'`). A mismatch there leaves
# the non-root runner unable to write its own work dir, which reads as a broken image.
FROM myoung34/github-runner:2.336.0-ubuntu-noble

# The runner image is Ubuntu-based and runs jobs as the `runner` user. Everything below installs to
# a system path so that user can reach it without a login shell.
USER root

# ---------------------------------------------------------------------------------------------
# Base toolchain. lsof, curl and bash are NOT incidental: bin/ci test-chunk-remote's script uses
# `lsof -ti tcp:$PORT` as its leftover-process guard, two curl probes (/up and whoami) and
# ${PIPESTATUS[0]}, which is a bashism the gate deliberately depends on.
# ---------------------------------------------------------------------------------------------
# `cmake` AND `pkg-config` ARE FOR ONE GEM, AND `build-essential` DOES NOT COVER THEM. `rugged`
# (libgit2 bindings — the git-editing stack, §14l) vendors libgit2 and builds it with CMake, so
# without these `bundle install` dies at
#
#     ERROR: CMake is required to build Rugged.
#     An error occurred while installing rugged (1.9.6), and Bundler cannot continue.
#
# and every gate fails identically at step 2 — on infrastructure rather than on code, which is the
# least legible kind of red. Measured on CI run 33440087622. It does not reproduce on the Mac
# runner, where Homebrew had already put cmake on PATH for unrelated reasons.
#
# THE REAL LESSON IS THE VERIFICATION, NOT THE PACKAGE: this list was assembled by reading the
# Gemfile rather than by running `bundle install`, so it was right about every pure-Ruby gem and
# wrong about the one with a native extension. Any change here should be checked by actually
# installing the bundle in the built image, not by inspection.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config \
      git openssh-client curl ca-certificates lsof bash \
      libssl-dev zlib1g-dev libyaml-dev libffi-dev libreadline-dev \
      sqlite3 libsqlite3-dev \
      libvips-tools \
      xz-utils unzip \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------------------------
# Ruby, via mise — the same manager the Mac runner used, so `.ruby-version` resolves the same way.
# Installed system-wide and shimmed onto PATH so `bundle install --quiet` is all a job needs, which
# is what every ci.yml job actually runs.
# ---------------------------------------------------------------------------------------------
ENV MISE_DATA_DIR=/opt/mise \
    MISE_CONFIG_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    PATH=/opt/mise/shims:/usr/local/cargo/bin:$PATH

RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
 && mise use --global ruby@3.4.7 \
 && mise reshim \
 && ruby --version | grep -q '3\.4\.7'

# ---------------------------------------------------------------------------------------------
# Chrome + chromedriver, for `bin/ci system` (driven_by :selenium, using: :headless_chrome).
# chromedriver is baked rather than left to Selenium Manager so a job never depends on a download
# at test time.
# ---------------------------------------------------------------------------------------------
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update && apt-get install -y --no-install-recommends google-chrome-stable \
 && rm -rf /var/lib/apt/lists/*

RUN CHROME_VER="$(google-chrome-stable --version | grep -oE '[0-9]+(\.[0-9]+){3}')" \
 && curl -fsSL -o /tmp/chromedriver.zip \
      "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VER}/linux64/chromedriver-linux64.zip" \
 && unzip -j /tmp/chromedriver.zip 'chromedriver-linux64/chromedriver' -d /usr/local/bin \
 && rm /tmp/chromedriver.zip \
 && chmod +x /usr/local/bin/chromedriver \
 && chromedriver --version

# ---------------------------------------------------------------------------------------------
# THE FOUR PREVIEW BINARIES. Each has an `available?` gate on PATH, so a missing one degrades that
# format to `unsupported` and the suite stays GREEN about less — the condition this block ends.
# vipsthumbnail came from libvips-tools above; the other three are here.
#
# resvg is pinned to 0.47.0, matching ci/ensure-resvg.sh's own cargo fallback, so the two cannot
# disagree about which version this repo means.
#
# RUST COMES FIRST BECAUSE resvg IS BUILT FROM SOURCE, AND THE PREBUILT BINARY IS NOT AN OPTION HERE.
# MEASURED, 2026-08-31, on the first real build on the box: the upstream
# `resvg-linux-x86_64.tar.gz` is linked against a newer glibc than this base image has, and the
# layer fails with
#
#     resvg: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.32' not found (required by resvg)
#     ...also GLIBC_2.33 and GLIBC_2.34
#
# because myoung34/github-runner:2.336.0 is **Ubuntu 20.04 Focal, glibc 2.31**
# (`ldd (Ubuntu GLIBC 2.31-0ubuntu9.18) 2.31`). Building from source removes the coupling to the
# base image's glibc entirely, and it is exactly what `ci/ensure-resvg.sh` already falls back to at
# this same pinned version — so this is the repo's own documented path, not an improvisation.
# The download form is left here in the comment so nobody "optimises" the build back into it:
# it FAILS LOUDLY at build time rather than silently, which is the good direction, but it fails.
# ---------------------------------------------------------------------------------------------
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal

RUN cargo install resvg --version 0.47.0 --root /usr/local \
 && resvg --version

RUN curl -fsSL -o /usr/local/bin/pdfium \
      "https://github.com/klippa-app/pdfium-cli/releases/download/v0.2.0/pdfium-linux-x64" \
 && chmod +x /usr/local/bin/pdfium \
 && pdfium --help >/dev/null

# stl-thumbnailer is OUR crate (tools/stl-thumbnailer, Apache-2.0) and is ABSENT ON THE MAC RUNNER,
# so the STL preview path has never once run in CI. Building it here is the single largest coverage
# change in this move. The Rust toolchain installed above is kept, since rebuilding these two crates
# is the only reason a future image change would need it.

# `--locked` IS NOT OPTIONAL, AND THE FIRST BUILD PROVED IT. `cargo install` IGNORES a committed
# Cargo.lock unless told otherwise: the build log read `Locking 37 packages to latest compatible
# versions` / `Adding stl_io v0.8.6 (available: v0.11.0)` — it re-resolved every dependency inside
# the semver ranges instead of using the lockfile this repo commits. That matters more here than
# usual: Maker::Previews::Stl carries a PAYLOAD_REVISION that is bumped *because the picture
# changed*, so a renderer whose dependencies drift silently between image rebuilds would change
# stored previews with nothing recording that it happened.
#
# THE SMOKE TEST RENDERS AN STL RATHER THAN PROBING A FLAG. `stl-thumbnailer --version` was the
# obvious check and it is WRONG — this tool takes positional arguments only and answers
# `usage: stl-thumbnailer <in.stl> <out.png> [w] [h]` on stderr with exit 1, which failed the build
# on an image that had in fact built the binary correctly. Rendering and asserting a non-empty PNG
# proves what the layer is actually for: the binary loads (the glibc class of failure above shows up
# here too), parses an STL, and writes an image.
#
# THE TETRAHEDRON IS GENERATED INLINE, NOT COPIED FROM test/fixtures/files/tetra.stl — WHICH EXISTS
# AND WOULD BE THE OBVIOUS SOURCE. `.dockerignore` excludes `/test/` (and `/ci/`), so that COPY
# fails with `"/test/fixtures/files/tetra.stl": not found`. **Do not add an exception for it.** That
# file is a §14c licensing guard — `test/deploy_hygiene_test.rb` reads it to prove `COPY . .` cannot
# ship the GPL sidecar trees into the permissive Rails image — and loosening an exclusion list to
# borrow one fixture trades a real guarantee for a convenience. Four facets rather than one triangle
# so the mesh has volume for `auto_frame` to frame.
COPY tools/stl-thumbnailer /tmp/stl-thumbnailer
RUN printf '%b\n' \
      'solid smoke' \
      'facet normal 0 0 -1\nouter loop\nvertex 0 0 0\nvertex 0 1 0\nvertex 1 0 0\nendloop\nendfacet' \
      'facet normal 0 -1 0\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 0 1\nendloop\nendfacet' \
      'facet normal -1 0 0\nouter loop\nvertex 0 0 0\nvertex 0 0 1\nvertex 0 1 0\nendloop\nendfacet' \
      'facet normal 1 1 1\nouter loop\nvertex 1 0 0\nvertex 0 1 0\nvertex 0 0 1\nendloop\nendfacet' \
      'endsolid smoke' > /tmp/smoke.stl \
 && cargo install --path /tmp/stl-thumbnailer --root /usr/local --locked \
 && stl-thumbnailer /tmp/smoke.stl /tmp/stl-smoke.png 64 64 \
 && test -s /tmp/stl-smoke.png \
 && head -c 4 /tmp/stl-smoke.png | grep -qa PNG \
 && rm -rf /tmp/stl-thumbnailer /tmp/smoke.stl /tmp/stl-smoke.png

# ---------------------------------------------------------------------------------------------
# EVERYTHING INSTALLED ABOVE WAS WRITTEN BY ROOT, AND THE JOBS ARE NOT ROOT — SO HAND mise TO THE
# RUNNER. `bundle install` writes into the Ruby installation's own gem directory, which lives under
# /opt/mise, so without this every job dies at step 2 with:
#
#     Bundler::PermissionError There was an error while trying to write to
#     `/opt/mise/installs/ruby/3.4.7/lib/ruby/gems/3.4.0/cache/bundler-4.0.3.gem`.
#
# Measured on the first real CI run (2026-08-31, run 33440087622): all six gate jobs failed this way
# in 13-20s while `preflight` — which runs no Ruby — passed. It was HIDDEN behind the `USER runner`
# bug below: with that line present the container never survived long enough to reach `bundle
# install` at all, so fixing one defect is what exposed this one.
#
# Per-container, so four runners cannot contend: /opt/mise is in each container's own writable
# layer, and only /_work is shared with the host.
RUN chown -R runner:runner /opt/mise

# ---------------------------------------------------------------------------------------------
# JOBS RUN AS THE NON-ROOT `runner` USER — VIA THE ENTRYPOINT'S OWN KNOB, NOT VIA `USER runner`.
#
# Headless Chrome refuses to start as root without --no-sandbox, and dropping the sandbox is the
# wrong fix, so jobs must not be root. The obvious way to say that is a final `USER runner`, and it
# is WRONG FOR THIS BASE IMAGE. Measured on the box, 2026-08-31 — all four containers registered and
# then immediately tore themselves down in a restart loop:
#
#     √ Connected to GitHub
#     √ Runner successfully added
#     ERROR: RUN_AS_ROOT env var is set to true but the user has been overridden
#            and is not running as root, but UID '1001'
#     Caught EXIT - Deregistering runner
#
# Note WHERE it failed: authentication and registration both SUCCEEDED. A `USER` line here reads as
# a container-security tweak and presents as a credential problem, which is the wrong place to look.
#
# `RUN_AS_ROOT=false` is the mechanism the image actually provides, and it needs the entrypoint to
# START as root: /entrypoint.sh then chowns /actions-runner, ${RUNNER_WORKDIR} and
# /opt/hostedtoolcache to `runner` — repairing the root-owned files `config.sh` just wrote — and only
# then execs `gosu runner "$@"`. Starting as `runner` skips every one of those chowns; the entrypoint
# has a branch for it and takes it silently, so the failure would surface later and further away.
#
# NET EFFECT IS WHAT `USER runner` WAS REACHING FOR: the runner process and every job it spawns run
# as uid 1001, so Chrome keeps its sandbox. Do not add `USER runner` back, and do not "fix" a
# Chrome-as-root error by adding --no-sandbox.
# ---------------------------------------------------------------------------------------------
ENV RUN_AS_ROOT=false
