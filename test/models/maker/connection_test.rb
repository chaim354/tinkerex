require "test_helper"

module Maker
  class ConnectionTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "wiring@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    test "valid belonging to a project" do
      connection = @project.connections.build(user: @user, from_label: "Driver", to_label: "Motor")
      assert connection.valid?
    end

    test "from_label and to_label are required" do
      connection = @project.connections.build(user: @user, from_label: "", to_label: "")
      assert_not connection.valid?
      assert_includes connection.errors[:from_label], "can't be blank"
      assert_includes connection.errors[:to_label], "can't be blank"
    end

    test "from_label and to_label are capped at 120 characters" do
      connection = @project.connections.build(user: @user, from_label: "a" * 121, to_label: "Motor")
      assert_not connection.valid?
      assert_includes connection.errors[:from_label], "is too long (maximum is 120 characters)"
    end

    test "wire is capped at 60 characters" do
      connection = @project.connections.build(user: @user, from_label: "Driver", to_label: "Motor",
                                               wire: "a" * 61)
      assert_not connection.valid?
      assert_includes connection.errors[:wire], "is too long (maximum is 60 characters)"
    end

    test "note is capped at 500 characters" do
      connection = @project.connections.build(user: @user, from_label: "Driver", to_label: "Motor",
                                               note: "a" * 501)
      assert_not connection.valid?
      assert_includes connection.errors[:note], "is too long (maximum is 500 characters)"
    end

    test "from_label, to_label and wire are stripped" do
      connection = @project.connections.create!(user: @user, from_label: "  Driver  ",
                                                 to_label: "  Motor  ", wire: "  22 AWG  ")
      assert_equal "Driver", connection.from_label
      assert_equal "Motor", connection.to_label
      assert_equal "22 AWG", connection.wire
    end

    test "the project must belong to the same user" do
      other = User.create!(email: "o@example.com")
      foreign = other.maker_projects.create!(name: "Theirs")
      connection = Maker::Connection.new(user: @user, project_id: foreign.id,
                                         from_label: "Driver", to_label: "Motor")
      assert_not connection.valid?
      assert_includes connection.errors[:project_id], "must reference your own project"
    end

    test "a project can have many connections, ordered by position" do
      @project.connections.create!(user: @user, from_label: "A", to_label: "B", position: 1)
      @project.connections.create!(user: @user, from_label: "C", to_label: "D", position: 0)
      assert_equal [ "C", "A" ], @project.connections.reload.pluck(:from_label)
    end

    test "destroying the project destroys its connections" do
      @project.connections.create!(user: @user, from_label: "Driver", to_label: "Motor")
      assert_difference -> { Maker::Connection.count }, -1 do
        @project.destroy
      end
    end
  end
end
