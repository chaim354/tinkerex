require "rails/generators"

# `bin/rails generate sidecar <name> --license <upstream LICENSE>` — scaffolds sidecar/<name>/ and
# inserts every touchpoint a sidecar needs, then asks Tinkerex::Sidecars whether anything is missing.
# The YAML it inserts IS Tinkerex::Sidecars#snippets — the text the guard prints — so the generator
# and the guard cannot disagree about what complete means. `bin/rails destroy sidecar <name>`
# reverses every insert.
#
# ALL REFUSALS COME BEFORE THE FIRST WRITE (Thor runs public methods in definition order): a bad
# name, an existing sidecar, a missing licence, any marker or prose anchor not present exactly once,
# and a name the config still mentions as a stray. A half-inserted config is worse than none.
class SidecarGenerator < Rails::Generators::Base
  source_root File.expand_path("templates", __dir__)
  argument :sidecar_name, type: :string
  class_option :license, type: :string, required: true,
               desc: "Path to the UPSTREAM project's LICENSE — a sidecar's image redistributes its GPL code (§9)"

  # The two prose touchpoints have no marker: each is a sentence listing every sidecar URL, and the
  # new one goes after the last.
  INSTALL_VARS = /^\| `[A-Z0-9_]+_SIDECAR_URL`(?:, `[A-Z0-9_]+_SIDECAR_URL`)*/
  INSTALL_URLS = /\*set by compose\* \(`http:\/\/[a-z0-9-]+:8000`(?:, `http:\/\/[a-z0-9-]+:8000`)*/
  HELP_VARS = /<code>[A-Z0-9_]+_SIDECAR_URL<\/code>(?:, <code>[A-Z0-9_]+_SIDECAR_URL<\/code>)*/

  def self.exit_on_failure? = true

  def refuse_before_writing_anything
    unless Tinkerex::Sidecars.valid_name?(sidecar_name)
      raise Thor::Error, "sidecar name #{sidecar_name.inspect} must be lowercase letters, digits and dashes, starting " \
                         "with a letter, and not a word YAML reads as a boolean or null (no, on, null…)"
    end
    # `destroy` runs against a sidecar that DOES exist — only `generate` refuses one.
    if behavior != :revoke && File.exist?(File.join(destination_root, "sidecar", sidecar_name))
      raise Thor::Error, "sidecar/#{sidecar_name}/ already exists"
    end
    raise Thor::Error, "--license #{options[:license]} is not a readable file" unless File.file?(options[:license]) && File.readable?(options[:license])

    Tinkerex::Sidecars::MARKERS.each_value do |file, marker|
      rel = Tinkerex::Sidecars::FILES.fetch(file)
      count = read(rel).scan(marker_line(marker)).size
      raise Thor::Error, "#{rel} must carry the marker '#{marker}' exactly once (found #{count})" unless count == 1
    end
    { install: [ INSTALL_VARS, INSTALL_URLS ], help: [ HELP_VARS ] }.each do |file, patterns|
      rel = Tinkerex::Sidecars::FILES.fetch(file)
      patterns.each do |re|
        count = read(rel).scan(re).size
        raise Thor::Error, "#{rel}: expected exactly one sidecar-URL list matching #{re.source} (found #{count})" unless count == 1
      end
    end
    return if behavior == :revoke

    # Leftovers FIRST: a removed sidecar's stray key is also a taken name, and "remove these" is the
    # actionable answer for it. What remains taken is a non-sidecar service (addons, sync, web).
    refuse_leftovers
    if sidecars.taken_names.include?(sidecar_name)
      raise Thor::Error, "#{sidecar_name} is already a service in config/deploy.yml or the compose files " \
                         "(not a sidecar) — pick another name"
    end
  end

  def scaffold
    dir = "sidecar/#{sidecar_name}"
    # The DIRECTORY is an action of its own so `destroy` removes it: revoking only the files below
    # leaves an empty sidecar/<name>/, which the existence refusal above then reads as a sidecar —
    # and `generate` of the same name refuses forever after (measured).
    empty_directory dir
    template "Dockerfile.tt", "#{dir}/Dockerfile"
    template "app.py.tt", "#{dir}/app.py"
    copy_file "requirements.txt", "#{dir}/requirements.txt"
    template "README.md.tt", "#{dir}/README.md"
    create_file "#{dir}/LICENSE", File.binread(options[:license])
  end

  def insert_config
    snippets = sidecars.snippets(sidecar_name)
    Tinkerex::Sidecars::MARKERS.each do |point, (file, marker)|
      inject_into_file Tinkerex::Sidecars::FILES.fetch(file), snippets.fetch(point), before: marker_line(marker)
    end
    inject_into_file Tinkerex::Sidecars::FILES[:install], ", #{snippets[:install]}", after: INSTALL_VARS
    inject_into_file Tinkerex::Sidecars::FILES[:install], ", #{snippets[:install_url]}", after: INSTALL_URLS
    inject_into_file Tinkerex::Sidecars::FILES[:help], ", #{snippets[:help]}", after: HELP_VARS
  end

  def verify_and_explain
    return if behavior == :revoke
    # UNDER --pretend NOTHING WAS WRITTEN, so the check below would find no sidecar/<name>/ to judge
    # and report "complete" about a sidecar that does not exist. Say what actually happened instead.
    if options[:pretend]
      say "\n(--pretend: nothing was written, so nothing was checked. Run without it to generate.)"
      return
    end

    problems = sidecars.problems
    unless problems.empty?
      raise Thor::Error, "generated, but Tinkerex::Sidecars still reports:\n" +
                         problems.map { |p| "  #{p.message}" }.join("\n")
    end
    say <<~NEXT

      sidecar/#{sidecar_name}/ is complete (sidecars:check would pass). Next:
        1. Write the service in sidecar/#{sidecar_name}/app.py (and its README).
        2. In the addon's manifest (chaim354/tinkerex-addons): "services": ["#{sidecar_name}"]
        3. bin/publish-sidecar #{sidecar_name}     — builds, boots the accessory, verifies it
        4. Redeploy chunk_remote, share and s3 so the app carries #{sidecars.env_key(sidecar_name)}.
    NEXT
  end

  private

  # A NAME THE CONFIG STILL MENTIONS IS REFUSED: a removed sidecar's leftover (its env key, its
  # accessory or service) plus the copy inserted here is a DUPLICATE KEY, and YAML silently keeps
  # the last of two — so every check passed, "complete", over a compose file `docker compose config`
  # refuses ("mapping key already defined"). Measured. `generate` only: `destroy` runs against a
  # sidecar that exists, whose entries are not strays.
  def refuse_leftovers
    leftovers = sidecars.problems.select do |p|
      p.file == "(stray)" && [ sidecar_name, sidecars.env_key(sidecar_name) ].include?(p.sidecar)
    end
    return if leftovers.empty?

    raise Thor::Error, "the config still names #{sidecar_name} — a removed sidecar's leftovers. Remove them first; " \
                       "inserting beside them would write duplicate keys YAML silently collapses:\n" +
                       leftovers.map { |p| "  #{p.message}" }.join("\n")
  end

  # A FRESH instance per call, never memoized: Tinkerex::Sidecars caches each file's parsed YAML,
  # and `snippets` reads deploy.yml (for the accessory host) BEFORE insert_config writes it — a
  # memoized one makes verify_and_explain judge the pre-insert deploy.yml and refuse a complete run.
  def sidecars = Tinkerex::Sidecars.new(root: destination_root)
  def read(rel) = File.read(File.join(destination_root, rel))
  def marker_line(marker) = /^ *#{Regexp.escape(marker)}\n/
end
