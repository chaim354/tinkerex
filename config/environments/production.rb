require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # HTTPS, opt-in per deployment via FORCE_SSL.
  #
  # WHY GATED AND NOT SIMPLY ON: this app runs in two shapes. The internet-facing host serves
  # HTTPS behind a terminating proxy and wants all three effects — assume_ssl so Rails believes
  # the proxy's X-Forwarded-Proto, force_ssl for the http->https redirect and HSTS, and (the one
  # that matters most) the SECURE FLAG ON THE SESSION COOKIE, which is what force_ssl actually
  # sets. The Unraid backends are reached by IP over plain HTTP on the LAN, and an unconditional
  # force_ssl would redirect them somewhere nothing listens — all three down, from a change made
  # to improve security. That is almost certainly why these lines sat commented rather than set.
  #
  # SET FORCE_SSL=1 ON ANY HOST REACHABLE FROM THE INTERNET. Without it the session cookie is
  # sent on plain-HTTP requests to the same host. See docs/DEPLOY.md.
  if ENV["FORCE_SSL"].present?
    config.assume_ssl = true
    config.force_ssl  = true
    # kamal-proxy health-checks over plain HTTP inside the container network; redirecting /up to
    # https would fail the check and roll the deploy back.
    config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }
  end

  # Hand share-backed downloads off to a front proxy instead of streaming them through Puma.
  # COMMENTED BECAUSE THIS DEPLOYMENT IS kamal-proxy, NOT nginx OR Apache — and that is the
  # whole reason it stays commented rather than a note about taste. Rack::Sendfile is in the
  # stack; when this is set it replaces the response body with [] and Content-Length with 0,
  # trusting the proxy to serve the file from the path in the header. kamal-proxy does not
  # implement x-sendfile, so enabling this here would silently serve EMPTY BODIES for every
  # share-mode download. Only set it if you have actually put such a proxy in front.
  #
  # Applies to LIBRARY_BACKEND=share only: it is the one backend with a filesystem path to hand
  # over (chunk and s3 redirect to presigned URLs — bytes never reach Rails at all, CLAUDE.md
  # §15). Rack acts only on a body that responds to to_path, which is why FilesController#blob
  # uses send_file and not send_data.
  #
  #   Apache (mod_xsendfile), or nginx with XSendFile-style handling:
  #     config.action_dispatch.x_sendfile_header = "x-sendfile"
  #
  #   nginx: x-accel-redirect ALSO needs a mapping, and without one Rack logs
  #   "x-accel-mapping header missing" and serves the bytes normally — it fails safe, but
  #   silently, so a misconfiguration looks like it works and merely never accelerates:
  #     config.action_dispatch.x_sendfile_header = "x-accel-redirect"
  #   plus, in nginx, an `internal` location over the library root and:
  #     proxy_set_header x-accel-mapping /mnt/nas/=/files/;
  #
  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # The cable connection is authenticated by a per-device token in the query string
  # (ApplicationCable::Connection), not cookies, so browser-CSRF origin checks don't
  # apply — and native clients (the sync daemon) send no Origin. The device token is
  # the auth; a malicious site can't read it, so there's nothing to forge.
  config.action_cable.disable_request_forgery_protection = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Background jobs run on Solid Queue, backed by its own SQLite database (the `queue`
  # entry in database.yml). Without this, Solid Queue connects to the primary DB — which
  # has no `solid_queue_*` tables — and the in-Puma supervisor (SOLID_QUEUE_IN_PUMA)
  # crashes the process on boot.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Solid Cache, backed by its own database (the `cache` entry in database.yml, schema in
  # db/cache_schema.rb, tuning in config/cache.yml). Without this line Rails falls back to a
  # FileStore in the container's tmp/ — wiped by every Kamal deploy and invisible to a second
  # container. Solid Queue (above) and Solid Cable (config/cable.yml) were both wired; this was
  # the third of the three that got missed, while CLAUDE.md §4 claimed all three.
  #
  # RATE LIMITING COUNTS IN THIS STORE (see the Users:: controllers), so it needs to be durable
  # and shared rather than per-container and wiped on deploy.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  # config.active_job.queue_adapter = :resque

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

  # Phase A (addons-runtime-bundle-design spec): addon bundles ship inside THIS image at
  # public/addons (committed to the repo), so production reads them off disk like dev does.
  # Neither ADDON_SOURCE_PATH nor ADDON_SOURCE_URL is set by deploy.yml today — without this
  # default, Maker::Addons::Source.current falls through to the HTTP branch and
  # ENV.fetch("ADDON_SOURCE_URL") raises KeyError, which Registry#manifests rescues to [],
  # silently emptying the /tools gallery (Generators included) on every deployed backend.
  #
  # NOT unconditional: Source gives ADDON_SOURCE_PATH precedence over ADDON_SOURCE_URL, so
  # defaulting PATH regardless would make Phase B's cutover to the addons repo's separate static
  # container silently inert — ADDON_SOURCE_URL would be set and ignored while this still reads a
  # public/addons directory Phase B deletes. Yielding to an explicit URL is what makes that
  # cutover a config change instead of a redeploy-and-debug.
  ENV["ADDON_SOURCE_PATH"] ||= Rails.public_path.join("addons").to_s if ENV["ADDON_SOURCE_URL"].blank?
end
