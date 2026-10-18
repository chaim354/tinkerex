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

  # Runs the task over a fake whose `problems` are these, and answers its stderr.
  def check_failing_with(*problems)
    fake = Struct.new(:problems, :names).new(problems, [ "openscad" ])
    stderr = nil
    replacing(Tinkerex::Sidecars, :new, ->(*) { fake }) do
      _stdout, stderr = capture_io do
        error = assert_raises(SystemExit) { Rake::Task["sidecars:check"].invoke }
        assert_not error.success?
      end
    end
    stderr
  end

  # THE SNIPPET IS PRINTED EXACTLY AS IT PASTES. It already carries its file's own indentation, so
  # any display prefix on top of it makes a verbatim paste fail to parse — deploy.yml with "did not
  # find expected key", docker-compose.yml in docker's parser (found by pasting it, 2026-10-18).
  test "a problem exits non-zero naming the file and what is missing, with the snippet byte-for-byte" do
    snippets = Tinkerex::Sidecars.new.snippets("openscad")
    accessory = Tinkerex::Sidecars::Problem.new(sidecar: "openscad", file: "config/deploy.yml",
                                                missing: "accessory openscad", snippet: snippets.fetch(:deploy_accessory))
    env = Tinkerex::Sidecars::Problem.new(sidecar: "openscad", file: "docker-compose.yml",
                                          missing: "web environment OPENSCAD_SIDECAR_URL", snippet: snippets.fetch(:compose_env))
    stderr = check_failing_with(accessory, env)
    assert_match(%r{^openscad: config/deploy\.yml is missing accessory openscad$}, stderr)
    assert_match(%r{^openscad: docker-compose\.yml is missing web environment OPENSCAD_SIDECAR_URL$}, stderr)
    assert_includes stderr, "\n  add exactly this to config/deploy.yml, directly above its marker if it has one:\n#{accessory.snippet}"
    assert_includes stderr, "\n  add exactly this to docker-compose.yml, directly above its marker if it has one:\n#{env.snippet}"
  end

  # A stray's and a misnamed directory's snippet is an INSTRUCTION, not text for a file.
  test "a stray and a misnamed directory print fix:, not text to add" do
    stray = Tinkerex::Sidecars::Problem.new(sidecar: "zed", file: "(stray)", missing: "ZED_SIDECAR_URL names no sidecar/<name>/",
                                            snippet: "remove it everywhere, or add sidecar/<name>/")
    misnamed = Tinkerex::Sidecars::Problem.new(sidecar: "no", file: "sidecar/no/", missing: "a name YAML keeps as a string",
                                               snippet: "git mv sidecar/no sidecar/<new-name>")
    stderr = check_failing_with(stray, misnamed)
    assert_match(%r{^zed: stray — ZED_SIDECAR_URL names no sidecar/<name>/\n  fix: remove it everywhere, or add sidecar/<name>/$}, stderr)
    assert_match(%r{^no: sidecar/no/ is missing a name YAML keeps as a string\n  fix: git mv sidecar/no sidecar/<new-name>$}, stderr)
    assert_no_match(/^  add/, stderr)
  end
end
