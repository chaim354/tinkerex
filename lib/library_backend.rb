# frozen_string_literal: true

# WHICH BACKEND THIS DEPLOYMENT RUNS, asked early enough to decide whether to load the sync engine
# at all. `FileLayer.build` answers the same question later, from the same variable -- but it lives
# in app/, which is not autoloadable while config/application.rb is still executing, and by the time
# it is, `Rails::Engine` subclasses have long since had to register themselves.
#
# NOT AUTOLOADED, DELIBERATELY: this file is in config.autoload_lib's `ignore:` list and is required
# explicitly by config/application.rb. Leaving it autoloadable while also requiring it by hand is
# how Zeitwerk and a manual require end up owning the same constant.
#
# THE HOST NEEDS ITS OWN COPY OF THIS QUESTION, and that is not duplication for its own sake: the
# gem ships `Sync.engine_present?` with an identical body, which is useless in exactly the case that
# matters -- when the gem is not loaded, the constant that would answer does not exist. The gem's
# copy stays for a bare mount, where this file is what is absent instead. Two files, one question,
# neither able to assume the other is there.
module LibraryBackend
  DEFAULT = "chunk"

  # `env:` as a kwarg default rather than a captured constant, matching the gem's own predicate:
  # ENV is re-read on every call, so a value injected by one test cannot leak into the next.
  def self.name(env: ENV) = env.fetch("LIBRARY_BACKEND", DEFAULT)

  # THE ONLY BACKEND THAT NEEDS THE ENGINE IN-PROCESS. share and s3 answer their own reads and
  # writes through their own adapters and never enter Sync::. Stage 4's `chunk_remote` will answer
  # FALSE here too -- it talks to a sync server over HTTP, so it wants the engine no more than share
  # does. That is the whole reason this predicate is a named question rather than `== "chunk"`
  # written out at each call site.
  #
  # SYNC_ENGINE OVERRIDES THE DERIVATION, AND IT EXISTS SO THAT BOTH PATHS ARE EXECUTED RATHER THAN
  # ONE ARGUED. The three backend test legs set SYNC_ENGINE=1: they keep the engine loaded even on
  # share/s3, so all three report IDENTICAL run and assertion counts and §15's guard against a test
  # depending on the ambient LIBRARY_BACKEND survives untouched. The fourth leg sets SYNC_ENGINE=0
  # against share and runs the boot-smoke suite, which is the only place the engine is genuinely
  # absent. Neither leg alone would do: without the override the counts diverge and the guard is
  # retired to accommodate one expected case; without the fourth leg the no-engine path is executed
  # by nothing, which is CLAUDE.md §14a's recorded bug verbatim (a boot guard that passed the whole
  # suite and took production down).
  #
  # An empty value is treated as UNSET, not as false -- kamal's env.clear blanks rather than
  # removes (§14c), so a deployment that has "cleared" this must fall back to the derivation.
  def self.engine_wanted?(env: ENV)
    forced = env["SYNC_ENGINE"]
    return %w[1 true yes].include?(forced.to_s.downcase) unless forced.nil? || forced.empty?

    name(env: env) == "chunk"
  end
end
