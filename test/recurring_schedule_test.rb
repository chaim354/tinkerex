require "test_helper"

# config/recurring.yml is loaded by the Solid Queue SUPERVISOR, not by the Rails process the suite
# boots — so a typo in a class name or a syntax error in a `command:` is invisible to every other
# test here and surfaces as a job that silently never runs, in production, at 5am. Same family as
# `deploy_hygiene_test.rb`: config the app never loads, guarded because nothing else can see it.
#
# Written when `dead_node_preview_reaper` was added, which is the first entry with a NAMESPACED
# class (`Maker::DeadNodeReaperJob`) — the shape most likely to be mistyped and the least likely to
# be noticed.
class RecurringScheduleTest < ActiveSupport::TestCase
  SCHEDULE = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production").freeze

  test "every scheduled class resolves to a real ActiveJob" do
    SCHEDULE.each do |name, entry|
      klass = entry["class"]
      next if klass.nil? # `command:` entries are checked below

      resolved = klass.safe_constantize
      assert resolved, "#{name}: `class: #{klass}` does not resolve to a constant"
      assert resolved < ActiveJob::Base, "#{name}: #{klass} is not an ActiveJob"
    end
  end

  # A `command:` is eval'd by the supervisor. It cannot be RUN here (these have real side effects),
  # but it can be parsed — which is what catches the typo, and it also pins that the constants it
  # names exist.
  test "every scheduled command parses and names constants that exist" do
    SCHEDULE.each do |name, entry|
      cmd = entry["command"]
      next if cmd.nil?

      assert_nothing_raised { RubyVM::InstructionSequence.compile(cmd) }
      cmd.scan(/\b(?:[A-Z]\w*::)*[A-Z]\w*/).uniq.each do |const|
        assert const.safe_constantize, "#{name}: `command:` names #{const}, which does not resolve"
      end
    end
  end

  test "every entry has exactly one of class/command, and a schedule" do
    SCHEDULE.each do |name, entry|
      assert_equal 1, [ entry["class"], entry["command"] ].compact.size,
                   "#{name}: needs exactly one of `class:` or `command:`"
      assert entry["schedule"].present?, "#{name}: has no `schedule:`"
    end
  end
end
