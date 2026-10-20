module Library
  # WHAT A LIBRARY-FOLDER CHANGE ENQUEUES, ONE PER USER (K §5). Waits for any running scan, optionally
  # starts the catalog over (Library::Reset), then scans the new folder INLINE.
  #
  # THE SCAN'S OWN SEMAPHORE: `group: "Library::ScanJob"` makes this job's concurrency key identical
  # to Library::ScanJob's for the same user (Solid Queue keys are "<group>/<key>", and a job's
  # default group is its class name), so a reset never runs underneath a scan and no scan starts
  # underneath a reset. `on_conflict: :block` here where the scan says :discard: a queued scan only
  # repeats the running one, but a change must happen. Pinned by concurrency_limits_test.rb.
  #
  # INLINE, NOT ENQUEUED: Solid Queue releases a semaphore when the job FINISHES, so a scan enqueued
  # from inside this perform would meet this job's own lock and be discarded by the scan's
  # :discard. perform_now bypasses enqueue-time controls -- the same reason ScanJob's inline intakes
  # are never discarded by their own limits.
  #
  # SHARE ONLY, AND ASKED BEFORE THE RESET, NOT AFTER IT. The chooser is a share fact, so a job left
  # over from a backend switch has nothing to scan -- and nothing to reset: on chunk_remote `nodes`
  # is the sync server's MIRROR (§14a), and on s3 a wiped catalog is re-minted by the next scan with
  # new node_ids, so either way a reset there destroys what no folder change asked about.
  #
  # NO RESCUE: an UnsafeScan from the new folder is the mass-deletion guard refusing a "switch" onto
  # a different library (K §5). Library::ScanJob records it for /settings/library; this job's failed
  # execution stays the operator's report.
  class RootChangeJob < ApplicationJob
    queue_as :background
    discard_on ActiveRecord::RecordNotFound

    limits_concurrency to: 1, key: ->(args) { args[:user_id] }, group: "Library::ScanJob",
                       duration: 1.hour, on_conflict: :block

    def perform(user_id:, start_over: false)
      user = User.find(user_id)
      return unless Tinkerex::LibraryRoot.share?

      Library::Reset.call(user) if start_over
      Library::ScanJob.perform_now(user_id: user.id, root: FileLayer.current.root.to_s)
    end
  end
end
