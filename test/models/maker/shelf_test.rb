require "test_helper"

module Maker
  class ShelfTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "shelf-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    test "the root is a valid path and matches the root" do
      shelf = @user.maker_shelves.create!(path: "")
      assert_predicate shelf, :persisted?
      assert Maker::Shelf.matches?("", "")
    end

    test "a literal path matches only itself" do
      assert Maker::Shelf.matches?("Models", "Models")
      assert_not Maker::Shelf.matches?("Models", "models")
      assert_not Maker::Shelf.matches?("Models", "Models/Benchy")
      assert_not Maker::Shelf.matches?("Models", "")
    end

    test "a star matches exactly one segment" do
      assert Maker::Shelf.matches?("Projects/*/models", "Projects/desk-lamp/models")
      assert_not Maker::Shelf.matches?("Projects/*/models", "Projects/models")
      assert_not Maker::Shelf.matches?("Projects/*/models", "Projects/desk-lamp/models/parts")
    end

    # THE REJECTIONS ARE THE POINT. A shelf path is compared against real library paths, so a
    # traversal segment or a reserved name is a typo worth refusing at the door -- and this asks
    # the SAME two questions LibraryBrowseController#create_folder asks rather than a private,
    # weaker spelling (14b).
    test "traversal, absolute, empty and reserved segments are refused" do
      [ "..", "a/../b", "/Models", "Models/", "Models//parts", ".trash", "a/.trash/b",
        ".maker-tmp-x" ].each do |bad|
        shelf = @user.maker_shelves.new(path: bad)
        assert_not shelf.valid?, "#{bad.inspect} should be refused"
        assert_includes shelf.errors[:path].join, "isn't allowed"
      end
    end

    test "a star is allowed only as a whole segment" do
      assert @user.maker_shelves.new(path: "Projects/*/models").valid?
      assert_not @user.maker_shelves.new(path: "Projects/*x/models").valid?
    end

    test "paths are unique per user" do
      @user.maker_shelves.create!(path: "Models")
      assert_not @user.maker_shelves.new(path: "Models").valid?
    end
  end
end
