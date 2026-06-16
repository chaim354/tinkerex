require "test_helper"

module Maker
  class ItemTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "item@example.com") }

    test "valid with a title" do
      item = @user.maker_items.build(title: "Benchy")
      assert item.valid?
    end

    test "title is required" do
      item = @user.maker_items.build(title: nil)
      assert_not item.valid?
      assert_includes item.errors[:title], "can't be blank"
    end

    test "item_type must be in the allowed set" do
      item = @user.maker_items.build(title: "x", item_type: "bogus")
      assert_not item.valid?
    end

    test "defaults item_type to other and origin to downloaded" do
      item = @user.maker_items.create!(title: "x")
      assert_equal "other", item.item_type
      assert_equal "downloaded", item.origin
    end

    test "scoped to the user via the association" do
      @user.maker_items.create!(title: "mine")
      other = User.create!(email: "other@example.com")
      other.maker_items.create!(title: "theirs")
      assert_equal [ "mine" ], @user.maker_items.pluck(:title)
    end

    test "of_type filters by type when given" do
      @user.maker_items.create!(title: "a", item_type: "model_3d")
      @user.maker_items.create!(title: "b", item_type: "cad")
      assert_equal [ "a" ], @user.maker_items.of_type("model_3d").pluck(:title)
    end

    test "of_type returns all when type is blank" do
      @user.maker_items.create!(title: "a", item_type: "model_3d")
      @user.maker_items.create!(title: "b", item_type: "cad")
      assert_equal 2, @user.maker_items.of_type(nil).count
    end

    test "origin must be in the allowed set" do
      item = @user.maker_items.build(title: "x", origin: "pirated")
      assert_not item.valid?
    end
  end
end
