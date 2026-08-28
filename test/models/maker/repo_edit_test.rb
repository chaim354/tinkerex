require "test_helper"

class Maker::RepoEditTest < ActiveSupport::TestCase
  setup { @user = User.create!(email: "rt-#{SecureRandom.hex(4)}@example.com") }

  test "one row per (user, node)" do
    Maker::RepoEdit.create!(user: @user, repo_root_node_id: "r1", node_id: "n1")

    assert_raises(ActiveRecord::RecordNotUnique) do
      Maker::RepoEdit.insert!({ user_id: @user.id, repo_root_node_id: "r1", node_id: "n1",
                                created_at: Time.current, updated_at: Time.current })
    end
  end

  test "record! is idempotent and re-stamps rather than duplicating" do
    Maker::RepoEdit.record!(user: @user, repo_root_node_id: "r1", node_id: "n1")
    travel 1.hour do
      Maker::RepoEdit.record!(user: @user, repo_root_node_id: "r1", node_id: "n1")
    end

    assert_equal 1, Maker::RepoEdit.where(user: @user).count
  end

  test "pending_for is scoped to one repository and one user" do
    other = User.create!(email: "rt2-#{SecureRandom.hex(4)}@example.com")
    Maker::RepoEdit.create!(user: @user, repo_root_node_id: "r1", node_id: "n1")
    Maker::RepoEdit.create!(user: @user, repo_root_node_id: "r2", node_id: "n2")
    Maker::RepoEdit.create!(user: other, repo_root_node_id: "r1", node_id: "n3")

    assert_equal [ "n1" ], Maker::RepoEdit.pending_for(@user, "r1").pluck(:node_id)
  end
end
