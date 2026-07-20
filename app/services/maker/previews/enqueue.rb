module Maker
  module Previews
    # THE ONE idempotent entry point the "bytes landed" seams call (web upload, API commit, scan).
    # Finds-or-creates the (node, version, kind: thumbnail) Preview and enqueues GeneratePreviewJob
    # only when it is new or previously `failed`. A new version_id is a new row (the model's unique
    # index), so an edited file re-renders. Returns the Preview, or nil when nothing to do (no
    # renderer for this name -> don't litter the table with rows that will only ever be
    # `unsupported`; that judgement is cheap and local here, and keeps the grid's preview map clean).
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

        preview = user.maker_previews.find_or_initialize_by(node_id:, version_id:, kind:)
        return preview unless preview.new_record? || preview.status == "failed"

        preview.status = "pending"
        preview.save!
        Maker::GeneratePreviewJob.perform_later(preview.id, filename: name)
        preview
      end
    end
  end
end
