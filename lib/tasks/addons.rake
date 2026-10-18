# The addon author's pre-publish check (Maker::Addons::Check): the host's own manifest rules plus
# on-disk file checks. tinkerex-addons' bin/publish runs it against that checkout; PATH defaults to
# ADDON_SOURCE_PATH, which development.rb points at ../tinkerex-addons/addons.
namespace :addons do
  desc 'Check addon manifests and their files: bin/rails "addons:check[PATH]" (default ADDON_SOURCE_PATH)'
  task :check, %i[path] => :environment do |_task, args|
    path = args[:path].presence || ENV["ADDON_SOURCE_PATH"]
    abort "addons:check: no PATH given and ADDON_SOURCE_PATH is not set" if path.blank?

    result = Maker::Addons::Check.run(path)
    abort result.problems.map { |p| "#{p[:key]}: #{p[:reason]}" }.join("\n") unless result.ok?

    puts "addons:check: #{result.count} #{'tool'.pluralize(result.count)} OK in #{path}"
  rescue Maker::Addons::Source::Error => e
    abort "addons:check: #{e.message}"
  end
end
