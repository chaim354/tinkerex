require "test_helper"
require "yaml"

# THE COMPOSE GENERATOR'S TEMPLATE IS docker-compose.yml, DERIVED AT RENDER TIME (2026-10-21; plan
# docs/superpowers/plans/2026-10-21-compose-generator.md). These tests hold the DERIVATION honest; the
# browser half (test/system/compose_generator_test.rb) holds the OUTPUT to the file. Every test here
# reads the real file, so a change to docker-compose.yml that the derivation no longer understands
# fails here first, naming the line, rather than reaching a visitor as a wrong file.
#
# MUTATION-CHECKED (§15), each run red and restored: not recording the generator markers (the
# comment count goes red), owning a closing comment by the open sequence item (`ind <= at`: the
# share derivation raises, finding no example), and accepting a service the app does not reach (the
# refusal test goes red). So do the three later refusals, each on its own fixture: any URL counting
# as a Tools key, an end-of-line comment accepted, a comment under a plain value accepted.
class ComposeTemplateTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("docker-compose.yml")

  def template(text = SOURCE.read) = Tinkerex::ComposeTemplate.new(text)

  def comment_lines(text) = text.lines.map(&:strip).select { |l| l.start_with?("#") }

  test "the tree is the file, with its ${VAR:-default} interpolations left for the browser to resolve" do
    t = template
    assert_equal YAML.safe_load(SOURCE.read), t.tree
    assert_equal "${TINKEREX_PORT:-8080}:80", t.tree.dig("services", "web", "ports", 0)
  end

  # NOTHING IS LOST: every comment line of the file lands in exactly one bucket. A comment the walk
  # dropped would vanish from every generated file with no error anywhere -- the derivation's quietest
  # failure, and the reason this counts lines rather than spot-checking a few.
  test "every comment line is the header, a key's leading comment, a block's closing comment, or a generator marker" do
    t = template
    expected = comment_lines(SOURCE.read)
    assert_operator expected.size, :>, 30, "the file has almost no comments; did it move?"
    got = t.header + t.leading.values.flatten + t.trailing.values.flatten + t.markers
    assert_equal expected.sort, got.sort
  end

  test "a comment belongs to the key it precedes, and one indented past the next key closes the block above" do
    t = template
    assert_match(/\A# The user the app runs as inside the container/, t.leading.fetch("services/web/environment/PUID").first)
    assert_match(/\A# The Tools gallery\. The two sidecars/, t.leading.fetch("services/boxes").first)
    assert_includes t.trailing.fetch("services/web/volumes"), "# - library:/library"
    assert_match(/\A# The network share behind/, t.trailing.fetch("volumes").first)
    t.leading.merge(t.trailing).each_key do |key|
      path = key.split("/").map { |seg| seg.match?(/\A\d+\z/) ? seg.to_i : seg }
      assert Tinkerex::ComposeTemplate.dig?(t.tree, path), "#{key} names no node of the tree"
    end
  end

  test "the bin/rails generate sidecar markers are instructions to a repo tool, never carried into a generated file" do
    t = template
    assert_equal Tinkerex::Sidecars::MARKERS.values.filter_map { |file, text| text if file == :compose }.sort, t.markers.sort
    refute t.leading.values.flatten.any? { |l| l.include?("bin/rails generate sidecar") }
  end

  test "the healthcheck's test list is the one flow sequence" do
    assert_equal [ "services/web/healthcheck/test" ], template.flow
  end

  # THE TOOLS SET IS READ OFF THE FILE, NEVER Tinkerex::Sidecars, because /sidecar/ is dockerignored
  # and `Sidecars#names` is [] in the image (sidecars.rb says so). Here, in a checkout, the two must
  # agree: that is the cross-check a request path cannot make.
  test "the Tools are the services the app reaches by URL, their env lines, and the volume only they mount" do
    tools = template.tools
    assert_equal (Tinkerex::Sidecars.new.names + %w[addons]).sort, tools[:services].sort
    sidecars = Tinkerex::Sidecars.new
    assert_equal (sidecars.names.map { sidecars.env_key(_1) } + %w[ADDON_SOURCE_URL]).sort, tools[:env].sort
    assert_equal %w[openscad_cache], tools[:volumes]
  end

  test "the network share is the commented library block, parsed back into the volume it describes" do
    share = template.share
    assert_equal "web", share[:service]
    assert_equal "/library", share[:target]
    assert_equal "library", share[:volume]
    assert_equal 1, share[:bind], "the bind mount is the second web volume"
    assert_equal "cifs", share.dig(:example, "driver_opts", "type")
    assert_equal "//192.168.1.50/Files", share.dig(:example, "driver_opts", "device")
    assert_match(/\Ausername=you,password=your-password,vers=3\.0,uid=1000,gid=1000,/, share.dig(:example, "driver_opts", "o"))
    assert_match(/\A# The network share behind/, share[:note].first)
    refute share[:note].any? { |l| l.match?(/\A# ?library:/) }, "the note stops where the commented example begins"
  end

  # A SHAPE THE WALK DOES NOT UNDERSTAND RAISES, NAMING THE LINE. Guessing would hand a visitor a file
  # with a comment in the wrong place or a service the Tools switch cannot remove.
  test "a file it cannot read the shape of is refused, never guessed at" do
    base = SOURCE.read
    refusals = {
      "a detached comment block" => base.sub("services:\n", "services:\n\n  # floating\n\n"),
      "a service the app does not reach" => base.sub("volumes:\n  tinkerex_storage", "  db:\n    image: postgres\n\nvolumes:\n  tinkerex_storage"),
      # Reached by URL, but not through a Tools key: switching the Tools off must not drop a database.
      "a service reached by a key that is not a Tools key" =>
        base.sub("volumes:\n  tinkerex_storage", "  db:\n    image: postgres\n\nvolumes:\n  tinkerex_storage")
            .sub("      ADDON_SOURCE_URL: http://addons\n", "      ADDON_SOURCE_URL: http://addons\n      DATABASE_URL: postgres://db:5432/x\n"),
      "an end-of-line comment" => base.sub("RAILS_MAX_THREADS: ${RAILS_MAX_THREADS:-16}\n", "RAILS_MAX_THREADS: ${RAILS_MAX_THREADS:-16}  # what the author runs\n"),
      "a comment under a plain value" => base.sub("      - tinkerex_storage:/rails/storage\n", "      - tinkerex_storage:/rails/storage\n        # the database\n"),
      "no network-share example" => base.sub(/  # library:\n(  #.*\n)+\z/, ""),
      "two library binds" => base.sub("      - ${LIBRARY_HOST_PATH:-.}:/library\n", "      - ${LIBRARY_HOST_PATH:-.}:/library\n      - ./x:/library\n")
    }
    refusals.each do |name, text|
      refute_equal base, text, "#{name}: the fixture edit did not apply"
      assert_raises(Tinkerex::ComposeTemplate::Error, name) { template(text) }
    end
  end
end
