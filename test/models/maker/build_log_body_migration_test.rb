require "test_helper"
require Dir[Rails.root.join("db/migrate/*_move_build_log_body_to_action_text.rb")].first

# Drives the data migration directly. The assertions are about CONTENT, not row counts: the two
# ways this conversion can quietly ruin a build log are collapsing newlines and letting raw text
# through as markup, and neither shows up in a count.
class BuildLogBodyMigrationTest < ActiveSupport::TestCase
  Converter = MoveBuildLogBodyToActionText

  test "a single line becomes one paragraph" do
    assert_equal "<p>Cut the panels</p>", Converter.to_html("Cut the panels")
  end

  test "single newlines become line breaks inside one paragraph" do
    assert_equal "<p>Cut the panels<br>Sanded the edges</p>",
                 Converter.to_html("Cut the panels\nSanded the edges")
  end

  test "a blank line starts a new paragraph" do
    assert_equal "<p>Day one</p><p>Day two</p>", Converter.to_html("Day one\n\nDay two")
  end

  test "text that looks like markup is escaped, not interpreted" do
    html = Converter.to_html("tolerance a < b <script>alert(1)</script>")
    assert_includes html, "&lt;script&gt;"
    assert_not_includes html, "<script>"
    assert_includes html, "a &lt; b"
  end

  test "carriage returns do not leak into the output" do
    assert_equal "<p>one<br>two</p>", Converter.to_html("one\r\ntwo")
  end

  # After the column drops, `body` is an Action Text association rather than an attribute. This is
  # the test that would fail if `has_rich_text :body` were missing, misnamed, or shadowed.
  test "an entry round-trips a rich body through the model" do
    user = User.create!(email: "richbody@example.com")
    project = user.maker_projects.create!(name: "Lamp")

    entry = project.build_log_entries.create!(user:, body: "<p>Cut the <strong>panels</strong></p>")

    assert_equal "<p>Cut the <strong>panels</strong></p>", entry.reload.body.body.to_html
    assert_includes entry.body.to_plain_text, "Cut the panels"
  end

  # A plain string is still a valid body — the v1 API sends one, and the presence validation has to
  # keep meaning what it meant.
  test "a plain string body is accepted and a blank one is rejected" do
    user = User.create!(email: "plainbody@example.com")
    project = user.maker_projects.create!(name: "Lamp")

    assert project.build_log_entries.create!(user:, body: "Cut the panels").persisted?
    assert_not project.build_log_entries.new(user:, body: "").valid?
  end
end
