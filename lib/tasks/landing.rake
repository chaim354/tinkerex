# The landing's format wall (Tinkerex::Landing): every tile rendered from db/seeds/demo through the
# library's own preview renderers. Needs every renderer's toolchain -- the production image built for
# linux/amd64 has them all (docs/superpowers/plans/2026-10-16-landing-format-wall.md, Task 4).
namespace :landing do
  desc 'Render the landing\'s twelve wall tiles: bin/rails "landing:wall[SEED_DIR,OUT_DIR]" (both optional)'
  task :wall, %i[seed_dir out_dir] => :environment do |_task, args|
    paths = Tinkerex::Landing.render_wall(seed_dir: args[:seed_dir].presence || Tinkerex::Landing::SEED_DIR,
                                          out_dir: args[:out_dir].presence || Tinkerex::Landing::OUT_DIR)
    paths.each { |path| puts "wrote #{path} (#{path.size} bytes)" }
  rescue Tinkerex::Landing::Error => e
    abort "landing:wall: #{e.message}"
  end
end
