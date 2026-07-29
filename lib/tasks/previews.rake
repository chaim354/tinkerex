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
end
