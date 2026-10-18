require "test_helper"
require "rails/generators/test_case"
require "generators/sidecar/sidecar_generator"

# Runs the generator over a TEMP COPY of the real touchpoint files (and the existing sidecars'
# Dockerfiles), never the repo itself. EACH TEST GETS ITS OWN DESTINATION: the suite forks parallel
# workers by test method, and a shared tmp/generators dir would race.
class SidecarGeneratorTest < Rails::Generators::TestCase
  tests SidecarGenerator

  setup do
    # `foo` (and `bar`, sidecars_test.rb's other one) are SCRATCH names: every real sidecar is
    # copied in below, so a real sidecar/foo/ would fail these tests for an unrelated reason. Say so.
    %w[foo bar].each do |scratch|
      assert_not Rails.root.join("sidecar", scratch).exist?,
                 "sidecar/#{scratch}/ now exists for real, but these tests use `#{scratch}` as a scratch name that must " \
                 "not — pick other scratch names in #{__FILE__}"
    end
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

  # THE SUCCESS PATH RAISES INSTEAD OF EXITING. Without `debug:`, Thor answers a Thor::Error with
  # exit(false), and SystemExit is a Minitest PASSTHROUGH: a broken generator ends the whole run —
  # or one parallel worker — with no failure reported (measured). The refusal tests below keep the
  # CLI path on purpose, because exit 1 is what a refusal must do.
  def generate(**config) = run_generator([ "foo", "--license", @license ], debug: true, **config)

  test "generates a complete sidecar: scaffold, config, and no problems" do
    generate
    %w[Dockerfile app.py requirements.txt README.md LICENSE].each { |f| assert_file "sidecar/foo/#{f}" }
    assert_file("sidecar/foo/LICENSE") { |c| assert_equal "GNU GENERAL PUBLIC LICENSE (test)\n", c }
    assert_file("sidecar/foo/Dockerfile") { |c| assert_match(/^COPY .*LICENSE/, c); assert_match(%r{> /revision}, c) }
    assert_includes sidecars.names, "foo"
    assert_equal [], sidecars.problems
  end

  # --pretend WRITES NOTHING, so the completeness check would find no sidecar/foo/ to judge and say
  # "complete" about a sidecar that does not exist. It must say nothing was checked instead.
  test "--pretend writes nothing and does not claim the sidecar is complete" do
    output = run_generator([ "foo", "--license", @license, "--pretend" ], debug: true)
    assert_no_file "sidecar/foo/Dockerfile"
    @originals.each { |rel, bytes| assert_equal bytes, File.binread(File.join(destination_root, rel)), rel }
    assert_match(/nothing was written, so nothing was checked/, output)
    assert_no_match(/is complete/, output)
  end

  test "destroy restores every touchpoint file byte-for-byte and removes the directory" do
    generate
    generate(behavior: :revoke)
    @originals.each { |rel, bytes| assert_equal bytes, File.binread(File.join(destination_root, rel)), rel }
    assert_no_file "sidecar/foo/Dockerfile"
    # The directory itself, not just its files: an empty sidecar/foo/ makes the next `generate foo`
    # refuse as "already exists".
    assert_no_directory "sidecar/foo"
  end

  test "refuses a bad name, an existing sidecar, and a missing licence — writing nothing" do
    [ [ "Foo", @license ], [ "no", @license ], [ "boxes", @license ], [ "foo", "/nonexistent/LICENSE" ] ].each do |name, license|
      assert_raises(SystemExit) { capture(:stderr) { run_generator [ name, "--license", license ] } }
      @originals.each { |rel, bytes| assert_equal bytes, File.binread(File.join(destination_root, rel)), "#{name}: #{rel}" }
      assert_no_file "sidecar/#{name.downcase}/app.py" unless name == "boxes"
    end
  end

  # YAML KEEPS THE LAST OF TWO DUPLICATE KEYS, SILENTLY: a removed sidecar's leftover plus the
  # inserted copy passed every guard here — exit 0, "complete" — over a compose file `docker compose
  # config` refuses ("mapping key already defined"). The leftover's value must DIFFER from the
  # snippet's, or Thor skips the identical insert and no duplicate is ever written.
  test "refuses a name the config still mentions as a stray — writing nothing" do
    {
      "docker-compose.yml" => [ "      OPENSCAD_SIDECAR_URL: http://openscad:8000\n",
                                "      FOO_SIDECAR_URL: http://foo-old:8000\n", "FOO_SIDECAR_URL: stray" ],
      "config/deploy.yml" => [ "  # bin/rails generate sidecar inserts sidecar accessories above this line\n",
                               "  foo:\n    image: ghcr.io/chaim354/foo-sidecar:latest\n    host: old\n", "foo: stray" ]
    }.each do |rel, (anchor, leftover, named)|
      path = File.join(destination_root, rel)
      File.write(path, File.read(path).sub(anchor) { anchor + leftover })
      assert_includes File.read(path), leftover, "the leftover was not planted — the test would prove nothing"
      snapshot = Tinkerex::Sidecars::FILES.values.to_h { |r| [ r, File.binread(File.join(destination_root, r)) ] }

      stderr = capture(:stderr) { assert_raises(SystemExit) { run_generator [ "foo", "--license", @license ] } }
      assert_match(/remove/, stderr)
      assert_includes stderr, named
      snapshot.each { |r, bytes| assert_equal bytes, File.binread(File.join(destination_root, r)), "#{rel}: #{r}" }
      assert_no_file "sidecar/foo/Dockerfile"
      File.binwrite(path, @originals.fetch(rel))
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
