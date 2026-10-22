# frozen_string_literal: true

require "ipaddr"

module Tinkerex
  # THE NUMBERS BOTH HUMAN-CREDENTIAL DOORS THROTTLE BY: the web sign-in (Users::SessionsController)
  # and the desktop app's device login (V1::DevicesController#login). One definition, so the two doors
  # cannot drift apart; each controller passes them to Rails' own `rate_limit`.
  #
  # THIS REPLACES DEVISE :lockable's LOCK, WHICH WAS A WEAPON (pentest M4b, tinkerex#466). Lockable
  # counted failures per ACCOUNT from every source and never forgot them until a success, so anyone
  # who knew an address could lock its owner out of both doors for an hour, from one IP, and do it
  # again every hour. The per-source limit that sat beside it did not prevent that, whatever its
  # comment said: ten attempts fit inside one three-minute window. `config.lock_strategy` is now
  # `:none` (config/initializers/devise.rb). Two windowed counters, neither of which ever touches
  # the owner signing in from somewhere else:
  #
  #   PER_SOURCE   one source, any accounts: bounds spraying a password across many addresses.
  #   PER_ACCOUNT  one source, one account: bounds guessing at a single account from one source
  #                as tightly as lockable did (ten an hour), and blocks only that source.
  #
  # THERE IS DELIBERATELY NO LIMIT PER ACCOUNT ACROSS ALL SOURCES. Any such counter can be filled by
  # the same attacker, and then it locks the owner out. That is the finding again, only spread over
  # more machines. A distributed guesser is bounded by the 10-character password floor and bcrypt
  # cost 12 instead (config/initializers/devise.rb). The decision is recorded in
  # docs/superpowers/plans/2026-10-22-device-token-lifecycle.md.
  #
  # Both counters gate the ACTION, not just failures. A correct password on the eleventh attempt is
  # refused too, or the limit would only throttle wrong guesses and tell a guesser which one was right.
  module SignInThrottle
    PER_SOURCE  = { to: 10, within: 3.minutes }.freeze
    PER_ACCOUNT = { to: 10, within: 1.hour }.freeze

    # A SOURCE IS AN IPv4 ADDRESS OR AN IPv6 /64. One host is routinely handed a whole /64, so
    # counting per IPv6 address would give one machine 2^64 budgets and bound nothing. An
    # IPv4-mapped IPv6 address counts as the IPv4 address it carries. Anything unparsable is used
    # verbatim, never dropped: a source that cannot be parsed must still have a budget of its own.
    def self.source(ip)
      addr = IPAddr.new(ip.to_s)
      addr = addr.native if addr.ipv4_mapped?
      addr.ipv6? ? "#{addr.mask(64)}/64" : addr.to_s
    rescue IPAddr::Error
      ip.to_s
    end

    # The PER_ACCOUNT key. The address is normalised as User normalises it, so `Owner@x.com ` and
    # `owner@x.com` share one budget. It is DIGESTED, because the cache store keeps keys in its
    # table and this one does not need to hold email addresses. An address with no account gets a
    # budget exactly like one that has an account, so the limit cannot be used to tell them apart.
    def self.account_key(email, ip)
      "#{Digest::SHA256.hexdigest(email.to_s.strip.downcase)}:#{source(ip)}"
    end
  end
end
