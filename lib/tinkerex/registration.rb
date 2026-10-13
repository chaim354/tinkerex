module Tinkerex
  # Whether strangers may create accounts, and who the first account is.
  #
  # CLOSED BY DEFAULT IN PRODUCTION. On `share` and `s3` every account indexes the SAME library
  # (Library::ScanJob.scan_all! walks one root for every user; FileLayer::Share/S3 carry no user
  # segment), so an open sign-up hands a stranger read, write and delete on the owner's files —
  # `open` is REFUSED there at boot. `open` is for chunk_remote (per-user remote libraries, §8)
  # and the managed service.
  #
  # THE FIRST ACCOUNT IS THE OWNER. With no user in the database the sign-up page is allowed once,
  # and the account it creates is confirmed on the spot: a self-hoster has no mail server on day
  # one, and the alternative — a console incantation before the first page works — is the thing
  # a stranger never finds. After that the page closes (403) unless REGISTRATION=open.
  #
  # TWO DOORS THIS DOES NOT GOVERN, ON PURPOSE. `User.from_omniauth` mints a confirmed account for
  # any identity the provider vouches for whatever the mode: enabling OMNIAUTH_ENABLED is the
  # opt-in, and the provider decides who may sign in (docs/DEPLOY.md "Accounts"). And
  # `first_owner?` is a plain `User.exists?` with no database-level claim, so two sign-ups
  # interleaving inside one request's window on an EMPTY server would both become owners — a
  # millisecond window on a box nobody else knows exists yet; recorded, not guarded.
  module Registration
    Error = Class.new(StandardError)
    MODES = %w[open closed].freeze
    SINGLE_LIBRARY_BACKENDS = %w[share s3].freeze

    def self.mode(env = ENV, production: Rails.env.production?)
      env["REGISTRATION"].presence || (production ? "closed" : "open")
    end

    # Raises for an unknown mode, and for an EXPLICIT `open` on a backend where every account is
    # one library. Returns nil when the configuration is acceptable. Called at boot
    # (config/initializers/registration.rb) and unit-tested directly; reads only ENV so it needs
    # no app constant.
    #
    # THE REFUSAL KEYS ON THE OPERATOR'S VALUE, NOT ON THE RESOLVED MODE. Outside production the
    # default is `open` (the suite drives the open flow on the share leg), and bin/ci's share and
    # s3 legs boot DEVELOPMENT first (`db:test:prepare`, config/ci.rb) with LIBRARY_BACKEND
    # exported — as does the dev server. Keyed on `mode`, this refuses every one of those boots
    # (measured 2026-10-13: `LIBRARY_BACKEND=share bin/rails runner` in development raised this
    # Error out of config/initializers/registration.rb's after_initialize and never ran); keyed
    # on ENV it refuses exactly the thing the rule names. Production's default is closed, so an
    # unset value never reaches this branch there. Pinned in test/lib/registration_test.rb.
    def self.validate!(env = ENV, production: Rails.env.production?)
      m = mode(env, production:)
      raise Error, "REGISTRATION=#{m.inspect} is not one of #{MODES.join('/')}" unless MODES.include?(m)

      backend = env["LIBRARY_BACKEND"].to_s
      if env["REGISTRATION"] == "open" && SINGLE_LIBRARY_BACKENDS.include?(backend)
        raise Error, "REGISTRATION=open is refused on LIBRARY_BACKEND=#{backend}: every account " \
                     "indexes the same library there, so an open sign-up hands a stranger the " \
                     "owner's files. Leave it closed (the first account is the owner; " \
                     "bin/rails tinkerex:owner adds more) or deploy chunk_remote."
      end
      nil
    end

    def self.open?(env: ENV, users_exist: User.exists?)
      mode(env) == "open" || !users_exist
    end

    def self.first_owner?(users_exist: User.exists?) = !users_exist

    # What the sign-up page should tell the visitor.
    def self.state(mode: self.mode, users_exist: User.exists?, mail_configured: MailSettings.deliverable?)
      return :first_owner unless users_exist
      return :closed if mode == "closed"

      mail_configured ? :open : :open_no_mail
    end
  end
end
