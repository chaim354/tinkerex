# THE HISTORICAL RENDER CACHE — thumbnails of PAST versions, and the whole design is shaped by the
# invariant it is most likely to undo.
#
# §14b: "A `Maker::Preview` is ONE ROW PER (user, node, kind), REPOINTED as content moves — was one
# per VERSION, which leaked a row + blob on every save." A thumbnail per version is exactly what was
# removed, so this table only earns its existence by being the other half of that sentence: THE LEAK
# WAS EAGER GENERATION ON EVERY SAVE, NOT THE EXISTENCE OF OLD THUMBNAILS. Three properties keep
# them apart, and undoing any one re-creates the bug §14b exists to record:
#
#   1. SEPARATE TABLE. `maker_previews` is not touched and `GeneratePreviewJob#commit_if_current`
#      keeps its compare-and-set, so a historical render can never claim the current row.
#   2. ON DEMAND ONLY. Rows are minted when someone opens History. Nothing on the save path, the
#      scan path or the commit path may create one — that is the leak, spelled differently.
#   3. RETENTION. `last_viewed_at` is the key, so the cache cannot grow without bound.
#
# NO `user_id`, AND THIS IS THE ONE PLACE IT DEPARTS FROM `maker_previews`. It is the shape
# `maker_git_repos` measured one commit ago: 22 of 24 maker_* tables carry a `user_id`, and the ones
# that do not are exactly the ones that hang off a parent through a REAL foreign key and take
# tenancy from it. A version only exists because a PROJECT's repository recorded it — there is no
# version history outside a project repo (`maker_git_repos.project_id` is unique) — so the project
# is the true parent, not a convenience, and a `user_id` here would be a second answer to "whose is
# this". `Maker::VersionPreview#user` delegates through the project.
#
# `on_delete: :cascade` for the same reason `maker_git_repos` has it: a row here is a CACHE about a
# project and means nothing without it, and the cascade also covers `delete_all`, a console
# `destroy_all` and a raw-SQL data migration, none of which run a callback. It reaches a destroyed
# USER too, through `User has_many :maker_projects, dependent: :destroy`. It deletes the ROW, never
# the version: the history is in the repository and this table was only ever a render cache over it.
class CreateMakerVersionPreviews < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_version_previews do |t|
      # `index: false`: the composite unique index below LEADS with project_id, so it already
      # serves both "this project's cached renders" and the cascade's child lookup. A second
      # single-column index would be a prefix of it.
      t.references :project, null: false, index: false,
                             foreign_key: { to_table: :maker_projects, on_delete: :cascade }

      # WHICH FILE. The stable string `nodes.node_id`, joined by bare string exactly as
      # `maker_previews.node_id` is (§14a: a tombstone outliving its row is the design, so this
      # must stay soft — no constraint).
      t.string :node_id, null: false

      # WHICH VERSION OF IT — a BACKEND-POLYMORPHIC content token, the same value space
      # `maker_previews.version_id` holds under a name it kept from before the FileLayer port
      # existed: a version UUID on chunk_remote, a CONTENT HASH on share/s3. It is NOT a foreign key
      # into anything and no `versions` table exists in this database to point at (§5).
      #
      # KEYED ON THE CONTENT, NOT ON THE COMMIT, and that is a deliberate dedup: two commits that
      # left a file byte-identical render to the same image, so they share one row and one blob.
      # A commit oid here would mint a second identical render for every commit that touched a
      # sibling file.
      t.string :content_token, null: false

      # THE NAME THE RENDERER WAS CHOSEN FROM, and it is called `source_filename` rather than `kind`
      # ON PURPOSE. The plan called this column `kind` and then passed it to
      # `Maker::Previews::Registry.for_filename` — but `Maker::Preview#kind` means something else
      # entirely (thumbnail / model_glb / render / geometry), so one word would have named two
      # unrelated things in two sibling tables. It is part of the unique key because it is genuinely
      # part of the render's identity: a file renamed `part.svg` -> `part.txt` between two versions
      # has ONE content token and TWO different pictures.
      t.string :source_filename, null: false

      # `state`, NOT `status`, and the difference in name tracks a real difference in vocabulary:
      # this one carries `not_kept`, which `maker_previews` has no concept of. Sharing the column
      # name across two different vocabularies is how a later reader comes to share a constant or a
      # scope between them. See Maker::VersionPreview::STATES for what each value means.
      t.string :state, null: false, default: "pending"

      # WHICH BUILD PRODUCED THE CACHED IMAGE — the second staleness axis
      # `Maker::Previews::Enqueue` already names ("was it made by the CURRENT CODE?"). DELIBERATELY
      # NOT IN THE UNIQUE KEY: a renderer bump would then mint a second row per version rather than
      # replacing one, which is the leak shape again with a different trigger.
      t.integer :renderer_revision
      t.integer :width
      t.integer :height
      t.text    :error

      # THE RETENTION KEY, AND IT IS `last_viewed_at` RATHER THAN `created_at` FOR A REASON: a
      # version nobody looks at should age out even if it was rendered recently, and one people keep
      # opening should stay. Nullable — a row exists from the moment History asks for it, which may
      # be before anything has been viewed — so every reader must fall back to `created_at`
      # (`Maker::VersionPreview.stale_before` is the one place that fallback is written).
      t.datetime :last_viewed_at
      t.timestamps

      # ONE ROW PER (project, node, version, renderable identity), ENFORCED BY THE DATABASE RATHER
      # THAN BY CONVENTION. The model validation beside it gives a door a 422 instead of a 500; only
      # this index actually holds, because a validation is a read-then-write and two History opens
      # can both read "no row yet".
      t.index %i[project_id node_id content_token source_filename],
              unique: true, name: "idx_maker_version_previews_unique"
      # The retention sweep's own access path. It orders by the COALESCE above, which no index can
      # serve directly; this one at least keeps the never-viewed rows cheap to find.
      t.index :last_viewed_at
    end
  end
end
