require "test_helper"

module Maker
  class BomTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "bom@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    test "valid belonging to a project" do
      bom = @project.boms.build(user: @user)
      assert bom.valid?
    end

    test "defaults name to BOM and revision to 1" do
      bom = @project.boms.create!(user: @user)
      assert_equal "BOM", bom.name
      assert_equal 1, bom.revision
    end

    test "revision must be positive" do
      bom = @project.boms.build(user: @user, revision: 0)
      assert_not bom.valid?
    end

    test "the project must belong to the same user" do
      other = User.create!(email: "o@example.com")
      foreign = other.maker_projects.create!(name: "Theirs")
      bom = Maker::Bom.new(user: @user, project_id: foreign.id)
      assert_not bom.valid?
      assert_includes bom.errors[:project_id], "must reference your own project"
    end

    test "a project can have many revisions" do
      @project.boms.create!(user: @user, revision: 1)
      @project.boms.create!(user: @user, revision: 2)
      assert_equal [ 1, 2 ], @project.boms.order(:revision).pluck(:revision)
    end

    test "destroying the project destroys its boms" do
      @project.boms.create!(user: @user)
      assert_difference -> { Maker::Bom.count }, -1 do
        @project.destroy
      end
    end
  end
end
