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
  # AND EVERY RECORDED ROOT IS STILL IN THE TRASH (the suites assert this too). The root's id is the
  # deleted node's own node_id, which the same folder's NEXT delete writes again — so a restore that
  # cannot bring a member back (its bytes are gone from the entry, or the backfill filed it under a
  # folder it was not deleted with) must not leave it naming the folder, or the next delete adopts it
  # and the next restore revives it over a same-named replacement: audit defect (b), through the
  # column. #release! re-roots what a restore leaves behind.
  #
  # Duplicating this per adapter would be two chances to revive different sets, the argument
  # FileLayer::Subtree makes for the walk itself. The BYTES stay each adapter's: share renames one
  # directory, s3 copies per object, and each asks its own store whether a member's bytes came back.
  module TrashMembership
    # Whether `node` may be restored as the root of an entry, or the refusal — asked BEFORE any byte is
    # touched. Raises, or returns nothing:
    #
    #   NULL               -> NotFound. Not in the trash: a scan tombstone, removed outside the app,
    #                         with nothing in `.trash` to bring back.
    #   another node's id  -> UnsupportedOperation while that root is still in the trash: the row went
    #                         in with its folder and comes back with it (§14a — a refusal is recoverable,
    #                         restore the folder first; a scatter to the root is not). A root that is NOT
    #                         in the trash can only be one whose row is gone (a restore re-roots what it
    #                         leaves behind, #release!): no folder is left to restore, so the row answers
    #                         on its own — from its own entry, or NotFound (purged?) for want of one.
    #   a trashed parent   -> UnsupportedOperation, the same sentence: an entry root deleted on its own
    #                         before its folder was can only come back into a folder that is back.
    #
    # "IN THE TRASH" IS THE COLUMN AND THE TRASH SHAPE TOGETHER, never the column alone: code from before
    # the column revives a row without clearing it, so an image rolled back past the migration can leave
    # a LIVE folder still naming itself — and a member sent to restore it would be refused for good.
    def self.restorable!(user, node)
      root_id = node.trash_root_node_id
      if root_id.nil?
        raise NotFound, "#{node.node_id.inspect} is not in the trash: it was removed outside the app, " \
                        "so there is nothing to restore"
      end
      if root_id != node.node_id &&
         user.nodes.exists?(node_id: root_id, trash_root_node_id: root_id, deleted: true, storage_path: nil)
        raise UnsupportedOperation, "#{node.node_id.inspect}: its folder is in the trash too — restore the folder first"
      end

      parent = user.nodes.find_by(node_id: node.parent_node_id) if node.parent_node_id.present?
      return unless parent&.trash_root_node_id.present? && parent.deleted? && parent.storage_path.nil?

      raise UnsupportedOperation, "#{node.node_id.inspect}: its folder is in the trash too — restore the folder first"
    end

    # Every row beneath `root` that recorded `root` as its entry, top-down, each with its path beneath
    # `root` built from NAMES along the parent edge — never from storage_path, which the delete NULLed.
    # Root-first level order is the guarantee a revive needs (a child's path is its parent's plus its
    # name).
    #
    # THE WALK GOES THROUGH a row that recorded no entry — a live row, or a scan tombstone kept beneath
    # the folder — because a member can sit below one: a file restored into a folder the scan had
    # tombstoned travels with the folder above it while that folder's row does not. It STOPS at a row of
    # another entry, which went into the trash on its own, before this one, with everything beneath it.
    def self.members(user, root)
      key = root.node_id
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

    # RE-ROOT WHAT A RESTORE LEFT BEHIND, once its root is back: every member of `members` (as #members
    # answered them, top-down) not in `revived` becomes the root of its own entry — or joins its nearest
    # left-behind ancestor's, since a row whose folder stayed behind with it went into the trash with
    # that folder (by everything the catalog can tell). Its own restore then answers from its own
    # entry: a row the backfill filed under a folder it was not deleted with still has one; a member
    # whose bytes were lost has none, and says so (NotFound, purged?) instead of being adopted by the
    # folder's next delete. One `update_all` per root.
    #
    # Callers run it whatever the revive did, including when it raised partway (a scan racing the
    # restore, the residual both adapters accept) — but only once the ROOT is back: a restore that
    # failed before that leaves its whole entry in the trash, which is where a retry finds it.
    # DELIBERATELY UNGUARDED in those `ensure`s: if this raises too, its error replaces the revive's. It
    # is plain UPDATEs on the connection the revive just used, so it fails only when the database does,
    # and that failure is the one to report; rescuing it to re-raise the first would hide it instead.
    def self.release!(user, members, revived)
      roots = {}
      members.each do |row, _|
        next if revived.include?(row.node_id)

        roots[row.node_id] = roots[row.parent_node_id] || row.node_id
      end
      roots.group_by(&:last).each do |root, pairs|
        user.nodes.where(node_id: pairs.map(&:first)).update_all(trash_root_node_id: root)
      end
    end
  end
end
