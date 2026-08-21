# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t tinkerex .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name tinkerex tinkerex

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.7
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips libvips-tools sqlite3 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock vendor ./

# THE SYNC ENGINE IS A PRIVATE git: DEPENDENCY (chaim354/tinkerex-sync -- see the Gemfile's own
# comment), which makes this the one build step in the image that needs a credential. The token
# arrives as a BuildKit secret, passed by kamal through `builder.secrets` in config/deploy.yml and
# resolved from .kamal/secrets-common; a secret mount exists only for the life of this RUN and is
# never written to a layer, unlike an ARG or an ENV, both of which survive in `docker history`.
#
# THE REWRITE IS PASSED THROUGH GIT_CONFIG_* RATHER THAN `git config --global`, and that is the
# whole point rather than a style choice: `git config --global` writes /root/.gitconfig, which IS
# part of the layer, so the token would ship inside the image having been "only" in a secret mount.
# GIT_CONFIG_COUNT/KEY/VALUE hand git the same setting through the environment of ONE command, so
# there is no file to forget to delete. The `rm -rf` below additionally clears bundler's git cache
# and the cloned engine's own .git, which is where a remote URL would otherwise be recorded.
RUN --mount=type=secret,id=TINKEREX_SYNC_TOKEN \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="url.https://$(cat /run/secrets/TINKEREX_SYNC_TOKEN)@github.com/.insteadOf" \
    GIT_CONFIG_VALUE_0="https://github.com/" \
    bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile


# ---- stl-thumbnailer: a tiny pure-CPU (NO GPU / OpenGL / Mesa / browser) STL→PNG thumbnailer
# (tools/stl-thumbnailer, euc Apache/MIT). Built here and copied into the runtime image so the
# preview pipeline renders STL thumbnails server-side with zero graphics-stack dependencies.
# Independent of `base`, so it builds in parallel. It lives under tools/, not client/, because
# it is a SERVER-side binary the Rails process execs (Maker::Previews::Stl) — despite the Rust
# source, it is not part of the client/ desktop app and has no path dependency from anything
# there. That is also why .dockerignore needs no re-include exception for it: tools/ is never
# excluded in the first place.
FROM docker.io/library/rust:1-slim AS stl-thumbnailer
WORKDIR /build
COPY tools/stl-thumbnailer ./
RUN cargo build --release && strip target/release/stl-thumbnailer


# ---- resvg: SVG→PNG rasterizer (Rust, MPL-2.0/Apache — permissive, CLAUDE.md §9). A single
# static binary, NO GPU/OpenGL/Mesa. Powers the SVG/DXF/LightBurn thumbnail path
# (Maker::Previews::SvgRasterizer). Built here, copied to PATH in the final stage. Independent of
# `base`, so it builds in parallel.
FROM docker.io/library/rust:1-slim AS resvg
RUN cargo install resvg --version 0.47.0 --root /out && strip /out/bin/resvg


# ---- pdfium: PDF page-1 → PNG for grid thumbnails (klippa pdfium-cli — MIT wrapper + BSD-3 pdfium,
# permissive per CLAUDE.md §9). The self-contained WebAssembly build embeds pdfium, so there is NO
# libpdfium.so to ship alongside and NO GPL/AGPL PDF stack (poppler/mupdf/ghostscript). `base` already
# has curl. Independent of the app build, so it fetches in parallel.
FROM base AS pdfium
ARG PDFIUM_VERSION=v0.11.0
RUN curl -fsSL "https://github.com/klippa-app/pdfium-cli/releases/download/${PDFIUM_VERSION}/pdfium-webassembly-linux-amd64" \
      -o /tmp/pdfium && chmod +x /tmp/pdfium


