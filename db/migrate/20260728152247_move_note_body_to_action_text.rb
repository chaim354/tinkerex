# Converts maker_notes.body (markdown) into Action Text, then drops the column. Same column-shadow
# reasoning as MoveBuildLogBodyToActionText.
#
# UNLIKE the other data migrations here, this one deliberately CALLS APP CODE: fidelity means
# producing exactly what the page was already showing, and that is NotesHelper#render_note
# (kramdown -> sanitize). Reimplementing a markdown renderer inline to stay self-contained would
# trade the one property that matters for a principle. render_note is safe to depend on — it keeps
# a second caller after this migration (app/views/models/show.html.erb renders Maker::Model#notes
# through it), so it is not going away.
class MoveNoteBodyToActionText < ActiveRecord::Migration[8.1]
  class MigrationNote < ActiveRecord::Base
    self.table_name = "maker_notes"
  end

  class MigrationRichText < ActiveRecord::Base
    self.table_name = "action_text_rich_texts"
  end

  RECORD_TYPE = "Maker::Note".freeze

  def self.to_html(markdown)
    ApplicationController.helpers.render_note(markdown).to_str
  end

  def up
    now = Time.current
    MigrationNote.find_each do |note|
      next if MigrationRichText.exists?(record_type: RECORD_TYPE, record_id: note.id, name: "body")
      MigrationRichText.create!(
        name: "body", record_type: RECORD_TYPE, record_id: note.id,
        body: self.class.to_html(note.body), created_at: now, updated_at: now
      )
    end
    remove_column :maker_notes, :body
  end

  # Irreversible, for the same two reasons as MoveBuildLogBodyToActionText — plus a third that makes
  # it strictly worse here: the source was MARKDOWN, and markdown syntax (`**`, `- `, `[t](url)`)
  # cannot be recovered from rendered HTML at all. Do not copy the reconstruction shape an earlier
  # draft of this plan had; it silently blanks every note (has_rich_text's reader shadows the
  # restored column) while returning text that has lost the very syntax that made it a note body.
  def down
    raise ActiveRecord::IrreversibleMigration,
      "Notes were markdown; rendered HTML cannot be converted back, and the restored column is " \
      "shadowed by has_rich_text :body. Restore from a pre-migration backup."
  end
end
