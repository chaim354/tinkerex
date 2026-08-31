# The CI runner image for chaim354/tinkerex — built NATIVELY on the Unraid Docker host
# (192.168.1.146, x86_64), never cross-built on the ARM64 Mac. Emulated builds of Ruby, Chrome and a
# Rust crate are slow enough that nobody rebuilds, and an image nobody rebuilds drifts from this
# file — the same failure ops/kaneo-stack.yml's header describes for a compose file.
#
# Build:  ssh root@192.168.1.146 'docker build -t tinkerex-ci-runner:<tag> -f ci/runner/Dockerfile .'
# Deploy: ops/ci-runner-stack.yml, through Portainer.
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
FROM myoung34/github-runner:2.336.0

# The runner image is Ubuntu-based and runs jobs as the `runner` user. Everything below installs to
# a system path so that user can reach it without a login shell.
USER root

# ---------------------------------------------------------------------------------------------
# Base toolchain. lsof, curl and bash are NOT incidental: bin/ci test-chunk-remote's script uses
# `lsof -ti tcp:$PORT` as its leftover-process guard, two curl probes (/up and whoami) and
# ${PIPESTATUS[0]}, which is a bashism the gate deliberately depends on.
# ---------------------------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git openssh-client curl ca-certificates lsof bash \
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

COPY tools/stl-thumbnailer /tmp/stl-thumbnailer
RUN cargo install --path /tmp/stl-thumbnailer --root /usr/local \
 && rm -rf /tmp/stl-thumbnailer \
 && stl-thumbnailer --version

# ---------------------------------------------------------------------------------------------
# BACK TO THE NON-ROOT RUNNER USER. Headless Chrome refuses to start as root without --no-sandbox,
# and dropping the sandbox is the wrong fix — running as an ordinary user keeps it.
# ---------------------------------------------------------------------------------------------
USER runner
