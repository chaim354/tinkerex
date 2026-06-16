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
  end
end
