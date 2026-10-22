require "test_helper"

module Maker
  class BuildLogEntryTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "log@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    test "valid with a body" do
      entry = @project.build_log_entries.build(user: @user, body: "Soldered the board")
      assert entry.valid?
    end

    test "body is required" do
      entry = @project.build_log_entries.build(user: @user, body: nil)
      assert_not entry.valid?
    end

    test "entry_type must be in the allowed set" do
      entry = @project.build_log_entries.build(user: @user, body: "x", entry_type: "bogus")
      assert_not entry.valid?
    end

    test "defaults entry_type to note and stamps logged_at on create" do
      entry = @project.build_log_entries.create!(user: @user, body: "x")
      assert_equal "note", entry.entry_type
      assert_not_nil entry.logged_at
    end

    test "an explicit logged_at is preserved" do
      ts = 3.days.ago.change(usec: 0)
      entry = @project.build_log_entries.create!(user: @user, body: "x", logged_at: ts)
      assert_equal ts, entry.logged_at
    end

    test "destroying the project destroys its build log entries" do
      @project.build_log_entries.create!(user: @user, body: "x")
      assert_difference -> { Maker::BuildLogEntry.count }, -1 do
        @project.destroy
      end
    end

    test "an entry can own file attachments" do
      entry = @project.build_log_entries.create!(user: @user, body: "x")
      @user.nodes.create!(node_id: "node-9", name: "photo.jpg", kind: "file")
      att = entry.file_attachments.create!(user: @user, node_id: "node-9")
      assert_equal entry, att.attachable
    end
  end
end
