module Maker
  # The daily run of Maker::FileAttachment.classify_unclassified! for every user: what keeps STORED
  # attachment roles following the vocabulary without a data migration per ROLE_BY_EXT widening
  # (F-S33-1). Scheduled from config/recurring.yml; `rake maker:classify_roles` is the same run on
  # demand.
  #
  # ITS OWN JOB, NOT A LOOP INSIDE Maker::AttachmentReaperJob, so the reaper's charter stays "rows
  # pointing at a dead node": that sweep destroys, this one re-labels live rows, and neither should
  # have to argue for the other's cadence. The per-user loop and its rescue are copied from
  # Maker::AttachmentReaper.reap_all! on purpose, for the same isolation.
  #
  # Backend-neutral, so no `command:` gate: DB-only, and `nodes` carries every file's name on
  # chunk_remote, share and s3 alike.
  class ClassifyAttachmentRolesJob < ApplicationJob
    queue_as :background

    def perform
      classified = User.find_each.sum do |user|
        Maker::FileAttachment.classify_unclassified!(user)
      rescue StandardError => e
        # One user's failure must not stop the sweep for everyone else — the isolation
        # Maker::AttachmentReaper.reap_all! and Maker::Previews::DeadNodeReaper.reap_all! apply.
        Rails.logger.error("ClassifyAttachmentRolesJob: user #{user.id} failed: " \
                           "#{e.class}: #{e.message}")
        0
      end
      Rails.logger.info("ClassifyAttachmentRolesJob classified #{classified} attachment role(s) " \
                        "stored as other that the vocabulary now names")
      classified
    end
  end
end
