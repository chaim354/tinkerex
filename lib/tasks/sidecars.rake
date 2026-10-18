# The sidecar pre-publish check (Tinkerex::Sidecars): every sidecar/<name>/ has all nine
# touchpoints and nothing names a sidecar that is not there. bin/publish-sidecar runs it.
#
# A SNIPPET IS PRINTED UNINDENTED, exactly as it pastes: it already carries its file's own
# indentation, so a display prefix on top made a verbatim paste fail to parse (deploy.yml: "did not
# find expected key"). The line ABOVE it says where it goes.
namespace :sidecars do
  desc "Check every sidecar has its deploy, compose, INSTALL and Help entries"
  task check: :environment do
    sidecars = Tinkerex::Sidecars.new
    problems = sidecars.problems
    unless problems.empty?
      abort problems.map { |p|
        fix = p.touchpoint? ? "add exactly this to #{p.file}, directly above its marker if it has one:\n#{p.snippet.chomp}" : "fix: #{p.snippet}"
        "#{p.message}\n  #{fix}"
      }.join("\n\n")
    end
    puts "sidecars:check: #{sidecars.names.size} #{'sidecar'.pluralize(sidecars.names.size)} complete (#{sidecars.names.join(', ')})"
  end
end
