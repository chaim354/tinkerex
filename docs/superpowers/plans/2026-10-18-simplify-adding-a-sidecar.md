# Simplify Adding a Sidecar — Implementation Plan

> **For agentic workers:** in THIS repo, execute with `.claude/commands/execute-plan.md` (CLAUDE.md
> §15) — it overrides the generic subagent-driven-development loop. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** Adding a GPL sidecar becomes `bin/rails generate sidecar <name> --license <path>`, write the
app, `bin/publish-sidecar <name>` — with a guard that names any missing touchpoint and its snippet.

**Architecture:** `Tinkerex::Sidecars` is the one definition of a sidecar's conventions and of every
touchpoint it needs; it produces the snippets, and reports what is missing. A `bin/ci` guard, a
`sidecars:check` task and a Rails generator all read it. `bin/build-sidecar` replaces the two copied
build scripts and bakes `/revision` into each image; `bin/publish-sidecar` builds, boots or reboots,
and verifies `/revision` and `/up` through `kamal accessory exec`.

**Tech Stack:** Rails 8 / Minitest / Rails::Generators (Thor); Bash; Kamal 2.12; Docker buildx.

**Spec:** `docs/superpowers/specs/2026-10-18-simplify-adding-a-sidecar-design.md`.
**Branch:** `claude/simplify-adding-a-sidecar` (off `main`).

---

## File map

| File | Task | Responsibility |
|---|---|---|
| `lib/tinkerex/sidecars.rb` | 1 | conventions, snippets, `problems` |
| `test/lib/sidecars_test.rb` | 1 | its tests, over a temp copy of the real files |
| `bin/build-sidecar` (new), `bin/build-boxes-sidecar` + `bin/build-openscad-sidecar` (deleted) | 2 | one build script, `--revision` mode |
| `sidecar/boxes/Dockerfile`, `sidecar/openscad/Dockerfile`, `sidecar/openscad/README.md` | 2 | `/revision`; openscad's build note moves to its README |
| `test/deploy_hygiene_test.rb` (revision test) | 2 | guards the one script and every Dockerfile's `/revision` |
| `config/deploy.yml` (one comment), `docs/DEPLOY.md` (one line) | 2 | references to the old script names |
| `test/sidecar_hygiene_test.rb`, `lib/tasks/sidecars.rake`, `test/tasks/sidecars_tasks_test.rb` | 3 | the guard and the task |
| `test/compose_hygiene_test.rb`, `test/deploy_hygiene_test.rb` (OVH count) | 3 | stop hard-coding the sidecar set |
| `config/deploy.yml`, `config/deploy.ovh.yml`, `docker-compose.yml`, `docker-compose.build.yml` (markers) | 4 | insertion points |
| `lib/generators/sidecar/sidecar_generator.rb` + `templates/` | 4 | the generator |
| `config/application.rb` | 4 | `generators` out of autoload/eager-load |
| `test/lib/generators/sidecar_generator_test.rb` | 4 | its tests |
| `bin/publish-sidecar` | 5 | one-command deploy |
| `docs/DEPLOY.md` (sidecar section), `docs/invariants/addons.md` | 5 | docs |

**Execution rounds** (disjoint paths in parallel): **R1** Task 1 ∥ Task 2 · **R2** Task 3 ∥ Task 4 ·
**R3** Task 5 · **R4** Task 6 (close-out, orchestrator).

---

## Task 1: `Tinkerex::Sidecars` — the one definition

**Files:** Create `lib/tinkerex/sidecars.rb`, `test/lib/sidecars_test.rb`.

`lib/tinkerex/` is autoloaded (`config.autoload_lib`), so `Tinkerex::Sidecars` needs no require.

- [ ] **Step 1: Write the failing test** — `test/lib/sidecars_test.rb`:

