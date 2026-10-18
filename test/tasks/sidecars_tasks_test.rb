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
