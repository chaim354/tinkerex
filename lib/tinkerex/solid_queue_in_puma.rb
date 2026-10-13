module Tinkerex
  # Whether Puma runs the Solid Queue supervisor in-process (config/puma.rb). On by default in
  # production — a single-container deployment did no background work at all until 2026-10-13
  # unless the operator knew the variable — with false/0/no as the off-switch for a split
  # bin/jobs container. No Rails constants: Puma evaluates its config before the app boots.
  module SolidQueueInPuma
    OFF = %w[false 0 no].freeze

    def self.enabled?(env = ENV, production: env["RAILS_ENV"] == "production")
      value = env["SOLID_QUEUE_IN_PUMA"].to_s.strip
      return production if value.empty?

      !OFF.include?(value.downcase)
    end
  end
end
