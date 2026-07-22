module Maker
  # A short markdown note attached to a file by node_id (a bare string, no FK — like
  # Maker::FileAttachment). User-scoped; a file has many notes. Rendered via NotesHelper#render_note.
  class Note < ApplicationRecord
    self.table_name = "maker_notes"

    belongs_to :user

    validates :node_id, presence: true
    validates :body, presence: true
  end
end
