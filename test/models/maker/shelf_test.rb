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

    # EVERY SEEDED PATH MUST SURVIVE THIS CLASS'S OWN VALIDATION. Nothing else checks that: once
    # seeding is wired up, an invalid SEEDS entry surfaces as create! raising for every user on
    # their first visit, at the door rather than here.
    # THE STATE THAT USED TO BE PERMANENT. A user holding a seed path with no stamp -- a process
    # that died between the rows and the stamp, or someone who created "" themselves -- made every
    # later call raise "Path has already been taken" forever, on the recurring sweep's own first
    # line. Found by Task 7's implementer when the plan's own job test hit it.
    test "seeding tolerates a seed path the user already has" do
      @user.maker_shelves.create!(path: "")

      assert_nothing_raised { Maker::Shelf.seed_once!(@user) }

      assert_equal [ "", "Models", "Projects/*/models" ], @user.maker_shelves.order(:path).pluck(:path)
      assert_predicate @user.reload.shelves_seeded_at, :present?
    end

    test "every seeded path is valid" do
      Maker::Shelf::SEEDS.each do |seeded|
        assert @user.maker_shelves.new(path: seeded).valid?, "#{seeded.inspect} should be valid"
      end
    end

    # NIL IS NOT THE ROOT. "" is; a missing path is a caller that forgot one, and letting it
    # validate defers the failure to the database's NOT NULL as a 500.
    test "a nil path is refused rather than deferred to the database" do
      shelf = @user.maker_shelves.new(path: nil)
      assert_not shelf.valid?
      assert_includes shelf.errors[:path].join, "isn't allowed"
    end

    test "seeding is idempotent and does not resurrect deleted rows" do
      Maker::Shelf.seed_once!(@user)
      assert_equal [ "", "Models", "Projects/*/models" ], @user.maker_shelves.order(:path).pluck(:path)

      Maker::Shelf.seed_once!(@user)
      assert_equal 3, @user.maker_shelves.count

      @user.maker_shelves.destroy_all
      Maker::Shelf.seed_once!(@user.reload)
      assert_empty @user.maker_shelves.reload
    end
  end
end
