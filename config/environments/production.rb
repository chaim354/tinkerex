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

  # TLS is terminated by an upstream reverse proxy (kamal-proxy serving the Cloudflare Origin
  # cert) ONLY on the public OVH deployment, which sets FORCE_SSL=true. The LAN test boxes
  # (chunk/s3/share on the Unraid box) run plain HTTP and set neither var, so this is a no-op
  # there. Do NOT hardcode these on — an unconditional force_ssl breaks the HTTP-only boxes.
  if ENV["FORCE_SSL"] == "true"
    config.assume_ssl = true
    config.force_ssl  = true
    # kamal-proxy health-checks /up over plain HTTP against the container by IP; an unexcluded
    # force_ssl 301 would fail that check and roll the deploy back.
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

  # Replace the default in-process memory cache store with a durable alternative.
  # config.cache_store = :mem_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  # config.active_job.queue_adapter = :resque

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates (confirmation/reset). The public
  # OVH deploy sets APP_DOMAIN; the LAN boxes keep the harmless default.
  config.action_mailer.default_url_options = {
    host: ENV["APP_DOMAIN"] || "example.com",
    protocol: ENV["FORCE_SSL"] == "true" ? "https" : "http"
  }

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

  # DNS-rebinding / Host-header protection. Enabled ONLY where APP_DOMAIN is set (the public OVH
  # deploy). The LAN boxes leave config.hosts empty (all hosts allowed) so IP + *.local access
  # keeps working — matching the current HTTP/no-TLS posture.
  if ENV["APP_DOMAIN"].present?
    config.hosts << ENV["APP_DOMAIN"]           # exact apex, e.g. tinkerex.com
    config.hosts << ".#{ENV['APP_DOMAIN']}"     # leading dot: apex + all subdomains (www, …)
    # The proxy healthcheck's Host is the container IP, which won't match APP_DOMAIN and would
    # 403 without this exclusion.
    config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
  end
end
