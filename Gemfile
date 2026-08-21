source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"

# THE SYNC ENGINE, from its own repository (chaim354/tinkerex-sync) since 2026-08-20. It lived at
# engines/tinkerex-sync/ as a `path:` source through Stage 3b -- deliberately, so that the eventual
# extraction was a filter-repo of ONE self-contained directory rather than a design problem. That
# is done, the directory is gone, and this repo no longer carries a copy of the engine.
#
# A PRIVATE git: SOURCE NEEDS CREDENTIALS WHEREVER `bundle install` RUNS. That cost was accepted
# here, not discovered: local shells and the self-hosted runner already resolve it through the
# operator's git credential helper, and the DOCKER BUILD -- which has neither a keychain nor a
# logged-in gh -- gets an explicit build secret instead (see the Dockerfile's own comment and
# config/deploy.yml's `builder.secrets`). A fresh clone on a machine with no GitHub credentials
# cannot `bundle install` this repo. That is the honest consequence of depending on a private
# repository, not a bug to be worked around.
#
# Gemfile.lock PINS THE EXACT REVISION, so `branch: "main"` is where updates come FROM, never what
# a build resolves to -- `bundle update tinkerex-sync` is the deliberate act that moves it, and a
# deploy in between builds the same commit every time.
#
# `require:` is spelled out because Bundler derives the require path from the HYPHENATED gem name
# ("tinkerex-sync"), while the entry point is lib/tinkerex_sync.rb -- the usual Ruby convention that
# a hyphen in a gem name means a `/` in the path, which is not the shape here.
# `require: false` -- config/application.rb loads it, and only when LIBRARY_BACKEND wants it.
# The gem stays here UNCONDITIONALLY: a conditional `gem` line would make Gemfile.lock depend on
# the environment that resolved it, and BUNDLE_DEPLOYMENT=1 refuses a lock that does not match.
gem "tinkerex-sync", git: "https://github.com/chaim354/tinkerex-sync.git", branch: "main",
                     require: false
gem "rails", "~> 8.1.1"
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
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

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

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 2.0"

# File-preview renderers (Maker::Previews::*, permissive only — CLAUDE.md §9):
#   rubyzip (BSD-2) — extract the embedded thumbnail from a 3MF (OPC/zip container).
#   nokogiri (MIT)  — parse LightBurn .lbrn2 XML → SVG. (Both are already transitive deps; pinned direct.)
# (Image thumbnails shell out to the `vipsthumbnail` binary — NOT the ruby-vips FFI gem — so no
#  in-process libvips thread pool to deadlock Rails' fork-based parallel test runner. See ImageThumb.)
gem "rubyzip", "~> 3.4", require: "zip"
gem "nokogiri", "~> 1.19"

# Presign chunk PUT/GET against S3-compatible storage (R2, SeaweedFS). Pure Ruby.
gem "aws-sdk-s3", require: false

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

# Lexxy — Basecamp's Action Text editor (MIT; CLAUDE.md §9 permissive-only). Used TEXT-ONLY:
# attachments are disabled because Lexxy's attachment path runs through Active Storage, a store
# separate from the file library, which §15 and the FileLayer port exist to avoid.
#
# PINNED EXACTLY, not `~>`. This gem shed its beta suffix in June 2026 and shipped six releases in
# the 24 days before this install — patch-level looseness is not safe to assume on a pre-1.0 line
# this fast-moving. Bump it deliberately: edit this line, run the suite, and re-do the manual
# editor check (Task 7), rather than letting a version ride in on someone's `bundle update`.
gem "lexxy", "0.9.27"
