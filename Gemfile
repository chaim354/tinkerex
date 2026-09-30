source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"

# THE SYNC ENGINE IS NO LONGER A DEPENDENCY OF THIS APP (Arc D Part 2). chaim354/tinkerex-sync
# arrived here as a private git: gem for as long as one deployment -- embedded `chunk` -- ran the
# engine in this Rails process. That backend is retired: the chunk-family deployment is now
# `chunk_remote`, which talks to a STANDALONE sync server over HTTP exactly as share and s3 talk
# to their own storage, so there is nothing left to load in-process.
#
# WHAT THIS ALSO REMOVES, deliberately and worth knowing before adding it back: the Docker build's
# read-only deploy key and its https->SSH rewrite (§14j), the engine_schema generator and its
# byte-identical cross-repo guard, and every /v1 sync endpoint this app used to serve. A desktop
# client syncs against the sync server now, never against the maker app.
gem "rails", "~> 8.1.4"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use sqlite3 as the database for Active Record (self-host default)
gem "sqlite3", ">= 2.1"
# PostgreSQL adapter for the managed/SaaS deployment. Both adapters ship; the active
# one is selected by config/database.yml / DATABASE_URL (see docs/SYNC_SERVER.md).
gem "pg", "~> 1.5"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# Powers the real web auth (User#password digest + Session model). bcrypt is MIT (CLAUDE.md §9).
gem "bcrypt", "~> 3.1.7"

# Human-identity authentication (web login + device-login enrollment). Devise is MIT
# (CLAUDE.md §9). It governs ONLY the human layer; the v1 device-token machinery is
# untouched. OmniAuth keeps the OAuth/OIDC seam open (also MIT).
gem "devise", ">= 5.0.4", "< 6"
gem "omniauth", "~> 2.1"
gem "omniauth-rails_csrf_protection", "~> 2.0"
gem "omniauth_openid_connect", "~> 0.8", require: false

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# File-preview renderers (Maker::Previews::*, permissive only — CLAUDE.md §9):
#   rubyzip (BSD-2) — extract the embedded thumbnail from a 3MF (OPC/zip container).
#   nokogiri (MIT)  — parse LightBurn .lbrn2 XML → SVG. (Both are already transitive deps; pinned direct.)
# (Image thumbnails shell out to the `vipsthumbnail` binary — NOT the ruby-vips FFI gem — so no
#  in-process libvips thread pool to deadlock Rails' fork-based parallel test runner. See ImageThumb.)
gem "rubyzip", "~> 3.4", require: "zip"
gem "nokogiri", "~> 1.19"

# Presign chunk PUT/GET against S3-compatible storage (R2, SeaweedFS). Pure Ruby.
gem "aws-sdk-s3", require: false

# libgit2 bindings, for editing and committing in a repository the maker brought
# (Maker::Git::LocalRepo).
#
# LICENCE NOTE, because §9 says avoid GPL and a future reader will otherwise flag this as a
# violation: libgit2 is GPL-2.0 WITH A LINKING EXCEPTION, written expressly to permit linking from
# a program under any licence. That is what makes it usable here where the `git` CLI is not --
# shipping the binary would put a GPL executable in our image, which is why this repo's answer to
# GPL everywhere else is an HTTP sidecar (§14c).
#
# IT DOES NOT COVER PACKING. Rugged::Repository exposes 69 instance methods and not one matches
# pack/repack/gc/prune; Packbuilder, Indexer and Odb are undefined. Measured against the built gem,
# not read off its README. Nothing here packs -- see docs/roads-not-taken.md §9 for why that
# matters only if git on s3 is ever revived.
gem "rugged"

# Ruby's own stdlib CSV writer, used by Maker::Sheet#to_csv. As of Ruby 3.4 this is a "bundled gem"
# rather than a default gem, so it still ships with Ruby but Bundler no longer activates it for
# free — `require "csv"` raises LoadError under Bundler.setup without this line even though the
# gem is present on disk. BSD (Ruby license), permissive per CLAUDE.md §9.
gem "csv"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
end

gem "kramdown", "~> 2.5"

# GFM input for kramdown (MIT; CLAUDE.md §9 permissive-only) — fenced code blocks, tables,
# strikethrough. kramdown's own `input: "GFM"` raises Kramdown::Error without this parser
# (probed: "kramdown has no parser to handle the specified input format: GFM"). Used only by
# Maker::Markdown (stage 3, S3-2 — README rendering); NotesHelper#render_note stays on
# kramdown's default input and needs no change.
gem "kramdown-parser-gfm", "~> 1.1"

# Lexxy — Basecamp's Action Text editor (MIT; CLAUDE.md §9 permissive-only). Used TEXT-ONLY:
# attachments are disabled because Lexxy's attachment path runs through Active Storage, a store
# separate from the file library, which §15 and the FileLayer port exist to avoid.
#
# PINNED EXACTLY, not `~>`. This gem shed its beta suffix in June 2026 and shipped six releases in
# the 24 days before this install — patch-level looseness is not safe to assume on a pre-1.0 line
# this fast-moving. Bump it deliberately: edit this line, run the suite, and re-do the manual
# editor check (Task 7), rather than letting a version ride in on someone's `bundle update`.
gem "lexxy", "0.9.31"
