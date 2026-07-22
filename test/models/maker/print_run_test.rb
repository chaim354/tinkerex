require "test_helper"

module Maker
  class PrintRunTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pr-#{SecureRandom.hex(4)}@example.com")
      @model = @user.maker_models.create!(title: "Dragon")
    end

    test "requires outcome in the allowed set" do
      assert_not @model.print_runs.build(printed_on: Date.today, outcome: "meh").valid?
      assert @model.print_runs.build(printed_on: Date.today, outcome: "success").valid?
    end

    test "a success run flips the model to printed" do
      @model.print_runs.create!(printed_on: Date.today, outcome: "success", printer: "MK4")
      assert_equal "printed", @model.reload.print_status
    end

    test "a failed run flips the model to failed" do
      @model.print_runs.create!(printed_on: Date.today, outcome: "failed")
      assert_equal "failed", @model.reload.print_status
    end

    test "the most recent run wins" do
      @model.print_runs.create!(printed_on: Date.new(2026, 7, 20), outcome: "failed")
      @model.print_runs.create!(printed_on: Date.new(2026, 7, 22), outcome: "success")
      assert_equal "printed", @model.reload.print_status
    end

    test "destroying the latest run recomputes from what remains" do
      @model.print_runs.create!(printed_on: Date.new(2026, 7, 20), outcome: "success")
      latest = @model.print_runs.create!(printed_on: Date.new(2026, 7, 22), outcome: "failed")
      assert_equal "failed", @model.reload.print_status
      latest.destroy!
      assert_equal "printed", @model.reload.print_status
    end

    test "removing the last run leaves the status untouched" do
      @model.update!(print_status: "want_to_print")
      run = @model.print_runs.create!(printed_on: Date.today, outcome: "success")
      assert_equal "printed", @model.reload.print_status
      run.destroy!
      assert_equal "printed", @model.reload.print_status # NOT reset to want_to_print
    end

    test "destroying the model destroys its print runs" do
      @model.print_runs.create!(printed_on: Date.today, outcome: "success")
      assert_difference "Maker::PrintRun.count", -1 do
        @model.destroy
      end
    end

    test "tie on printed_on breaks by id (later-created wins)" do
      @model.print_runs.create!(printed_on: Date.today, outcome: "failed")
      @model.print_runs.create!(printed_on: Date.today, outcome: "success")
      assert_equal "printed", @model.reload.print_status
    end

    test "backfilling an older run after a newer one does not change status" do
      @model.print_runs.create!(printed_on: Date.new(2026, 7, 22), outcome: "success")
      @model.print_runs.create!(printed_on: Date.new(2026, 7, 20), outcome: "failed")
      assert_equal "printed", @model.reload.print_status
    end
  end
end
