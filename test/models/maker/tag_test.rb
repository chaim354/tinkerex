require "test_helper"

module Maker
  class TagTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "tag@example.com")
      @item = @user.maker_items.create!(title: "Gear")
    end

    test "tag name is unique per user" do
      @user.maker_tags.create!(name: "printed")
      dup = @user.maker_tags.build(name: "printed")
      assert_not dup.valid?
    end

    test "same name allowed for a different user" do
      @user.maker_tags.create!(name: "printed")
      other = User.create!(email: "o@example.com")
      assert other.maker_tags.build(name: "printed").valid?
    end

    test "tagging links a tag to an item" do
      tag = @user.maker_tags.create!(name: "useful")
      @item.taggings.create!(user: @user, tag: tag)
      assert_equal [ "useful" ], @item.reload.tags.pluck(:name)
    end

    test "destroying a tag removes its taggings" do
      tag = @user.maker_tags.create!(name: "useful")
      @item.taggings.create!(user: @user, tag: tag)
      assert_difference -> { Maker::Tagging.count }, -1 do
        tag.destroy
      end
    end
  end
end
