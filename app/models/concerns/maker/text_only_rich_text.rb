module Maker
  # Enforces ON THE SERVER the text-only policy that `attachments="false"` states in the editor only.
  #
  # Lexxy is configured attachment-free so that Active Storage is never used for user content
  # (CLAUDE.md §15 — bytes stay out of Rails). That attribute governs the browser and NOTHING else:
  # Action Text's sanitizer PRESERVES <action-text-attachment>, so a body posted directly — curl,
  # devtools, a modified fetch — creates a real, rendering attachment with the editor never
  # involved. Demonstrated, not theorised; see the record (CLAUDE.md §11) and the overhaul design's §9a.
  #
  # The element is removed rather than its attributes scrubbed, so the guarantee is "no attachment
  # survives a save" regardless of which attributes Action Text or Lexxy emit in a future version.
  #
  # CONSEQUENCE, DELIBERATE: the two models that `validates :body, presence: true` (Maker::Note and
  # Maker::BuildLogEntry) REJECT a body that was ONLY an attachment, because it strips to empty.
  # That is correct — the submission contained nothing this app accepts — and it is pinned by a
  # test so it is not later read as a regression. Maker::Release's `notes` are optional, so the
  # same submission there strips to a blank changelog and the release is created without one.
  module TextOnlyRichText
    extend ActiveSupport::Concern

    ATTACHMENT_SELECTOR = "action-text-attachment".freeze

    included do
      # WHICH RICH TEXT ATTRIBUTE THIS MODEL CARRIES, because the name is not always `body`.
      # Maker::Note and Maker::BuildLogEntry name theirs `body` and say nothing; Maker::Release's
      # changelog is `notes` and overrides this. Until S3-5 the strip below read `body` LITERALLY,
      # so including this concern in a model with any other name raised, on the first save,
      # `NameError: undefined local variable or method 'body' for an instance of Maker::Release`.
      # Mutation-checked by putting the literal spelling back: 16 of release_test.rb's 17 cases
      # error, and text_only_rich_text_test.rb's 7 note/entry cases stay green — the default is
      # genuinely untouched. That is why the alternative (a second copy of the strip in Release)
      # is the wrong answer:
      # the policy would then have two places to be forgotten in, and this file's whole
      # existence is that forgetting it is silent.
      class_attribute :text_only_rich_text_attribute, instance_writer: false, default: :body
      before_validation :strip_rich_text_attachments
    end

    private

    # Returns early when there is nothing to strip — we do not re-serialise a fragment we did not
    # touch. NOT because a rewrite would churn the stored HTML: measured, `fragment.to_html` is
    # byte-identical to the stored value (the value came from this same serialiser), so an
    # unconditional rewrite would leave `changed?` false and issue no UPDATE at all. The saving is
    # a serialisation and an attribute write, which is a smaller claim than "prevents churn" and
    # is the one that is actually true.
    def strip_rich_text_attachments
      attribute = text_only_rich_text_attribute
      content = public_send(attribute)&.body
      return if content.nil?

      # MUTATES THE LIVE TREE IN PLACE, and that is safe only because of the line that follows it.
      # The attribute's `.body` returns a MEMOIZED Content — the same object across reads — so this is not a
      # throwaway copy, and Action Text's own ActionText::Fragment#update dups the source before
      # yielding precisely to avoid what this does. What makes it correct here is that the strip is
      # immediately followed by replacing the attribute, so the mutated Content is discarded on the
      # next read. Moving that replacement away from here, or "simplifying" it to reuse this
      # fragment, breaks a property no other line states.
      fragment = content.fragment.source
      nodes = fragment.css(ATTACHMENT_SELECTOR)
      return if nodes.empty?

      nodes.each(&:remove)
      public_send("#{attribute}=", fragment.to_html)
    end
  end
end
