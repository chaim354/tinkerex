# HOST-SIDE WIRING for the sync engine's capability-gate seam (Stage 3b Task 9; Sync module
# methods at the tinkerex-sync gem's lib/tinkerex_sync/sync_module.rb; the gate itself at its
# app/controllers/concerns/sync/v1/capability_gate.rb). CLAUDE.md §14j used
# to record two host constants the engine referenced directly — `::LibraryCapabilities` and
# `::FileLayer.current.capabilities.versioned?` — which stopped a bare mount from loading at all.
# This file is what replaces those direct references: the engine asks `Sync.capability_available?`
# and `Sync.capability_unavailable_message`, and THIS is where the host answers.
#
# A DEPLOYMENT THAT MOUNTS THE ENGINE WITH NO MAKER LAYER AT ALL (goal 1 of the four-stage
# separation) SIMPLY NEVER LOADS THIS INITIALIZER, and `Sync.capability_check`/`capability_message`
# stay at their standalone defaults — "available, always" (see sync_module.rb's own comment for
# why that is the correct answer for a bare sync server, not a placeholder). Nothing about the
# engine's request path requires this file to exist, the same property `sync_hooks.rb` states for
# itself.
#
# THE SAME TWO QUESTIONS, THE SAME ANSWERS, AS `LibraryCapabilities` GAVE DIRECTLY — this file's
# whole job is to be behaviourally invisible from outside the process.
# `test/integration/v1/capability_gating_test.rb` asserts the wire-level 501 bodies these
# lambdas ultimately produce and is unchanged by this refactor; if it goes red, the wiring below
# is why.
#
# WRAPPED IN `after_initialize`, NOT ASSIGNED AT THIS FILE'S TOP LEVEL — the identical reason
# `sync_hooks.rb` and `postgres_pooler_check.rb` both give: app/ constants (here, `FileLayer` and
# `LibraryCapabilities`, and `Sync` itself) are not reliably autoloadable while
# `config/initializers/*.rb` are still running, so a bare top-level assignment risks
# `NameError: uninitialized constant` depending on load order. The two lambdas below only
# REFERENCE those constants inside their own bodies — nothing forces them to resolve until the
# lambda is actually CALLED, which cannot happen before a real request arrives, long after
# `Rails.application.initialize!` has returned — but the ASSIGNMENT statement itself
# (`Sync.capability_check = ...`) still needs the bare `Sync` constant resolvable to run at all,
# and that is what `after_initialize` guarantees.
Rails.application.config.after_initialize do
  # Same call `Sync::V1::CapabilityGate`'s own predecessor made per-request: `FileLayer.current` is a
  # lazily-built singleton (`app/services/file_layer.rb`), so re-reading it on every call, rather
  # than capturing today's adapter in the closure, is what makes `FileLayer.reset!` (every test
  # that switches backends mid-run) work exactly as it always did.
  Sync.capability_check = ->(capability) {
    FileLayer.current.capabilities.public_send(:"#{capability}?")
  }

  # Byte-identical wording to what direct `include ::LibraryCapabilities` produced — same frozen
  # Hash, same `#fetch` (raises `KeyError` for a capability name neither this nor the gate itself
  # recognizes, exactly as `LibraryCapabilities#require_capability!`'s own eager
  # `CAPABILITY_ABSENT.fetch(capability)` already did before this refactor).
  Sync.capability_message = ->(capability) {
    LibraryCapabilities::CAPABILITY_ABSENT.fetch(capability)
  }
end
