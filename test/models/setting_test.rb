require "test_helper"

# Deployment-wide settings (K, 2026-10-20): one row per key, read through a per-process memo.
class SettingTest < ActiveSupport::TestCase
  KEY = "test.example".freeze

  test "get answers nil for an absent key and the value for a present one" do
    assert_nil Setting.get(KEY)
    Setting.put(KEY, "a value")
    assert_equal "a value", Setting.get(KEY)
  end

  test "put writes one row and updates it in place, and get sees the new value" do
    Setting.put(KEY, "first")
    assert_equal "first", Setting.get(KEY)
    Setting.put(KEY, "second")

    assert_equal 1, Setting.where(key: KEY).count
    assert_equal "second", Setting.get(KEY), "put must drop the memo, or the old value is served forever"
  end

  test "forget deletes the row and its cached value" do
    Setting.put(KEY, "x")
    assert_equal "x", Setting.get(KEY)
    Setting.forget(KEY)

    assert_not Setting.exists?(key: KEY)
    assert_nil Setting.get(KEY)
  end

  # THE CACHE LASTS ONE REQUEST OR ONE JOB, AND NO LONGER. Within one, a second read runs no query and
  # does not see a write made behind its back (that is what tells a cache from a fast query); once
  # Current is cleared -- which the executor does around every request and every job, in every process
  # -- the next read sees it. That second half is the fix for a process-wide memo, which Solid Queue's
  # FORKED workers never had cleared (app/models/setting.rb). Mutation-checked: memoise in a class
  # ivar instead and the last assertion reads "cached".
  test "a read is cached for the request or job, and the next one sees a write made elsewhere" do
    Setting.put(KEY, "cached")
    assert_equal "cached", Setting.get(KEY)

    assert_queries_count(0) { Setting.get(KEY) }
    Setting.where(key: KEY).update_all(value: "changed elsewhere")
    assert_equal "cached", Setting.get(KEY)

    Current.reset
    assert_equal "changed elsewhere", Setting.get(KEY)
  end

  # An absent key is cached too, or every port call on a pending deployment would query.
  test "an absent key is cached as absent" do
    assert_nil Setting.get(KEY)
    assert_queries_count(0) { Setting.get(KEY) }
  end

  test "a cached value is frozen, so no caller can edit what the next one is handed" do
    Setting.put(KEY, "x")
    assert_predicate Setting.get(KEY), :frozen?
  end

  test "changed_at reads the row's updated_at" do
    travel_to Time.utc(2026, 10, 20, 9, 0, 0) do
      Setting.put(KEY, "x")
    end
    assert_equal Time.utc(2026, 10, 20, 9, 0, 0), Setting.changed_at(KEY)
    assert_nil Setting.changed_at("test.absent")
  end
end
