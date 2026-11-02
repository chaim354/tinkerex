# frozen_string_literal: true

require "active_support"
require "active_support/values/time_zone"

module Tinkerex
  # THE APP'S ONE ZONE (UX audit D1, 2026-11-02), and config/application.rb's `config.time_zone`.
  #
  # Until this, `config.time_zone` was the scaffold's unset UTC, so the page showed three clocks: a
  # Rails timestamp (a note, a build log entry, Trash) printed in UTC, a file's mtime printed in
  # whatever zone the PROCESS ran in (`Time.at` is process-local), and the History panel in the
  # browser's. ApplicationHelper#time_at now converts every one of them to this zone, so a note and
  # the file it is about, saved in the same minute, read the same minute.
  #
  # THREE ANSWERS, IN ORDER:
  #   TIME_ZONE set   -> that name, when ActiveSupport::TimeZone knows it. Otherwise REFUSED in
  #                      production, naming the variable and the value, and UTC with a warning
  #                      anywhere else. Rejected, never normalised, as LibraryBackendCheck treats
  #                      LIBRARY_BACKEND: `america/new_york` or a stray space is an operator's typo,
  #                      and guessing would leave every time on the page an hour or a day out
  #                      with nothing saying so.
  #   TIME_ZONE unset -> the host's zone: `TZ` when it names one, else the name `/etc/localtime`
  #                      links to (`.../zoneinfo/<name>`), else UTC. Inside the image both say UTC,
  #                      so a container installed by a stranger needs TIME_ZONE (or TZ) set to show
  #                      local times; docs/INSTALL.md says so.
  #   the test env    -> UTC ALWAYS, whatever TIME_ZONE or the host says. The suite's expected
  #                      strings must not depend on which machine runs it (the Mac is New York, the
  #                      CI runners are UTC); a test that is about a zone sets one around itself
  #                      with Time.use_zone. A bad TIME_ZONE still warns there.
  #
  # Blank counts as unset, the same rule as LIBRARY_BACKEND: an empty line in a .env names no zone.
  #
  # Called from config/application.rb's class body, before the initializers and before lib/ is on
  # the load path, which is why it is required by relative path there and names only ActiveSupport.
  module TimeZone
    # An ArgumentError, like LibraryBackendCheck::UnknownBackend: a value that names nothing is a
    # misconfigured deployment.
    Invalid = Class.new(ArgumentError)

    FALLBACK = "UTC"
    LOCALTIME = "/etc/localtime"

    def self.resolve(env: ENV, rails_env: Rails.env, localtime: LOCALTIME, log: ->(msg) { warn(msg) })
      named = configured(env:, production: rails_env.production?, log:)
      return FALLBACK if rails_env.test?

      named || detect(env:, localtime:)
    end

    # The zone TIME_ZONE names: nil when it is unset or blank, the name itself when it is a zone,
    # and otherwise the refusal (production) or UTC with a warning (anywhere else).
    def self.configured(env:, production:, log:)
      raw = env["TIME_ZONE"]
      return nil if raw.to_s.strip.empty?
      return raw if zone?(raw)

      message = "TIME_ZONE #{raw.inspect} is not a time zone: expected an IANA name, spelled exactly, " \
                "such as America/New_York or Europe/Berlin"
      raise Invalid, message if production

      log.call("#{message}. Showing times in #{FALLBACK}.")
      FALLBACK
    end

    # The host's zone, or UTC. `TZ` first, because a container that sets it means it; then the
    # /etc/localtime symlink, which is how Debian, macOS and most Linux hosts record the zone (a
    # COPIED file, as Alpine leaves it, carries no name and answers UTC).
    def self.detect(env:, localtime:)
      [ env["TZ"], zoneinfo_name(localtime) ].find { |name| zone?(name) } || FALLBACK
    end

    def self.zoneinfo_name(path)
      return nil unless File.symlink?(path)

      File.readlink(path)[%r{zoneinfo/(.+)\z}, 1]
    rescue SystemCallError
      nil
    end

    def self.zone?(name)
      name.is_a?(String) && !name.empty? && !::ActiveSupport::TimeZone[name].nil?
    end

    private_class_method :configured, :detect, :zoneinfo_name
  end
end