```ruby
require "test_helper"

# Tinkerex::Sidecars over a TEMP COPY of the real files, so a fixture can never drift from the
# configs it stands in for: each test copies the eight touchpoint files and every sidecar's
# Dockerfile, then breaks exactly one thing and asserts exactly that problem.
class SidecarsTest < ActiveSupport::TestCase
  def with_tree
    Dir.mktmpdir do |dir|
      root = Pathname.new(dir)
      (Tinkerex::Sidecars::FILES.values + Rails.root.glob("sidecar/*/Dockerfile").map { |p| p.relative_path_from(Rails.root).to_s })
        .each do |rel|
          root.join(rel).dirname.mkpath
          FileUtils.cp(Rails.root.join(rel), root.join(rel))
        end
      yield root, Tinkerex::Sidecars.new(root:)
    end
  end

  def edit(root, rel)
    path = root.join(rel)
    before = path.read
    after = yield before
    assert_not_equal before, after, "the edit to #{rel} changed nothing — the test would prove nothing"
    path.write(after)
  end

  def only_problem(sidecars)
    problems = sidecars.problems
    assert_equal 1, problems.size, problems.map(&:to_h).inspect
    problems.first
  end

  test "the real tree's copy has sidecars and no problems" do
    with_tree do |_root, sidecars|
      assert_not_empty sidecars.names, "no sidecar/*/Dockerfile found — every check below would pass over nothing"
      assert_equal [], sidecars.problems
    end
  end

  test "conventions follow from the name, and the env key is Services' derivation" do
    s = Tinkerex::Sidecars.new
    assert_equal "ghcr.io/chaim354/foo-bar-sidecar:latest", s.image("foo-bar")
    assert_equal "tinkerex-foo-bar", s.container("foo-bar")
    assert_equal "http://tinkerex-foo-bar:8000", s.kamal_url("foo-bar")
    assert_equal "http://foo-bar:8000", s.compose_url("foo-bar")
    assert_equal "FOO_BAR_SIDECAR_URL", s.env_key("foo-bar")
  end

  test "a missing deploy.yml accessory is named with its snippet" do
    with_tree do |root, sidecars|
      edit(root, "config/deploy.yml") { |t| t.sub("image: ghcr.io/chaim354/openscad-sidecar:latest", "image: ghcr.io/chaim354/openscad-sidecar:v1") }
      p = only_problem(sidecars)
      assert_equal [ "openscad", "config/deploy.yml" ], [ p.sidecar, p.file ]
      assert_match(/accessory openscad/, p.missing)
      assert_equal sidecars.snippets("openscad").fetch(:deploy_accessory), p.snippet
    end
  end

  test "a missing deploy.yml URL is named" do
    with_tree do |root, sidecars|
      edit(root, "config/deploy.yml") { |t| t.sub("OPENSCAD_SIDECAR_URL: http://tinkerex-openscad:8000", "# gone") }
      p = only_problem(sidecars)
      assert_equal [ "openscad", "config/deploy.yml" ], [ p.sidecar, p.file ]
      assert_match(/OPENSCAD_SIDECAR_URL: http:\/\/tinkerex-openscad:8000/, p.missing)
      assert_equal sidecars.snippets("openscad").fetch(:deploy_env), p.snippet
    end
  end

  test "an OVH overlay that does not blank the URL is named" do
    with_tree do |root, sidecars|
      edit(root, "config/deploy.ovh.yml") { |t| t.sub(%(OPENSCAD_SIDECAR_URL: ""), %(OPENSCAD_SIDECAR_URL: "http://x")) }
      p = only_problem(sidecars)
      assert_equal [ "openscad", "config/deploy.ovh.yml" ], [ p.sidecar, p.file ]
    end
  end

  test "a compose service without its amd64 pin is named" do
    with_tree do |root, sidecars|
      edit(root, "docker-compose.yml") { |t| t.sub("openscad-sidecar:latest\n    platform: linux/amd64\n", "openscad-sidecar:latest\n") }
      p = only_problem(sidecars)
      assert_equal [ "openscad", "docker-compose.yml" ], [ p.sidecar, p.file ]
      assert_match(/service openscad/, p.missing)
    end
  end

  test "a compose web env missing the URL is named" do
    with_tree do |root, sidecars|
      edit(root, "docker-compose.yml") { |t| t.sub("OPENSCAD_SIDECAR_URL: http://openscad:8000", "# gone") }
      p = only_problem(sidecars)
      assert_equal [ "openscad", "docker-compose.yml" ], [ p.sidecar, p.file ]
      assert_match(/web environment/, p.missing)
    end
  end

  test "a build overlay entry building the wrong context is named" do
    with_tree do |root, sidecars|
      edit(root, "docker-compose.build.yml") { |t| t.sub("build: sidecar/openscad", "build: sidecar/elsewhere") }
      p = only_problem(sidecars)
      assert_equal [ "openscad", "docker-compose.build.yml" ], [ p.sidecar, p.file ]
    end
  end

  test "INSTALL.md not naming the URL is named" do
    with_tree do |root, sidecars|
      edit(root, "docs/INSTALL.md") { |t| t.gsub("`OPENSCAD_SIDECAR_URL`", "`OPENSCAD_URL`") }
      p = only_problem(sidecars)
      assert_equal [ "openscad", "docs/INSTALL.md" ], [ p.sidecar, p.file ]
    end
  end

  test "the Help page not naming the URL is named" do
    with_tree do |root, sidecars|
      edit(root, "app/views/help/show.html.erb") { |t| t.sub(", <code>OPENSCAD_SIDECAR_URL</code>", "") }
      p = only_problem(sidecars)
      assert_equal [ "openscad", "app/views/help/show.html.erb" ], [ p.sidecar, p.file ]
    end
  end

  test "a new sidecar directory with nothing else reports all eight touchpoints, in order" do
    with_tree do |root, sidecars|
      root.join("sidecar/foo").mkpath
      root.join("sidecar/foo/Dockerfile").write("FROM scratch\n")
      problems = sidecars.problems.select { |p| p.sidecar == "foo" }
      assert_equal %w[config/deploy.yml config/deploy.yml config/deploy.ovh.yml docker-compose.yml
                      docker-compose.yml docker-compose.build.yml docs/INSTALL.md app/views/help/show.html.erb],
                   problems.map(&:file)
    end
  end

  test "config naming a sidecar with no directory behind it is a stray" do
    with_tree do |root, sidecars|
      FileUtils.rm(root.join("sidecar/openscad/Dockerfile"))
      strays = sidecars.problems
      assert_equal 2, strays.size, strays.map(&:to_h).inspect
      assert(strays.any? { |p| p.missing.include?("OPENSCAD_SIDECAR_URL") }, "the env key is a stray")
      assert(strays.any? { |p| p.missing.include?("service openscad") }, "the accessory/compose service is a stray")
    end
  end

  test "every YAML snippet parses into exactly the values problems checks for" do
    s = Tinkerex::Sidecars.new
    snips = s.snippets("foo")
    assert_equal({ "FOO_SIDECAR_URL" => "http://tinkerex-foo:8000" }, YAML.safe_load(snips[:deploy_env]))
    assert_equal "ghcr.io/chaim354/foo-sidecar:latest", YAML.safe_load(snips[:deploy_accessory]).dig("foo", "image")
    assert_equal({ "FOO_SIDECAR_URL" => "" }, YAML.safe_load(snips[:ovh_env]))
    assert_equal({ "FOO_SIDECAR_URL" => "http://foo:8000" }, YAML.safe_load(snips[:compose_env]))
    assert_equal "linux/amd64", YAML.safe_load(snips[:compose_service]).dig("foo", "platform")
    assert_equal "sidecar/foo", YAML.safe_load(snips[:compose_build]).dig("foo", "build")
  end
end
```

