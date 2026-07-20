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
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 && \
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

RUN bundle install && \
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
# (client/stl-thumbnailer, euc Apache/MIT). Built here and copied into the runtime image so the
# preview pipeline renders STL thumbnails server-side with zero graphics-stack dependencies.
# Independent of `base`, so it builds in parallel. (.dockerignore re-includes just this crate.)
FROM docker.io/library/rust:1-slim AS stl-thumbnailer
WORKDIR /build
COPY client/stl-thumbnailer ./
RUN cargo build --release && strip target/release/stl-thumbnailer


# ---- resvg: SVG→PNG rasterizer (Rust, MPL-2.0/Apache — permissive, CLAUDE.md §9). A single
# static binary, NO GPU/OpenGL/Mesa. Powers the SVG/DXF/LightBurn thumbnail path
# (Maker::Previews::SvgRasterizer). Built here, copied to PATH in the final stage. Independent of
# `base`, so it builds in parallel.
FROM docker.io/library/rust:1-slim AS resvg
RUN cargo install resvg --version 0.47.0 --root /out && strip /out/bin/resvg


# Final stage for app image
FROM base

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

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
