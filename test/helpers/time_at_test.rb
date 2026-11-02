require "test_helper"

# ApplicationHelper#time_at, the one way a timestamp reaches a page (UX audit D1), and #time_label,
# the same words as plain text for the History panel's JSON. Every case names its zone with
# Time.use_zone, so the expected strings hold on the UTC suite and on whatever box runs it.
class TimeAtTest < ActionView::TestCase
  include ApplicationHelper

  # 03:11:06 UTC on 2 November is 22:11:06 the evening BEFORE in New York -- the audit's own case,
  # where the date itself differs between the two zones.
  INSTANT = Time.utc(2026, 11, 2, 3, 11, 6)

  def in_new_york(&) = Time.use_zone("America/New_York", &)

  test ":absolute is the default: minute precision, ISO 8601 in the app's zone, the full time in title" do
    in_new_york do
      assert_dom_equal %(<time datetime="2026-11-01T22:11:06-05:00" title="2026-11-01 22:11:06 EST">2026-11-01 22:11</time>),
                       time_at(INSTANT)
    end
  end

  test ":date drops the time of day and keeps the full time in title" do
    in_new_york do
      assert_dom_equal %(<time datetime="2026-11-01T22:11:06-05:00" title="2026-11-01 22:11:06 EST">2026-11-01</time>),
                       time_at(INSTANT, style: :date)
    end
  end

  test ":relative says how long ago, and title says exactly when" do
    travel_to(INSTANT + 10.minutes) do
      in_new_york do
        assert_dom_equal %(<time datetime="2026-11-01T22:11:06-05:00" title="2026-11-01 22:11:06 EST">10 minutes ago</time>),
                         time_at(INSTANT, style: :relative)
        assert_equal "in 10 minutes", time_label(INSTANT + 20.minutes, style: :relative),
                     "a time ahead of the clock (a fast author clock on a commit) must not read as the past"
      end
    end
  end

  test "nil is an empty string, so a call site keeps its own placeholder" do
    assert_equal "", time_at(nil)
    assert_equal "", time_at(nil, style: :relative)
    assert_equal "", time_label(nil)
    assert_equal "—", time_at(nil).presence || "—"
  end

  test "datetime is the app's zone, whatever zone the value arrived in" do
    utc = INSTANT
    tokyo = INSTANT.getlocal("+09:00") # a process-local Time, as Time.at and Rugged hand out
    with_zone = INSTANT.in_time_zone("Asia/Tokyo")
    in_new_york do
      [ utc, tokyo, with_zone, INSTANT.to_datetime ].each do |value|
        html = time_at(value)
        assert_includes html, %(datetime="2026-11-01T22:11:06-05:00"), "#{value.class} #{value.inspect}"
        assert_includes html, ">2026-11-01 22:11<"
      end
    end
    Time.use_zone("UTC") { assert_includes time_at(tokyo), %(datetime="2026-11-02T03:11:06Z") }
  end

  test "a Date is a day: it prints the day in every style but :relative, with no title to add" do
    printed_on = Date.new(2026, 11, 2)
    in_new_york do
      assert_dom_equal %(<time datetime="2026-11-02">2026-11-02</time>), time_at(printed_on, style: :date)
      assert_dom_equal %(<time datetime="2026-11-02">2026-11-02</time>), time_at(printed_on)
    end
  end

  test "html attributes pass through, so a <time> that carried a class keeps it" do
    Time.use_zone("UTC") do
      assert_dom_equal %(<time class="entry-time muted" datetime="2026-11-02T03:11:06Z" title="2026-11-02 03:11:06 UTC">2026-11-02 03:11</time>),
                       time_at(INSTANT, class: "entry-time muted")
    end
  end

  # The style check runs BEFORE the nil shortcut: a typo at a nullable call site must fail on the
  # first render, not only once the column holds a value (T8 review).
  test "an unknown style raises even when the time is nil" do
    assert_raises(ArgumentError) { time_at(nil, style: :bogus) }
    assert_equal "", time_at(nil, style: :date)
  end

  test "the three styles are the whole vocabulary" do
    error = assert_raises(ArgumentError) { time_at(INSTANT, style: :long) }
    assert_match(/absolute, date, relative/, error.message)
  end

  test "time_label is the same words as plain text" do
    in_new_york do
      assert_equal "2026-11-01 22:11", time_label(INSTANT)
      assert_equal "2026-11-01", time_label(INSTANT, style: :date)
      assert_not time_label(INSTANT).html_safe?, "the History panel sets it as textContent; it is text, not markup"
    end
  end

  test "time_from_nanos reads a FileInfo/Node mtime as nanoseconds" do
    assert_nil time_from_nanos(nil)
    assert_equal INSTANT.to_i, time_from_nanos(INSTANT.to_i * 1_000_000_000 + 123_456_789).to_i
  end
end
