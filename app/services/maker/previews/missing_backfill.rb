module Maker
  module Previews
    # One-off repair: enqueue a thumbnail for every live file whose CURRENT content has no preview
    # row at all.
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

      # Returns the number of previews enqueued.
      def call(user: nil)
        (user ? [ user ] : User.all.to_a).sum { |u| backfill(u) }
      end

      def backfill(user)
        count = 0
        # `present` here keeps tombstones out of the BATCH; it is not what keeps a deleted file
        # from sprouting a preview. `stat_all` already omits one (absent key, never a raise), and
        # the token check below is what acts on that.
        user.nodes.present.where(kind: "file").find_in_batches(batch_size: BATCH) do |nodes|
          ids  = nodes.map(&:node_id)
          info = FileLayer.current.stat_all(user, node_ids: ids)
          # A missing node is an ABSENT KEY from stat_all, never a raise — so `info[id]` may be nil
          # for a row tombstoned since the batch was read, and that is a skip, not an error.
          seen = user.maker_previews.where(kind: "thumbnail", node_id: ids)
                     .pluck(:node_id, :version_id).to_set

          nodes.each do |node|
            token = info[node.node_id]&.content_token
            next if token.blank? || seen.include?([ node.node_id, token ])

            # Enqueue self-guards on renderer presence (nil for a name nothing renders), and the
            # row cannot already exist — `seen` just proved it — so a non-nil return IS an enqueue.
            count += 1 if Maker::Previews::Enqueue.call(user:, node_id: node.node_id,
                                                        name: node.name, version_id: token)
          end
        end
        count
      end
    end
  end
end
