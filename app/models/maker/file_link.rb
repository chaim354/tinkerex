module Maker
  # ONE FILE'S TIE TO ANOTHER (stage 4, S4-8; stories 3.2 and 3.3). Two kinds, and which way each
  # points is spelled ONCE here so no door can invert one:
  #
  #   derived_from — FROM the derived file (an SVG export, a generated 3MF) TO its source (the
  #                  .lbrn2, the .scad). "This came from …" sits on the derived file's page.
  #   photo_of     — FROM the photograph TO the file it depicts. "Photos of this file" sits on the
  #                  depicted file's page.
  #
  # BOTH COLUMNS ARE BARE node_id STRINGS WITH NO FOREIGN KEY, and LIVENESS IS ANSWERED AT READ
  # TIME by `nodes.present`, never by the row (§14a). A link whose partner is a tombstone is
  # dropped by the page immediately and destroyed by Maker::AttachmentReaper once that node's undo
  # window closes — hiding is instant because hiding is reversible, destroying waits because it is
  # not (Maker::DeadNodes owns that rule and this table is its third subject).
  #
  # NO OWNERSHIP VALIDATION ON EITHER NODE, AND THAT IS THE SIBLINGS' RULE RATHER THAN AN OMISSION.
  # Maker::Note, Maker::FileAttachment, Maker::Preview and Maker::ReleaseFile all validate a node
  # column for PRESENCE only and ask `current_user.nodes.present.exists?` at the door. Adding one
  # here would put ownership in two places, and — both columns being `null: false` — an unguarded
  # check would run on EVERY save and refuse the row the moment either file was tombstoned, which
  # is the ordinary state this table is built to survive (§14d's dangling-id lock, one table over).
  class FileLink < ApplicationRecord
    self.table_name = "maker_file_links"

    KINDS = %w[derived_from photo_of].freeze

    belongs_to :user

    validates :from_node_id, :to_node_id, presence: true
    validates :kind, inclusion: { in: KINDS }
    validate  :not_a_self_link

    # BOTH DIRECTIONS IN ONE PREDICATE, because the file page needs both and asking twice is two
    # queries for one panel. Both halves are indexed (see the migration).
    scope :touching, ->(node_id) { where("from_node_id = :n OR to_node_id = :n", n: node_id) }

    private

    # A FILE DERIVED FROM ITSELF IS A MISCLICK, NOT A FACT — and the unique index cannot refuse it,
    # since one such row is unique on all four columns. A validation rather than a door check
    # because otherwise all three write doors would each need their own copy.
    def not_a_self_link
      return if from_node_id.blank? || from_node_id != to_node_id

      errors.add(:to_node_id, "can't be the same file")
    end
  end
end
