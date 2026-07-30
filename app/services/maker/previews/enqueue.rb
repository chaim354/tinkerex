module Maker
  module Previews
    # THE ONE idempotent entry point the "bytes landed" seams call (web upload, API commit, scan).
    # Finds-or-creates the (node, kind: thumbnail) Preview and enqueues GeneratePreviewJob when it
    # is new, when the content has MOVED, or when it previously `failed`. Returns the Preview, or
    # nil when nothing to do (no renderer for this name -> don't litter the table with rows that
    # will only ever be `unsupported`; that judgement is cheap and local here, and keeps the grid's
    # preview map clean).
    #
    # ONE ROW PER (node, kind), REPOINTED — not one row per version. The old key included
    # `version_id`, so every save minted a row and stranded its predecessor: nothing reads a
    # superseded preview (every surface resolves by the node's CURRENT content_token) and nothing
    # deleted one either. 160 of 1334 rows on the deployed share library were orphans that way,
    # growing ~17.6/day with editing. Repointing removes the leak at its source instead of adding
    # a reaper to chase it, and ActiveStorage purges the replaced blob by itself.
    #
    # `status = "pending"` on a repoint is deliberate and is what keeps the page honest: the row
    # still holds the PREVIOUS render until the job finishes, and `_thumb.html.erb` shows an image
    # only when `ready`, so the user sees a spinner rather than the old picture labelled as the new
    # content. Same thing they saw before, when the superseded row simply was not found.
    #
    # This is deliberately a DIFFERENT policy from V1::Maker::PreviewsController#create, which DOES
    # create a row for a non-renderable name so an API client can poll and observe the terminal
    # `unsupported` state. Here the trigger is automatic/eager, so skipping non-renderable files is
    # the right call. The two are not merged for that reason.
    #
    # NOT a controller concern and NOT sync-coupled: it reads a filename + content id and enqueues a
    # job. Callable from a controller, a service, or a scan loop (§10 tripwire stays intact).
    module Enqueue
      module_function

      def call(user:, node_id:, name:, version_id:, kind: "thumbnail")
        return nil if Maker::Previews::Registry.for_filename(name).nil?

        preview = user.maker_previews.find_or_initialize_by(node_id:, kind:)
        stale   = preview.version_id != version_id
        return preview unless preview.new_record? || stale || preview.status == "failed"

        preview.version_id = version_id
        preview.status = "pending"
        preview.save!
        Maker::GeneratePreviewJob.perform_later(preview.id, filename: name)
        preview
      end
    end
  end
end
