# The sidecar pre-publish check (Tinkerex::Sidecars): every sidecar/<name>/ has all eight
# touchpoints and nothing names a sidecar that is not there. bin/publish-sidecar runs it.
namespace :sidecars do
  desc "Check every sidecar has its deploy, compose, INSTALL and Help entries"
  task check: :environment do
    sidecars = Tinkerex::Sidecars.new
    problems = sidecars.problems
    unless problems.empty?
      abort problems.map { |p| "#{p.message}\n  add:\n#{p.snippet.gsub(/^/, '    ')}" }.join("\n")
    end
    puts "sidecars:check: #{sidecars.names.size} #{'sidecar'.pluralize(sidecars.names.size)} complete (#{sidecars.names.join(', ')})"
  end
end
