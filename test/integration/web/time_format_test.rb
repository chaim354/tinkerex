require "test_helper"

module Web
  # ONE ZONE, ONE HELPER (UX audit D1, 2026-11-02). The audit found three clocks and six formats on
  # one evening's pages: notes, the build log, Trash and the inventory ledger in UTC, a file's mtime
  # in the process's own zone, the History panel in the browser's, as `%Y-%m-%d %H:%M`, `...:%S`,
  # `%Y-%m-%d`, `%B %d, %Y`, toLocaleString() and "10 minutes ago". Every timestamp now goes
  # through ApplicationHelper#time_at in config.time_zone; this pins both halves where they meet a
  # page -- the templates name no other formatter, and six real pages render through it.
  #
  # PINS A SHARE LIBRARY (use_fresh_share_library!) so every case runs identically on all three
  # legs; what is under test is how a time is printed, not which backend holds the file.
  class TimeFormatTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # 03:11:06 UTC on 2 November is 22:11 the evening BEFORE in New York: a page printing UTC, or
    # a process-local time, gets the minute AND the date wrong, so neither can pass by coinciding.
    INSTANT = Time.utc(2026, 11, 2, 3, 11, 6)
    NEW_YORK = "America/New_York".freeze
    ABSOLUTE = "2026-11-01 22:11".freeze
    TITLE = "2026-11-01 22:11:06 EST".freeze
    NANOS = INSTANT.to_i * 1_000_000_000

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "time-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    # Every page is read in New York; Time.use_zone reaches the request, which runs on this thread.
    def get_in_new_york(path) = Time.use_zone(NEW_YORK) { get path }

    # The one <time> the selector names, with its text, datetime and title checked together.
    def assert_time(selector, text:, title: TITLE)
      times = css_select(selector)
      assert_equal 1, times.size, "expected one <time> at #{selector}, found #{times.size}"
      time = times.first
      assert_equal "time", time.name
      assert_equal text, time.text.strip, "#{selector} prints the time in the app's zone, minute precision"
      assert_equal "2026-11-01T22:11:06-05:00", time["datetime"], "#{selector}: datetime is ISO 8601 in the app's zone"
      assert_equal title, time["title"], "#{selector}: title is the full local time with the zone"
    end

    # --- the templates ----------------------------------------------------------------------------

    FORBIDDEN = /strftime|to_fs\(|to_formatted_s\(|time_ago_in_words|distance_of_time_in_words|%B %d/

    test "no template formats a time itself: every timestamp goes through time_at" do
      templates = Dir[Rails.root.join("app/views/**/*")].select { |f| File.file?(f) }
      # A GUARD THAT SCANS A DIRECTORY DIES SILENTLY WHEN THE DIRECTORY LEAVES (CLAUDE.md §14e): an
      # empty glob satisfies assert_empty perfectly. The census was 24 sites in 23 templates, and
      # these four held them; if they are no longer scanned, the glob is wrong, not the app clean.
      assert_operator templates.size, :>, 100, "the app/views glob found almost nothing"
      %w[files/_list.html.erb trash/index.html.erb settings/devices/_device.html.erb public/projects/_build_log.html.erb].each do |known|
        assert_includes templates, Rails.root.join("app/views", known).to_s, "the scan no longer covers #{known}"
      end

      offenders = templates.flat_map { |file|
        File.readlines(file).each_with_index.filter_map { |line, i|
          "#{file.delete_prefix("#{Rails.root}/")}:#{i + 1}: #{line.strip}" if line.match?(FORBIDDEN)
        }
      }
      assert_empty offenders, "format times with time_at(time, style: :absolute | :date | :relative), " \
                              "never by hand:\n#{offenders.join("\n")}"
    end

    # --- one zone ---------------------------------------------------------------------------------

    # THE AUDIT'S OWN CASE, AS A READER MEETS IT: a file saved at 22:11 and a note written about it
    # in the same minute must read the same minute on the file page. The file's time is a unix
    # nanosecond count, turned into a ::Time in the PROCESS's zone -- made Tokyo here, unlike both
    # UTC and New York -- and the note's is a Rails column; only converting both to the app's zone
    # makes them agree.
    test "a file's mtime and a note written in the same minute read the same minute" do
      node = create_node!(@user, node_id: "f-same", name: "bracket.stl", kind: "file", mtime: NANOS)
      @user.maker_notes.create!(node_id: node.node_id, body: "printed at 0.2", created_at: INSTANT)

      with_process_zone("Asia/Tokyo") { get_in_new_york file_path(node.node_id) }

      assert_response :success
      assert_time "dl.meta dd time", text: ABSOLUTE
      assert_time ".note-meta time", text: ABSOLUTE
    end

    # --- six pages ----------------------------------------------------------------------------------

    test "the Library list prints each file's mtime" do
      create_node!(@user, node_id: "f-list", name: "bracket.stl", kind: "file", mtime: NANOS, size: 1)

      get_in_new_york files_path(view: "list")

      assert_response :success
      assert_time "td.col-modified time", text: ABSOLUTE
    end

    test "the build log prints each entry's time" do
      project = @user.maker_projects.create!(name: "Lamp")
      project.build_log_entries.create!(user: @user, body: "Cut the panels", logged_at: INSTANT)

      get_in_new_york project_path(project)

      assert_response :success
      assert_time ".log-entry time.entry-time", text: ABSOLUTE
    end

    test "Trash prints when each file was deleted" do
      node = create_node!(@user, node_id: "f-trash", name: "bracket.stl", kind: "file", mtime: NANOS, size: 1)
      delete file_path(node.node_id)
      assert_response :redirect
      # Share's Trash reads the deletion time off the tombstone's updated_at (FileLayer::Share#trashed).
      @user.nodes.find_by!(node_id: node.node_id).update_columns(updated_at: INSTANT)

      get_in_new_york trash_index_path

      assert_response :success
      assert_time "td.col-modified time", text: ABSOLUTE
    end

    test "the inventory ledger prints each change's time" do
      item = @user.maker_inventory_items.create!(name: "M3 screw", unit: "each")
      Maker::InventoryTransaction.apply!(item:, user: @user, delta: 40, reason: "restocked")
      item.transactions.update_all(created_at: INSTANT)

      get_in_new_york inventory_item_path(item)

      assert_response :success
      assert_time "td.col-when time", text: ABSOLUTE
    end

    # Devices shows a DAY (added) and a RECENCY (used), the two other styles -- and each keeps the
    # full time in title, which is the absolute form plus seconds and the zone.
    test "Devices prints the day a device was added and how long since it was used" do
      device = Device.register!(user: @user, name: "Workshop laptop")
      device.update_columns(created_at: INSTANT, last_seen_at: INSTANT)

      get_in_new_york settings_devices_path

      assert_response :success
      facts = css_select(".settings-fact").select { |fact| fact.at_css("time") }
      added = facts.find { |fact| fact.text.start_with?("added") }
      used = facts.find { |fact| fact.text.start_with?("used") }
      assert added && used, "Devices lost its added/used facts: #{facts.map(&:text).inspect}"

      assert_equal "added 2026-11-01", added.text.strip
      assert_match(/\Aused .+ ago\z/, used.text.strip)
      [ added, used ].each do |fact|
        assert_equal "2026-11-01T22:11:06-05:00", fact.at_css("time")["datetime"]
        assert_equal TITLE, fact.at_css("time")["title"]
      end
    end

    private

    # Ruby re-reads TZ when it is assigned, so `Time.at` answers in this zone for the block.
    def with_process_zone(zone)
      before = ENV.fetch("TZ", nil)
      ENV["TZ"] = zone
      yield
    ensure
      before.nil? ? ENV.delete("TZ") : ENV["TZ"] = before
    end
  end
end
