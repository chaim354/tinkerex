require "test_helper"

module Library
  # "START OVER WITH THIS FOLDER" DELETES ROWS AND NOTHING ELSE (K §5), so it is rows-only here and
  # runs identically on all three backend legs: every node is a bare `nodes.create!`, no adapter is
  # asked, and the preview's blob lives in Active Storage's own test service.
  #
  # ONE ASSERTION PER TABLE, so the list in Library::Reset cannot shrink silently: drop a line there
  # and exactly one assertion here goes red.
  #
  # THREE KINDS OF FOLDER, because the reset treats them three ways: `parts` is the project's folder
  # WITH A PATH (kept as a scan tombstone, re-linked by the next scan); `old-folder` is a project's
  # folder that is a TRASH tombstone, with no path to find again (forgotten, pointer nulled);
  # `scratch` is a folder nothing the maker owns names (forgotten, its pin with it).
  class ResetTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @user = User.create!(email: "reset-#{SecureRandom.hex(4)}@example.com")
      @user.update_columns(library_scanned_at: Time.current, library_scan_refusal: "refused")

      @dir   = node!("parts", kind: "dir")
      @file  = node!("bracket.stl", parent: @dir)
      @svg   = node!("bracket.svg", parent: @dir)
      @gone  = node!("old.stl", deleted: true)
      @scratch = node!("scratch", kind: "dir")
      @trashed_dir = node!("old-folder", kind: "dir", deleted: true)
      @trashed_dir.update_column(:trash_root_node_id, @trashed_dir.node_id)
      @other = User.create!(email: "reset-other-#{SecureRandom.hex(4)}@example.com")
      @other_dir = @other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs", kind: "dir")
      @other.maker_pins.create!(node_id: @other_dir.node_id)

      @project = @user.maker_projects.create!(name: "Lamp", folder_node_id: @dir.node_id,
                                              cover_node_id: @file.node_id)
      @user.maker_file_attachments.create!(attachable: @project, node_id: @file.node_id, role: "model")
      @user.maker_file_links.create!(from_node_id: @svg.node_id, to_node_id: @file.node_id,
                                     kind: "derived_from")
      @user.maker_pins.create!(node_id: @dir.node_id)
      @user.maker_pins.create!(node_id: @scratch.node_id)
      @note = @user.maker_notes.create!(node_id: @file.node_id, body: "print at 0.2 mm")
      @folder_note = @user.maker_notes.create!(node_id: @dir.node_id, body: "the lamp lives here")
      @trashed_project = @user.maker_projects.create!(name: "Shelf", folder_node_id: @trashed_dir.node_id)
      @preview = @user.maker_previews.create!(node_id: @file.node_id, kind: "thumbnail", status: "ready")
      @preview.asset.attach(io: StringIO.new("png-bytes"), filename: "thumb.png", content_type: "image/png")
      @blob_id = @preview.asset.blob.id
      @user.maker_repo_edits.create!(repo_root_node_id: @dir.node_id, node_id: @file.node_id)
      @addon_state = @user.maker_addon_states.create!(addon_key: "boxes", name: "box-1", data: {})
      @addon_state.files.create!(node_id: @svg.node_id, role: "output")

      @release = @project.releases.create!(user: @user, version: "v1.0.0", published_at: Time.current,
                                           repo_node_id: @dir.node_id)
      @release_file = @release.files.create!(user: @user, node_id: @file.node_id, name: "bracket.stl")
      @item = @user.maker_items.create!(title: "Bracket", primary_node_id: @file.node_id)
      bom = @project.boms.create!(user: @user)
      @file_line = bom.lines.create!(user: @user, node_id: @file.node_id, quantity: 2)
      @dangling_line = bom.lines.create!(user: @user, node_id: SecureRandom.uuid, quantity: 1)
      @block = @user.maker_project_blocks.create!(project: @project, kind: "image", node_id: @file.node_id)

      @auto = @user.maker_models.create!(title: "Bracket", origin: "auto", auto_node_id: @dir.node_id,
                                         folder_node_id: @dir.node_id)
      @user.maker_file_attachments.create!(attachable: @auto, node_id: @file.node_id, role: "model")
      @dismissed = @user.maker_models.create!(title: "Old", origin: "auto", auto_node_id: @gone.node_id,
                                              dismissed_at: Time.current)
      @import = @user.maker_models.create!(title: "Benchy", folder_node_id: @dir.node_id,
                                           cover_node_id: @file.node_id)
      @task = @user.maker_tasks.create!(title: "Sand it")
      @stock = @user.maker_inventory_items.create!(name: "M3 bolt")

      # Vacuity: a builder that persisted nothing would make every "zero rows" below prove nothing.
      assert_equal 6, @user.nodes.count
      assert ActiveStorage::Blob.exists?(@blob_id), "the preview must really carry a blob"

      @result = perform_enqueued_jobs { Library::Reset.call(@user) }
    end

    test "every row whose identity is a forgotten node is destroyed, tombstones included" do
      assert_equal [ @dir.node_id ], Node.where(user_id: @user.id).pluck(:node_id),
                   "nodes: only the kept project folder is left, the tombstones went too"
      assert_equal 0, @user.maker_file_attachments.count, "maker_file_attachments"
      assert_equal 0, @user.maker_file_links.count, "maker_file_links"
      assert_equal [ @dir.node_id ], @user.maker_pins.pluck(:node_id), "maker_pins: the scratch folder's went"
      assert_equal [ @folder_note.id ], @user.maker_notes.pluck(:id), "maker_notes: the file's went"
      assert_not ActionText::RichText.exists?(record_type: "Maker::Note", record_id: @note.id),
                 "a note's rich text goes with it"
      assert_equal 0, @user.maker_previews.count, "maker_previews"
      assert_equal 0, @user.maker_repo_edits.count, "maker_repo_edits"
      assert_equal 0, @addon_state.files.count, "maker_addon_files"

      # attachments: 1 -- the project's; the auto model's went with the model, destroyed first.
      assert_equal({ nodes: 5, attachments: 1, previews: 1, models: 2, kept: 1 }, @result.to_h)
    end

    # The blob is the one thing a bare DELETE of maker_previews would leave behind for good.
    test "a destroyed preview's blob is purged" do
      assert_not ActiveStorage::Blob.exists?(@blob_id)
    end

    test "every pointer into a forgotten node is nulled" do
      assert_nil @project.reload[:cover_node_id], "maker_projects.cover_node_id"
      assert_nil @trashed_project.reload[:folder_node_id],
                 "maker_projects.folder_node_id, when the folder has no path to find again"
      assert_nil @item.reload.primary_node_id, "maker_items.primary_node_id"
      assert_nil @import.reload[:cover_node_id], "an import model's cover_node_id"
    end

    # RE-LINK BY PATH (the owner's call at review): the folder a project, an import model and a
    # release live in is kept as a SCAN tombstone -- the shape Library::Reconciler#ensure_dirs revives
    # by path with its old node_id -- and every pointer into it is left alone. Mutation-checked:
    # forget it like any other node and every assertion here goes red.
    test "the folders the maker's records live in are kept, as scan tombstones, with their pointers" do
      kept = Node.find_by!(user_id: @user.id, node_id: @dir.node_id)
      assert kept.deleted?, "a tombstone until the next scan finds it"
      assert_equal "parts", kept.storage_path, "a SCAN tombstone keeps its path, which is what revives it"
      assert_nil kept.trash_root_node_id, "and is no trash entry"
      assert_nil kept.parent_node_id, "its parent row is gone; the revive recomputes it"

      assert_equal @dir.node_id, @project.reload[:folder_node_id], "maker_projects.folder_node_id"
      assert_equal @dir.node_id, @release.reload.repo_node_id, "maker_releases.repo_node_id"
      assert_equal @dir.node_id, @import.reload.folder_node_id, "an import model's folder_node_id"
      assert @user.maker_pins.exists?(node_id: @dir.node_id), "the folder's pin waits for the folder"
    end

    # §14d: nulling alone leaves no target, and `exactly_one_target` then refuses every later save.
    # `valid?` FIRST, so the tempting wrong fix (null the column, take no name) fails on the lock
    # itself; skipping the conversion altogether fails on the line that follows, because a dangling
    # node_id is still a target and validates.
    test "a BOM line that named a file keeps the file's name as its part, and stays editable" do
      @file_line.reload
      assert @file_line.valid?, @file_line.errors.full_messages.to_sentence
      assert_nil @file_line.node_id
      assert_equal "bracket.stl", @file_line.part_name

      @dangling_line.reload
      assert @dangling_line.valid?, @dangling_line.errors.full_messages.to_sentence
      assert_nil @dangling_line.node_id
      assert_equal "Missing file", @dangling_line.part_name, "a node already gone still leaves a part"
    end

    test "auto models go, dismissed ones too; the import model stays" do
      assert_not Maker::Model.exists?(@auto.id), "an auto model"
      assert_not Maker::Model.exists?(@dismissed.id), "a dismissed auto model has nothing left to keep dismissed"
      assert Maker::Model.exists?(@import.id), "an import model is the maker's"
    end

    test "the maker's own things survive, history keeps its dangling ids" do
      assert Maker::Project.exists?(@project.id), "the project"
      assert Maker::Task.exists?(@task.id), "the task"
      assert Maker::InventoryItem.exists?(@stock.id), "the inventory item"
      assert Maker::Release.exists?(@release.id), "the release"
      assert Maker::Item.exists?(@item.id), "the item"
      assert Maker::AddonState.exists?(@addon_state.id), "the addon state"
      assert_equal @file.node_id, @release_file.reload.node_id, "a release file is history by design"
      assert_equal @file.node_id, @block.reload.node_id, "an image block requires its id"
    end

    test "the scan bookkeeping is cleared: the next scan is the library's first" do
      @user.reload
      assert_nil @user.library_scanned_at
      assert_nil @user.library_scan_refusal
    end

    test "another user's library is untouched" do
      assert @other.nodes.exists?(@other_dir.id), "their node"
      assert_equal 1, @other.maker_pins.count, "their pin"
    end

    private

    def node!(name, kind: "file", parent: nil, deleted: false)
      path = parent ? "#{parent.storage_path}/#{name}" : name
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind:, parent_node_id: parent&.node_id,
                          storage_path: (path unless deleted), deleted:, size: (0 if kind == "file"))
    end
  end
end
