module Maker
  # The scheduled half of Maker::ProjectDiscovery. Mirrors Maker::ModelIntakeJob down to why each
  # decision is what it is — read that file, and Maker::ProjectIntakeJob before it.
  class ProjectDiscoveryJob < ApplicationJob
    queue_as :background

    # The user can be deleted between the fan-out and this running. Nothing to sweep and nothing
    # wrong (GeneratePreviewJob sets the precedent).
    discard_on ActiveRecord::RecordNotFound

    # ONE SWEEP PER USER AT A TIME. The race it exists for: maker_projects has a unique index on
    # (user_id, slug) but NONE on folder_node_id, so two concurrent sweeps would both see one
    # folder unclaimed and mint `desk-lamp` AND `desk-lamp-2` pointing at the same node. :discard
    # because a queued second sweep re-does the first one's work; the 15-minute schedule IS the
    # retry, and it re-reads the world rather than replaying a stale verdict.
    #
    # IT COVERS THE `sweep_all!` PATH AND NOTHING ELSE — WHICH IS TO SAY chunk_remote ONLY. Solid
    # Queue acquires the semaphore in an `after_create` on the job ROW, so the limit is consulted
    # at ENQUEUE and only at enqueue: `perform_now` and `.new.perform` create no row and are
    # invisible to it (`ProjectIntakeJob`'s header states the same thing about its own limit).
    # `Library::ScanJob` calls this job with `perform_now`, so ON SHARE/S3 THIS LINE PROTECTS
    # NOTHING.
    #
    # WHAT PROTECTS THAT PATH IS `Library::ScanJob`'S OWN `limits_concurrency` — it is enqueued
    # exclusively via `perform_later`, and by now exclusively through `Library::ScanJob.enqueue_for`,
    # whose three callers are `scan_all!`, `FilesController#rescan` and
    # `Projects::ScansController#create` (the per-project "Scan folder" button); grep-verified. So
    # its per-user limit is what serializes the share/s3 sweep. DO NOT DELETE IT AS REDUNDANT WITH
    # THIS ONE: they cover disjoint paths, and removing ScanJob's reopens the duplicate-adoption
    # race above on the two backends this line cannot reach.
    limits_concurrency to: 1, key: ->(args) { args[:user_id] },
                       duration: 15.minutes, on_conflict: :discard

    # `cap:` IS THE REQUEST PATH'S KNOB (stage 4, S4-6). The recurring sweep and Library::ScanJob
    # pass none and get MAX_PROJECTS (or the env override); Projects::ScansController#pull_and_file
    # runs this synchronously inside a POST and passes EAGER_MAX_PROJECTS, the second cap the
    # service's own comment demands of any nudge.
    def perform(user_id:, cap: nil)
      user = User.find(user_id)
      run = Maker::ProjectDiscovery.for_user(user:, cap:)
      if run.created.positive? || run.status == :capped
        Rails.logger.info("Maker::ProjectDiscoveryJob: user #{user.id} created #{run.created} " \
                          "of #{run.candidates} candidates, status #{run.status}")
      end
      chain_intake(user) if run.created.positive?
      run
    end

    # THE GATE IS HERE AND NOT IN #perform, matching Library::ScanJob.scan_all! and both sibling
    # sweeps: on a scannable backend Library::ScanJob already calls discovery at the start of its
    # own post-reconcile sequence. A second caller would adopt folders the reconcile has not
    # settled yet. It asks a CAPABILITY rather than a class, per the Phase 3 trap `is_a?(Share)`
    # shipped: a gate that names classes answers false for the next backend and silently never runs.
    def self.sweep_all!
      return if FileLayer.current.capabilities.scannable?

      User.find_each { |user| perform_later(user_id: user.id) }
    end

    private

    # THE ONE THING ModelIntakeJob DOES NOT DO. Without it a chunk_remote user waits a SECOND
    # 15-minute tick between "the folder became a project" and "its files got attached and filed" —
    # two ticks to see anything happen, on a feature whose whole point is that dropping a folder in
    # just works.
    #
    # GATED ON !scannable?, AND THAT GATE IS NOT OPTIONAL. On share/s3 Library::ScanJob sequences
    # discovery -> intake -> catalog inside ONE perform. A second, unsequenced filer is exactly the
    # scan-overlap bug §14f records: a move made after the Scanner captured its observations is
    # paired back by (content_hash, size), re-pointing the node at its OLD path while the bytes sit
    # at the new one — and a download in that window gets Share#download's ENOENT -> NotFound -> a
    # TERMINAL 404, not the retryable 503.
    #
    # A TRIGGER, NOT A SECOND COPY OF THE POLICY — the same reading Maker::ProjectIntakeJob
    # .nudge_parents records. Nothing here decides where a file goes; it only makes the one sweep
    # happen sooner, and ProjectIntakeJob's own limits_concurrency collapses duplicates.
    #
    # BEST-EFFORT: a discovery run that has already committed its rows must not fail because a
    # follow-on could not be enqueued.
    def chain_intake(user)
      return if FileLayer.current.capabilities.scannable?

      Maker::ProjectIntakeJob.perform_later(user_id: user.id)
    rescue StandardError => e
      Rails.logger.warn("Maker::ProjectDiscoveryJob: created projects for user #{user.id} but " \
                        "could not enqueue the intake: #{e.class}: #{e.message}")
    end
  end
end
