require "test_helper"

require "support/git_repo_fixture"

class RepoEditFlowTest < ActionDispatch::IntegrationTest
  include GitRepoFixture

  # `sign_in_as` DOES NOT EXIST IN test_helper.rb. The only method by that name is a Capybara
  # helper in test/system/support/web_helpers.rb, which takes an EMAIL and drives the real form.
  # Every web integration test here defines its own; shelves_test.rb records a previous plan
  # having assumed otherwise, so do not assume it again.
  PASSWORD = "password123".freeze

  setup do
    @library = use_fresh_share_library!
    @user = User.create!(email: "re-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    sign_in_as(@user)
  end

  def sign_in_as(user)
    post user_session_path, params: { user: { email: user.email, password: PASSWORD } }
  end

  # Drives the REAL door. §14e: the suite being green is not evidence a guard works if the
  # guard's precondition is never established in test.
  test "saving a text file in a working tree rewrites it and keeps the node" do
    node = seed_repo_file!("notes.md", "old\n")
    before = node.node_id

    patch file_path(node.node_id), params: { content: "new\n", base_token: token_for(node) }

    assert_response :success
    assert_equal "new\n", read_back(node)
    assert_equal before, @user.nodes.present.find_by!(name: "notes.md").node_id,
                 "a replace must REUSE the node (§14a) or every attachment is orphaned"
  end

  test "saving records exactly one pending edit, however many saves" do
    node = seed_repo_file!("notes.md", "a\n")

    patch file_path(node.node_id), params: { content: "b\n", base_token: token_for(node) }
    patch file_path(node.node_id), params: { content: "c\n", base_token: token_for(node.reload) }

    assert_equal 1, Maker::RepoEdit.where(user: @user, node_id: node.node_id).count
  end

  test "a stale base_token is refused and nothing is written" do
    node = seed_repo_file!("notes.md", "original\n")

    patch file_path(node.node_id), params: { content: "clobber\n", base_token: "sha256:stale" }

    assert_response :conflict
    assert_equal "original\n", read_back(node),
                 "last-write-wins would destroy the other edit silently, and on share for good"
  end

  test "a file outside a working tree is not saveable" do
    node = seed_plain_file!("loose.md", "x\n")

    patch file_path(node.node_id), params: { content: "y\n", base_token: token_for(node) }

    assert_response :unprocessable_entity
  end

  # THE SIZE CAP IS RE-CHECKED ON THE SERVER, and this case is the reason it is not merely a
  # courtesy in JavaScript. codeview_controller fetches at most MAX_BYTES and appends
  # "… (truncated)"; a save of that buffer TRUNCATES THE FILE. A refusal that only lives in the
  # browser is one an unmodified `curl` walks straight past.
  test "a file over the editable cap is refused" do
    node = seed_repo_file!("huge.md", "x" * (FilesController::EDITABLE_MAX_BYTES + 1))

    patch file_path(node.node_id), params: { content: "tiny\n", base_token: token_for(node) }

    assert_response :unprocessable_entity
    assert_equal "x" * (FilesController::EDITABLE_MAX_BYTES + 1), read_back(node)
  end
end

# SAVE ON WHATEVER BACKEND IS LIVE. The cases above pin a share library so they run identically on
# all three legs, which is what keeps run counts equal — but that means none of them exercises s3's
# `write` or chunk_remote's two-phase upload, and "Save works everywhere" is half this design.
#
# NO REAL GIT IS NEEDED, and that is the point: the Save door asks Library::WorkingTree, which
# reads NODES. A `.git` dir node is all it takes, and every backend has one — on chunk_remote the
# mirror carries whatever the client synced, and repo_metadata_purge.rb records those rows as
# HIDDEN rather than removed.
class RepoEditAmbientBackendTest < ActionDispatch::IntegrationTest
  PASSWORD = "password123".freeze

  setup do
    stub_the_s3_client_only!
    @user = User.create!(email: "ab-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
  end

  teardown { FileLayer.reset! if @stubbed_s3 }

  # THE S3 LEG POINTS AT A BUCKET THAT DOES NOT EXIST, and that is `config/ci.rb`'s design rather
  # than a gap here: `LIBRARY_S3_BUCKET=ci-not-a-real-bucket` with credentials `ci`/`ci`, so the
  # first real call answers `Aws::S3::Errors::Forbidden`. Every s3-mode test in this suite that
  # needs a working port therefore injects `FakeS3` (s3_write_test.rb, s3_delivery_test.rb); this
  # one is not an exception to that, it is the same concession spelled out at the one door that
  # needs it.
  #
  # IT SWAPS THE CLIENT, NOT THE BACKEND. The adapter is still `FileLayer::S3` and the Save door
  # still takes S3's own `write`, so what this test asserts about the ambient backend stays true —
  # only the socket at the far end is fake. `is_a?` is allowed HERE for Task 2's stated reason: a
  # test naming which adapter is live is the opposite of production code branching on the class.
  # The `FileLayer.reset!` in teardown is load-bearing, not decoration — a direct assignment does
  # not set the pin flag test_helper's teardown looks for.
  def stub_the_s3_client_only!
    return unless FileLayer.current.is_a?(FileLayer::S3)

    require_relative "../../support/fake_s3"
    @stubbed_s3 = FakeS3.new
    FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                          secret_access_key: "sk", prefix: "library",
                                          client: @stubbed_s3.client)
  end

  # THE FOLDER GOES THROUGH THE REAL DOOR AND THE MARKER DOES NOT, and the asymmetry is the whole
  # fixture. A `nodes.create!` dir has a NULL `storage_path`, which cannot exist on share or s3
  # (§14a) — `FileLayer::Share#write` into it raises `FileLayer::NotFound: parent … has no
  # storage_path`, so the plan's two bare rows made this case pass on chunk_remote alone, which is
  # the one leg it was written to escape. `Maker::LibraryFolder` is the one cross-backend
  # folder-creation door and gives a real parent on all three.
  #
  # THE `.git` MARKER STAYS A BARE ROW BECAUSE NO DOOR MAY MINT ONE. `Library::ReservedNames`
  # refuses that name at every leaf-minting door and the port refuses it as a write destination
  # (§14b), so `ensure_path!` cannot create it and must not learn how. Nothing reads the marker's
  # bytes anyway: `Library::WorkingTree` asks the catalog for a live `.git` DIR row and nothing else.
  test "saving works on the ambient backend, whichever it is" do
    repo = Maker::LibraryFolder.ensure_path!(@user, [ "r-#{SecureRandom.hex(4)}" ])
    @user.nodes.create!(node_id: SecureRandom.uuid, name: ".git", kind: "dir",
                        parent_node_id: repo.node_id)
    node = write_through_port!(parent: repo, name: "a.md", bytes: "old\n")

    patch file_path(node.node_id),
          params: { content: "new\n",
                    base_token: FileLayer.current.stat(@user, node_id: node.node_id)&.content_token }

    assert_response :success
    assert_equal "new\n", FileLayer.current.read(@user, node_id: node.node_id)
  end

  # Uses the SAME door the editor does, so this test cannot pass by a route the product lacks.
  def write_through_port!(parent:, name:, bytes:)
    id = Maker::Addons::LibraryOutput.write_bytes!(@user, parent_node_id: parent.node_id, name:, bytes:)
    @user.nodes.present.find_by!(node_id: id)
  end
end
