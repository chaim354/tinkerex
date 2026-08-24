# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Rate limiting counts in config.action_controller.cache_store, which DEFAULTS to
  # config.cache_store — and NullStore#increment returns nil, which makes ActionController's
  # `if count && count > to` silently never fire. A throttle test would then fail for the wrong
  # reason and, worse, a "normal requests still work" test would pass whether or not the throttle
  # exists at all. Give rate limiting a real store; leave general caching off, so no test can
  # read a stale value.
  #
  # Counters are keyed by request.remote_ip, which is 127.0.0.1 for every integration test, so a
  # test touching a throttled endpoint must call `ActionController::Base.cache_store.clear` in
  # setup or it inherits the previous test's count.
  config.action_controller.cache_store = :memory_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # Encrypt fixture values for any column an `encrypts` model declares, before they're inserted
  # -- config/initializers/active_record_encryption.rb#support_unencrypted_data is FALSE, so a
  # fixture-loaded plaintext value under an encrypted column would come back from the model as
  # ActiveRecord::Encryption::Errors::Decryption on first read, not as the plaintext the YAML
  # said. This app has no `encrypts` attribute yet (Task 4 adds the first one, a per-user
  # sync-server device token on `users`) and no `users.yml` fixture either -- every test creates
  # users with `User.create!`, which runs the real encrypted setter, so today this flag changes
  # nothing observable: `ActiveRecord::Fixture.prepend ActiveRecord::Encryption::EncryptedFixtures`
  # (activerecord's railtie.rb) touches a fixture row only via `model_class.encrypted_attributes`,
  # which is empty for every model right now. Set anyway, now, rather than left for Task 4 to
  # discover the hard way if it ever adds a fixture file that populates an encrypted column.
  config.active_record.encryption.encrypt_fixtures = true
end
