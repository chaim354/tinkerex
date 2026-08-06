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

      # What a renderer that declares no revision of its own is taken to be. Every artifact that
      # existed before `renderer_revision` was introduced is stamped 1 by the migration, so a
      # renderer only invalidates its cache by bumping PAST this — silence changes nothing.
      BASE_REVISION = 1

      def call(user:, node_id:, name:, version_id:, kind: "thumbnail")
        renderer = Maker::Previews::Registry.for_filename(name)
        return nil if renderer.nil?

        revision = revision_for(renderer, kind)
        preview  = user.maker_previews.find_or_initialize_by(node_id:, kind:)
        # TWO INDEPENDENT REASONS A STORED ARTIFACT IS OUT OF DATE, and they are not the same
        # question. `version_id` asks "was this made from the file's CURRENT CONTENT?";
        # `renderer_revision` asks "was it made by the CURRENT CODE?". Only the first was checked
        # until a thinning fix shipped for the .lbrn2 Measure view and every already-measured file
        # kept serving output from the old algorithm, because its content had not changed and
        # nothing else was being compared.
        stale = preview.version_id != version_id || preview.renderer_revision != revision
        return preview unless preview.new_record? || stale || preview.status == "failed"

        preview.version_id = version_id
        preview.renderer_revision = revision
        preview.status = "pending"
        preview.save!
        Maker::GeneratePreviewJob.perform_later(preview.id, filename: name)
        preview
      end

      # The revision a renderer claims for one kind, or BASE_REVISION when it claims none.
      #
      # ASKED OF THE RENDERER RATHER THAN HELD IN A TABLE HERE, so the number lives beside the code
      # whose output it describes — someone changing a payload sees the constant they need to bump
      # in the file they are already editing, which is the entire point of having it.
      #
      # PER KIND, NOT PER RENDERER: Lbrn2 produces both a thumbnail and a geometry payload, and
      # bumping one must not re-render the other. A geometry change that also rebuilt every
      # LightBurn thumbnail would be a silent full-library rebuild attached to an unrelated fix.
      def revision_for(renderer, kind)
        return BASE_REVISION unless renderer.respond_to?(:payload_revision)

        renderer.payload_revision(kind) || BASE_REVISION
      end

      # The same answer, for a caller that holds a filename rather than a renderer — the shape a
      # controller has when deciding whether a row it already found is worth serving.
      def revision_for_name(name, kind)
        renderer = Maker::Previews::Registry.for_filename(name)
        renderer.nil? ? BASE_REVISION : revision_for(renderer, kind)
      end
    end
  end
end
