module FileLayer
  # EVERY NODE AT OR BENEATH A DIRECTORY, walked by the parent edge.
  #
  # WHY THIS IS ONE SHARED THING rather than a private method on each adapter: share and s3 move a
  # deleted directory's bytes completely differently — one atomic rename against one copy-and-delete
  # per object — but they must tombstone exactly the SAME SET, and a second copy of this walk is a
  # second chance to tombstone a subset. A live node left pointing at a path now inside `.trash` is
  # §14b's skip-list wedge: the scan refuses to look in `.trash`, so no observation can ever pair
  # it, and the tombstone that follows trips the mass-deletion guard — refusing that scan and every
  # scan after it, permanently. There is no error and no log; the library simply stops indexing.
  #
  # BY `parent_node_id`, NEVER BY `storage_path` PREFIX. `move` rewrites only the moved node's own
  # row, so a moved directory's descendants keep a STALE storage_path until the next scan pairs them
  # back — a prefix walk would miss exactly the children most likely to be mid-reorganisation, which
  # is the wedge again with a narrower door. The parent edge is always accurate in the catalog.
  #
  # TOMBSTONES ARE INCLUDED, AND THAT IS A CLAIM ABOUT REACH, NOT MEMBERSHIP. A live row can sit
  # beneath a tombstoned directory — `undelete` restores into a folder the scan tombstoned, and it
  # stays that way until the next scan revives the folder — so a walk that stopped at tombstones
  # would leave that row live by omission. WHICH returned rows a delete moves is not this walk's
  # answer: a tombstone already in the folder was never part of what the user deleted, so each
  # adapter narrows its own UPDATE to `present` rows. Narrow the consumers, never this walk.
  module Subtree
    # A cap on DEPTH, not on size. `parent_node_id` has no constraint forbidding a cycle — the same
    # reason `Maker::LibraryTree#path_for` carries a guard (docs/invariants/model-intake.md) — and
    # without this the walk never returns, holding a Puma thread until the request times out. 64 is
    # far past any real library and far short of hanging.
    MAX_DEPTH = 64

    # Returns the node ids as an Array, root first. ADAPTER-AGNOSTIC AND ITERATIVE, not a recursive
    # CTE: this codebase runs on SQLite and Postgres from one adapter-agnostic codebase (§14e), and
    # a level-at-a-time walk is one query per LEVEL whatever the width — a folder of 200 files costs
    # the same two queries as a folder of two.
    def self.node_ids(user, root_node_id)
      root = root_node_id.to_s
      return [] if root.blank?

      ids = [ root ]
      seen = { root => true }
      frontier = ids
      MAX_DEPTH.times do
        break if frontier.empty?

        # `user.nodes` SCOPES THE WALK, so a foreign row that names one of these as its parent — a
        # corrupt or hand-edited catalog — cannot pull another tenant's node into a delete.
        frontier = user.nodes.where(parent_node_id: frontier).pluck(:node_id)
        # The `seen` filter is what makes a cycle terminate at the point it closes rather than
        # running out the depth cap, and it also keeps a diamond from being visited twice.
        frontier = frontier.reject { |id| seen[id] }
        frontier.each { |id| seen[id] = true }
        ids.concat(frontier)
      end
      ids
    end
  end
end
