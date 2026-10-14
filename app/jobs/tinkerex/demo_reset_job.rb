module Tinkerex
  # The public demo's nightly reset, scheduled from config/recurring.yml (04:00 UTC). A NO-OP UNLESS
  # DEMO_ACCOUNT_EMAIL IS SET — every deployment but the demo's runs this entry and must find nothing
  # to do — and unless that address names an account, which `bin/rails tinkerex:demo:setup` creates.
  # The reset itself is Tinkerex::DemoReset's.
  #
  # IT RESOLVES THE ACCOUNT ITSELF, from the one setting, rather than through Tinkerex::Demo: the two
  # were written in parallel and the reset must not wait on the module that decides demo mode. The
  # address is normalised by User's own `normalizes :email`, which `find_by` applies to its argument.
  #
  # A REFUSAL IS LOGGED AND THE JOB RETURNS. Every refusal is a configuration the next run would meet
  # unchanged — a library other accounts share, a backend with no byte write, a missing seed — and
  # each one has changed nothing, so a retry buys nothing and a failed execution would repeat the
  # same sentence nightly. The sentence names the fix. Anything else (a store that will not answer)
  # propagates and fails the job, which is how Solid Queue reports it.
  class DemoResetJob < ApplicationJob
    queue_as :background

    def perform
      email = ENV["DEMO_ACCOUNT_EMAIL"].presence
      return unless email

      user = User.find_by(email:)
      unless user
        Rails.logger.warn("Tinkerex::DemoResetJob: DEMO_ACCOUNT_EMAIL is #{email.strip}, which names " \
                          "no account; run bin/rails tinkerex:demo:setup to create it")
        return
      end

      Tinkerex::DemoReset.new(user:).call
    rescue Tinkerex::DemoReset::Refused => e
      Rails.logger.error("Tinkerex::DemoResetJob: the reset refused and changed nothing: #{e.message}")
    end
  end
end
