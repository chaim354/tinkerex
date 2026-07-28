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
  # <br>, which is what the old `white-space: pre-wrap` rendering showed.
  def self.to_html(text)
    ERB::Util.html_escape(text.to_s.delete("\r")).to_str
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

  def down
    add_column :maker_build_log_entries, :body, :text
    MigrationRichText.where(record_type: RECORD_TYPE, name: "body").find_each do |rt|
      # Best-effort inverse: paragraphs and breaks back to newlines, tags stripped.
      text = rt.body.to_s.gsub(%r{</p>\s*<p>}, "\n\n").gsub(%r{<br\s*/?>}, "\n")
      text = ActionController::Base.helpers.strip_tags(text).to_s
      MigrationEntry.where(id: rt.record_id).update_all(body: CGI.unescapeHTML(text))
    end
    change_column_null :maker_build_log_entries, :body, false
    MigrationRichText.where(record_type: RECORD_TYPE, name: "body").delete_all
  end
end
