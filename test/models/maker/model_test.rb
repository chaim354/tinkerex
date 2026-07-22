require "test_helper"

module Maker
  class ModelTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "model-#{SecureRandom.hex(4)}@example.com") }

    test "valid with a title" do
      assert @user.maker_models.build(title: "Articulated Dragon").valid?
    end

    test "title is required" do
      m = @user.maker_models.build(title: nil)
      assert_not m.valid?
      assert_includes m.errors[:title], "can't be blank"
    end

    test "slug is auto-generated from the title" do
      m = @user.maker_models.create!(title: "Articulated Dragon v2!")
      assert_equal "articulated-dragon-v2", m.slug
    end

    test "slug disambiguates on collision instead of failing" do
      first  = @user.maker_models.create!(title: "Benchy")
      second = @user.maker_models.create!(title: "Benchy")
      assert_equal "benchy", first.slug
      assert_equal "benchy-2", second.slug
    end

    test "same slug allowed for a different user" do
      @user.maker_models.create!(title: "Benchy")
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com")
      assert_equal "benchy", other.maker_models.create!(title: "Benchy").slug
    end

    test "print_status defaults to want_to_print and is validated" do
      m = @user.maker_models.create!(title: "x")
      assert_equal "want_to_print", m.print_status
      assert_not @user.maker_models.build(title: "y", print_status: "bogus").valid?
    end

    test "to_param is the slug" do
      m = @user.maker_models.create!(title: "Cool Thing")
      assert_equal "cool-thing", m.to_param
    end

    test "destroyed with the user" do
      @user.maker_models.create!(title: "x")
      assert_difference "Maker::Model.count", -1 do
        @user.destroy!
      end
    end
  end
end
