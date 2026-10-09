require "test_helper"
require "ripper"

# NO EMOJI IN THE INTERFACE (structural redesign; design-system.md). css_hygiene_test.rb guards the
# stylesheets; this guards the rest of the source a page is built from: templates (compiled, so `<%# %>`
# comments are not read), helpers and controllers (Ripper, comment tokens skipped), and scripts (comments
# stripped). Pictographs only — U+1F300–U+1FAFF — because ✓, ✕ and ✎ are typographic marks a status
# carries as words. An addon's manifest `icon` is data the bundle supplies, not this repo's source.
class NoEmojiTest < ActiveSupport::TestCase
  PICTOGRAPH = /[\u{1F300}-\u{1FAFF}]/

  test "no template, helper, controller or script draws an emoji" do
    erb = Dir[Rails.root.join("app/views/**/*.erb")]
    rb = Dir[Rails.root.join("app/helpers/**/*.rb"), Rails.root.join("app/controllers/**/*.rb")]
    js = Dir[Rails.root.join("app/javascript/**/*.js")]
    [ erb, rb, js ].each { |set| refute_empty set, "a scan found no files — it would pass over nothing" }

    hits = erb.filter_map { |f| f if ActionView::Template::Handlers::ERB::Erubi.new(File.read(f)).src.match?(PICTOGRAPH) }
    hits += rb.filter_map do |f|
      f if Ripper.lex(File.read(f)).any? { |(_, type, str, _)| type != :on_comment && str.match?(PICTOGRAPH) }
    end
    hits += js.filter_map do |f|
      f if File.read(f).gsub(%r{/\*.*?\*/}m, "").gsub(%r{^\s*//.*$}, "").match?(PICTOGRAPH)
    end
    assert_empty hits.map { |f| Pathname.new(f).relative_path_from(Rails.root).to_s },
                 "an interface source draws an emoji; use a glyph (rail_icon, folder_glyph) or a word"
  end
end
