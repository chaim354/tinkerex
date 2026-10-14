module Tinkerex
  # THE PUBLIC DEMO: one shared account a visitor signs into with one click, reset every night (H,
  # 2026-10-14; docs/superpowers/specs/2026-10-14-h-public-demo-design.md).
  #
  # ONE SETTING, AND NOTHING OF THE DEMO EXISTS WITHOUT IT. `DEMO_ACCOUNT_EMAIL` names the shared
  # account; blank (every destination but the public box) means no button, no banner, no cap, and
  # `POST /demo` answering 404. This module is the one place that reads it, so a door asks `demo?`
  # and never compares an address of its own.
  #
  # READ ON EVERY CALL, NEVER MEMOIZED, as Tinkerex::Registration is: a test flips ENV between
  # requests, and a memo would carry one test's demo into the next.
  #
  # BY ADDRESS, NOT BY ID. The nightly reset destroys the row and creates a new one with the same
  # address, so a remembered id would name yesterday's account, and comparing addresses costs a door
  # no query. Both sides are compared the way Devise stores the column (config/initializers/devise.rb
  # names :email in case_insensitive_keys and strip_whitespace_keys), or `Demo@Example.com` in a
  # deploy file would name no account at all.
  #
  # WHAT THE DEMO MAY NOT DO IS DECIDED AT EACH DOOR, not here: changing or deleting the account
  # (Users::RegistrationsController), a reset mail (Users::PasswordsController), publishing
  # (ProjectsController), a file over the cap (FilesController's two upload doors) and enrolling a
  # device (V1::DevicesController). This module says who the demo is and how large one file may be.
  module Demo
    Error = Class.new(StandardError)

    # Per file, on every upload door. docs/INSTALL.md documents the same 26214400.
    DEFAULT_MAX_UPLOAD_BYTES = 25 * 1024 * 1024

    # The configured address, downcased and stripped, or nil when demo mode is off.
    def self.email = normalize(ENV["DEMO_ACCOUNT_EMAIL"])

    def self.enabled? = !email.nil?

    # The User, or nil: demo mode off, or on before `bin/rails tinkerex:demo:setup` has created the
    # account (and for the instant inside a reset between its destroy and its create). Off, it asks
    # the database nothing.
    def self.account
      address = email
      address && User.find_by(email: address)
    end

    # WHETHER THE DOOR MAY OPEN: demo mode on, the account present, AND no other account sharing its
    # library. On share and s3 every account indexes the one library (§8), so a visitor signed into
    # the demo beside another account would be handed that account's files; the nightly reset refuses
    # the same condition (Tinkerex::DemoReset.refusal), and this is the same rule at the front door.
    # Behind a sync server (chunk_remote) every account has its own library and the count is 0. Costs
    # the sign-in page one COUNT; the button, the links and POST /demo all ask this and nothing else.
    def self.available?
       account = self.account
       !account.nil? && Tinkerex::DemoReset.accounts_sharing_library(except: account).zero?
    end

    def self.demo?(user) = !user.nil? && demo_email?(user.email)

    # For the doors that hold an address before they hold a user (a reset request).
    def self.demo_email?(address)
      configured = email
      !configured.nil? && normalize(address) == configured
    end

    # DEMO_MAX_UPLOAD_BYTES, or the 25 MB default. A WHOLE NUMBER OF BYTES OR NOTHING: `25MB` reads as
    # 25 BYTES through `to_i`, which would refuse every upload with a limit nobody set, so anything
    # but digits raises. validate! raises it at boot, before any visitor reaches an upload door.
    def self.max_upload_bytes
      raw = ENV["DEMO_MAX_UPLOAD_BYTES"].to_s.strip
      return DEFAULT_MAX_UPLOAD_BYTES if raw.empty?
      return raw.to_i if raw.match?(/\A[1-9]\d*\z/)

      raise Error, "DEMO_MAX_UPLOAD_BYTES=#{raw.inspect} is not a whole number of bytes. Set it to " \
                   "one (26214400 is 25 MB), or leave it unset for that default."
    end

    # The sentence an upload door answers with, or nil when the file may go on: any account but the
    # demo, or a file within the cap. One wording for every door, naming the file and the limit.
    def self.upload_refusal(user, name:, size:)
      return nil unless demo?(user)

      limit = max_upload_bytes
      return nil if size.to_i <= limit

      "#{name} is larger than #{ActiveSupport::NumberHelper.number_to_human_size(limit)}, " \
        "the most the shared demo takes in one file."
    end

    # Called at boot (config/initializers/demo.rb). Nil when the configuration is acceptable. Only
    # while demo mode is on: off, nothing reads the cap, so a stale value is no one's problem.
    def self.validate!
      max_upload_bytes if enabled?
      nil
    end

    def self.normalize(address) = address.to_s.strip.downcase.presence
    private_class_method :normalize
  end
end
