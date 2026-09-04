class CreateMakerFilingRules < ActiveRecord::Migration[8.1]
  # Stage 3, S3-1: the extension map the intake sweep files by, per user (spec §3, §5). Seeded from
  # Maker::ProjectFolders::ROLE_FOLDERS' eleven roles on a user's first read
  # (Maker::FilingRules.seed!); edited at /settings/filing thereafter. `ext` and `folder` are both
  # validated in Maker::FilingRule (format, presence, the reserved-name/plain-segment rule) — this
  # migration only carries the NOT NULL floor and the uniqueness the app-level check can race.
  def change
    create_table :maker_filing_rules do |t|
      # `index: false` — the composite unique index below already leads with `user_id`, so a bare
      # one here would be a strict prefix of it and cost a write on every insert for a seek the
      # composite already answers (test/architecture_invariants_test.rb's redundant-prefix-index
      # guard; CreateMakerRepoEdits is the precedent this copies).
      t.references :user, null: false, foreign_key: true, index: false
      t.string :ext, null: false      # "stl" — lowercase, no dot, FilesController::EXT_RE
      t.string :folder, null: false   # "models" — one lowercase path segment, never reserved
      t.timestamps
    end
    add_index :maker_filing_rules, %i[user_id ext], unique: true
  end
end
