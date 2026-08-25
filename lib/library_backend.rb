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

  # `engine_wanted?` AND THE `SYNC_ENGINE` KNOB ARE BOTH GONE (Arc D Part 2). They existed because
  # exactly one backend -- embedded `chunk` -- needed the sync engine loaded in this process, and
  # the knob forced the OTHER legs to load it anyway so their run counts stayed identical and §15's
  # ambient-backend guard survived. With embedded chunk retired there is no backend that wants the
  # engine here: `chunk_remote` talks to a standalone sync server over HTTP, exactly as share and
  # s3 talk to their own storage. The gem is not a dependency of this app any more, so there is
  # nothing left for a predicate to answer.
end
