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
