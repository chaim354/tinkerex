# frozen_string_literal: true

module FileLayer
  class ChunkRemote
    # THE MAKER APP AS A SYNC CLIENT — pulls changelog deltas from a remote sync server and applies
    # them to this app's OWN `nodes`, which is what `apply_remote` does in Rust (sync-protocol.md;
    # design §6). This is the piece that lets `chunk_remote` reads be LOCAL SQL: once the tree is
    # mirrored here, `stat`/`stat_all`/`trashed` never touch the WAN, and CLAUDE.md §2's "the WAN is
    # never in the metadata path" becomes true of the maker app for the first time.
    #
    # ONE UPSERT FOR EVERY OP, NOT A BRANCH PER OP. Each entry carries the node's FULL post-change
    # state (`Sync::Changes.serialize` emits parent_node_id, name, kind, deleted, mode, mtime), so
    # "apply" is "make the local row equal that", whatever the op was. A per-op state machine
    # (`move` edits parent, `delete` sets a flag...) would be six chances to disagree with the
    # server about a state the server already told us. The op is retained for the DELETE-without-a-
    # node case below and for nothing else.
    class ChangelogSync
      PAGE = 500

      Result = Data.define(:applied, :cursor, :resynced) do
        def to_s = "applied=#{applied} cursor=#{cursor} resynced=#{resynced}"
      end

      def initialize(user, transport:)
        # Parents of live files applied by THIS pull, for the project-intake nudge (see #call).
        @nudge_parents = Set.new
        @user = user
        @transport = transport
      end

      # Pulls until caught up. Returns a Result; raises FileLayer::FetchError on a wire failure,
      # which the caller renders as a retryable 503 rather than as an empty library.
      #
      # ONE GET OPENS IT, NOT TWO. `oldest_seq` and `head_seq` are computed independently of
      # `since`/`limit` and ride on EVERY /v1/changes response, so the separate `limit: 1` probe
      # this used to open with asked the WAN for data the first page was about to carry anyway --
      # a doubled round trip on every pull (720 per user per day at the 2-minute cadence) for a
      # question that answers "no" in every library where changelog retention is not pruning.
      # It was also two SEPARATE observations of the server for one decision: a prune landing
      # between the probe and the page would answer "not gapped" and then apply a page with a
      # silent hole -- the exact failure the check exists to prevent. One body answers both.
      def call
        resynced = false
        applied = 0
        body = fetch_changes

        # THE GAP IS DECIDED EXACTLY ONCE, OUTSIDE THE LOOP, AND THAT PLACEMENT IS LOAD-BEARING
        # RATHER THAN TIDY. A server can report an `oldest_seq` that stays ABOVE the cursor we
        # resync TO -- `head_seq + 1` is what an emptied changelog reports (sync-protocol.md) --
        # so re-asking per page would resync forever against it, never applying anything. Once is
        # also all the question is worth: a resync re-reads the whole tree and leaves the cursor at
        # the server's own head, which cannot be behind what survived the prune.
        if gapped?(body)
          full_resync(head_seq: body["head_seq"].to_i)
          resynced = true
          # THE PRE-RESYNC PAGE IS DISCARDED, NEVER APPLIED. It was computed against a cursor the
          # server has just told us is worthless, and `apply_page` is also what feeds
          # @nudge_parents -- applying it would file stale arrivals (docs/invariants/
          # project-intake.md's "the nudge is DELIBERATELY NOT fed by full_resync") and write
          # partial pre-prune state over the tree the resync just made correct. The cost is one
          # wasted PAGE-sized body per prune event, against the 720 round trips a day saved.
          body = fetch_changes
        end

        loop do
          before = cursor
          entries = body["changes"] || []
          break if entries.empty?

          apply_page(entries)

          # THE CURSOR MUST STRICTLY ADVANCE, AND THIS GUARD WAS ADDED BECAUSE MUTATION-TESTING
          # HUNG RATHER THAN FAILED. Freezing the cursor turned this into an infinite loop: a FULL
          # page keeps `entries.size < PAGE` false, so it refetched `since: 0` forever, holding a
          # request or a job with no error anywhere. A server that replays a page, or a future edit
          # that drops the cursor write, must fail LOUDLY and quickly instead of spinning.
          #
          # `<=`, not `==`: a cursor that went BACKWARDS is the same class of wrong and would loop
          # just as happily.
          raise FileLayer::FetchError,
                "sync server changelog did not advance past seq #{before} -- refusing to loop" if cursor <= before

          applied += entries.size
          # PAGE-AT-A-TIME, COMMITTING THE CURSOR AS WE GO. A single transaction around the whole
          # catch-up would make a 200k-entry first sync one lock; worse, an interruption at entry
          # 199k would discard all of it and start over. Each page is atomic, so a crash resumes
          # from the last committed page rather than from zero.
          break if entries.size < PAGE

          body = fetch_changes
        end

        # THE DEVICE-PUSH FAST PATH, RESTORED HERE RATHER THAN AT A COMMIT.
        #
        # CLAUDE.md §12.10 recorded `Maker::ProjectIntakeJob.nudge` as live, correct and CALLERLESS:
        # PR #135 gave it an enqueue-with-delay shape, `984a3dc` moved its caller behind the sync
        # engine's `Sync::Hooks` seam, and the engine then left this repo -- so nothing reached it
        # and a file arriving through a device mount waited up to 15 minutes for the periodic sweep.
        #
        # THE SIGNAL WAS ALREADY HERE. §12.10 also guessed that re-wiring would need the sync server
        # to signal this app -- "a protocol question." It does not: this pull is exactly where this
        # app LEARNS about a node another device pushed, and it learns locally. Latency goes from
        # "up to 15 minutes" to "the 2-minute pull, plus NUDGE_DELAY".
        #
        # AFTER THE LOOP, NOT INSIDE IT, and that placement is the cost control: one `exists?` for
        # the whole catch-up instead of one per page, and none at all for the overwhelmingly common
        # pull that applied nothing. A first sync of 200k entries asks it once.
        #
        # `full_resync` DELIBERATELY DOES NOT FEED THIS. It re-applies the entire tree, so every
        # file in the library would look like an arrival; the periodic sweep is the right mechanism
        # for that case and already covers it.
        nudge_project_intake

        Result.new(applied:, cursor:, resynced:)
      end

      private

      # Best-effort by construction -- `nudge_parents` swallows and logs. The cursor is already
      # committed by the time this runs, so a failure here must never look like a failed pull.
      def nudge_project_intake
        return if @nudge_parents.empty?

        Maker::ProjectIntakeJob.nudge_parents(user: @user, parent_node_ids: @nudge_parents.to_a)
      end

      def cursor = @user.remote_sync_cursor

      # ONE PAGE-SIZED GET IS THE WHOLE REQUEST SHAPE. `limit: PAGE` is the server's own default
      # and is clamped to [1, 2000] there, so this asks for nothing unusual -- it is the same
      # request the Rust reference client makes, and its body carries the gap fields too.
      def fetch_changes = @transport.get("/v1/changes", { since: cursor, limit: PAGE })

      # THE PRUNED-GAP CHECK, AND `oldest_seq` IS WHY THE SERVER SENDS IT. Retention can prune
      # changelog entries; a cursor below what survives means the delta we would receive has a HOLE,
      # and applying it leaves a tree that is silently wrong -- files the server deleted still
      # present, moves never seen. The protocol's answer is not to patch the hole but to stop
      # trusting the cursor: re-read the whole tree.
      #
      # `cursor.positive?` matters: a FIRST sync has cursor 0, which is below every oldest_seq, and
      # is not a gap -- it is the ordinary beginning. Treating it as one would work, but would call
      # every first sync a "resync" and make the signal useless for spotting real prunes.
      #
      # `cursor < oldest` IS CARRIED OVER VERBATIM AND IS NOT THE PLACE TO TIDY. The Rust client
      # spells the same question `oldest_seq > cursor + 1`, i.e. it does NOT call `oldest ==
      # cursor + 1` a gap and this does. That divergence is a wire-spec question for tinkerex-sync
      # (§14j: the boundary is a network), unreachable while nothing schedules a prune, and
      # changing it here would silently make the two clients disagree about the same server.
      def gapped?(body)
        oldest = body["oldest_seq"].to_i
        cursor.positive? && oldest.positive? && cursor < oldest
      end

      # Re-reads /v1/tree, which returns only LIVE nodes, then marks anything local that the server
      # did not mention as deleted. Without that sweep a resync is additive and every file deleted
      # while we were behind stays visible forever -- the exact failure a resync exists to repair.
      def full_resync(head_seq:)
        seen = []
        after_id = 0

        loop do
          body = @transport.get("/v1/tree", { after_id:, limit: 1000 })
          nodes = body["nodes"] || []
          break if nodes.empty?

          @user.transaction do
            nodes.each do |n|
              # A TREE NODE CARRIES ITS CONTENT FLAT -- `version_id`, `size`, `manifest` beside its
              # name (sync-protocol.md §8.4), where a change entry nests `version` (§8.3) -- so this
              # arm reads its own shape and hands `upsert` what `apply_page` hands it. Handing over
              # nothing once let every resync repair a node's place and keep its stale content: a
              # file created while the mirror was behind listed at 0 bytes and 404'd on read, a
              # changed one served its old bytes. No `version_id` (a directory, a symlink) is no
              # content, like a change entry with no `version`, and leaves the row's own alone.
              version = n["version_id"] ? n.slice("version_id", "size") : nil
              upsert(n, deleted: false, version:, manifest: n["manifest"])
            end
          end
          seen.concat(nodes.map { |n| n["node_id"] })
          after_id = body["next_after_id"].to_i
          break if after_id.zero?
        end

        @user.transaction do
          @user.nodes.present.where.not(node_id: seen).update_all(deleted: true) if seen.any?
          @user.update_column(:remote_sync_cursor, head_seq)
        end
      end

      def apply_page(entries)
        @user.transaction do
          entries.each do |entry|
            node = entry["node"]
            if node
              # A CHANGE ENTRY CARRIES ITS CONTENT AT THE ENTRY LEVEL -- `version` and `manifest`
              # beside `node`, never inside it -- and only on a `put` whose version still resolves
              # (sync-protocol.md §8.3). Every other op omits both, and so does a `put` whose version
              # was pruned since: `upsert` then leaves the row's content alone rather than nulling it.
              upsert(node, deleted: node["deleted"], version: entry["version"], manifest: entry["manifest"])
              # A LIVE FILE LANDING SOMEWHERE is the only kind of entry that can need filing, so
              # only those parents are collected. Directories have nothing to file and a tombstone
              # is a removal; collecting either would enqueue sweeps for changes that cannot move
              # anything. The `exists?` that decides whether this is a PROJECT folder is asked once
              # for the whole pull, in `nudge_project_intake` below -- never here, per entry.
              if !node["deleted"] && node["kind"] == "file" && node["parent_node_id"].present?
                @nudge_parents << node["parent_node_id"]
              end
            else
              # THE SERVER SENT NO NODE PAYLOAD. Sync::Changes only includes one when the row still
              # exists, so this is a node hard-removed since the entry was written. Marking the
              # local row deleted is the honest reading; creating one from node_id alone would
              # invent a nameless, parentless row.
              @user.nodes.where(node_id: entry["node_id"]).update_all(deleted: true)
            end
          end
          @user.update_column(:remote_sync_cursor, entries.last["seq"].to_i)
        end
      end

      # THE CONTENT ARRIVES AS TWO EXPLICIT ARGUMENTS, NEVER DUG OUT OF `payload`, because the two
      # wire shapes keep it in different places: a change entry's `version`/`manifest` ride on the
      # ENTRY, a tree node's lie flat on the NODE. Each caller reads its own shape; this reads
      # neither. REQUIRED keywords, not defaults: a caller that forgets them is an ArgumentError,
      # where the `version ||= payload["version"]` guess this replaced made forgetting SILENT -- the
      # resync arm passed nothing, the guess looked for a key no tree has ever sent, and every
      # resynced file kept stale content (CLAUDE.md §14e: the only test's fake shared the guess).
      # `version` nil means "this payload carries no content", and leaves the row's own alone.
      #
      # `size` COMES OFF THE VERSION AND LANDS ON THE NODE, which is the whole reason `stat_all` can
      # be ONE query here. `nodes.size` already exists and is NULL on chunk -- only
      # Library::Reconciler ever wrote it, and Chunk#stat_all pays a second query to `versions` for
      # what this loop can record once, at apply time.
      def upsert(payload, deleted:, version:, manifest:)
        row = @user.nodes.find_or_initialize_by(node_id: payload["node_id"])
        row.parent_node_id = payload["parent_node_id"]
        row.name = payload["name"]
        row.kind = payload["kind"]
        row.mode = payload["mode"]
        row.mtime = payload["mtime"]
        row.deleted = !!deleted

        if version
          row.current_version_id = version["version_id"]
          row.size = version["size"]
          # THE MANIFEST IS KEPT, NOT DISCARDED. It arrives unbidden with every put, and
          # POST /v1/chunks/download cannot be asked "what are the chunks for node X" -- only
          # "presign these hashes". Dropping it here would leave byte reads with no way to name the
          # chunks they need, and the only alternative is a new server endpoint the design forbids.
          store_manifest(version["version_id"], manifest)
        end
        row.symlink_target = Base64.decode64(payload["symlink_target"]) if payload["symlink_target"]

        row.save!
      end

      # IDEMPOTENT BY DELETE-THEN-INSERT, because a resync re-applies versions this app already has
      # and `insert_all` would collide on the unique (user, version, seq) index. Replacing rather
      # than skipping also means a manifest that somehow differs is corrected rather than kept --
      # the server is the source of truth for what a version is made of.
      def store_manifest(version_id, manifest)
        return if version_id.blank? || manifest.blank?

        RemoteManifestChunk.where(user_id: @user.id, version_id:).delete_all
        rows = manifest.each_with_index.map do |c, i|
          { user_id: @user.id, version_id:, seq: i, chunk_hash: c["hash"],
            offset: c["offset"], length: c["length"], created_at: Time.current, updated_at: Time.current }
        end
        RemoteManifestChunk.insert_all(rows)
      end
    end
  end
end
