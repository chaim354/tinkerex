require "test_helper"
require Dir[Rails.root.join("db/migrate/*_move_note_body_to_action_text.rb")].first

# Note bodies are MARKDOWN today. The failure this pins is a note that used to render as bold
# arriving in the editor as literal asterisks — a silent, unrecoverable downgrade of every
# existing note.
class NoteBodyMigrationTest < ActiveSupport::TestCase
  Converter = MoveNoteBodyToActionText

  test "markdown emphasis is rendered, not preserved literally" do
    html = Converter.to_html("**tight** fit")
    assert_includes html, "<strong>tight</strong>"
    assert_not_includes html, "**"
  end

  test "markdown lists become real lists" do
    html = Converter.to_html("- one\n- two")
    assert_includes html, "<li>one</li>"
  end

  test "links survive" do
    assert_includes Converter.to_html("[docs](http://example.com)"), 'href="http://example.com"'
  end

  test "the sanitizer still runs — this conversion must not become an XSS hole" do
    html = Converter.to_html("hi <script>alert('x')</script>")
    assert_not_includes html, "<script>"
  end

  test "a javascript: href is stripped" do
    assert_not_includes Converter.to_html("[x](javascript:alert(1))"), "javascript:"
  end

  # After the column drops, `body` is an Action Text association rather than an attribute. This is
  # the test that would fail if `has_rich_text :body` were missing, misnamed, or shadowed.
  test "a note round-trips a rich body through the model" do
    user = User.create!(email: "richnote@example.com")
    note = user.maker_notes.create!(node_id: "n-1", body: "<p>Print at <strong>0.2mm</strong></p>")

    assert_equal "<p>Print at <strong>0.2mm</strong></p>", note.reload.body.body.to_html
    assert_includes note.body.to_plain_text, "Print at 0.2mm"
  end

  # A plain string is still a valid body — the notes popover posts one — and the presence validation
  # has to keep meaning what it meant.
  test "a plain string body is accepted and a blank one is rejected" do
    user = User.create!(email: "plainnote@example.com")

    assert user.maker_notes.create!(node_id: "n-2", body: "print at 0.2mm").persisted?
    assert_not user.maker_notes.new(node_id: "n-3", body: "").valid?
  end
end
