require "test_helper"

module Maker
  class CollectionTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "coll@example.com")
      @item = @user.maker_items.create!(title: "Knob")
      @collection = @user.maker_collections.create!(name: "Lamp v2 parts")
    end

    test "name is required" do
      assert_not @user.maker_collections.build(name: nil).valid?
    end

    test "adds an item to the collection" do
      @collection.collection_items.create!(user: @user, item: @item)
      assert_equal [ "Knob" ], @collection.reload.items.pluck(:title)
    end

    test "the same item cannot be added twice" do
      @collection.collection_items.create!(user: @user, item: @item)
      dup = @collection.collection_items.build(user: @user, item: @item)
      assert_not dup.valid?
    end

    test "destroying the collection removes memberships but not items" do
      @collection.collection_items.create!(user: @user, item: @item)
      @collection.destroy
      assert Maker::Item.exists?(@item.id)
      assert_equal 0, Maker::CollectionItem.count
    end

    test "destroying an item removes its collection memberships" do
      @collection.collection_items.create!(user: @user, item: @item)
      assert_difference -> { Maker::CollectionItem.count }, -1 do
        @item.destroy
      end
      assert Maker::Collection.exists?(@collection.id)
    end
  end
end
