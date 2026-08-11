module Maker
  module Previews
    # One-off repair: enqueue a thumbnail for every live file that has no preview THE READ PATH
    # WOULD SERVE.
    #
    # Since 20260730001500 there is ONE row per (node, kind), repointed as content moves, so "no
    # preview for the current content" means either no row at all or a row still pointing at
    # superseded content. Both are handled the same way — `Enqueue` creates or repoints.
    #
    # THE `seen` KEY IS THE (node_id, version_id, renderer_revision) TRIPLE, AND IT MUST BE THE
    # SAME TRIPLE `FilesController#thumbnails_for` AND `#current_thumbnail` RESOLVE ON. It was the
    # PAIR (node_id, version_id) until 2026-08-07, and that omission is the whole reason this sweep
    # could not repair a renderer bump: a row built by an older build sits at the current content,
    # so it satisfied a pair-keyed check and was skipped — while the read path, which does compare
    # revisions, treated the very same row as absent and re-enqueued it. Two answers to one
    # question, and the sweep held the wrong one.
    #
    # The consequence was not theoretical. `Stl`/`ThreeMf` moved to revision 2 (the Z-up camera
    # fix), which means every STL and 3MF thumbnail already in a library depicts a model lying on
    # its side. Those files self-heal only when someone OPENS the page that shows them; a library
    # nobody browses stays wrong indefinitely, and this task existed, was run, and reported
    # "Enqueued 0" while every one of them was stale.
    #
    # WHAT IT STILL DOES NOT DO, deliberately: `kind` is `thumbnail` only. Geometry payloads carry
    # their own revisions, but they are built on demand by a client that polls
    # (`FilesController#geometry`), so sweeping them would render measurement data for every
    # measurable file in the library whether or not anyone ever measures it. A thumbnail is
    # different in kind — it is what the FILE LIST draws, so it is wanted before anyone asks.
    #
    # WHY A SWEEP IS NEEDED AND A SCAN IS NOT ENOUGH. `Library::Reconciler` used to enqueue a
    # thumbnail only for files it had never seen; a file re-saved in place had its `content_hash`
    # updated and nothing else, so its preview row stayed keyed to content that no longer exists
    # while every surface that resolves one by the current `content_token` — `FilesController#show`
    # and `#thumbnails_for` — found none. That is fixed at the source, but the fix cannot reach
    # backwards: those files are now `unchanged?` and the next scan skips them WITHOUT re-reading
    # them, which is exactly the behaviour that keeps a 2TB archive cheap. So the backlog needs
    # its own pass. Same shape as [[LbrnBackfill]], different condition.
    #
    # NOT the `unsupported`-row sweep docs/STATUS.md still leaves open. A row saying `unsupported`
    # for the current content is present and terminal; this only ever looks for content with NO
    # row, so the two migrations stay separable and keep their own correctness arguments.
    #
    # Backend-neutral: the token comes from `FileLayer#stat_all`, the port's bulk read, which is
    # `current_version_id` on chunk and `content_hash` on share/s3 and costs no filesystem or
    # network I/O on any of them. Idempotent — a second run enqueues nothing, because the first
    # run's rows are what it now finds.
    module MissingBackfill
      module_function

      BATCH = 500
      KIND = "thumbnail".freeze

      # Returns the number of previews enqueued (or, under `dry_run`, that WOULD be enqueued).
      def call(user: nil, dry_run: false)
        (user ? [ user ] : User.all.to_a).sum { |u| backfill(u, dry_run:) }
      end

      # `dry_run` EXISTS BECAUSE THIS SWEEP CAN NOW COST A FULL-LIBRARY RE-RENDER. Before the
      # revision check it only ever found a backlog someone was already missing; a renderer bump
      # makes every file of that format eligible at once, and an operator deciding whether to run
      # that on a 2000-file library deserves the number first. Deliberately NOT capped the way
      # `ProjectIntake::MAX_MOVES` is: a cap there bounds unattended churn, whereas here doing all
      # of them IS the task, so a cap would be guarding against success.
      def backfill(user, dry_run: false)
        count = 0
        # `present` here keeps tombstones out of the BATCH; it is not what keeps a deleted file
        # from sprouting a preview. `stat_all` already omits one (absent key, never a raise), and
        # the token check below is what acts on that.
        user.nodes.present.where(kind: "file").find_in_batches(batch_size: BATCH) do |nodes|
          ids  = nodes.map(&:node_id)
          info = FileLayer.current.stat_all(user, node_ids: ids)
          # A missing node is an ABSENT KEY from stat_all, never a raise — so `info[id]` may be nil
          # for a row tombstoned since the batch was read, and that is a skip, not an error.
          #
          # THE TRIPLE, matching the read path. One query per batch, unchanged: adding a column to
          # a pluck costs nothing, where asking per node would be the N+1 this batching exists to
          # avoid.
          seen = user.maker_previews.where(kind: KIND, node_id: ids)
                     .pluck(:node_id, :version_id, :renderer_revision).to_set

          nodes.each do |node|
            token = info[node.node_id]&.content_token
            next if token.blank?

            # RESOLVED FROM THE RENDERER, NOT FROM A CONSTANT, because the current revision depends
            # on the file's own extension — there is no single value to compare a whole batch
            # against, which is the same reason `thumbnails_for` filters in Ruby rather than SQL.
            #
            # A name nothing renders is skipped HERE rather than being left to Enqueue's own nil
            # return. Enqueue would still do the right thing, but `revision_for_name` answers
            # BASE_REVISION for such a file, so it would read as stale on every run and be counted
            # forever by the dry run — a report that never reaches zero.
            renderer = Maker::Previews::Registry.for_filename(node.name)
            next if renderer.nil?

            revision = Maker::Previews::Enqueue.revision_for(renderer, KIND)
            next if seen.include?([ node.node_id, token, revision ])

            count += 1
            next if dry_run

            Maker::Previews::Enqueue.call(user:, node_id: node.node_id,
                                          name: node.name, version_id: token, kind: KIND)
          end
        end
        count
      end
    end
  end
end
