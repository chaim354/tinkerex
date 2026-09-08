require "test_helper"
require "support/git_repo_fixture"

module Maker
  # THE ONE TEXT SAVE (stage 4, S4-4). FilesController#update (a file inside a working tree) and
  # Projects::ReadmesController#update (the project's README, anywhere) are the same operation seen
  # twice — stale-check, write through the port keeping the node, record a pending git edit — and a
  # second copy of it is where the 409 or the `replace:` quietly goes missing on one of the two.
  #
  # OWNS A SHARE LIBRARY: this writes real bytes through the port, so it pins share rather than
  # hitting the s3 stub bucket and the sync server's provisioning on the other two legs.
  class TextSaveTest < ActiveSupport::TestCase
    include GitRepoFixture
    # The save re-enqueues the thumbnail it just invalidated (stage 4, S4-3's rule, in the one
    # save since S4-4), so this suite asserts on the QUEUE too.
    include ActiveJob::TestHelper

    setup do
      @library = use_fresh_share_library!
      @user = User.create!(email: "textsave-#{SecureRandom.hex(4)}@example.com",
                           password: "correct horse battery staple", confirmed_at: Time.current)
      @folder = Maker::LibraryFolder.ensure_path!(@user, [ "Docs" ])
    end

    def write!(name, body)
      Maker::Addons::LibraryOutput.write_bytes!(@user, parent_node_id: @folder.node_id, name:, bytes: body)
      Library::ScanJob.new.perform(user_id: @user.id)
      @user.nodes.present.find_by!(parent_node_id: @folder.node_id, name:)
    end


    test "an existing file is rewritten IN PLACE, keeping its node_id, and the new token comes back" do
      node = write!("README.md", "# Old\n")
      before = node.node_id

      result = Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id,
                                    name: node.name, body: "# New\n", base_token: token_for(node))

      assert result.ok, result.error
      assert_equal before, result.node_id, "a replace must REUSE the node (§14a) — every attachment is keyed on it"
      assert_equal "# New\n", FileLayer.current.read(@user, node_id: before)
      assert_equal token_for(node), result.content_token
    end

    test "a stale base_token is a conflict and writes nothing" do
      node = write!("README.md", "# Old\n")

      result = Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id,
                                    name: node.name, body: "# New\n", base_token: "stale")

      refute result.ok
      assert_equal :conflict, result.status
      assert_equal "# Old\n", FileLayer.current.read(@user, node_id: node.node_id)
    end

    # THE GAP THE CATALOG ARM CANNOT SEE, AND THE ONE THIS SERVICE'S HEADER USED TO CONCEDE. The row
    # arm compares the editor's token against `stat`, which answers from `nodes` — so a Finder save
    # made between render and Save, with no scan in between, agreed with it and was silently
    # overwritten (measured in S4-4's review). Bytes straight to the disk here, deliberately no
    # scan: that is what makes the catalog agree, and what makes this test fail the moment the check
    # goes back to asking the row instead of the store.
    #
    # THE SAME REFUSAL EITHER ARM CATCHES IT ON — status, and the STALE sentence, not merely "not
    # ok". One condition, one answer (§14a): a maker who raced the scan must not get a different
    # message from one who did not.
    test "a desktop edit the catalog has not observed yet is refused, not overwritten" do
      node = write!("README.md", "# Old\n")
      rendered = token_for(node)
      on_disk = @library.join(node.storage_path)
      File.binwrite(on_disk, "# From the desktop\n")

      result = Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id,
                                    name: node.name, body: "# From the browser\n", base_token: rendered)

      refute result.ok
      assert_equal :conflict, result.status
      assert_equal Maker::TextSave::STALE, result.error
      assert_equal "# From the desktop\n", File.read(on_disk),
                   "the other edit must survive — on share there is no version to restore it from"
    end

    test "no node creates the file at the folder root" do
      result = Maker::TextSave.call(user: @user, node: nil, parent_node_id: @folder.node_id,
                                    name: "README.md", body: "# Fresh\n", base_token: nil)

      assert result.ok, result.error
      assert_equal "# Fresh\n", FileLayer.current.read(@user, node_id: result.node_id)
    end

    test "a create whose name is already taken is refused by the port, not silently clobbered" do
      write!("README.md", "# Old\n")

      assert_raises(FileLayer::UnsupportedOperation) do
        Maker::TextSave.call(user: @user, node: nil, parent_node_id: @folder.node_id,
                             name: "README.md", body: "# New\n", base_token: nil)
      end
    end

    test "a repo root records a pending edit; no repo root records none" do
      node = write!("README.md", "# Old\n")

      Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id, name: node.name,
                           body: "# A\n", base_token: token_for(node))
      assert_equal 0, Maker::RepoEdit.where(user: @user).count

      Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id, name: node.name,
                           body: "# B\n", base_token: token_for(node), repo_root_node_id: @folder.node_id)
      assert_equal [ node.node_id ], Maker::RepoEdit.where(user: @user).pluck(:node_id)
    end

    # THE SAVE INVALIDATES THE PICTURE OF THE FILE, AND THE ONE SAVE IS WHERE THAT IS SAID (stage 4,
    # S4-3's rule, moved into this service in S4-4 so the README door gets it too). Mirrors
    # repo_edit_flow_test.rb's "saving re-enqueues the thumbnail", which drives the file page's door
    # onto this same line: the row is repointed at the token the write minted and blanked to
    # `pending` (§14h), and one GeneratePreviewJob is queued.
    test "a save enqueues the thumbnail for the bytes it just wrote" do
      node = write!("README.md", "# Old\n")
      before_token = token_for(node)
      # find_or_initialize, NOT create!: write! runs a REAL Library::ScanJob, whose Reconciler
      # already enqueued a thumbnail for this node, and maker_previews is unique on (user, node_id,
      # kind). Putting that existing row into the state under test is what the assertions are about.
      preview = @user.maker_previews.find_or_initialize_by(node_id: node.node_id, kind: "thumbnail")
      preview.update!(version_id: before_token, status: "ready",
                      renderer_revision: Maker::Previews::Enqueue.revision_for_name("README.md", "thumbnail"))

      assert_enqueued_with(job: Maker::GeneratePreviewJob) do
        Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id,
                             name: node.name, body: "# New\n", base_token: before_token)
      end

      preview.reload
      assert_equal "pending", preview.status, "a content repoint blanks the artifact (§14h)"
      assert_not_equal before_token, preview.version_id, "the row points at the bytes that now exist"
      assert_equal token_for(node.reload), preview.version_id
    end

    # A REFUSED SAVE MUST NOT TOUCH THE PREVIEW: the 409 writes nothing, so re-enqueueing there
    # would blank a correct picture for a save that never happened.
    test "a refused save enqueues nothing" do
      node = write!("README.md", "# Old\n")

      assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
        Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id,
                             name: node.name, body: "# New\n", base_token: "stale")
      end
    end
  end
end
