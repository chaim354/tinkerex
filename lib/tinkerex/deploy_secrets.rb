require "pathname"

module Tinkerex
  # WHERE KAMAL RESOLVES A SECRET, AND WHICH DESTINATIONS THERE ARE — the one definition, kept for the
  # one failure §14g exists to prevent (docs/invariants/deploy-secrets.md): kamal expands `$(…)` in
  # .kamal/secrets* through Ruby backticks, which discard exit status, so a locked vault deploys an
  # EMPTY credential without raising. bin/secrets-preflight resolves every name this walk collects
  # through the real Kamal::Secrets and refuses an empty one — so a name the walk never collects is a
  # credential that deploys UNCHECKED, and "Safe to deploy." is printed over it.
  #
  # TWO READERS, ONE ANSWER: bin/secrets-preflight (`require_relative`, before every deploy) and
  # test/deploy_hygiene_test.rb (bin/ci, static and vault-free), with test/lib/deploy_secrets_test.rb
  # driving both on fixtures. Until 2026-10-19 (F-S25-1) each held its own copy of this walk and of
  # the destination list, each saying "widen both together", and the copy that gated a deploy was the
  # one no test ran: with its accessory arm deleted every test still passed, while the preflight would
  # have stopped checking SECRET_KEY_BASE on every destination. NEVER COPY THE WALK BACK INTO A
  # READER. Widen it here, and widen the oracle in deploy_hygiene_test.rb ("the shared walk covers
  # every site …"), which plants a name at every arm, in the same commit.
  #
  # READS CONFIG ONLY — no secret is resolved here. Verified by fencing Dotenv.parse and
  # Kamal::Secrets#[]/#key?/#to_h to raise and building all four destinations: the fence never trips
  # (re-run over both test files in-process on 2026-10-19), which is what keeps
  # deploy_hygiene_test.rb STATIC and runnable on a runner with no 1Password.
  #
  # PLAIN RUBY, AND CHECKOUT-ONLY. The preflight loads this file without Rails, and nothing in the
  # web process calls it. Zeitwerk still eager-loads lib/tinkerex in production and under CI's test
  # env, which is why this file defines exactly Tinkerex::DeploySecrets and requires kamal only inside
  # `required`: kamal is `require: false` in the Gemfile and must never load in the web process.
  module DeploySecrets
    # Every destination kamal can deploy. nil is the base (`kamal deploy`, no -d): config/deploy.yml
    # alone, the chunk_remote deployment on Unraid. `remote` WAS A FIFTH ENTRY and is gone: Arc D
    # Part 2 folded that destination into the base, which now carries LIBRARY_BACKEND=chunk_remote
    # itself. test/lib/deploy_secrets_test.rb holds this equal to the config/deploy.<name>.yml files
    # present.
    DESTINATIONS = [ nil, "s3", "share", "ovh" ].freeze

    def self.label(destination) = destination || "base"

    # Every secret name kamal will resolve for `destination`, read off the MERGED config — so the
    # answer cannot drift from what kamal will look up. env.secret is an ARRAY that kamal REPLACES
    # wholesale on merge (deep_merge unions hashes but replaces arrays), which is why each overlay
    # re-declares RAILS_MASTER_KEY; reading the merged config reflects that replacement rather than a
    # union we invented.
    def self.required(destination, config_file:)
      require "kamal"
      config = Kamal::Configuration.create_from(config_file: Pathname(config_file), destination: destination)
      keys = names(config.raw_config)
      raise "no secret keys resolved for #{label(destination)} — raw_config shape changed?" if keys.empty?

      keys
    end

    # STRING keys throughout, and that is not interchangeable with symbols: raw_config is an
    # ActiveSupport::InheritableOptions whose `dig(:env, :secret)` returns nil while
    # `dig("env", "secret")` returns the list (the nesting below it is plain string-keyed Hashes). A
    # symbol-keyed walk returns [] for every destination: the preflight reports "0 secrets, all fine",
    # the one wrong answer it must never give, and the hygiene tests pass while asserting NOTHING —
    # caught only because minitest reported "Test is missing assertions".
    def self.at(node, *path)
      path.reduce(node) { |value, key| value.is_a?(Hash) ? value[key] : nil }
    end

    # EVERY PLACE KAMAL 2.12.0 RESOLVES A SECRET, each arm named for the file it mirrors. The LIST OF
    # SITES is hand-maintained, and that is the part that drifted: both copies of this walk once
    # collected `env.secret + registry.password`, two of NINE, while claiming they could not drift
    # (e2fafea1). Add an arm when kamal grows a site — nothing else in this repo will notice that it
    # has. Every traversal tolerates the member being absent, because a destination need not declare
    # a role, an accessory, a proxy or a builder at all.
    def self.names(raw)
      roles       = at(raw, "servers").is_a?(Hash)     ? at(raw, "servers").values     : []
      accessories = at(raw, "accessories").is_a?(Hash) ? at(raw, "accessories").values : []

      # env.secret — root (env.rb:35), per env tag (configuration.rb:286), per role (role.rb:20),
      # per accessory (accessory.rb:126). An entry may be `VAR:SECRET`, and kamal looks up the part
      # AFTER the colon (Env#extract_alias) — the first half names the container's env var, not a key.
      envs = [ at(raw, "env"), *at(raw, "env", "tags").to_h.values,
               *roles.map { |role| at(role, "env") }, *accessories.map { |acc| at(acc, "env") } ]
      keys = envs.flat_map { |env| Array(at(env, "secret")) }.map { |key| key.to_s.split(":", 2).last }

      # registry password AND username — root (registry.rb:35) and per accessory (accessory.rb:141).
      # ONLY the Array form is a secret reference (Registry#lookup); a bare String is the literal
      # value, which `username: chaim354` in deploy.yml is. Collecting that would report a MISSING
      # secret named "chaim354" and block every deploy — over-collection fails LOUD, but it fails.
      registries = [ at(raw, "registry"), *accessories.map { |acc| at(acc, "registry") } ]
      keys += registries.flat_map { |reg| [ at(reg, "password"), at(reg, "username") ] }
                        .grep(Array).map(&:first)

      # Custom proxy TLS material — root and per role (proxy.rb:41,47), per accessory
      # (accessory.rb:135). A role's `proxy:` specialization can be `true`/`false` rather than a hash.
      proxies = [ at(raw, "proxy"), *roles.map { |role| at(role, "proxy") },
                  *accessories.map { |acc| at(acc, "proxy") } ]
      keys += proxies.flat_map { |p| [ at(p, "ssl", "certificate_pem"), at(p, "ssl", "private_key_pem") ] }

      # builder.secrets (builder.rb:73) — read the raw key LIST. Never call `config.builder.secrets`,
      # which eagerly resolves each one through `config.secrets[key]`: that moves the vault hit into
      # collection, where a failure has nothing to report it against, and makes the hygiene test need
      # a vault.
      keys += Array(at(raw, "builder", "secrets"))

      # ssh.key_data (ssh.rb:43-44). Kamal falls back to treating an entry as an INLINE literal key
      # when the secrets do not define it, so a deploy still using that deprecated spelling is
      # reported MISSING here. Deliberate: loud beats an empty key reaching an ssh handshake, and
      # kamal 3 removes the inline form outright.
      keys += Array(at(raw, "ssh", "key_data"))

      keys.compact.uniq
    end
  end
end
