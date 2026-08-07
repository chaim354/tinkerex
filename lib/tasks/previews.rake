namespace :previews do
  desc "Re-render LightBurn thumbnails missing laser-settings metadata"
  task backfill_lbrn: :environment do
    n = Maker::Previews::LbrnBackfill.call
    puts "Enqueued #{n} LightBurn preview(s) for metadata backfill."
  end

  # ALSO CATCHES A RENDERER BUMP since 2026-08-07 — a row built by an older build sits at the
  # current content, so it used to satisfy this sweep's check while the read path treated it as
  # absent. DRY_RUN first on any real library: after a revision bump every file of that format is
  # eligible at once, which is the point, but it is worth seeing the number before enqueueing it.
  desc "Enqueue a thumbnail for every live file with no preview the read path would serve " \
       "— missing, superseded content, or an older renderer (DRY_RUN=1 to report only)"
  task backfill_missing: :environment do
    dry = ENV["DRY_RUN"].present?
    n = Maker::Previews::MissingBackfill.call(dry_run: dry)
    puts "#{dry ? 'Would enqueue' : 'Enqueued'} #{n} preview(s) with no current render."
  end

  desc "Reap previews whose node no longer exists (DRY_RUN=1 to report only)"
  task reap_dead_nodes: :environment do
    dry = ENV["DRY_RUN"].present?
    n = Maker::Previews::DeadNodeReaper.reap_all!(dry_run: dry)
    puts "#{dry ? 'Would reap' : 'Reaped'} #{n} preview(s) whose node no longer exists."
  end
end