- [ ] **Step 2: Run it — expect `NameError: uninitialized constant Tinkerex::Sidecars`.**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/lib/sidecars_test.rb`

- [ ] **Step 3: Implement** — `lib/tinkerex/sidecars.rb`:

```ruby
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
```

- [ ] **Step 4: Run the test — all green.** If the stray test reports 3 (deploy env and compose env both carry the key but `uniq` collapses names; accessory and compose service both carry the service and `uniq` collapses those), re-check `uniq` placement before touching the test.

- [ ] **Step 5: Commit** (pathspec: the two files), message
  `Tinkerex::Sidecars: one definition of a sidecar and every touchpoint it needs`.

- [ ] **Step 6: Mutation-check — report each output** (restore with `git checkout -- lib/tinkerex/sidecars.rb`, then `rm -rf tmp/cache/bootsnap*`):
  1. Replace the OVH check's value test with `true` → the OVH test goes red.
  2. Drop `&& compose.dig("services", name, "platform") == "linux/amd64"` → the amd64 test goes red.
  3. Make `strays` return `[]` → the stray test goes red.
  4. Change `env_key` to `"#{name.upcase}_SIDECAR_URL"` → the conventions test goes red (hyphen).
  5. Change `snippets[:deploy_env]`'s value to `kamal_url(name).sub("8000", "80")` → the snippet-parse test goes red.

---

## Task 2: `bin/build-sidecar` and `/revision`

Parallel with Task 1 (disjoint paths).

**Files:** Create `bin/build-sidecar`. Delete `bin/build-boxes-sidecar`, `bin/build-openscad-sidecar`.
Modify `sidecar/boxes/Dockerfile`, `sidecar/openscad/Dockerfile`, `sidecar/openscad/README.md`,
`test/deploy_hygiene_test.rb` (the "every sidecar build script bakes the source revision" test only),
`config/deploy.yml` (the one comment naming `bin/build-openscad-sidecar`), `docs/DEPLOY.md` (the one
line naming `bin/build-boxes-sidecar`).

- [ ] **Step 1: Update the guard first** — in `test/deploy_hygiene_test.rb`, replace the body of
  `test "every sidecar build script bakes the source revision into the image"` and rename it, keeping
  its "WHAT THIS COVERS / CANNOT" and "WHY THE LABEL" comment paragraphs (edit "both scripts" → "the
  script" where they say so):

```ruby
  test "the one sidecar build script bakes the source revision into the image, both ways" do
    # (keep the existing explanatory comment block here)
    script = ROOT.join("bin/build-sidecar")
    assert script.exist?, "bin/build-sidecar is the one sidecar build script"
    assert_empty ROOT.glob("bin/build-*-sidecar").map { |p| p.basename.to_s },
                 "per-sidecar build scripts are retired — bin/build-sidecar <name> builds any of them"

    body = script.read
    label = body[/--label\s+"?org\.opencontainers\.image\.revision=([^"'\s]*)/, 1]
    assert label, "bin/build-sidecar must pass --label org.opencontainers.image.revision=…"
    assert_includes label, "$", "the revision label must be computed at build time, not a literal — got #{label.inspect}"
    arg = body[/--build-arg\s+"?SIDECAR_REVISION=([^"'\s]*)/, 1]
    assert arg, "bin/build-sidecar must pass --build-arg SIDECAR_REVISION=… (read back as /revision)"
    assert_equal label, arg, "the label and /revision must carry ONE value"
    assert_match %r{ghcr\.io/chaim354/\$\{?NAME\}?-sidecar}, body,
                 "the pushed image name must be Tinkerex::Sidecars#image's convention"

    # EVERY sidecar writes /revision from that build arg — directory-driven, like the licence test.
    dockerfiles = ROOT.glob("sidecar/*/Dockerfile")
    assert dockerfiles.any?, "expected at least one sidecar/<name>/Dockerfile"
    dockerfiles.each do |df|
      text = df.read
      where = df.relative_path_from(ROOT)
      assert_match(/^ARG SIDECAR_REVISION\b/, text, "#{where} must declare ARG SIDECAR_REVISION")
      assert_match(%r{\$SIDECAR_REVISION"?\s*>\s*/revision}, text, "#{where} must write $SIDECAR_REVISION to /revision")
    end
  end
```

- [ ] **Step 2: Run it — expect red** (`bin/build-sidecar` missing).
  `LIBRARY_PATH=$(mktemp -d) bin/rails test test/deploy_hygiene_test.rb`

- [ ] **Step 3: Create `bin/build-sidecar`** (`chmod +x`). Merge the two scripts' comments into this
  header — keep every paragraph of `bin/build-openscad-sidecar`'s header and PROVENANCE comment, keep
  `bin/build-boxes-sidecar`'s "THIS SIDECAR NEEDS IT AS MUCH" paragraph rewritten as "EVERY sidecar
  needs it, not only openscad", and move openscad's build-assertions paragraph (the one beginning
  "The box is amd64; build for it … The build runs the six capability assertions") into
  `sidecar/openscad/README.md` under a "Build-time assertions" heading. Code:

```bash
#!/usr/bin/env bash
# Build + push ANY sidecar image (sidecar/<name>) to ghcr. Each is a SEPARATE GPL image from the Rails
# app — the app never links it (CLAUDE.md §9). Replaces the per-sidecar copies this repo used to carry.
#
#   bin/build-sidecar <name>              build + push sidecar/<name> as ghcr.io/chaim354/<name>-sidecar
#   bin/build-sidecar --revision <name>   print the revision it WOULD stamp, and nothing else
#
# Deploying it is bin/publish-sidecar <name> (which calls this). The ghcr token comes from 1Password
# via bin/secret — no export needed; an exported KAMAL_REGISTRY_PASSWORD wins.
#
# (merged PROVENANCE / git-describe / tag-vs-label paragraphs go here, from the two old scripts)
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "usage: bin/build-sidecar <name> | bin/build-sidecar --revision <name>" >&2; exit 2; }
mode=build
if [ "${1:-}" = "--revision" ]; then mode=revision; shift; fi
[ $# -eq 1 ] || usage
NAME="$1"
[[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "build-sidecar: bad name '$NAME'" >&2; exit 2; }
CONTEXT="sidecar/$NAME"
[ -f "$CONTEXT/Dockerfile" ] || { echo "build-sidecar: no $CONTEXT/Dockerfile" >&2; exit 1; }

# ONE definition of the revision: this script stamps it, and bin/publish-sidecar asks for it with
# --revision and verifies the running container's /revision against it.
REVISION="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain -- "$CONTEXT")" ]; then
  REVISION="$REVISION-dirty"
fi
if [ "$mode" = revision ]; then echo "$REVISION"; exit 0; fi

REPO="ghcr.io/chaim354/${NAME}-sidecar"
# Xtrace off before the secret: under `bash -x` an assignment is traced AFTER expansion.
{ set +x; } 2>/dev/null
KAMAL_REGISTRY_PASSWORD="$(bin/secret KAMAL_REGISTRY_PASSWORD 'op://tinkerex/ghcr.io/password')"
echo "$KAMAL_REGISTRY_PASSWORD" | docker login ghcr.io -u chaim354 --password-stdin
docker buildx build --platform linux/amd64 \
  --build-arg "SIDECAR_REVISION=$REVISION" \
  --label "org.opencontainers.image.revision=$REVISION" \
  -t "$REPO:latest" -t "$REPO:$REVISION" --push "$CONTEXT"
echo "pushed $REPO:latest (revision $REVISION)"
```

- [ ] **Step 4: Dockerfiles.** In `sidecar/boxes/Dockerfile`, immediately before `EXPOSE 8000`; in
  `sidecar/openscad/Dockerfile`, immediately before `USER openscad` (a non-root RUN cannot write `/`):

```dockerfile
# WHICH BUILD IS RUNNING, readable through `kamal accessory exec` (bin/publish-sidecar verifies it)
# beside the OCI label, which needs `docker inspect` on the host. Declared LATE so a new revision
# invalidates only this layer.
ARG SIDECAR_REVISION=unknown
RUN printf '%s\n' "$SIDECAR_REVISION" > /revision
```

- [ ] **Step 5: Delete the two old scripts** (`git rm bin/build-boxes-sidecar bin/build-openscad-sidecar`)
  and fix the three live references: `config/deploy.yml` (the openscad accessory comment —
  "built + pushed with `bin/build-sidecar openscad`"), `docs/DEPLOY.md:905` (`bin/build-sidecar boxes`),
  `sidecar/openscad/Dockerfile:3`. Then `grep -rn "build-boxes-sidecar\|build-openscad-sidecar" --exclude-dir=.git . | grep -v "docs/superpowers\|docs/AUDIT\|docs/FIX-LOG"` must print nothing (historical plans, specs and audits keep the old names).

- [ ] **Step 6: Verify.** `bash -n bin/build-sidecar`; `bin/build-sidecar --revision boxes` (a SHA,
  touching no secret); `touch sidecar/boxes/zz && bin/build-sidecar --revision boxes; rm sidecar/boxes/zz`
  (`-dirty`); `bin/build-sidecar nope; echo $?` (1, "no sidecar/nope/Dockerfile");
  `bin/build-sidecar 'a b'; echo $?` (2). **Never run it in build mode.** Then
  `LIBRARY_PATH=$(mktemp -d) bin/rails test test/deploy_hygiene_test.rb` — green.

- [ ] **Step 7: Commit** (pathspec), message `bin/build-sidecar: one build script for every sidecar, and /revision inside each image`.

- [ ] **Step 8: Mutation-check** — after the commit: remove `--build-arg` line → red; make the
  boxes Dockerfile's printf write `/rev` → red; `cp bin/build-sidecar bin/build-foo-sidecar` → red
  (then `rm` it). Restore with `git checkout -- <file>`; report each output.

---

## Task 3: The guard, the task, and two hard-coded counts

After Tasks 1 and 2. Parallel with Task 4 (disjoint paths).

**Files:** Create `test/sidecar_hygiene_test.rb`, `lib/tasks/sidecars.rake`, `test/tasks/sidecars_tasks_test.rb`.
Modify `test/compose_hygiene_test.rb`, `test/deploy_hygiene_test.rb` (the OVH test's count only).

- [ ] **Step 1: `test/sidecar_hygiene_test.rb`:**

```ruby
require "test_helper"

# EVERY SIDECAR HAS EVERY TOUCHPOINT, AND NO CONFIG NAMES A SIDECAR THAT IS NOT THERE.
# Tinkerex::Sidecars is the definition; this asserts it of the real tree, so a hand-added sidecar
# that skips one of the eight edits fails bin/ci with the exact snippet to add.
class SidecarHygieneTest < ActiveSupport::TestCase
  test "every sidecar is complete and nothing is stray" do
    sidecars = Tinkerex::Sidecars.new
    assert_not_empty sidecars.names, "no sidecar/*/Dockerfile — this guard would pass over nothing (§14e)"
    problems = sidecars.problems
    assert problems.empty?, problems.map { |p| "#{p.sidecar}: #{p.file} is missing #{p.missing}; add:\n#{p.snippet}" }.join("\n")
  end
end
```

- [ ] **Step 2: `lib/tasks/sidecars.rake`:**

```ruby
# The sidecar pre-publish check (Tinkerex::Sidecars): every sidecar/<name>/ has all eight
# touchpoints and nothing names a sidecar that is not there. bin/publish-sidecar runs it.
namespace :sidecars do
  desc "Check every sidecar has its deploy, compose, INSTALL and Help entries"
  task check: :environment do
    sidecars = Tinkerex::Sidecars.new
    problems = sidecars.problems
    unless problems.empty?
      abort problems.map { |p| "#{p.sidecar}: #{p.file} is missing #{p.missing}\n  add:\n#{p.snippet.gsub(/^/, '    ')}" }.join("\n")
    end
    puts "sidecars:check: #{sidecars.names.size} #{'sidecar'.pluralize(sidecars.names.size)} complete (#{sidecars.names.join(', ')})"
  end
end
```

- [ ] **Step 3: `test/tasks/sidecars_tasks_test.rb`:**

```ruby
require "test_helper"
require "rake"

# `bin/rails sidecars:check` — loading and re-enabling follow landing_tasks_test.rb: task definitions
# load once per process, and a task runs its action only once until re-enabled.
class SidecarsTasksTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("sidecars:check")
    Rake::Task["sidecars:check"].reenable
  end

  # The house stub helper (help_page_test.rb carries the same body; Minitest 6 has no Object#stub).
  def replacing(owner, name, replacement)
    mod = owner.singleton_class
    own = mod.instance_methods(false).include?(name)
    original = mod.instance_method(name)
    mod.define_method(name, &replacement)
    yield
  ensure
    own ? mod.define_method(name, original) : mod.remove_method(name)
  end

  test "the real tree is complete and says how many sidecars it checked" do
    stdout, _stderr = capture_io { Rake::Task["sidecars:check"].invoke }
    assert_match(/\Asidecars:check: \d+ sidecars? complete \(/, stdout)
  end

  test "a problem exits non-zero naming the file, what is missing, and the snippet to add" do
    problem = Tinkerex::Sidecars::Problem.new(sidecar: "openscad", file: "config/deploy.yml",
                                              missing: "env.clear X_SIDECAR_URL: y", snippet: "    X_SIDECAR_URL: y\n")
    fake = Struct.new(:problems, :names).new([ problem ], [ "openscad" ])
    replacing(Tinkerex::Sidecars, :new, ->(*) { fake }) do
      _stdout, stderr = capture_io do
        error = assert_raises(SystemExit) { Rake::Task["sidecars:check"].invoke }
        assert_not error.success?
      end
      assert_match(%r{^openscad: config/deploy\.yml is missing env\.clear X_SIDECAR_URL: y$}, stderr)
      assert_match(/^\s+X_SIDECAR_URL: y$/, stderr)
    end
  end
end
```

- [ ] **Step 4: Stop hard-coding the sidecar set.**
  - `test/compose_hygiene_test.rb`: `SERVICES = (%w[web addons] + Tinkerex::Sidecars.new.names).freeze`;
    rename "pulls four ghcr images" → "pulls one ghcr image per service"; "the three Tools images" →
    `(Tinkerex::Sidecars.new.names + %w[addons]).each`, renamed "every Tools image is pinned to amd64";
    replace the two literal `BOXES_`/`OPENSCAD_` env assertions with a loop over names asserting
    `env[s.env_key(n)] == s.compose_url(n)`. Keep every other assertion and comment.
  - `test/deploy_hygiene_test.rb` OVH test: replace `assert_equal 4, host_only_url_keys.size, …` with
    `assert_equal (Tinkerex::Sidecars.new.names.map { |n| Maker::Addons::Services.env_key_for(n) } + %w[ADDON_SOURCE_URL CHUNK_REMOTE_URL]).sort, host_only_url_keys.sort, …`.

- [ ] **Step 5: Run** `LIBRARY_PATH=$(mktemp -d) bin/rails test test/sidecar_hygiene_test.rb test/tasks/sidecars_tasks_test.rb test/compose_hygiene_test.rb test/deploy_hygiene_test.rb test/install_docs_test.rb` — green; and `bin/rails sidecars:check` prints `2 sidecars complete (boxes, openscad)`.

- [ ] **Step 6: Commit** (pathspec), message `sidecars:check and a bin/ci guard; compose and OVH tests derive the sidecar set`.

- [ ] **Step 7: Mutation-check** — after the commit: delete `OPENSCAD_SIDECAR_URL: ""` from
  `config/deploy.ovh.yml` → `sidecar_hygiene_test` AND the OVH test go red, and `bin/rails sidecars:check`
  exits 1 printing the snippet; add `  foo:\n    image: ghcr.io/chaim354/foo-sidecar:latest\n` under
  `docker-compose.yml` services → the hygiene test reports a stray. Restore with `git checkout --`.

---

## Task 4: Markers and the generator

After Task 1. Parallel with Task 3.

**Files:** Modify `config/deploy.yml`, `config/deploy.ovh.yml`, `docker-compose.yml`,
`docker-compose.build.yml` (one marker each, two in `deploy.yml` and `docker-compose.yml`),
`config/application.rb`. Create `lib/generators/sidecar/sidecar_generator.rb`,
`lib/generators/sidecar/templates/{Dockerfile.tt,app.py.tt,requirements.txt,README.md.tt}`,
`test/lib/generators/sidecar_generator_test.rb`.

- [ ] **Step 1: Keep generators out of autoload.** `config/application.rb`:
  `config.autoload_lib(ignore: %w[assets tasks generators library_backend.rb])`. Without it production
  EAGER-LOADS `lib/generators/sidecar/sidecar_generator.rb`, where `Rails::Generators` is not loaded —
  a boot crash. Verify: `bin/rails zeitwerk:check` → "All is good!".

- [ ] **Step 2: Markers** — insert each marker line from `Tinkerex::Sidecars::MARKERS`, at the
  indentation shown, exactly once:
  - `config/deploy.yml` env.clear: the line after `OPENSCAD_SIDECAR_URL: http://tinkerex-openscad:8000` (4 spaces).
  - `config/deploy.yml` accessories: after the openscad accessory block (its volumes), before the `addons` accessory's comment (2 spaces).
  - `config/deploy.ovh.yml`: the line after `OPENSCAD_SIDECAR_URL: ""` (4 spaces).
  - `docker-compose.yml` web environment: the line after `OPENSCAD_SIDECAR_URL: http://openscad:8000` (6 spaces).
  - `docker-compose.yml` services: after the openscad service block, before `addons:` (2 spaces).
  - `docker-compose.build.yml`: after the openscad build entry, before `addons:` (2 spaces).
  Markers contain no ERB tag (Kamal runs deploy*.yml through ERB, comments included). Then
  `LIBRARY_PATH=$(mktemp -d) bin/rails test test/compose_hygiene_test.rb test/deploy_hygiene_test.rb test/lib/sidecars_test.rb` stays green (comments are YAML-neutral).

- [ ] **Step 3: Write the failing generator test** — `test/lib/generators/sidecar_generator_test.rb`:

```ruby
require "test_helper"
require "rails/generators/test_case"
require "generators/sidecar/sidecar_generator"

# Runs the generator over a TEMP COPY of the real touchpoint files (and the existing sidecars'
# Dockerfiles), never the repo itself. EACH TEST GETS ITS OWN DESTINATION: the suite forks parallel
# workers by test method, and a shared tmp/generators dir would race.
class SidecarGeneratorTest < Rails::Generators::TestCase
  tests SidecarGenerator

  setup do
    self.class.destination_root = Dir.mktmpdir
    (Tinkerex::Sidecars::FILES.values + Rails.root.glob("sidecar/*/Dockerfile").map { |p| p.relative_path_from(Rails.root).to_s })
      .each do |rel|
        FileUtils.mkdir_p(File.dirname(File.join(destination_root, rel)))
        FileUtils.cp(Rails.root.join(rel), File.join(destination_root, rel))
      end
    @license = File.join(destination_root, "UPSTREAM_LICENSE")
    File.write(@license, "GNU GENERAL PUBLIC LICENSE (test)\n")
    @originals = Tinkerex::Sidecars::FILES.values.to_h { |rel| [ rel, File.binread(File.join(destination_root, rel)) ] }
  end

  teardown { FileUtils.rm_rf(destination_root) }

  def sidecars = Tinkerex::Sidecars.new(root: destination_root)

  test "generates a complete sidecar: scaffold, config, and no problems" do
    run_generator [ "foo", "--license", @license ]
    %w[Dockerfile app.py requirements.txt README.md LICENSE].each { |f| assert_file "sidecar/foo/#{f}" }
    assert_file("sidecar/foo/LICENSE") { |c| assert_equal "GNU GENERAL PUBLIC LICENSE (test)\n", c }
    assert_file("sidecar/foo/Dockerfile") { |c| assert_match(/^COPY .*LICENSE/, c); assert_match(%r{> /revision}, c) }
    assert_includes sidecars.names, "foo"
    assert_equal [], sidecars.problems
  end

  test "destroy restores every touchpoint file byte-for-byte and removes the directory" do
    run_generator [ "foo", "--license", @license ]
    run_generator [ "foo", "--license", @license ], behavior: :revoke
    @originals.each { |rel, bytes| assert_equal bytes, File.binread(File.join(destination_root, rel)), rel }
    assert_no_file "sidecar/foo/Dockerfile"
  end

  test "refuses a bad name, an existing sidecar, and a missing licence — writing nothing" do
    [ [ "Foo", @license ], [ "boxes", @license ], [ "foo", "/nonexistent/LICENSE" ] ].each do |name, license|
      assert_raises(SystemExit) { capture(:stderr) { run_generator [ name, "--license", license ] } }
      @originals.each { |rel, bytes| assert_equal bytes, File.binread(File.join(destination_root, rel)), "#{name}: #{rel}" }
      assert_no_file "sidecar/#{name.downcase}/app.py" unless name == "boxes"
    end
  end

  test "refuses when any insertion marker is missing — writing nothing" do
    path = File.join(destination_root, "docker-compose.build.yml")
    File.write(path, File.read(path).sub(/^ *# bin\/rails generate sidecar inserts sidecar builds above this line\n/, ""))
    snapshot = Tinkerex::Sidecars::FILES.values.to_h { |rel| [ rel, File.binread(File.join(destination_root, rel)) ] }
    assert_raises(SystemExit) { capture(:stderr) { run_generator [ "foo", "--license", @license ] } }
    snapshot.each { |rel, bytes| assert_equal bytes, File.binread(File.join(destination_root, rel)), rel }
    assert_no_file "sidecar/foo/Dockerfile"
  end
end
```

  Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/lib/generators/sidecar_generator_test.rb` → `LoadError` / `NameError`.

- [ ] **Step 4: Implement** — `lib/generators/sidecar/sidecar_generator.rb`:

```ruby
require "rails/generators"

# `bin/rails generate sidecar <name> --license <upstream LICENSE>` — scaffolds sidecar/<name>/ and
# inserts every touchpoint a sidecar needs, then asks Tinkerex::Sidecars whether anything is missing.
# The YAML it inserts IS Tinkerex::Sidecars#snippets — the text the guard prints — so the generator
# and the guard cannot disagree about what complete means. `bin/rails destroy sidecar <name>`
# reverses every insert.
#
# ALL REFUSALS COME BEFORE THE FIRST WRITE (Thor runs public methods in definition order): a bad
# name, an existing sidecar, a missing licence, and any marker or prose anchor not present exactly
# once. A half-inserted config is worse than none.
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
    raise Thor::Error, "sidecar name #{sidecar_name.inspect} must be lowercase letters, digits and dashes, starting with a letter" unless sidecar_name.match?(/\A[a-z][a-z0-9-]*\z/)
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
  end

  def scaffold
    dir = "sidecar/#{sidecar_name}"
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
    inject_into_file Tinkerex::Sidecars::FILES[:install], ", `#{sidecars.compose_url(sidecar_name)}`", after: INSTALL_URLS
    inject_into_file Tinkerex::Sidecars::FILES[:help], ", #{snippets[:help]}", after: HELP_VARS
  end

  def verify_and_explain
    return if behavior == :revoke

    problems = sidecars.problems
    unless problems.empty?
      raise Thor::Error, "generated, but Tinkerex::Sidecars still reports:\n" +
                         problems.map { |p| "  #{p.sidecar}: #{p.file} is missing #{p.missing}" }.join("\n")
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

  def sidecars = @sidecars ||= Tinkerex::Sidecars.new(root: destination_root)
  def read(rel) = File.read(File.join(destination_root, rel))
  def marker_line(marker) = /^ *#{Regexp.escape(marker)}\n/
end
```

  `inject_into_file` on `:revoke` removes exactly the injected text, which is what makes `destroy`
  byte-identical; the destroy test is the proof, so if it fails, report the diff rather than
  loosening the assertion.

- [ ] **Step 5: Templates** in `lib/generators/sidecar/templates/`:

`Dockerfile.tt`:
```dockerfile
# The <%= sidecar_name %> sidecar — a SEPARATE image from the Rails app, built and pushed by
# `bin/publish-sidecar <%= sidecar_name %>`. The app never links it (CLAUDE.md §9).
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ./
# The upstream licence travels INSIDE the image: pushing to a registry is redistribution.
COPY LICENSE README.md ./
# WHICH BUILD IS RUNNING, read back through `kamal accessory exec` by bin/publish-sidecar. Late, so a
# new revision invalidates only this layer.
ARG SIDECAR_REVISION=unknown
RUN printf '%s\n' "$SIDECAR_REVISION" > /revision
EXPOSE 8000
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "2", "--timeout", "60", "app:app"]
```

`app.py.tt`:
```python
"""The <%= sidecar_name %> sidecar, scaffolded by `bin/rails generate sidecar`.

A SEPARATE process the Tinkerex app reaches over HTTP through its service proxy — never a library it
links; this is where GPL code runs (CLAUDE.md §9). An addon reaches it by declaring
"services": ["<%= sidecar_name %>"] in its manifest and calling
host.service.post("<%= sidecar_name %>", "render", {...}) — the proxy forwards a JSON body.
"""
from flask import Flask, jsonify, request

app = Flask(__name__)


@app.get("/up")
def up():
    return "ok", 200, {"Content-Type": "text/plain"}


@app.post("/render")
def render():
    params = request.get_json(silent=True)
    if not isinstance(params, dict):
        return error(400, "bad_request", "send a JSON object")
    text = params.get("text")
    if not isinstance(text, str):
        # A refused VALUE is 422 with a machine `code` a bundle branches on — never the prose, which
        # a release may reword (docs/invariants/addons.md).
        return error(422, "invalid_params", "text must be a string")
    return jsonify({"result": text.upper()})


def error(status, code, message):
    return jsonify({"error": message[:200], "code": code}), status
```

`requirements.txt`:
```
flask==3.0.*
gunicorn==22.0.*
```

`README.md.tt`:
```markdown
# <%= sidecar_name %>-sidecar

A **GPL** service the Tinkerex app reaches only over HTTP, on the internal network. It wraps
<!-- name and link the upstream project, and its licence -->. `LICENSE` is the upstream licence; the
image carries it, because pushing an image is redistribution (CLAUDE.md §9).

- `GET /up` — health (`ok`).
- `POST /render` `{text}` — the scaffold's example; replace it.

Errors are `{"error": <prose>, "code": <machine code>}`; a refused value is **422** with
`code: "invalid_params"`. A bundle branches on `code`, never the prose.

An addon reaches it with `"services": ["<%= sidecar_name %>"]` in its manifest and
`host.service.post("<%= sidecar_name %>", "render", {...})`.

Deploy: `bin/publish-sidecar <%= sidecar_name %>` (from the tinkerex repo root).
```

- [ ] **Step 6: Run the generator test — green.** Then drive it for real in a scratch copy, never the
  repo: `bin/rails generate sidecar foo --license sidecar/boxes/LICENSE --pretend` from the repo root
  (pretend writes nothing) and report its output; then `git status --porcelain` must show only this
  task's files.

- [ ] **Step 7: Commit** (pathspec), message `bin/rails generate sidecar: scaffold a sidecar and insert every touchpoint, at markers`.

- [ ] **Step 8: Mutation-check** — after the commit: drop the marker-count check → the
  missing-marker test goes red (it writes); drop `insert_config`'s compose_build line → the
  "complete" test goes red; make `create_file LICENSE` write `""` → red. Restore with `git checkout --`;
  report each output.

---

## Task 5: `bin/publish-sidecar` and the docs

After Tasks 2, 3 and 4.

**Files:** Create `bin/publish-sidecar`. Modify `docs/DEPLOY.md` (the "Box Generator sidecar" and
"Which build is a sidecar accessory running?" sections), `docs/invariants/addons.md`.

- [ ] **Step 1: `bin/publish-sidecar`** (`chmod +x`):

```bash
#!/usr/bin/env bash
# ONE COMMAND FROM "I CHANGED A SIDECAR" TO "IT IS LIVE". Stops at the first failure:
#
#   1. bin/rails sidecars:check — every touchpoint present (Tinkerex::Sidecars), nothing stray.
#   2. bin/secrets-preflight — kamal expands secrets through Ruby backticks, which discard exit status,
#      so an unreadable one becomes EMPTY silently (docs/invariants/deploy-secrets.md).
#   3. bin/build-sidecar <name> — build + push, stamping the label and /revision.
#   4. BOOT the first time, REBOOT after — decided by whether `kamal accessory exec --reuse` reaches a
#      running container. A network failure fails the probe too; boot then fails as well, loudly.
#   5. VERIFY /revision equals the revision just pushed (a ghcr tag move once silently reverted and a
#      reboot redeployed the old image while reporting success, 2026-10-07) and /up answers ok.
#
# On a FIRST boot the three app legs must be redeployed to carry <NAME>_SIDECAR_URL; this prints that
# and does not do it — a three-destination deploy is its own decision.
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -eq 1 ] || { echo "usage: bin/publish-sidecar <name>" >&2; exit 2; }
NAME="$1"

echo "==> 1/5 checking sidecars"
bin/rails sidecars:check

echo "==> 2/5 preflighting secrets"
bin/secrets-preflight

REVISION="$(bin/build-sidecar --revision "$NAME")"
echo "==> 3/5 building and pushing $REVISION"
bin/build-sidecar "$NAME"

echo "==> 4/5 rolling the $NAME accessory"
if bin/kamal accessory exec "$NAME" --reuse -q true >/dev/null 2>&1; then
  first=no
  bin/kamal accessory reboot "$NAME"
else
  first=yes
  bin/kamal accessory boot "$NAME"
fi

echo "==> 5/5 verifying what is running"
# Only the revision is kept; a miss prints NOTHING from the buffer (how this repo has leaked before).
running="$(bin/kamal accessory exec "$NAME" --reuse -q "cat /revision" 2>/dev/null \
  | grep -oE '[0-9a-f]{40}(-dirty)?' | head -1 || true)"
if [ "$running" != "$REVISION" ]; then
  echo "publish-sidecar: $NAME is running '${running:-unreadable}', not $REVISION." >&2
  echo "  The registry tag may not have persisted (2026-10-07). Re-run — a fresh push persisted then." >&2
  exit 1
fi
up="$(bin/kamal accessory exec "$NAME" --reuse -q \
  "python -c \"import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/up',timeout=5).read().decode())\"" \
  2>/dev/null | grep -c '^ok$' || true)"
if [ "$up" -lt 1 ]; then
  echo "publish-sidecar: $NAME is running $REVISION but /up did not answer ok." >&2
  exit 1
fi
echo "==> live: tinkerex-$NAME is serving $REVISION."
if [ "$first" = yes ]; then
  echo "    FIRST BOOT: redeploy chunk_remote, share and s3 so the app carries the sidecar URL."
fi
```

- [ ] **Step 2: Hermetic verification** — never against the real box. Copy the repo's `bin/` into a
  scratch dir with stubs: `bin/rails` (prints and exits 0, or 1 to test step 1), `bin/secrets-preflight`,
  `bin/build-sidecar` (`--revision` prints a fixed SHA; build mode exits 0), and `bin/kamal` (the probe
  succeeds or fails per a flag file; `exec … cat /revision` prints the SHA or a different one;
  `exec … python …` prints `ok`). Report: success on reboot; success on first boot printing the
  FIRST BOOT line; exit 1 at each step when that stub fails, with no later stub called (log calls to a
  file); exit 1 on a revision mismatch and on `/up` not ok.

- [ ] **Step 3: Docs.** `docs/DEPLOY.md`: replace the "Box Generator sidecar" section with a
  "Sidecars" section — adding one (`bin/rails generate sidecar <name> --license <path>`, then the
  four next steps it prints), deploying one (`bin/publish-sidecar <name>` and its five steps), and
  provenance (the new `kamal accessory exec <name> --reuse "cat /revision"` reading first, then the
  existing `docker inspect` label reading, unchanged). `docs/invariants/addons.md`: one new bullet
  after the sidecar bullet at the top — `Tinkerex::Sidecars` is the one definition; the generator's
  snippets ARE its snippets; the six marker comments must stay (the generator refuses without them,
  and `bin/rails destroy` depends on exact inserts); sidecar URLs stay explicit — no convention
  fallback, and why (the OVH failure). Grep both files for `build-boxes-sidecar`,
  `build-openscad-sidecar`, "Both sidecar build scripts" and fix every live hit.

- [ ] **Step 4: Commit** (pathspec), message `bin/publish-sidecar: check, preflight, build, boot or reboot, verify /revision and /up`.

---

## Task 6: Close-out (orchestrator)

- [ ] Run bare `bin/ci`; read the three backend legs' run counts — identical (§15).
- [ ] `bin/rails sidecars:check` and `bin/rails zeitwerk:check` once more on the final tree.
- [ ] `/finish-branch` → PR; `bin/log arc --from-pr <n>`. State plainly that `bin/publish-sidecar`
  was verified hermetically only; a real run redeploys a live sidecar and needs the owner's go-ahead.
