require "test_helper"

module Maker
  class GitRepoTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "gitrepo-#{SecureRandom.hex(4)}@example.com")
      @project = @user.maker_projects.create!(name: "P")
    end

    # ONE ROW PER PROJECT, and the uniqueness is enforced in the DATABASE as well as the model --
    # two rows would let two workers each believe they hold the head.
    test "one row per project" do
      Maker::GitRepo.create!(project: @project)
      assert_raises(ActiveRecord::RecordInvalid) { Maker::GitRepo.create!(project: @project) }
    end

    # THE HALF THE VALIDATION CANNOT GIVE. `validates ... uniqueness` is a SELECT then an INSERT,
    # so two workers can both read "no row yet" and both insert. Bypassing the validation is how
    # this test reaches the only mechanism that actually holds under concurrency.
    test "the unique index refuses a second row even when the validation is bypassed" do
      Maker::GitRepo.create!(project: @project)
      assert_raises(ActiveRecord::RecordNotUnique) do
        Maker::GitRepo.new(project: @project).save!(validate: false)
      end
    end

    # A REPO IS BOOKKEEPING THAT MAY PREDATE ITS FIRST COMMIT, so neither cache column is required.
    # Asserted rather than assumed: a `null: false` added to either one later would make
    # `GitRepo.create!(project:)` -- the call every door starts from -- raise.
    test "a row is valid before anything has been committed" do
      repo = Maker::GitRepo.create!(project: @project)
      assert_nil repo.head_oid
      assert_nil repo.last_commit_at
    end

    # TENANCY COMES FROM THE PROJECT, WHICH IS ONLY TRUE IF THE POINTER IS REQUIRED.
    test "a repo without a project is refused" do
      assert_not Maker::GitRepo.new.valid?
    end
  end
end
