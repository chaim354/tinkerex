namespace :previews do
  desc "Re-render LightBurn thumbnails missing laser-settings metadata"
  task backfill_lbrn: :environment do
    n = Maker::Previews::LbrnBackfill.call
    puts "Enqueued #{n} LightBurn preview(s) for metadata backfill."
  end

  desc "Enqueue a thumbnail for every live file whose current content has no preview row"
  task backfill_missing: :environment do
    n = Maker::Previews::MissingBackfill.call
    puts "Enqueued #{n} preview(s) for content that had none."
  end

  desc "Reap previews whose node no longer exists (DRY_RUN=1 to report only)"
  task reap_dead_nodes: :environment do
    dry = ENV["DRY_RUN"].present?
    n = Maker::Previews::DeadNodeReaper.reap_all!(dry_run: dry)
    puts "#{dry ? 'Would reap' : 'Reaped'} #{n} preview(s) whose node no longer exists."
  end
end
