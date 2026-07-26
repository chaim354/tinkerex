namespace :previews do
  desc "Re-render LightBurn thumbnails missing laser-settings metadata"
  task backfill_lbrn: :environment do
    n = Maker::Previews::LbrnBackfill.call
    puts "Enqueued #{n} LightBurn preview(s) for metadata backfill."
  end
end
