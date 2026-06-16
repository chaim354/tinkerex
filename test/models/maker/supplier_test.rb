require "test_helper"

module Maker
  class SupplierTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "sup@example.com") }

    test "valid with a name" do
      assert @user.maker_suppliers.build(name: "McMaster-Carr").valid?
    end

    test "name is required" do
      assert_not @user.maker_suppliers.build(name: nil).valid?
    end

    test "stores url and notes" do
      s = @user.maker_suppliers.create!(name: "Digikey", url: "https://digikey.com", notes: "fast")
      assert_equal "https://digikey.com", s.url
      assert_equal "fast", s.notes
    end

    test "scoped to the user via the association" do
      @user.maker_suppliers.create!(name: "mine")
      other = User.create!(email: "o@example.com")
      other.maker_suppliers.create!(name: "theirs")
      assert_equal [ "mine" ], @user.maker_suppliers.pluck(:name)
    end
  end
end
