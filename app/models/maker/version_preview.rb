module Maker
  # ONE CACHED RENDER OF ONE PAST VERSION OF ONE FILE. The read side of git-tracked history: the
  # tile the version list shows beside a commit.
  #
  # THIS TABLE EXISTS ONLY BECAUSE §14b'S LEAK WAS EAGER GENERATION, NOT OLD THUMBNAILS. That
  # invariant records `Maker::Preview` being collapsed from one row per VERSION to one row per
  # (user, node, kind) "which leaked a row + blob on every save". Nothing here may re-create that:
  #
  #   * `maker_previews` IS NOT TOUCHED by this model or by Maker::RenderVersionPreviewJob, so
  #     `GeneratePreviewJob#commit_if_current` still owns the current row and a historical render
  #     can never repoint it. `version_preview_test.rb` pins that directly.
  #   * ROWS ARE MINTED ON DEMAND, when someone opens History. Nothing on the save path, the scan
  #     path or the commit path may create one — creating them eagerly IS the leak, spelled
  #     differently, and it would be spelled convincingly ("we already have the bytes here").
  #   * RETENTION IS PART OF THE DESIGN, not a later idea: see `stale_before`.
  #
  # NOT USER-SCOPED, unlike `Maker::Preview` — see the migration for the measured argument. Tenancy
  # comes from the project through a real foreign key, the shape `Maker::GitRepo` and
  # `Maker::AddonFile` already have.
  #
  # ACTIVE STORAGE, AND THE OPEN PROBLEM IT INHERITS. `has_one_attached` follows `Maker::Preview`
  # exactly, which is defensible consistency and is why it was chosen — one attachment mechanism for
  # rendered artifacts, one place to change it. But it is not a free choice: tinkerex#160 records
  # that Active Storage sits on a Kamal VOLUME today, and that "no app volume" is what shaped the
  # whole git-tracked-projects design (the repository itself lives in the user's own library, over
  # the port, for exactly that reason). This cache does NOT solve that; it inherits it, and it makes
  # the volume grow with browsing rather than only with saves. Retention is what bounds the damage,
  # which is the other reason `last_viewed_at` is not optional decoration.
  class VersionPreview < ApplicationRecord
    self.table_name = "maker_version_previews"

    belongs_to :project, class_name: "Maker::Project"
    has_one_attached :asset

    # The port's byte reads are per USER, and this row reaches one only through its project. A
    # delegate rather than a column: two answers to "whose is this" is what the missing `user_id`
    # deliberately avoids.
    delegate :user, to: :project

    # FIVE STATES, AND THE THREE NON-READY TERMINALS ARE THREE DIFFERENT FACTS. Collapsing any pair
    # is how a UI comes to tell a maker their history is broken when it is not:
    #
    #   pending     — the only non-terminal state. The row exists (History asked for it); the job
    #                 has not finished. A retryable fetch failure stays here on purpose, with the
    #                 reason in `error`, so a blip is never recorded as a permanent verdict.
    #   ready       — rendered, `asset` attached.
    #   not_kept    — THE STORE NO LONGER HAS THESE BYTES. Expected, not an error, and the ordinary
    #                 case on `share`: the maker's overwrite in Finder destroyed the previous bytes
    #                 before this app ever saw them (§14a — share and s3 are current-state only, by
    #                 design). The COMMIT is real and its metadata intact; only the content is gone.
    #                 This is the greyed "not kept" tile, and it must never read as `failed`.
    #   unsupported — no permissive renderer for this format on this box. Neither a loss nor a bug;
    #                 the same word `maker_previews` already uses for it.
    #   failed      — a real error while rendering. THIS ONE IS A BUG and should be read as one.
    STATES = %w[pending ready not_kept unsupported failed].freeze

    validates :node_id, :content_token, :source_filename, presence: true
    validates :state, inclusion: { in: STATES }
    # BOTH HALVES ARE LOAD-BEARING AND NEITHER SUBSTITUTES FOR THE OTHER. The validation gives a
    # door a 422 instead of a 500; the unique index behind it is what actually holds, because a
    # validation is a read-then-write and two History opens can both read "no row yet".
    validates :node_id, uniqueness: { scope: %i[project_id content_token source_filename] }

    scope :ready, -> { where(state: "ready") }

    # THE RETENTION KEY, WRITTEN DOWN ONCE. `last_viewed_at` is null until something is actually
    # viewed, and a null there must never read as "infinitely old" (which would evict every row the
    # moment History minted it) nor as "infinitely new" (which would make an unviewed row immortal).
    # It falls back to `created_at`, which is the honest answer to "when did this last matter".
    #
    # `COALESCE` rather than an `OR` pair because it is one comparison in both adapters (§14e: no
    # PG-only SQL, and no SQLite-only SQL either).
    #
    # SAY WHAT IS NOT HERE: NOTHING SWEEPS YET. This scope is the retention KEY; the recurring job
    # that uses it is a later step. Do not read the existence of this scope as retention being
    # implemented — the cache is bounded only once something calls it.
    scope :stale_before, ->(cutoff) { where("COALESCE(last_viewed_at, created_at) < ?", cutoff) }
  end
end
