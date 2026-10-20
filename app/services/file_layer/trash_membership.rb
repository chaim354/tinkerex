module FileLayer
  # WHICH TRASH ENTRY A TOMBSTONE BELONGS TO, AND SO WHAT A RESTORE BRINGS BACK — read from
  # `nodes.trash_root_node_id`, the one place it is recorded (F-S02-1, 2026-10-20). Share and s3 only:
  # chunk_remote's trash is the sync server's and its mirror records no entry at all.
  #
  # `delete` writes the column on every row it moves: the deleted node's own id on itself and on every
  # LIVE row of its subtree. A row already tombstoned keeps what it had — a SCAN tombstone stays NULL
  # (its bytes left in Finder or the console, its path kept: §14a's two kinds), an older trash entry
  # keeps its own root and its own date. So `trash_root_node_id IS NOT NULL` and `deleted AND
  # storage_path IS NULL` are two spellings of one fact, and the adapters' suites assert they agree on
  # every row (adapter_trash_entry_contract.rb): the NULL path is what stops `Reconciler#create_or_revive!`
  # reviving a trash row by path, the column is what `undelete` reads.
  #
  # IT REPLACES AN INFERENCE. A folder restore used to revive every walked row whose rebuilt path
  # existed after the move back, and to skip a row that still owned a `.trash/<id>` entry — so a file
  # deleted on its own and replaced inside the folder looked like a member the moment the purge took its
  # entry: it came back over its replacement's bytes, or collided with the replacement in the partial
  # unique index and 500ed mid-restore. Where bytes are says nothing about which delete moved them; the
  # column says exactly that, and it says it after the purge too.
  #
  # Duplicating this per adapter would be two chances to revive different sets, the argument
  # FileLayer::Subtree makes for the walk itself. The BYTES stay each adapter's: share renames one
  # directory, s3 copies per object, and each asks its own store whether a member's bytes came back.
  module TrashMembership
    # The entry `node` is restored as, or the refusal — asked BEFORE any byte is touched.
    #
    #   NULL               -> NotFound. Not in the trash: a scan tombstone, removed outside the app,
    #                         with nothing in `.trash` to bring back.
    #   another node's id  -> UnsupportedOperation while that root is still in the trash: the row went
    #                         in with its folder and comes back with it (§14a — a refusal is recoverable,
    #                         restore the folder first; a scatter to the root is not). Once the root is
    #                         back, the membership is spent: the row is restored on its own, from its own
    #                         entry. A member the folder's restore could not bring back has none (NotFound,
    #                         purged?), and a row the backfill filed under its folder because the old
    #                         cascade re-stamped it (the migration says when) still has its own.
    #   a trashed parent   -> UnsupportedOperation, the same sentence: an entry root deleted on its own
    #                         before its folder was can only come back into a folder that is back.
    #
    # Returns the membership KEY the restore revives by: the node's own id for an entry root, the spent
    # root's id for a row restored on its own, so a folder restored that way brings back the rows
    # beneath it that recorded the same root.
    def self.restorable!(user, node)
      key = node.trash_root_node_id
      if key.nil?
        raise NotFound, "#{node.node_id.inspect} is not in the trash: it was removed outside the app, " \
                        "so there is nothing to restore"
      end
      if key != node.node_id && user.nodes.exists?(node_id: key, trash_root_node_id: key)
        raise UnsupportedOperation, "#{node.node_id.inspect}: its folder is in the trash too — restore the folder first"
      end

      parent = user.nodes.find_by(node_id: node.parent_node_id) if node.parent_node_id.present?
      if parent&.trash_root_node_id.present?
        raise UnsupportedOperation, "#{node.node_id.inspect}: its folder is in the trash too — restore the folder first"
      end

      key
    end

    # Every row beneath `root` that recorded `key`, top-down, each with its path beneath `root` built
    # from NAMES along the parent edge — never from storage_path, which the delete NULLed. Root-first
    # level order is the guarantee a revive needs (a child's path is its parent's plus its name).
    #
    # THE WALK GOES THROUGH a row that recorded no entry — a live row, or a scan tombstone kept beneath
    # the folder — because a member can sit below one: a file restored into a folder the scan had
    # tombstoned travels with the folder above it while that folder's row does not. It STOPS at a row of
    # another entry, which went into the trash on its own, before this one, with everything beneath it.
    def self.members(user, root, key)
      ids = Subtree.node_ids(user, root.node_id)
      by_parent = user.nodes.where(node_id: ids - [ root.node_id ]).group_by(&:parent_node_id)
      found = []
      seen = Set[root.node_id]
      queue = [ [ root.node_id, nil ] ]
      until queue.empty?
        parent_id, parent_rel = queue.shift
        Array(by_parent[parent_id]).each do |child|
          next unless seen.add?(child.node_id)
          next unless child.trash_root_node_id.nil? || child.trash_root_node_id == key

          rel = parent_rel ? "#{parent_rel}/#{child.name}" : child.name
          found << [ child, rel ] if child.trash_root_node_id == key
          queue << [ child.node_id, rel ]
        end
      end
      found
    end
  end
end
