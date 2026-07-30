# Dedupe maker_file_attachments on (user_id, attachable_type, attachable_id, node_id), keeping the
# LOWEST id in each group, then add a unique index on those same four columns — so the DATABASE,
# not application code, is what stops a second row for one file attached to one thing.
#
# WHY THIS EXISTS NOW, NOT WHEN THE TABLE WAS ADDED. Every writer of this table already dedupes on
# READ before it writes (Maker::AttachToProject#call's find_or_create_by!,
# Maker::AttachToProject#attach_bundle's pluck-and-reject, Maker::ProjectIntake#attach's own
# pluck-and-reject) — enough to stop an ordinary double-click, but not a genuine RACE: two writers
# that both read "not attached yet" in the same window both then write, and until this index existed
# nothing stopped the second write from landing too. Every writer has so far run from a user action,
# so the window needed a rare double-submit to matter in practice. Task 9 wires
# Maker::ProjectIntake into a PERIODIC JOB with no user on the other end to serialize against — one
# ordinary concurrent attach landing in the window is enough on its own, and it recurs every 15
# minutes forever. See Maker::ProjectIntake#attach's own comment for the other half of the fix:
# passing `unique_by:` on its insert_all so a concurrent insert is skipped by the database instead
# of duplicated.
#
# SELF-CONTAINED, following 20260728124303_rederive_vector_and_cad_source_roles.rb,
# 20260729035422_rederive_document_roles.rb and 20260730153103_rederive_laser_roles.rb: a local
# model class rather than Maker::FileAttachment, because a data migration runs against whatever the
# schema and the code look like months from now, and app code keeps moving.
#
# ORDER IS LOAD-BEARING: dedupe FIRST, unique index SECOND. Adding the index before removing the
# existing duplicates fails outright — both Postgres and SQLite refuse to build a unique index over
# rows that already violate it — so a migration that got this backwards would never get past `up`.
#
# THE SURVIVOR IS THE LOWEST ID — the same tie-break Maker::AttachToProject#model_owning uses
# (`order(:id).first`), for the reason that method's own comment gives: a bare `find_by`/`first` is
# `LIMIT 1` over an UNORDERED set, so on SQLite it happens to come back lowest-id-first but on the
# managed Postgres deployment the row returned depends on the query plan. An explicit `order(:id)`
# is what makes "the oldest attachment wins" a fact rather than an assumption about a query plan.
class DedupeAndIndexMakerFileAttachments < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_maker_file_attachments_unique".freeze
  DEDUPE_COLUMNS = %i[user_id attachable_type attachable_id node_id].freeze

  class MigrationAttachment < ActiveRecord::Base
    self.table_name = "maker_file_attachments"
  end

  def up
    # ORDER BY id ASC means each group's rows arrive lowest-id-first, so `drop(1)` keeps exactly
    # that row and marks every later duplicate for deletion. Enumerable#group_by preserves the
    # order elements were encountered in within each bucket, so this holds regardless of how big
    # any one group gets.
    doomed_ids =
      MigrationAttachment
        .select(:id, *DEDUPE_COLUMNS)
        .order(:id)
        .group_by { |a| DEDUPE_COLUMNS.map { |c| a[c] } }
        .flat_map { |_key, rows| rows.drop(1) }
        .map(&:id)

    MigrationAttachment.where(id: doomed_ids).delete_all if doomed_ids.any?
    say "deleted #{doomed_ids.size} duplicate attachment row#{"s" unless doomed_ids.size == 1}"

    # if_not_exists: this must be safe to run against a schema that already has the index — both
    # when `up` runs twice in a row (see the migration test's "up is idempotent") and because the
    # test SUITE loads its schema from db/schema.rb wholesale rather than replaying migrations one
    # at a time, so by the time any test calls `.new.up` the index this line adds is already there.
    add_index :maker_file_attachments, DEDUPE_COLUMNS, unique: true, name: INDEX_NAME,
              if_not_exists: true
  end

  # DROPS THE INDEX AND NOTHING ELSE — and that asymmetry is inherent, not an oversight. `up`
  # deletes rows with `delete_all`; nothing here or anywhere else keeps a shadow copy of what those
  # rows were, so there is nothing for `down` to re-insert. Running `down` after `up` restores the
  # SCHEMA to its pre-migration shape (a downgraded app can write duplicate rows again) but the
  # duplicate rows themselves are gone for good — `down` cannot and does not claim otherwise.
  def down
    remove_index :maker_file_attachments, name: INDEX_NAME, if_exists: true
  end
end
