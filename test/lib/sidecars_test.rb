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

  # A STRUCTURAL edit, for shapes a text substitution cannot reach (a map turned into a list, a
  # block turned into a scalar): parse, change, dump. The dump drops comments, which a temp copy
  # can afford — the checker reads only the data. The no-op guard compares DATA, because every
  # dump differs from the commented original and would satisfy a text comparison vacuously.
  def edit_yaml(root, rel)
    path = root.join(rel)
    data = YAML.safe_load(path.read, aliases: true)
    before = YAML.dump(data)
    yield data
    after = YAML.dump(data)
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

  # TWO problems, not one: the wrong context is also a build of a sidecar/elsewhere/ that does not
  # exist, which the build overlay's stray check reports in its own right.
  test "a build overlay entry building the wrong context is named" do
    with_tree do |root, sidecars|
      edit(root, "docker-compose.build.yml") { |t| t.sub("build: sidecar/openscad", "build: sidecar/elsewhere") }
      problems = sidecars.problems
      assert_equal [ [ "openscad", "docker-compose.build.yml" ], [ "elsewhere", "(stray)" ] ],
                   problems.map { |p| [ p.sidecar, p.file ] }, problems.map(&:to_h).inspect
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

  # Still TWO although five places now name openscad as a stray (deploy env, web env, OVH env,
  # accessory + compose service, build overlay): strays are one problem per stray NAME, and the
  # key and the service are the two names a removal leaves.
  test "a problem reads as one sentence, and a stray reads as a stray" do
    missing = Tinkerex::Sidecars::Problem.new(sidecar: "foo", file: "config/deploy.yml", missing: "env.clear X", snippet: "")
    stray = Tinkerex::Sidecars::Problem.new(sidecar: "foo", file: "(stray)", missing: "service foo has no sidecar/foo/", snippet: "")
    assert_equal "foo: config/deploy.yml is missing env.clear X", missing.message
    assert_equal "foo: stray — service foo has no sidecar/foo/", stray.message
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

  test "a stray accessory is found even when a compose service shares its name with a non-sidecar image" do
    with_tree do |root, sidecars|
      edit_yaml(root, "config/deploy.yml") { |d| d["accessories"]["bar"] = { "image" => sidecars.image("bar"), "host" => "h" } }
      edit_yaml(root, "docker-compose.yml") { |c| c["services"]["bar"] = { "image" => "postgres:16" } }
      p = only_problem(sidecars)
      assert_equal [ "bar", "(stray)" ], [ p.sidecar, p.file ]
      assert_match(/service bar/, p.missing)
    end
  end

  test "a stray accessory under a key YAML read as a boolean is still reported" do
    with_tree do |root, sidecars|
      edit_yaml(root, "config/deploy.yml") { |d| d["accessories"][false] = { "image" => sidecars.image("no"), "host" => "h" } }
      p = only_problem(sidecars)
      assert_equal [ false, "(stray)" ], [ p.sidecar, p.file ]
    end
  end

  test "a leftover URL in the OVH overlay is a stray" do
    with_tree do |root, sidecars|
      edit(root, "config/deploy.ovh.yml") { |t| t.sub(%(OPENSCAD_SIDECAR_URL: ""\n), %(OPENSCAD_SIDECAR_URL: ""\n    FOO_SIDECAR_URL: ""\n)) }
      p = only_problem(sidecars)
      assert_equal [ "FOO_SIDECAR_URL", "(stray)" ], [ p.sidecar, p.file ]
    end
  end

  test "a build overlay entry building a sidecar directory that does not exist is a stray" do
    with_tree do |root, sidecars|
      edit(root, "docker-compose.build.yml") { |t| t.sub("    build: sidecar/openscad\n", "    build: sidecar/openscad\n  bar:\n    image: bar-sidecar:local\n    build: sidecar/bar\n") }
      p = only_problem(sidecars)
      assert_equal [ "bar", "(stray)" ], [ p.sidecar, p.file ]
      assert_match(%r{sidecar/bar}, p.missing)
    end
  end

  test "a build overlay entry naming the directory as a context: is a stray too" do
    with_tree do |root, sidecars|
      edit_yaml(root, "docker-compose.build.yml") { |c| c["services"]["bar"] = { "build" => { "context" => "sidecar/bar" } } }
      p = only_problem(sidecars)
      assert_equal [ "bar", "(stray)" ], [ p.sidecar, p.file ]
    end
  end

  # MALFORMED CONFIG IS ANSWERED, NEVER RAISED: the guard is what tells you the config is wrong, so
  # a shape it did not expect must come back as problems, not a TypeError out of bin/ci.
  { deploy: 2, ovh: 1, compose: 2, compose_build: 1 }.each do |file, per_sidecar|
    rel = Tinkerex::Sidecars::FILES.fetch(file)
    { "a list" => "- a\n- b\n", "a string" => "hello\n" }.each do |shape, body|
      test "#{rel} parsing to #{shape} is every one of its touchpoints missing, not an exception" do
        with_tree do |root, sidecars|
          edit(root, rel) { body }
          problems = sidecars.problems
          assert_kind_of Array, problems
          assert_equal [ rel ], problems.map(&:file).uniq, problems.map(&:to_h).inspect
          assert_equal per_sidecar * sidecars.names.size, problems.size, problems.map(&:to_h).inspect
        end
      end
    end

    test "a YAML syntax error in #{rel} still raises, and names the file" do
      with_tree do |root, sidecars|
        edit(root, rel) { |t| t + "\nbroken: [unclosed\n" }
        error = assert_raises(Psych::SyntaxError) { sidecars.problems }
        assert_includes error.message, "(#{rel})"
      end
    end
  end

  test "a sidecar's own accessory as a scalar is that accessory missing" do
    with_tree do |root, sidecars|
      edit_yaml(root, "config/deploy.yml") { |d| d["accessories"]["openscad"] = "oops" }
      p = only_problem(sidecars)
      assert_equal [ "openscad", "config/deploy.yml" ], [ p.sidecar, p.file ]
      assert_match(/accessory openscad/, p.missing)
    end
  end

  test "a sidecar's own compose service as a scalar is that service missing" do
    with_tree do |root, sidecars|
      edit_yaml(root, "docker-compose.yml") { |c| c["services"]["openscad"] = "oops" }
      p = only_problem(sidecars)
      assert_equal [ "openscad", "docker-compose.yml" ], [ p.sidecar, p.file ]
      assert_match(/service openscad/, p.missing)
    end
  end

  test "accessories as a list is every accessory missing" do
    with_tree do |root, sidecars|
      edit_yaml(root, "config/deploy.yml") { |d| d["accessories"] = d["accessories"].keys }
      problems = sidecars.problems
      assert_kind_of Array, problems
      assert_equal sidecars.names.map { |n| [ n, "config/deploy.yml", "accessory #{n}" ] },
                   problems.map { |p| [ p.sidecar, p.file, p.missing[/\Aaccessory \S+/] ] }
    end
  end

  test "deploy env.clear as a list is every URL missing" do
    with_tree do |root, sidecars|
      edit_yaml(root, "config/deploy.yml") { |d| d["env"]["clear"] = d["env"]["clear"].keys }
      assert_equal sidecars.names.map { |n| [ n, "config/deploy.yml", true ] },
                   sidecars.problems.map { |p| [ p.sidecar, p.file, p.missing.start_with?("env.clear") ] }
    end
  end

  test "deploy env as a bare string is every URL missing" do
    with_tree do |root, sidecars|
      edit_yaml(root, "config/deploy.yml") { |d| d["env"] = "hello" }
      assert_equal sidecars.names.map { |n| [ n, "config/deploy.yml", true ] },
                   sidecars.problems.map { |p| [ p.sidecar, p.file, p.missing.start_with?("env.clear") ] }
    end
  end

  test "OVH env.clear as a list is every blank missing" do
    with_tree do |root, sidecars|
      edit_yaml(root, "config/deploy.ovh.yml") { |d| d["env"]["clear"] = d["env"]["clear"].keys }
      assert_equal sidecars.names.map { |n| [ n, "config/deploy.ovh.yml" ] },
                   sidecars.problems.map { |p| [ p.sidecar, p.file ] }
    end
  end

  # `- KEY=value` is valid compose syntax for the same environment, so it must read as the same
  # answer — no problems — not merely avoid raising.
  test "a compose web environment in list form reads as the equivalent map" do
    with_tree do |root, sidecars|
      edit_yaml(root, "docker-compose.yml") do |c|
        c["services"]["web"]["environment"] = c["services"]["web"]["environment"].map { |k, v| "#{k}=#{v}" }
      end
      assert_equal [], sidecars.problems
    end
  end

  # A sidecar named `no` becomes a `false:` KEY the moment its snippet is inserted, so its eight
  # checks could never pass — the only fix is a different name.
  test "valid_name? is the generator's rule minus every name YAML reads back as something else" do
    %w[openscad foo-bar boxes2].each { |n| assert Tinkerex::Sidecars.valid_name?(n), n }
    %w[no on null].each { |n| assert_not Tinkerex::Sidecars.valid_name?(n), n }
    %w[Foo foo_bar 1x -x].each { |n| assert_not Tinkerex::Sidecars.valid_name?(n), n }
  end

  test "a sidecar directory YAML cannot keep as a string is one problem: rename it" do
    with_tree do |root, sidecars|
      %w[no on null].each do |n|
        root.join("sidecar/#{n}").mkpath
        root.join("sidecar/#{n}/Dockerfile").write("FROM scratch\n")
      end
      problems = sidecars.problems
      assert_equal [ [ "no", "sidecar/no/" ], [ "null", "sidecar/null/" ], [ "on", "sidecar/on/" ] ],
                   problems.map { |p| [ p.sidecar, p.file ] }, problems.map(&:to_h).inspect
      problems.each { |p| assert_match(/a name YAML keeps as a string — rename the directory/, p.missing) }
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
