module Maker
  # THE DESKTOP CLIENT'S CATALOG. Broader than Maker::Model on purpose: an Item is any maker
  # artefact — electronics, a LightBurn job, a CAD part — where a Model is specifically a
  # 3D-print model. The two are NOT duplicates awaiting a merge; tinkerex#153 asked which
  # survives and the answer is both, because their vocabularies do not fit inside one another
  # (ITEM_TYPES has five members; a Model has a print_status).
  #
  # NOTHING IN THE WEB LAYER READS THIS CLASS — no route, no view. Its only consumer is the
  # desktop app's Library tab, over the v1 API: chaim354/tinkerex-client's
  # `client/maker-app/src/index.html` (the navLibrary tab) -> `src/library.js` -> the
  # `maker_*_item`/`maker_*_collection` Tauri commands -> `sync-client/src/maker.rs`. That is
  # why V1::Maker::ItemsController and the collections controller exist with no web counterpart,
  # and why removing either is a WIRE deprecation with a client release behind it, never a
  # deletion here. Verified 2026-08-26; re-grep the client before assuming it has moved on.
  class Item < ApplicationRecord
    self.table_name = "maker_items"

    belongs_to :user

    ITEM_TYPES = %w[model_3d cad lightburn electronics other].freeze

    # HOW THE PHYSICAL THING WAS OBTAINED. Named for that question rather than for its column,
    # because Maker::Model has an `origin` column too whose values answer a DIFFERENT question
    # (which door wrote the row) — see Maker::Model::ROW_ORIGINS. Both were called ORIGINS until
    # 2026-08-26 and the collision cost a standing comment warning readers not to connect them.
    ACQUISITION_ORIGINS = %w[self_made downloaded modified].freeze

    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy
    has_many :taggings, as: :taggable, class_name: "Maker::Tagging", dependent: :destroy
    has_many :collection_items, class_name: "Maker::CollectionItem", dependent: :destroy
    has_many :tags, through: :taggings, class_name: "Maker::Tag"
    # §14d: without a `dependent:`, a destroyed item leaves a DANGLING taskable_id, and
    # `Task#taskable_belongs_to_owner` (guarded on `taskable_id.present?`) then refuses every later
    # save of that task — the row is permanently uneditable. `:nullify`, not `:destroy`: `taskable`
    # is `optional: true`, so an ownerless task is a valid, already-blessed state, and destroying
    # the task would delete the user's own to-do along with the item it happened to mention.
    has_many :tasks, as: :taskable, class_name: "Maker::Task", dependent: :nullify

    validates :title, presence: true
    validates :item_type, inclusion: { in: ITEM_TYPES }
    validates :origin, inclusion: { in: ACQUISITION_ORIGINS }

    scope :of_type, ->(t) { where(item_type: t) if t.present? }
    scope :favorited, -> { where(favorited: true) }
  end
end
