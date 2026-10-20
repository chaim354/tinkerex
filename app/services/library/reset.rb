module Library
  # "START OVER WITH THIS FOLDER" (K §5): forget everything the catalog learned from the old folder,
  # for one user, in one transaction. NEVER TOUCHES DISK -- the old folder, its .trash and every file
  # stay exactly where they are; this deletes rows. Run only by Library::RootChangeJob, under the
  # scan's own semaphore and on a share deployment only, which then scans the new folder.
  #
  # WHAT GOES IS WHAT A NODE IS: a row whose identity is a node is destroyed, a pointer that merely
  # names one is nulled, and the maker's own things -- projects, tasks, build logs, inventory, BOMs,
  # suppliers, locations, tags, releases, import models -- survive.
  #
  # EXCEPT THE FOLDERS THOSE THINGS LIVE IN, WHICH ARE RE-LINKED BY PATH (the owner's call at review,
  # 2026-10-20). A project's folder, an import model's folder and a release's repository are KEPT as
  # SCAN tombstones -- deleted, `storage_path` kept, no trash entry (§14a's two kinds) -- and their
  # pointers are left alone. The scan of the new folder that follows then revives each one found at
  # the same path with its OLD node_id (Library::Reconciler#ensure_dirs, the rule that already keeps a
  # folder's identity when it is restored on disk), so the project stays linked, discovery counts its
  # folder as claimed rather than adopting a `desk-lamp-2` beside it, and an archived project keeps
  # the claim that keeps its folder dismissed. Pins, notes and attachments on a kept folder stay with
  # it (the sidebar already skips a pin whose folder is a tombstone, so restoring the folder restores
  # the pin). A folder the new library does not have stays a tombstone: the state of a project whose
  # folder was deleted on disk, which the app already answers (Maker::Project#ensure_library_folder!
  # never re-mints one) -- where a nulled pointer would have MINTED a fresh `Projects/<slug>` on the
  # next upload. A folder with no path to match (a TRASH tombstone, whose bytes sit in the OLD
  # folder's .trash) is forgotten as before. Every other pointer into a forgotten node is nulled.
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
    Result = Data.define(:nodes, :attachments, :previews, :models, :kept)

    def self.call(user) = new(user).call

    def initialize(user) = @user = user

    def call
      result = nil
      User.transaction do
        release_bom_lines!
        # FIRST, so the folders they name are not kept: an auto model is the catalog's own, not the
        # maker's, and the next sweep rebuilds it.
        models = @user.maker_models.where(origin: "auto").to_a.each(&:destroy!).size
        kept = kept_folders
        attachments = @user.maker_file_attachments.where.not(node_id: kept).delete_all
        @user.maker_file_links.where.not(from_node_id: kept).or(@user.maker_file_links.where.not(to_node_id: kept))
             .delete_all
        @user.maker_pins.where.not(node_id: kept).delete_all
        @user.maker_repo_edits.where.not(node_id: kept).delete_all
        Maker::AddonFile.where(addon_state_id: @user.maker_addon_states.select(:id)).where.not(node_id: kept)
                        .delete_all
        @user.maker_notes.where.not(node_id: kept).find_each(&:destroy!)
        previews = 0
        @user.maker_previews.where.not(node_id: kept).find_each { |preview| preview.destroy!; previews += 1 }
        # Only import rows are left, and nothing but the intake writes `auto_node_id`, so that column
        # is already nil here; nulling it anyway cannot collide with the partial unique index, which
        # covers non-NULL values only.
        @user.maker_models.update_all(cover_node_id: nil, auto_node_id: nil)
        @user.maker_models.where.not(folder_node_id: kept).update_all(folder_node_id: nil)
        @user.maker_projects.update_all(cover_node_id: nil)
        @user.maker_projects.where.not(folder_node_id: kept).update_all(folder_node_id: nil)
        @user.maker_releases.where.not(repo_node_id: kept).update_all(repo_node_id: nil)
        @user.maker_items.update_all(primary_node_id: nil)
        nodes = @user.nodes.where.not(node_id: kept).delete_all
        # SCAN tombstones: deleted, path kept, no trash entry, and no parent -- the parent row is gone,
        # and the revive recomputes it from the path. `updated_at` now, so the reapers' grace window
        # (Maker::DeadNodes) starts at the reset, as it does for any tombstone.
        @user.nodes.where(node_id: kept).update_all(deleted: true, trash_root_node_id: nil, parent_node_id: nil,
                                                    updated_at: Time.current)
        @user.update_columns(library_scanned_at: nil, library_scan_refusal: nil)
        result = Result.new(nodes:, attachments:, previews:, models:, kept: kept.size)
      end
      Rails.logger.info("Library::Reset: user #{@user.id}: #{result.to_h}")
      result
    end

    private

    # The folders the maker's own surviving records live in, that a later scan can find again: a
    # DIRECTORY with a path. Asked after the auto models are gone.
    def kept_folders
      ids = @user.maker_projects.where.not(folder_node_id: [ nil, "" ]).pluck(:folder_node_id) +
            @user.maker_models.where.not(folder_node_id: [ nil, "" ]).pluck(:folder_node_id) +
            @user.maker_releases.where.not(repo_node_id: [ nil, "" ]).pluck(:repo_node_id)
      return [] if ids.empty?

      @user.nodes.where(node_id: ids.uniq, kind: "dir").where.not(storage_path: [ nil, "" ]).pluck(:node_id)
    end

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
