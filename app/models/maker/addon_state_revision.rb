module Maker
  # ONE IMMUTABLE SNAPSHOT of a saved state's params. Never updated: the row records what was saved
  # at revision N, and a later save appends N+1 rather than rewriting this one.
  #
  # `attr_readonly` IS WHAT REFUSES THE REWRITE — NOT THE SCHEMA, AND NOT THE MISSING `updated_at`
  # (a prior version of this comment conflated the two). Probed directly against this app's own
  # config (`load_defaults 8.1`, under which `ActiveRecord.raise_on_assign_to_attr_readonly`
  # defaults to true): on a PERSISTED row, plain assignment (`revision.data = x`) raises
  # `ActiveRecord::ReadonlyAttributeError` at the assignment itself, and `update!`/`update` raise
  # the same class. `update_column`/`update_columns` ALSO refuse, but with the PARENT class
  # `ActiveRecord::ActiveRecordError` ("data is marked as readonly") rather than that subclass —
  # Rails 8.1's `update_columns` calls `verify_readonly_attribute` before it touches the database,
  # unlike older Rails versions where `update_column` was the standard way AROUND `attr_readonly`.
  # The class difference is worth knowing rather than smoothing over: a `rescue
  # ActiveRecord::ReadonlyAttributeError` written against this comment would NOT catch an
  # `update_column` attempt. None of it blocks CREATE: a new, not-yet-persisted record can set these
  # attributes freely, which is how a revision gets written in the first place.
  #
  # `created_at` IS DELIBERATELY NOT IN THE LIST, so "immutable" above means the SNAPSHOT — the
  # identity, the number and the params. Backdating a row is neither a way to corrupt a design's
  # history nor something anyone does by accident, and nothing downstream reads `created_at` as
  # anything but a display date.
  #
  # WHAT IT DOES NOT CATCH: a relation-level `Maker::AddonStateRevision.update_all` (confirmed —
  # it never instantiates a record, so there is no readonly check to trip) and raw SQL both bypass
  # it entirely, the same blind spot CLAUDE.md §14e documents for chunk refcounts. The migration's
  # own backfill is the one legitimate writer that goes around it, deliberately, via `execute`.
  #
  # There is no `updated_at` column. That is NOT a second enforcement mechanism — record_timestamps
  # still sets `created_at`; there is simply no updated_at column to set, and its absence stops
  # nothing by itself. What it buys is narrower: if a rewrite ever DID get through one of the doors
  # above (`update_all`, raw SQL), there is no updated_at for it to bump — no column making a
  # bypassed edit look like it went through an ordinary, sanctioned save.
  class AddonStateRevision < ApplicationRecord
    self.table_name = "maker_addon_state_revisions"

    belongs_to :addon_state, class_name: "Maker::AddonState"

    attr_readonly :addon_state_id, :revision, :data

    validates :revision, presence: true, numericality: { only_integer: true, greater_than: 0 }
  end
end
