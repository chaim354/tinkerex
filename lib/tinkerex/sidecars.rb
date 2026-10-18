require "yaml"

module Tinkerex
  # WHAT A SIDECAR IS, AND EVERYTHING ONE NEEDS — the one definition. A sidecar is a GPL service an
  # addon reaches over HTTP through the host's proxy, never a library this app links (CLAUDE.md §9,
  # §14c). It is discovered as `sidecar/<name>/Dockerfile` — the licence guard's own discovery — and
  # each one needs nine touchpoints in the six FILES (`problems_for`), which used to be remembered by hand.
  #
  # THREE READERS, ONE ANSWER: test/sidecar_hygiene_test.rb (bin/ci), `bin/rails sidecars:check`
  # (bin/publish-sidecar runs it) and `bin/rails generate sidecar`, which INSERTS `snippets` — the
  # same text a problem prints — so the generator and the guard cannot disagree about what complete
  # means. The env name comes from Maker::Addons::Services.env_key_for, never a second spelling.
  #
  # A CHECKOUT-ONLY OBJECT: /sidecar/ is dockerignored, so in the production image `names` is []. No
  # request path calls this.
  #
  # NO URL CONVENTION FALLBACK, deliberately: a sidecar's URL stays explicit per deployment, because
  # an implied `http://tinkerex-<name>:8000` would make every declared service read "available"
  # before its accessory exists — and on OVH every call would fail instead of greying out.
  class Sidecars
    Problem = Data.define(:sidecar, :file, :missing, :snippet) do
      # ONE SENTENCE for every reader (sidecars:check, the bin/ci guard, the generator). A stray is not
      # missing from a file, so it reads as what it is.
      def message = file == "(stray)" ? "#{sidecar}: stray — #{missing}" : "#{sidecar}: #{file} is missing #{missing}"

      # A touchpoint's snippet is TEXT for its file, exact to the byte (indentation included); a
      # stray's or a misnamed directory's is an INSTRUCTION. sidecars:check prints the two differently.
      def touchpoint? = FILES.value?(file)
    end

    REGISTRY = "ghcr.io/chaim354".freeze
    PORT = 8000
    FILES = {
      deploy: "config/deploy.yml", ovh: "config/deploy.ovh.yml", compose: "docker-compose.yml",
      compose_build: "docker-compose.build.yml", install: "docs/INSTALL.md", help: "app/views/help/show.html.erb"
    }.freeze
    # Where `bin/rails generate sidecar` inserts each YAML snippet: one comment line per point, each
    # present EXACTLY ONCE in its file (the generator refuses before writing anything otherwise).
    MARKERS = {
      deploy_env:       [ :deploy,        "# bin/rails generate sidecar inserts sidecar URLs above this line" ],
      deploy_accessory: [ :deploy,        "# bin/rails generate sidecar inserts sidecar accessories above this line" ],
      ovh_env:          [ :ovh,           "# bin/rails generate sidecar inserts sidecar URLs above this line" ],
      compose_env:      [ :compose,       "# bin/rails generate sidecar inserts sidecar URLs above this line" ],
      compose_service:  [ :compose,       "# bin/rails generate sidecar inserts sidecar services above this line" ],
      compose_build:    [ :compose_build, "# bin/rails generate sidecar inserts sidecar builds above this line" ]
    }.freeze
    SIDECAR_IMAGE = %r{\A#{Regexp.escape(REGISTRY)}/.+-sidecar:latest\z}
    NAME = /\A[a-z][a-z0-9-]*\z/

    # A NAME IS VALID ONLY IF YAML READS IT BACK AS ITSELF. Each snippet inserts the name as a bare
    # key (`<name>:`), and YAML 1.1 reads `no:` as `false:`, `on:` as `true:`, `null:` as `nil:` —
    # so such a sidecar's touchpoints could never match and its problems never clear. The reserved
    # set is ASKED of Psych, the parser every reader here uses, never a hand list.
    def self.valid_name?(name)
      return false unless name.is_a?(String) && name.match?(NAME)

      parsed = YAML.safe_load("#{name}: 1")
      parsed.is_a?(Hash) && parsed.keys.first == name
    end

    def initialize(root: Rails.root) = @root = Pathname.new(root.to_s)

    def names = @root.glob("sidecar/*/Dockerfile").map { |df| df.dirname.basename.to_s }.sort

    def image(name) = "#{REGISTRY}/#{name}-sidecar:latest"
    def container(name) = "tinkerex-#{name}"
    def kamal_url(name) = "http://#{container(name)}:#{PORT}"
    def compose_url(name) = "http://#{name}:#{PORT}"
    def env_key(name) = Maker::Addons::Services.env_key_for(name)

    # The host every existing sidecar accessory runs on — a new one joins them.
    def accessory_host
      hash_at(deploy, "accessories").values
            .find { |a| a.is_a?(Hash) && a["image"].to_s.match?(SIDECAR_IMAGE) }&.dig("host")
    end

    # The exact text each touchpoint needs. YAML snippets are whole indented lines, ready to insert
    # above their marker; the three prose ones are the token that must appear (INSTALL.md's row
    # lists both the variable and the compose URL it is set to).
    def snippets(name)
      key = env_key(name)
      {
        deploy_env: <<~YAML.gsub(/^/, "    "),
          # The #{name} sidecar (sidecar/#{name}; the `#{name}` accessory below). Internal-only, never
          # published. deploy.ovh.yml blanks it, because Kamal deep-merges env.clear.
          #{key}: #{kamal_url(name)}
        YAML
        deploy_accessory: <<~YAML.gsub(/^/, "  "),
          # The #{name} sidecar (sidecar/#{name}) — a SEPARATE GPL image, built and pushed by
          # `bin/publish-sidecar #{name}`. NO `port:` -> internal-only, reachable as `#{container(name)}`.
          #{name}:
            image: #{image(name)}
            host: #{accessory_host}
        YAML
        ovh_env: %(    #{key}: ""\n),
        compose_env: "      #{key}: #{compose_url(name)}\n",
        compose_service: <<~YAML.gsub(/^/, "  "),
          #{name}:
            image: #{image(name)}
            platform: linux/amd64
            restart: unless-stopped
        YAML
        compose_build: <<~YAML.gsub(/^/, "  "),
          #{name}:
            image: #{name}-sidecar:local
            build: sidecar/#{name}
        YAML
        install: "`#{key}`",
        install_url: "`#{compose_url(name)}`",
        help: "<code>#{key}</code>"
      }
    end

    # A sidecar/<name>/ whose name YAML cannot keep is ONE problem — rename it — rather than nine
    # snippets that could never clear.
    def problems = names.flat_map { |name| self.class.valid_name?(name) ? problems_for(name) : [ misnamed(name) ] } + strays

    # Every service key already in use — Kamal accessories, compose services, build-overlay services.
    # A new sidecar may not take one: `addons`, `web` and `sync` are not sidecars, so they are never
    # strays, and inserting a sidecar under the same key writes a duplicate YAML silently collapses.
    def taken_names
      [ hash_at(deploy, "accessories"), hash_at(compose, "services"), hash_at(compose_build, "services") ]
        .flat_map(&:keys).map(&:to_s).uniq
    end

    private

    def misnamed(name) =
      Problem.new(sidecar: name, file: "sidecar/#{name}/", missing: "a name YAML keeps as a string — rename the directory",
                  snippet: "git mv sidecar/#{name} sidecar/<new-name>  (lowercase letters, digits and dashes, starting with a letter)")

    def problems_for(name)
      key = env_key(name)
      s = snippets(name)
      [
        [ :deploy, "accessory #{name} with image #{image(name)}", s[:deploy_accessory],
          at(deploy, "accessories", name, "image") == image(name) ],
        [ :deploy, "env.clear #{key}: #{kamal_url(name)}", s[:deploy_env],
          deploy_env[key] == kamal_url(name) ],
        [ :ovh, %(env.clear #{key}: "" (blank — the accessory runs on the Unraid host)), s[:ovh_env],
          ovh_env.key?(key) && ovh_env[key].to_s.blank? ],
        [ :compose, "service #{name} (image #{image(name)}, platform linux/amd64)", s[:compose_service],
          at(compose, "services", name, "image") == image(name) && at(compose, "services", name, "platform") == "linux/amd64" ],
        [ :compose, "web environment #{key}: #{compose_url(name)}", s[:compose_env],
          web_env[key] == compose_url(name) ],
        [ :compose_build, "service #{name} building sidecar/#{name}", s[:compose_build],
          at(compose_build, "services", name, "build") == "sidecar/#{name}" ],
        [ :install, "#{key} in the sidecar-URL row", s[:install], text(:install).include?(s[:install]) ],
        [ :install, "#{compose_url(name)} in the sidecar-URL row", s[:install_url], text(:install).include?(s[:install_url]) ],
        [ :help, "#{key} in the operator list", s[:help], text(:help).include?(s[:help]) ]
      ].reject(&:last).map do |file, missing, snippet, _|
        Problem.new(sidecar: name, file: FILES.fetch(file), missing:, snippet:)
      end
    end

    # THE REVERSE DIRECTION: config naming a sidecar with no sidecar/<name>/ behind it — what a
    # removal leaves behind. One problem per stray NAME, however many files carry it.
    #
    # The accessories and the compose services are scanned SEPARATELY and concatenated, never
    # merged: a merge lets a compose service hide a same-named stray accessory. And `select`, never
    # `filter_map { svc if … }`, which drops a stray whose key YAML read as `false` or `nil`.
    def strays
      known = names
      # The two prose touchpoints count too: a removed sidecar's name left in the INSTALL row or the
      # Help list is the same leftover as one left in env, and the generator's insert sits beside it.
      prose_keys = (text(:install) + text(:help)).scan(/\b[A-Z][A-Z0-9_]*_SIDECAR_URL\b/)
      stray_keys = (deploy_env.keys + web_env.keys + ovh_env.keys).grep(/_SIDECAR_URL\z/)
        .concat(prose_keys).uniq - known.map { |n| env_key(n) }
      runners = [ hash_at(deploy, "accessories"), hash_at(compose, "services") ]
        .flat_map { |services| services.select { |_svc, cfg| runs_sidecar_image?(cfg) }.keys }
        .map { |svc| [ svc, "service #{svc} runs a -sidecar image with no sidecar/#{svc}/" ] }
      builds = hash_at(compose_build, "services").values.map { |cfg| built_sidecar(cfg) }.compact
        .map { |dir| [ dir, "#{FILES[:compose_build]} builds sidecar/#{dir}/, which does not exist" ] }
      stray_services = (runners + builds).reject { |svc, _| known.include?(svc) }.uniq(&:first)
      stray_keys.map { |k| stray(k, "#{k} names no sidecar/<name>/") } +
        stray_services.map { |svc, missing| stray(svc, missing) }
    end

    def runs_sidecar_image?(cfg) = cfg.is_a?(Hash) && cfg["image"].to_s.match?(SIDECAR_IMAGE)

    # The <x> of a build overlay entry building sidecar/<x> — `build:` as a path or as `context:`.
    def built_sidecar(cfg)
      build = at(cfg, "build")
      build = at(build, "context") if build.is_a?(Hash)
      build.to_s[%r{\A(?:\./)?sidecar/([^/]+)/?\z}, 1]
    end

    def stray(name, missing) =
      Problem.new(sidecar: name, file: "(stray)", missing:, snippet: "remove it everywhere, or add sidecar/<name>/")

    def deploy = @deploy ||= yaml(:deploy)
    def ovh_env = @ovh_env ||= hash_at(yaml(:ovh), "env", "clear")
    def deploy_env = @deploy_env ||= hash_at(deploy, "env", "clear")
    def compose = @compose ||= yaml(:compose)
    def web_env = @web_env ||= environment(at(compose, "services", "web", "environment"))
    def compose_build = @compose_build ||= yaml(:compose_build)

    # MALFORMED CONFIG IS ANSWERED, NEVER RAISED: every traversal goes through `at`, which is nil at
    # any level that is not a Hash, so a list or a scalar where a map belongs reads as "missing" and
    # comes back as problems. A YAML SYNTAX ERROR still raises, naming its file — a guard must not
    # read a broken file as an empty one.
    def at(obj, *keys) = keys.reduce(obj) { |o, k| o.is_a?(Hash) ? o[k] : nil }

    def hash_at(obj, *keys)
      found = at(obj, *keys)
      found.is_a?(Hash) ? found : {}
    end

    # Compose takes `environment:` as a map OR as a list of `KEY=value` strings — one answer for both.
    def environment(env)
      return env if env.is_a?(Hash)
      return {} unless env.is_a?(Array)

      env.grep(String).to_h { |entry| entry.split("=", 2).values_at(0, 1) }
    end

    # No Hash check here: every reader goes through `at`/`hash_at`, which already answer nil for a
    # file that parsed to a list or a scalar, so a second check could never fail (mutation-checked).
    def yaml(file) = YAML.safe_load(text(file), aliases: true, filename: FILES.fetch(file))

    def text(file)
      path = @root.join(FILES.fetch(file))
      path.exist? ? path.read : ""
    end
  end
end
