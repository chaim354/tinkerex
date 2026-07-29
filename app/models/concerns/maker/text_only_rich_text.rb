module Maker
  # Enforces ON THE SERVER the text-only policy that `attachments="false"` states in the editor only.
  #
  # Lexxy is configured attachment-free so that Active Storage is never used for user content
  # (CLAUDE.md §15 — bytes stay out of Rails). That attribute governs the browser and NOTHING else:
  # Action Text's sanitizer PRESERVES <action-text-attachment>, so a body posted directly — curl,
  # devtools, a modified fetch — creates a real, rendering attachment with the editor never
  # involved. Demonstrated, not theorised; see docs/STATUS.md and the overhaul design's §9a.
  #
  # The element is removed rather than its attributes scrubbed, so the guarantee is "no attachment
  # survives a save" regardless of which attributes Action Text or Lexxy emit in a future version.
  #
  # CONSEQUENCE, DELIBERATE: both including models `validates :body, presence: true`, so a body that
  # was ONLY an attachment strips to empty and is REJECTED. That is correct — the submission
  # contained nothing this app accepts — and it is pinned by a test so it is not later read as a
  # regression.
  module TextOnlyRichText
    extend ActiveSupport::Concern

    ATTACHMENT_SELECTOR = "action-text-attachment".freeze

    included do
      before_validation :strip_rich_text_attachments
    end

    private

    # Returns early when there is nothing to strip, so an untouched body is never re-serialised
    # (a rewrite would churn the stored HTML on every save for no reason).
    def strip_rich_text_attachments
      content = body&.body
      return if content.nil?

      fragment = content.fragment.source
      nodes = fragment.css(ATTACHMENT_SELECTOR)
      return if nodes.empty?

      nodes.each(&:remove)
      self.body = fragment.to_html
    end
  end
end
