module Maker
  # Maker rows that point at a node the library no longer has: `Maker::FileAttachment` rows (a
  # project's or a model's Files panel) and a project's or a model's chosen `cover_node_id`.
  #
  # THE REPORTED BUG: delete a file from the share and it stayed in every project it was attached
  # to, forever, as a "⚠️ (file unavailable)" tile with a Remove button nobody was going to click
  # for each of them. `Library::Reconciler` TOMBSTONES rather than destroys — deliberately, that is
  # what makes a NAS reorganisation survivable — so no `dependent: :destroy` fires and nothing else
  # was watching.
  #
  # A SWEEP, NOT A HOOK, and for the same reason `Maker::ProjectIntake` is one: there is no funnel.
  # A node can die by the share/s3 scan, by `Sync::SubtreeDelete`, by a device push through the
  # mount, or by a trash purge, and hooking each is four sites that must agree plus a fifth that
  # gets added later and silently skips the rule — this repo's recorded failure shape. Reading
  # `nodes`, the catalog all three backends populate, covers every door present and future.
  #
  # AND IT IS DELIBERATELY NOT THE ONLY HALF OF THE FIX. The panels themselves stop RENDERING a
  # tile whose node is gone the moment it is gone (`ProjectsController#show`, `ModelsController`),
  # so from the user's side the file leaves the project immediately. This sweep is the destructive
  # half, and it is the half that has to wait: a tombstone is an undo away from coming back with
  # the same node_id, and destroying the attachment inside that window turns "restore from Trash"
  # into "restore, then re-file it into every project by hand". Hiding is instant because hiding is
  # reversible; destroying waits because destroying is not. `Maker::DeadNodes` owns that rule and
  # `Maker::Previews::DeadNodeReaper` applies the same one to thumbnails.
  #
  # NOT gated on any capability: a dead node is dead on chunk, share and s3 alike.
  module AttachmentReaper
    module_function

    GRACE = Maker::DeadNodes::GRACE

    def reap_all!(grace: GRACE, dry_run: false)
      User.find_each.sum do |user|
        reap!(user, grace:, dry_run:)
      rescue StandardError => e
        # One user's failure must not stop the sweep for everyone else — the same isolation
        # Sync::ChunkReaper.reap_all! and DeadNodeReaper.reap_all! apply.
        Rails.logger.error("AttachmentReaper: user #{user.id} failed: #{e.class}: #{e.message}")
        0
      end
    end

    # -> the number of rows changed (attachments destroyed + covers cleared).
    def reap!(user, grace: GRACE, dry_run: false)
      attachments = user.maker_file_attachments.to_a
      # A project or MODEL whose cover was CHOSEN. A derived cover needs nothing here — it is
      # computed from the attachments, so reaping those moves it on its own.
      #
      # BOTH CLASSES. `maker_models` carries the identical column with the identical override, and
      # this sweep is the ONLY thing that ever restores the derived fallback — a non-blank column
      # shadows it permanently, `stat_all` answers a tombstone with an absent key, so the card paints
      # a spinner that no page load resolves. Models had no user escape either: `ModelsController`
      # never permits the parameter and there is no clear action, while the importer sets it on
      # every import, so a model's cover is chosen far more often than a project's.
      #
      # `covered` is therefore HETEROGENEOUS. Every line below is duck-typed on `[:cover_node_id]`
      # and `update_column`, which both classes answer identically — but a future line branching on
      # the class, or reaching for something only `Project` has, breaks the model half SILENTLY.
      covered = user.maker_projects.where.not(cover_node_id: [ nil, "" ]).to_a +
                user.maker_models.where.not(cover_node_id: [ nil, "" ]).to_a
      return 0 if attachments.empty? && covered.empty?

      nodes  = Maker::DeadNodes.index(user, attachments.map(&:node_id) + covered.map { |p| p[:cover_node_id] })
      cutoff = grace.ago

      doomed = attachments.select { |a| Maker::DeadNodes.reapable?(nodes[a.node_id], cutoff) }
      # `p[:cover_node_id]`, NOT `p.cover_node_id`, because the reader is overridden to fall back to
      # the DERIVED pick and this sweep is about the COLUMN.
      #
      # STATED HONESTLY, because it was mutation-checked and the obvious claim is too strong: the
      # two spellings cannot differ HERE. `where.not(cover_node_id: [nil, ""])` above has already
      # excluded every row whose column is blank, and on the rest `.presence` wins, so swapping
      # in the method changes nothing and no test goes red. What carries the weight is the `where.not`
      # itself — drop it and an un-chosen project or model arrives with a nil, `nodes[nil]` misses,
      # `reapable?(nil, ...)` answers true, and the sweep "clears" a column that was already empty and
      # reports it as work done. That is what the two `never chose a cover…` tests pin. The raw read
      # stays because it says what this line means without depending on the filter above to be right.
      stale_covers = covered.select { |p| Maker::DeadNodes.reapable?(nodes[p[:cover_node_id]], cutoff) }
      return doomed.size + stale_covers.size if dry_run

      doomed.each(&:destroy!)
      # update_column, not update!: this is a sweep touching rows nobody asked to modify, and
      # bumping `updated_at` would reorder the user's project list — and, identically, the models
      # index, whose default sort is the same `updated_at: :desc` — as a side effect of a file they
      # deleted weeks ago being cleaned up.
      stale_covers.each { |p| p.update_column(:cover_node_id, nil) }
      doomed.size + stale_covers.size
    end
  end
end
