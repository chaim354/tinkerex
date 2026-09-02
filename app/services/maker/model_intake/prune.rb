module Maker
  class ModelIntake
    # ONE-OFF REPAIR for auto models an EARLIER rule wrote. Maker::ModelIntake only ever INSERTS
    # (attach_all is one `insert_all ... unique_by`), which is what makes a re-sweep free -- and it
    # is also why tightening the rule cannot fix a library on its own: the rows the loose rule
    # already wrote stay forever. Measured on a real share library the day the rule changed, six
    # folder models held 2441 attachments of which 32 were meshes.
    #
    # NOT FOLDED INTO THE SWEEP, deliberately. A sweep that deleted what its plan no longer claims
    # would also delete what a user attached BY HAND through Models::AttachmentsController#create --
    # `maker_file_attachments` has no column saying which door wrote a row, so the two are
    # indistinguishable -- and it would do it every fifteen minutes, unattended. This runs when
    # someone asks for it, reports before it writes, and is safe to re-run.
    #
    # IT NEVER TOUCHES THE PORT and never touches a library file: it deletes attachment ROWS and
    # destroys catalog ROWS. The files stay exactly where they are.
    class Prune
      # `detached` is [[model, count]] and `destroyed` is [model], both so a dry run can name what
      # it WOULD do rather than printing a total the operator has to trust.
      Result = Data.define(:destroyed, :detached, :applied) do
        def attachments = detached.sum(&:last)
        def any? = destroyed.any? || detached.any?
      end

      # `apply:` DEFAULTS TO FALSE, and that is the whole safety story. Every other guard here is
      # about not deleting the wrong row; this one is about the operator seeing the list first.
      def self.for_user(user:, apply: false)
        # FOLDER MODELS ONLY. A one-file model's key IS its file, so the sweep never gave it a
        # second attachment -- there is nothing here that the old rule got wrong, and anything else
        # hanging off it was attached by hand.
        autos = user.maker_models.where(origin: "auto").where.not(folder_node_id: nil)
                    .includes(:file_attachments).to_a
        return Result.new(destroyed: [], detached: [], applied: apply) if autos.empty?

        claimed = Maker::ModelIntake.claimed_folders(user, autos.map(&:auto_node_id))
        destroyed, keep = autos.partition { |m| claimed.include?(m.auto_node_id) }
        detached = stale_attachments(user, keep)

        if apply
          Maker::FileAttachment.where(id: detached.values.flatten.map(&:id)).delete_all
          destroyed.each(&:destroy!)
        end

        Result.new(destroyed:, detached: detached.map { |m, a| [ m, a.size ] }, applied: apply)
      end

      # WHAT THE CURRENT RULE WOULD NOT HAVE ATTACHED, narrowed by two guards that both exist to
      # protect a row this repair has no business touching:
      #
      #   A TOMBSTONED NODE IS LEFT ALONE. Maker::AttachmentReaper owns those, on a grace window,
      #   because Library::Reconciler tombstones rather than destroys and an undelete brings the
      #   file back with the SAME node_id -- and every attachment is keyed on it (§14d). Reaping
      #   here would pre-empt that window and turn "restore from Trash" into "re-file it by hand".
      #   `classify` reads `.present`, so a tombstone is absent from the plan and would otherwise
      #   look exactly like a file the rule no longer claims.
      #
      #   A NODE OUTSIDE THE MODEL'S OWN FOLDER IS LEFT ALONE. The sweep can only ever have
      #   attached from inside it, so anything else was attached by hand and is the user's. This is
      #   what makes the manual-attachment risk small enough to run unattended-ish: what survives
      #   is exactly what the sweep could not have written.
      def self.stale_attachments(user, models)
        ids = models.flat_map { |m| m.file_attachments.map(&:node_id) }.uniq
        return {} if ids.empty?

        # TOMBSTONES INCLUDED, DELIBERATELY -- `.present` here would make the liveness guard below
        # REDUNDANT rather than independent: a tombstone would have no parent, so `inside?` would
        # answer false and protect it by accident. Mutation-checked: with `.present` the liveness
        # clause can be deleted and every test stays green, which is a guard that has not been
        # shown to work (§15).
        rows    = user.nodes.where(node_id: ids).pluck(:node_id, :parent_node_id, :deleted)
        live    = rows.reject { |_, _, deleted| deleted }.map(&:first).to_set
        parents = rows.to_h { |id, parent, _| [ id, parent ] }
        tree    = Maker::LibraryTree.new(user)
        plan    = Maker::ModelIntake.classify(user)

        models.each_with_object({}) do |model, out|
          wanted = plan.files_for(model.auto_node_id).to_set
          stale  = model.file_attachments.reject do |att|
            wanted.include?(att.node_id) ||
              !live.include?(att.node_id) ||
              !inside?(tree, parents[att.node_id], model.folder_node_id)
          end
          out[model] = stale if stale.any?
        end
      end
      private_class_method :stale_attachments

      # NIL IS "NOT INSIDE", NOT "EVERYTHING". `ancestors_of` answers nil on a broken chain (§14k),
      # and the safe reading of "I cannot tell where this node lives" is to keep the row.
      def self.inside?(tree, parent_id, folder_id)
        return true if parent_id == folder_id

        (tree.ancestors_of(parent_id) || []).include?(folder_id)
      end
      private_class_method :inside?
    end
  end
end
