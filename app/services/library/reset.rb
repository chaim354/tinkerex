module Library
  # "START OVER WITH THIS FOLDER" (K §5): forget everything the catalog learned from the old folder,
  # for one user, in one transaction. NEVER TOUCHES DISK -- the old folder, its .trash and every file
  # stay exactly where they are; this deletes rows. Run only by Library::RootChangeJob, under the
  # scan's own semaphore and on a share deployment only, which then scans the new folder.
  #
  # WHAT GOES IS WHAT A NODE IS: a row whose identity is a node is destroyed, a pointer that merely
  # names one is nulled, and the maker's own things -- projects, tasks, build logs, inventory, BOMs,
  # suppliers, locations, tags, releases, import models -- survive. Every node of this user goes
  # (tombstones included), so every pointer into them dangles; the nulls are therefore unconditional,
  # with no node-id list to carry.
  #
  # Three are handled differently, each for a recorded rule:
  #   - a BOM line that names a file takes the file's name as its part first: nulling alone leaves
  #     no target and `exactly_one_target` locks the row (§14d, InventoryItem#release_bom_lines);
  #   - AUTO models are destroyed, dismissed ones too: a dismissal names a node_id this deletes and
  #     no later scan can mint again, so there is nothing left for it to keep dismissed. Their print
  #     runs and taggings go with them (Maker::Model's own `dependent:`s);
  #   - release files and image blocks keep their dangling ids: a release file is history by design
  #     (it renders "gone"), and an image block requires its id and already hides when it resolves
  #     to nothing (projects/_block_panel).
  #
  # PREVIEWS ARE DESTROYED ONE BY ONE, NOT DELETED: `has_one_attached :asset` purges its blob only
  # through a record-level destroy (purge_later, after commit). A bare DELETE strands every rendered
  # thumbnail in Active Storage with nothing left to name it. Notes likewise, for their rich text.
  class Reset
    Result = Data.define(:nodes, :attachments, :previews, :models)

    def self.call(user) = new(user).call

    def initialize(user) = @user = user

    def call
      result = nil
      User.transaction do
        release_bom_lines!
        attachments = @user.maker_file_attachments.delete_all
        @user.maker_file_links.delete_all
        @user.maker_pins.delete_all
        @user.maker_repo_edits.delete_all
        Maker::AddonFile.where(addon_state_id: @user.maker_addon_states.select(:id)).delete_all
        @user.maker_notes.find_each(&:destroy!)
        previews = 0
        @user.maker_previews.find_each { |preview| preview.destroy!; previews += 1 }
        models = @user.maker_models.where(origin: "auto").to_a.each(&:destroy!).size
        # Only import rows are left, and nothing but the intake writes `auto_node_id`, so that column
        # is already nil here; nulling it anyway cannot collide with the partial unique index, which
        # covers non-NULL values only.
        @user.maker_models.update_all(folder_node_id: nil, cover_node_id: nil, auto_node_id: nil)
        @user.maker_projects.update_all(folder_node_id: nil, cover_node_id: nil)
        @user.maker_releases.update_all(repo_node_id: nil)
        @user.maker_items.update_all(primary_node_id: nil)
        nodes = @user.nodes.delete_all
        @user.update_columns(library_scanned_at: nil, library_scan_refusal: nil)
        result = Result.new(nodes:, attachments:, previews:, models:)
      end
      Rails.logger.info("Library::Reset: user #{@user.id}: #{result.to_h}")
      result
    end

    private

    # Only a line left with NO other target takes the name -- release_bom_lines' own rule: a line
    # that also names an item or a part already has one, and a second would fail
    # `exactly_one_target` just as surely as none. Blank counts as absent, as `present?` does there.
    def release_bom_lines!
      lines = @user.maker_bom_lines.where.not(node_id: [ nil, "" ]).to_a
      return if lines.empty?

      names = @user.nodes.where(node_id: lines.map(&:node_id)).pluck(:node_id, :name).to_h
      lines.each do |line|
        if line.inventory_item_id.present? || line.part_name.present?
          line.update_columns(node_id: nil)
        else
          line.update_columns(node_id: nil, part_name: names[line.node_id] || "Missing file")
        end
      end
    end
  end
end
