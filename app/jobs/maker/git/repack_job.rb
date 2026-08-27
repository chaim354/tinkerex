module Maker
  module Git
    # EVERY PROJECT REPOSITORY THAT HAS ACCUMULATED TOO MANY PACKS, COLLAPSED INTO ONE. The
    # per-repository work is Maker::Git::Repo#repack_all!; this is the loop around it, the audit
    # trail for what it did, and the scheduled fan-out.
    #
    # WHY THIS IS A SEPARATE JOB RATHER THAN A STEP IN THE COMMIT LOOP, which is where
    # #consolidate! lives and has to: consolidation packs ONE WINDOW's loose objects and is cheap,
    # while a repack READS AND REWRITES EVERY OBJECT the repository holds -- on a hydrated backend
    # a full download and a full re-upload of the whole history. Paying that every fifteen minutes
    # to remove a file count that grows by one per window would cost enormously more than it saves.
    # THE THRESHOLD IS WHAT KEEPS IT RARE, NOT THE CADENCE: Repo::MAX_PACKS declines on nearly every
    # run, and the weekly schedule only decides how long a repository is allowed to sit over the
    # limit once it crosses it.
    #
    # NO BACKEND GATE, unlike Maker::Git::CommitJob.commit_all! and every gated entry in
    # recurring.yml. Those decline on `scannable` because Library::ScanJob is already their caller
    # there and a second, unsequenced one would commit files the intake is about to move. Nothing
    # else calls a repack on any backend, and every backend wants one: s3 pays per GET, chunk_remote
    # per WAN round trip, and share per SMB metadata round trip -- the file-count term is the same
    # term on all three.
    #
    # ONLY PROJECTS THAT ALREADY HAVE A REPOSITORY ARE VISITED, and Maker::GitRepo is the filter.
    # `Repo#hydrate!` MINTS `.git`, and that directory is the marker Maker::AttachToProject reads to
    # decide whether project-intake filing applies to a folder -- so a tidy-up sweep that hydrated
    # every project would switch filing off across the whole library, silently, at the next scan and
    # nowhere near here. The index row is exactly the right strength for the reason
    # Maker::Git::VersionHistory#never_committed? gives: this asks "is there anything to do", and
    # its absent-row answer is SKIP, which is the safe direction. That model's warning -- never
    # treat an absent row as "no repo" for a destructive decision -- is honoured rather than
    # dodged: the destructive reading would be to hydrate.
    class RepackJob < ApplicationJob
      queue_as :background

      # The user can be deleted between the fan-out and this running. Nothing to repack and nothing
      # wrong -- discard rather than record a failure (GeneratePreviewJob sets the precedent).
      discard_on ActiveRecord::RecordNotFound

      # ONE PASS PER USER AT A TIME, Maker::Git::CommitJob's shape and for its reason: a repository
      # is not safe to have two passes in. :discard because a queued second pass would re-do the
      # first one's work, and the weekly schedule is the retry. The duration is an hour rather than
      # CommitJob's fifteen minutes because a repack rewrites the whole history of every repository
      # this user has, which on a hydrated backend is bounded by their bandwidth.
      #
      # IT DOES NOT EXCLUDE A CONCURRENT CommitJob, and that is stated rather than left to be
      # discovered: the two jobs have different concurrency keys and share a cache directory, so a
      # repack can run while a commit pass is mid-flight. Nothing there corrupts -- every state
      # #repack_all! can be interrupted in is a complete repository, and the packs it deletes were
      # snapshotted before it wrote anything -- but a commit pass whose library pack is deleted out
      # from under its hydrate fails for that project and is retried on the next tick.
      limits_concurrency to: 1, key: ->(args) { args[:user_id] },
                         duration: 1.hour, on_conflict: :discard

      def perform(user_id:)
        user = User.find(user_id)
        considered = repacked = failed = 0

        projects_with_repositories(user).find_each do |project|
          considered += 1
          # THE CACHE IS LEFT WARM ON PURPOSE -- no #discard_cache!. It is keyed by user and project,
          # so it is the SAME directory Maker::Git::CommitJob's fifteen-minute pass hydrates into;
          # throwing it away here would make the next commit pass re-download the whole repository
          # to save a directory that job is about to rebuild anyway.
          repo = Repo.for(project).hydrate!
          name = repo.repack_all!
          next if name.nil?

          repacked += 1
          Rails.logger.info("Maker::Git::RepackJob #{project.slug}: repacked into #{name}")
        rescue StandardError => e
          # ONE PROJECT'S FAILURE MUST NOT STALL THE REST -- CommitJob's rule, scoped per project
          # and never around the loop. A repository whose bytes are briefly unreachable is ordinary
          # on a NAS, and a raise here would leave every project after it in this loop unrepacked
          # with nothing anywhere saying why.
          failed += 1
          Rails.logger.error("Maker::Git::RepackJob: project #{project.slug} (#{project.id}) " \
                             "failed for user #{user.id}: #{e.class}: #{e.message}")
        end

        report(user, considered:, repacked:, failed:)
        repacked
      end

      def self.repack_all!
        User.find_each { |user| perform_later(user_id: user.id) }
      end

      private

      # A project with no library folder has nowhere for its repo data to live -- the port resolves
      # `.git` under that folder's own path -- so it is filtered here rather than left to raise
      # inside the loop. Same filter, same spelling, as Maker::Git::CommitJob's.
      def projects_with_repositories(user)
        user.maker_projects
            .where.not(folder_node_id: nil)
            .where(id: Maker::GitRepo.select(:project_id))
      end

      # SILENT AT STEADY STATE, which is nearly every run: the threshold declines and there is
      # nothing to say. Maker::Git::CommitJob#report's rule, and the same pair of events kept
      # distinguishable -- a run that repacked nothing and a run that FAILED on everything must not
      # read the same, so the second gets a WARN carrying the denominator that N error lines cannot.
      def report(user, considered:, repacked:, failed:)
        if failed.positive?
          Rails.logger.warn("Maker::Git::RepackJob: user #{user.id} repacked #{repacked} of " \
                            "#{considered} repositories — #{failed} FAILED (see the errors above).")
        elsif repacked.positive?
          Rails.logger.info("Maker::Git::RepackJob: user #{user.id} repacked #{repacked} of " \
                            "#{considered} repositories.")
        end
      end
    end
  end
end
