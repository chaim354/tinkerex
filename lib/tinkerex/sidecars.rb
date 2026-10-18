require "yaml"

module Tinkerex
  # WHAT A SIDECAR IS, AND EVERYTHING ONE NEEDS — the one definition. A sidecar is a GPL service an
  # addon reaches over HTTP through the host's proxy, never a library this app links (CLAUDE.md §9,
  # §14c). It is discovered as `sidecar/<name>/Dockerfile` — the licence guard's own discovery — and
  # each one needs eight touchpoints in five files, which used to be remembered by hand.
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
    Problem = Data.define(:sidecar, :file, :missing, :snippet)

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

    def initialize(root: Rails.root) = @root = Pathname.new(root.to_s)

    def names = @root.glob("sidecar/*/Dockerfile").map { |df| df.dirname.basename.to_s }.sort

    def image(name) = "#{REGISTRY}/#{name}-sidecar:latest"
    def container(name) = "tinkerex-#{name}"
    def kamal_url(name) = "http://#{container(name)}:#{PORT}"
    def compose_url(name) = "http://#{name}:#{PORT}"
    def env_key(name) = Maker::Addons::Services.env_key_for(name)

    # The host every existing sidecar accessory runs on — a new one joins them.
    def accessory_host
      deploy.fetch("accessories", {}).to_h.values
            .find { |a| a.is_a?(Hash) && a["image"].to_s.match?(SIDECAR_IMAGE) }&.dig("host")
    end

    # The exact text each touchpoint needs. YAML snippets are whole indented lines, ready to insert
    # above their marker; the two prose ones are the token that must appear.
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
        help: "<code>#{key}</code>"
      }
    end

    def problems = names.flat_map { |name| problems_for(name) } + strays

    private

    def problems_for(name)
      key = env_key(name)
      s = snippets(name)
      [
        [ :deploy, "accessory #{name} with image #{image(name)}", s[:deploy_accessory],
          deploy.dig("accessories", name, "image") == image(name) ],
        [ :deploy, "env.clear #{key}: #{kamal_url(name)}", s[:deploy_env],
          deploy_env[key] == kamal_url(name) ],
        [ :ovh, %(env.clear #{key}: "" (blank — the accessory runs on the Unraid host)), s[:ovh_env],
          ovh_env.key?(key) && ovh_env[key].to_s.blank? ],
        [ :compose, "service #{name} (image #{image(name)}, platform linux/amd64)", s[:compose_service],
          compose.dig("services", name, "image") == image(name) && compose.dig("services", name, "platform") == "linux/amd64" ],
        [ :compose, "web environment #{key}: #{compose_url(name)}", s[:compose_env],
          web_env[key] == compose_url(name) ],
        [ :compose_build, "service #{name} building sidecar/#{name}", s[:compose_build],
          compose_build.dig("services", name, "build") == "sidecar/#{name}" ],
        [ :install, "#{key} in the sidecar-URL row", s[:install], text(:install).include?(s[:install]) ],
        [ :help, "#{key} in the operator list", s[:help], text(:help).include?(s[:help]) ]
      ].reject(&:last).map do |file, missing, snippet, _|
        Problem.new(sidecar: name, file: FILES.fetch(file), missing:, snippet:)
      end
    end

    # THE REVERSE DIRECTION: config naming a sidecar with no sidecar/<name>/ behind it — what a
    # removal leaves behind. One problem per stray NAME, however many files carry it.
    def strays
      known_keys = names.map { |n| env_key(n) }
      stray_keys = (deploy_env.keys + web_env.keys).grep(/_SIDECAR_URL\z/).uniq - known_keys
      services = deploy.fetch("accessories", {}).to_h.merge(compose.fetch("services", {}).to_h)
      stray_services = services.filter_map do |svc, cfg|
        svc if cfg.is_a?(Hash) && cfg["image"].to_s.match?(SIDECAR_IMAGE) && !names.include?(svc)
      end.uniq
      stray_keys.map { |k| stray(k, "#{k} names no sidecar/<name>/") } +
        stray_services.map { |svc| stray(svc, "service #{svc} runs a -sidecar image with no sidecar/#{svc}/") }
    end

    def stray(name, missing) =
      Problem.new(sidecar: name, file: "(stray)", missing:, snippet: "remove it everywhere, or add sidecar/<name>/")

    def deploy = @deploy ||= yaml(:deploy)
    def ovh_env = @ovh_env ||= yaml(:ovh).dig("env", "clear").to_h
    def deploy_env = @deploy_env ||= deploy.dig("env", "clear").to_h
    def compose = @compose ||= yaml(:compose)
    def web_env = @web_env ||= compose.dig("services", "web", "environment").to_h
    def compose_build = @compose_build ||= yaml(:compose_build)

    def yaml(file) = YAML.safe_load(text(file), aliases: true) || {}

    def text(file)
      path = @root.join(FILES.fetch(file))
      path.exist? ? path.read : ""
    end
  end
end
