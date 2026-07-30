module Maker
  # A note attached to a file by node_id (a bare string, no FK — like Maker::FileAttachment).
  # User-scoped; a file has many notes. The body is Action Text (Lexxy in the browser); it was
  # markdown until 2026-07-27 and existing notes were converted through NotesHelper#render_note.
  class Note < ApplicationRecord
    self.table_name = "maker_notes"

    belongs_to :user

    has_rich_text :body
    include Maker::TextOnlyRichText

    validates :node_id, presence: true
    validates :body, presence: true
  end
end
