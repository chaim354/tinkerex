# Converts maker_build_log_entries.body (plain text) into Action Text, then drops the column.
#
# The column must GO, not stay alongside: `has_rich_text :body` defines a reader that shadows a
# same-named attribute, so leaving both means the model silently answers with a different object
# than the table holds, and `validates :body, presence:` starts validating that object instead.
#
# Self-contained (raw table classes, no app models) for the usual data-migration reason: this runs
# against whatever the code looks like months from now.
class MoveBuildLogBodyToActionText < ActiveRecord::Migration[8.1]
  class MigrationEntry < ActiveRecord::Base
    self.table_name = "maker_build_log_entries"
  end

  class MigrationRichText < ActiveRecord::Base
    self.table_name = "action_text_rich_texts"
  end

  RECORD_TYPE = "Maker::BuildLogEntry".freeze

  # Plain text -> an Action Text body. Escape FIRST, then add markup: the source is plain text a
  # user typed, so a stray `<` is a less-than sign and `<script>` is something they wrote about,
  # never markup to honour. Blank-line-separated blocks become paragraphs; single newlines become
  # <br>, which is what the old `white-space: pre-wrap` rendering showed. Newlines are normalized
  # (not just `\r` deleted) so a bare `\r` — a lone-CR classic-Mac line ending, not just `\r\n` —
  # still becomes a line break instead of silently fusing the two sides together.
  def self.to_html(text)
    ERB::Util.html_escape(text.to_s.gsub(/\r\n?/, "\n")).to_str
      .split(/\n{2,}/)
      .reject(&:empty?)
      .map { |para| "<p>#{para.gsub("\n", "<br>")}</p>" }
      .join
  end

  def up
    now = Time.current
    MigrationEntry.find_each do |entry|
      next if MigrationRichText.exists?(record_type: RECORD_TYPE, record_id: entry.id, name: "body")
      MigrationRichText.create!(
        name: "body", record_type: RECORD_TYPE, record_id: entry.id,
        body: self.class.to_html(entry.body), created_at: now, updated_at: now
      )
    end
    remove_column :maker_build_log_entries, :body
  end

  # Deliberately irreversible. Two independent reasons, both verified rather than assumed:
  #
  # 1. `has_rich_text :body` reads `rich_text_body || build_rich_text_body`, so once the rich texts
  #    are deleted the model returns a freshly built BLANK RichText — shadowing the plain column a
  #    reconstruction would have just repopulated. A bare `db:rollback`, not paired with reverting
  #    the model in lockstep, would leave every entry reading empty, silently, app-wide. A rollback
  #    that erases visible content without erroring is worse than one that refuses.
  # 2. Reconstruction is not merely lossy but garbling: once Lexxy is wired up, <ul>/<li>/<h1> match
  #    neither the </p><p> nor the <br> pattern, so strip_tags fuses adjacent blocks with no
  #    separator — "<h1>Day 1</h1><p>Started.</p>" comes back as "Day 1Started."
  #
  # The real undo for a dropped populated column is a pre-migration snapshot, which an operator
  # should be taking regardless. A regex reconstruction does not replace that; it only makes it feel
  # unnecessary.
  def down
    raise ActiveRecord::IrreversibleMigration,
      "Action Text -> plain text is lossy and garbling, and the restored column is shadowed by " \
      "has_rich_text :body (every entry would read blank). Restore from a pre-migration backup."
  end
end
