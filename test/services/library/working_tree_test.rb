require "test_helper"

class Library::WorkingTreeTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rt-#{SecureRandom.hex(4)}@example.com")
    @tree = Library::WorkingTree.new(@user)
  end

  def dir!(name, parent: nil)
    @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir",
                        parent_node_id: parent&.node_id)
  end

  def file!(name, parent:)
    @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                        parent_node_id: parent.node_id)
  end

  test "returns the repository root for a file inside a working tree" do
    repo = dir!("TheFlightWall_OSS")
    dir!(".git", parent: repo)
    src  = dir!("src", parent: repo)
    file = file!("main.cpp", parent: src)

    assert_equal repo.node_id, @tree.root_for(file)&.node_id
  end

  test "returns nil outside a working tree" do
    plain = dir!("Models")
    assert_nil @tree.root_for(file!("bracket.stl", parent: plain))
  end

  # The marker node is the repository root's CHILD, so the root is its parent -- not the marker.
  test "the marker itself resolves to its parent, not to itself" do
    repo   = dir!("catan")
    marker = dir!(".git", parent: repo)

    assert_equal repo.node_id, @tree.root_for(marker)&.node_id
  end

  # A tombstoned .git is not a working tree. Without this, deleting a repository would freeze its
  # former folder against the intake sweep forever with nothing visible saying why.
  test "a tombstoned marker is not a working tree" do
    repo = dir!("catan")
    dir!(".git", parent: repo).update!(deleted: true)

    assert_nil @tree.root_for(file!("board.stl", parent: repo))
  end

  # RepoMetadata's rule is "a DIRECTORY named .git". A .git FILE is a submodule or linked-worktree
  # pointer and nothing here reads the pointer, so treating it as a marker would be right by
  # accident and wrong by construction.
  test "a .git FILE is not a marker" do
    repo = dir!("submodule")
    file!(".git", parent: repo)

    assert_nil @tree.root_for(file!("thing.txt", parent: repo))
  end

  test "the nearest marker wins for a nested repository" do
    outer = dir!("outer");  dir!(".git", parent: outer)
    inner = dir!("inner", parent: outer); dir!(".git", parent: inner)

    assert_equal inner.node_id, @tree.root_for(file!("a.txt", parent: inner))&.node_id
  end

  test "the ancestor walk is memoised per parent" do
    repo = dir!("r"); dir!(".git", parent: repo)
    deep = dir!("a", parent: repo)
    files = 5.times.map { |i| file!("f#{i}.txt", parent: deep) }

    @tree.root_for(files.first)
    after = count_queries { files.each { |f| @tree.root_for(f) } }

    assert_equal 0, after, "a second lookup under a known parent must not query"
  end

  def count_queries
    n = 0
    sub = ->(*, payload) { n += 1 unless payload[:name].in?(%w[CACHE SCHEMA TRANSACTION]) }
    ActiveSupport::Notifications.subscribed(sub, "sql.active_record") { yield }
    n
  end
end
