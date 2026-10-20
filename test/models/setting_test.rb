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

  test "forget deletes the row and the memo" do
    Setting.put(KEY, "x")
    assert_equal "x", Setting.get(KEY)
    Setting.forget(KEY)

    assert_not Setting.exists?(key: KEY)
    assert_nil Setting.get(KEY)
  end

  # THE MEMO IS THE POINT: ApplicationController's library redirect asks on every signed-in request,
  # so a confirmed deployment must pay no query for it. Both halves: no query on the second read, and
  # a value changed BEHIND the memo's back (another process, here an update_all) is not seen until the
  # memo is dropped -- which is what tells a memo from a fast query.
  test "get is memoised: a second read runs no query and does not see a write behind its back" do
    Setting.put(KEY, "cached")
    assert_equal "cached", Setting.get(KEY)

    assert_queries_count(0) { Setting.get(KEY) }
    Setting.where(key: KEY).update_all(value: "changed elsewhere")
    assert_equal "cached", Setting.get(KEY)

    Setting.reset_cache!
    assert_equal "changed elsewhere", Setting.get(KEY)
  end

  # An absent key is memoised too, or every request on a pending deployment would query.
  test "an absent key is memoised as absent" do
    assert_nil Setting.get(KEY)
    assert_queries_count(0) { Setting.get(KEY) }
  end

  test "changed_at reads the row's updated_at" do
    travel_to Time.utc(2026, 10, 20, 9, 0, 0) do
      Setting.put(KEY, "x")
    end
    assert_equal Time.utc(2026, 10, 20, 9, 0, 0), Setting.changed_at(KEY)
    assert_nil Setting.changed_at("test.absent")
  end
end
