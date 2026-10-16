require "test_helper"
require "rake"

# `bin/rails "landing:wall[seed,out]"` -- loading and re-enabling follow tinkerex_tasks_test.rb: task
# definitions load once per process, and a task runs its action only once until re-enabled. Its
# directories are rake ARGUMENTS, never environment variables: install_docs_test.rb demands an
# INSTALL.md row for any variable lib/tasks reads, and these two are not an installer's business.
class LandingTasksTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("landing:wall")
    Rake::Task["landing:wall"].reenable
  end

  test "landing:wall stops with the reason when a tile cannot be rendered, and writes nothing" do
    Dir.mktmpdir do |seed|
      Dir.mktmpdir do |out|
        _stdout, stderr = capture_io do
          assert_raises(SystemExit) { Rake::Task["landing:wall"].invoke(seed, out) }
        end
        assert_match(/landing:wall: .+ is not in /, stderr)
        assert_empty Dir.children(out)
      end
    end
  end
end
