require "test_helper"

module Maker
  # The SERVER half of the text-only policy that `attachments="false"` states in the editor only.
  # Both models are exercised by the same cases: the guarantee has to hold per-model, and a concern
  # included in one place and forgotten in another is exactly the failure this file catches.
  class TextOnlyRichTextTest < ActiveSupport::TestCase
    ATTACHMENT = %q(<action-text-attachment sgid="abc" content-type="image/png" filename="x.png"></action-text-attachment>).freeze

    # CAPTIONED, and that is load-bearing rather than decorative. An attachment whose sgid does not
    # resolve has NO plain-text representation, so ActionText::RichText#blank? is already true for
    # it and a presence test using one passes with or without this concern — a vacuous guard that
    # reads as coverage. A caption gives it plain text, so the body is genuinely non-blank BEFORE
    # the strip and blank after: the test can only pass because the strip ran.
    CAPTIONED_ATTACHMENT = %q(<action-text-attachment sgid="abc" caption="a photo"></action-text-attachment>).freeze

    setup do
      @user = User.create!(email: "tort-#{SecureRandom.hex(4)}@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    def build_note(body)  = Maker::Note.new(user: @user, node_id: "n-1", body: body)
    def build_entry(body) = Maker::BuildLogEntry.new(user: @user, project: @project, body: body, entry_type: "note")

    # The headline: markup that Action Text's own sanitizer PRESERVES does not survive a save.
    test "an attachment inside text is stripped on a note" do
      note = build_note("<div>hi #{ATTACHMENT} there</div>")
      note.save!
      note.reload
      assert_equal 0, note.body.body.attachments.size
      assert_not_includes note.body.body.to_html, "action-text-attachment"
    end

    test "an attachment inside text is stripped on a build log entry" do
      entry = build_entry("<div>hi #{ATTACHMENT} there</div>")
      entry.save!
      entry.reload
      assert_equal 0, entry.body.body.attachments.size
      assert_not_includes entry.body.body.to_html, "action-text-attachment"
    end

    # Deliberate consequence, pinned so it is never read later as a regression: both models
    # `validates :body, presence: true`, so a body that was ONLY an attachment strips to nothing
    # and is rejected. The user submitted only a thing this app does not accept.
    test "a body that is only an attachment fails presence validation on a note" do
      note = build_note(CAPTIONED_ATTACHMENT)
      assert_not note.valid?
      assert_includes note.errors.full_messages.join, "Body"
    end

    test "a body that is only an attachment fails presence validation on a build log entry" do
      entry = build_entry(CAPTIONED_ATTACHMENT)
      assert_not entry.valid?
      assert_includes entry.errors.full_messages.join, "Body"
    end

    # Guards against an over-broad strip. Without this, removing the whole body would pass every
    # test above while destroying every note in the library.
    test "ordinary formatting survives untouched on a note" do
      html = "<div><strong>bold</strong> <em>italic</em> <a href=\"https://example.com\">link</a><ul><li>one</li></ul></div>"
      note = build_note(html)
      note.save!
      note.reload
      stored = note.body.body.to_html
      assert_includes stored, "<strong>bold</strong>"
      assert_includes stored, "<em>italic</em>"
      assert_includes stored, "https://example.com"
      assert_includes stored, "<li>one</li>"
    end

    test "ordinary formatting survives untouched on a build log entry" do
      html = "<div><strong>bold</strong> <a href=\"https://example.com\">link</a></div>"
      entry = build_entry(html)
      entry.save!
      entry.reload
      stored = entry.body.body.to_html
      assert_includes stored, "<strong>bold</strong>"
      assert_includes stored, "https://example.com"
    end

    # A body with no attachment must not be rewritten at all — the strip returns early.
    test "a body with no attachment is left byte-identical" do
      note = build_note("<div>plain</div>")
      note.save!
      assert_equal "<div>plain</div>", note.body.body.to_html
    end
  end
end
