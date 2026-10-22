require "test_helper"

module Maker
  # A saved calculator result (2026-10-21; plan 2026-10-21-calculator-modal.md). The server stores what
  # the browser's engine computed and never re-evaluates it, so what is pinned here is the SHAPE the
  # model accepts — and the two rules that keep a row from pointing somewhere it must not.
  class CalculationTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "calc-model-#{SecureRandom.hex(4)}@example.com", password: "x" * 12,
                           confirmed_at: Time.current)
      @project = @user.maker_projects.create!(name: "Shelf")
    end

    def build(**attrs)
      @project.calculations.new({ user: @user, label: "Shelf depth", expression: "12.5mm + 1/4in",
                                  result: 18.85, unit: "mm" }.merge(attrs))
    end

    test "a calculation saves with its label, expression, result and unit, the label squished" do
      calc = build(label: "  Shelf   depth ")
      assert calc.save, calc.errors.full_messages.to_sentence
      assert_equal "Shelf depth", calc.reload.label
      assert_in_delta 18.85, calc.result
      assert_equal "mm", calc.unit
    end

    test "the label is required, and says how to name one" do
      calc = build(label: "  ")
      refute calc.valid?
      assert_includes calc.errors[:label].join, "Shelf depth"
    end

    test "a plain number's unit is the empty string, and a unit the engine cannot produce is refused" do
      assert build(unit: "").valid?
      assert build(unit: "in²").valid?
      assert build(unit: "°").valid?
      refute build(unit: "kg").valid?
      refute build(unit: "<b>mm</b>").valid?
    end

    test "Infinity and NaN are refused, though both are Floats numericality lets through" do
      refute build(result: Float::INFINITY).valid?
      refute build(result: Float::NAN).valid?
      refute build(result: "twelve").valid?
    end

    test "an inch fraction is 16 or 32 and only on an inch result" do
      assert build(unit: "in", inch_fraction: 16).valid?
      assert build(unit: "in", inch_fraction: 32).valid?
      refute build(unit: "in", inch_fraction: 8).valid?
      refute build(unit: "mm", inch_fraction: 16).valid?
    end

    test "another user's project is refused — the *_belongs_to_user rule (§14d)" do
      other = User.create!(email: "calc-other-#{SecureRandom.hex(4)}@example.com", password: "x" * 12,
                           confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")
      calc = Maker::Calculation.new(user: @user, project: theirs, label: "x", expression: "1", result: 1, unit: "")
      refute calc.valid?
      assert_includes calc.errors[:project_id], "must reference your own project"
    end

    test "a project holds CAP calculations, and the next is refused with how to make room" do
      rows = Array.new(Maker::Calculation::CAP) do |i|
        { user_id: @user.id, project_id: @project.id, label: "c#{i}", expression: "#{i}", result: i, unit: "",
          created_at: Time.current, updated_at: Time.current }
      end
      Maker::Calculation.insert_all!(rows)
      calc = build
      refute calc.valid?
      assert_match(/holds #{Maker::Calculation::CAP} saved calculations/, calc.errors[:base].join)
      # Editing a row at the cap is not a create, so a label can still be fixed.
      existing = @project.calculations.first
      assert existing.update(label: "renamed")
    end

    test "destroying the project takes its calculations with it" do
      build.save!
      assert_difference -> { Maker::Calculation.count }, -1 do
        @project.destroy!
      end
    end
  end
end