# ---- F3D: mesh + CAD → PNG thumbnails (BSD-3 — CLAUDE.md §9). The one renderer here that is NOT a
# small static binary: the tarball carries its own VTK, OCCT, GDAL, USD etc. in lib/, and through the
# OCCT plugin it is what gives STEP/IGES a preview at all. OCCT is LGPL and stays process-isolated in
# the f3d subprocess — the same posture §9 takes for the GPL sidecars and the FUSE drivers, and the
# reason Maker::Previews::Mesh shells out rather than linking. (The tarball ships OCCT's own LGPL
# licence text at share/licenses/occt/, which the COPY below carries into the image with it.)
#
# xz-utils IS required: ruby:slim has GNU tar but no `xz`, and `tar -J` shells out to it, so the
# plain `tar -xJf` fails with "Cannot exec". Installing it here rather than switching to the .tar.gz
# asset keeps the download at 58 MB instead of 87 MB, and this whole stage is thrown away.
# The deploy builds linux/amd64 (config/deploy.yml `arch: amd64`), so x86_64 is the right asset.
FROM base AS f3d
ARG F3D_VERSION=3.5.0
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y xz-utils && \
    curl -fsSL "https://github.com/f3d-app/f3d/releases/download/v${F3D_VERSION}/F3D-${F3D_VERSION}-Linux-x86_64.tar.xz" \
      -o /tmp/f3d.tar.xz && \
    mkdir -p /opt/f3d && \
    tar -xJf /tmp/f3d.tar.xz -C /opt/f3d --strip-components=1 && \
    rm /tmp/f3d.tar.xz && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives


# Final stage for app image
FROM base

# F3D's runtime libraries — must precede the USER switch below, since apt needs root. These are the
# only packages in this image that exist for ONE renderer; every other one is a static binary, which
# is why they are listed here rather than folded into `base`.
#
# The list is DERIVED, not guessed: `readelf -d` across the f3d binary and every bundled .so shows
# libX11 as the only external NEEDED beyond glibc/libstdc++/libcrypto (all already in base). The
# rest is the GL stack, which VTK dlopens — invisible to ldd, so it was settled by running a real
# render. F3D renders OFFSCREEN (Maker::Previews::Mesh always passes --output): no X server, no GPU,
# so Mesa's software EGL is what actually draws.
#   libegl1        the vendor-neutral GLVND loader — DISPATCH ONLY, it draws nothing on its own
#   libegl-mesa0   the Mesa EGL driver the loader dlopens; WITHOUT IT EGL finds no device and the
#                  render fails, which is why libegl1 alone is not enough
#   libgl1-mesa-dri  the gallium/llvmpipe software rasterizer that does the actual drawing
# Verified sufficient by rendering both tetra.obj and a real 4.7 MB STEP file to PNG in this image.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      libx11-6 libegl1 libegl-mesa0 libgl1-mesa-dri && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# The STL thumbnailer binary on PATH → Maker::Previews::Stl#available? is true on the server,
# so STL uploads get a real thumbnail (no F3D/Mesa). root:root 0755 → runnable by the rails user.
COPY --from=stl-thumbnailer /build/target/release/stl-thumbnailer /usr/local/bin/stl-thumbnailer

# The resvg binary on PATH → Maker::Previews::SvgRasterizer#available? is true on the server,
# so SVG/DXF/LightBurn uploads get a PNG thumbnail.
COPY --from=resvg /out/bin/resvg /usr/local/bin/resvg

# The pdfium binary on PATH → Maker::Previews::Pdf#available? is true, so PDF uploads get a page-1
# PNG grid thumbnail. (The detail view embeds the whole PDF via the browser's own viewer — no tool.)
COPY --from=pdfium /tmp/pdfium /usr/local/bin/pdfium

# F3D → Maker::Previews::Mesh#available? is true, so .obj/.step/.stp/.iges/.igs get a thumbnail
# instead of falling through to `unsupported`.
#
# F3D_BIN RATHER THAN A PATH SYMLINK: the renderer already reads ENV["F3D_BIN"], and the final stage
# has switched to USER 1000:1000 by the time these COPYs run, so a `RUN ln -s` into /usr/local/bin
# would need root back. Pointing the existing knob at the tree is the smaller change and keeps F3D's
# own bin/../lib layout intact — the binary resolves its bundled libraries and its OCCT plugin
# relative to itself, so it must NOT be lifted out of the tree the way the static binaries above are.
COPY --from=f3d /opt/f3d /opt/f3d
ENV F3D_BIN="/opt/f3d/bin/f3d"

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
