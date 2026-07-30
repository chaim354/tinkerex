namespace :projects do
  # DRY_RUN=1 follows the house idiom set by previews:reap_dead_nodes (lib/tasks/previews.rake)
  # rather than the design spec's `projects:organize:dry_run` subtask — consistency with the
  # neighbouring rake tasks wins over the spec text, and the implementation plan already records
  # that departure (docs/superpowers/plans/2026-07-29-project-folder-auto-organize.md).
  desc "Attach + file every project's loose library files (DRY_RUN=1 to report only, writes nothing)"
  task organize: :environment do
    dry_run = ENV["DRY_RUN"].present?

    # THE CAP IS LIFTED HERE, and that is the whole reason this task exists. The periodic run
    # (Maker::ProjectIntakeJob on chunk, Library::ScanJob's post-reconcile call on share/s3)
    # refuses to FILE above PROJECT_ORGANIZE_MAX_MOVES because an implausible count is worth
    # stopping an UNATTENDED run for; an operator who has just read the dry run and is now running
    # this BY HAND is the deliberate action that refusal is waiting for. Float::INFINITY rather
    # than a flag: `count > Float::INFINITY` is false for every possible count, so
    # RunResult#status can never come back :refused_too_many_moves here — no branch below has to
    # learn a second meaning of "no cap".
    cap = Float::INFINITY

    totals = { attached: 0, moved: 0, skipped: 0 }

    User.find_each do |user|
      run = Maker::ProjectIntake.for_user(user:, dry_run:, cap:)

      run.results.each do |project, result|
        # Silent for a project that did nothing at all — Maker::ProjectIntakeJob#report's own
        # rule, matched here so a steady-state run (nothing loose, forever) prints only the
        # closing total instead of a row of zeroes per project. A project that left something
        # behind (skipped > 0) is NOT "did nothing" and still gets a line — that is accurate
        # reporting of an unresolved file, not a bug to silence.
        next if result.attached.zero? && result.moved.zero? && result.skipped.zero?

        puts "#{project.slug}: #{dry_run ? 'would attach' : 'attached'} #{result.attached}, " \
             "#{dry_run ? 'would file' : 'filed'} #{result.moved}, left #{result.skipped}"
        result.plan.each { |name, folder| puts "    #{name} -> #{folder}/" }
        result.skips.each { |name, reason| puts "    #{name} -> left in place (#{reason})" }

        totals[:attached] += result.attached
        totals[:moved] += result.moved
        totals[:skipped] += result.skipped
      end
    end

    puts "#{dry_run ? 'Would attach' : 'Attached'} #{totals[:attached]}, " \
         "#{dry_run ? 'would file' : 'filed'} #{totals[:moved]}, left #{totals[:skipped]} total."
    puts "DRY RUN — nothing was written (no attachment rows, no folders created)." if dry_run
  end
end
