require "test_helper"
require "rake"

# `bin/rails "addons:check[PATH]"` — loading and re-enabling follow landing_tasks_test.rb: task
# definitions load once per process, and a task runs its action only once until re-enabled.
class AddonsTasksTest < ActiveSupport::TestCase
  MANIFEST = {
    "key" => "widget", "title" => "Widget", "icon" => "🛠️", "description" => "Makes widgets",
    "api_version" => "1", "entry" => "widget.js"
  }.freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("addons:check")
    Rake::Task["addons:check"].reenable
  end

  def addons_dir(manifests, files: [ "widget/widget.js" ])
    Dir.mktmpdir do |root|
      File.write(File.join(root, "manifests.json"), JSON.generate(manifests))
      files.each { |rel| FileUtils.mkdir_p(File.dirname(File.join(root, rel))); File.write(File.join(root, rel), "") }
      yield root
    end
  end

  test "a clean directory prints how many tools are OK and exits normally" do
    addons_dir([ MANIFEST ]) do |root|
      stdout, _stderr = capture_io { Rake::Task["addons:check"].invoke(root) }
      assert_match(/addons:check: 1 tool OK in /, stdout)
    end
  end

  test "problems exit non-zero with one key: reason line each" do
    addons_dir([ MANIFEST.except("icon"), MANIFEST.merge("key" => "gadget", "title" => "Gadget") ]) do |root|
      _stdout, stderr = capture_io do
        error = assert_raises(SystemExit) { Rake::Task["addons:check"].invoke(root) }
        assert_not error.success?
      end
      assert_match(/^widget: missing icon$/, stderr)
      assert_match(%r{^gadget: no gadget/ directory beside manifests.json$}, stderr)
    end
  end

  test "an unreadable directory exits non-zero naming the problem" do
    _stdout, stderr = capture_io do
      assert_raises(SystemExit) { Rake::Task["addons:check"].invoke("/nonexistent/addons") }
    end
    assert_match(%r{addons:check: /nonexistent/addons is not a directory}, stderr)
  end

  test "with no PATH it reads ADDON_SOURCE_PATH" do
    addons_dir([ MANIFEST ]) do |root|
      prior = ENV["ADDON_SOURCE_PATH"]
      ENV["ADDON_SOURCE_PATH"] = root
      stdout, _stderr = capture_io { Rake::Task["addons:check"].invoke }
      assert_match(/1 tool OK in #{Regexp.escape(root)}/, stdout)
    ensure
      prior.nil? ? ENV.delete("ADDON_SOURCE_PATH") : ENV["ADDON_SOURCE_PATH"] = prior
    end
  end
end
