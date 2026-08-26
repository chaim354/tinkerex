module Maker
  # A folder that is NOT itself a model: its loose model-role files are each their own model, and
  # each of its subfolders is one model claiming its whole subtree. The nearest shelf ancestor of a
  # file decides which. Rules and reasoning: docs/invariants/model-intake.md.
  class Shelf < ApplicationRecord
    self.table_name = "maker_shelves"

    belongs_to :user

    # What ships. All three are ordinary deletable rows -- see .seed_once! for why they are seeded
    # exactly once rather than ensured on every sweep.
    SEEDS = [ "", "Models", "Projects/*/models" ].freeze

    # A whole segment may be this and nothing else. `*x` is not a wildcard, it is a filename we
    # cannot match, so it is refused rather than silently never matching.
    WILDCARD = "*".freeze

    validates :path, uniqueness: { scope: :user_id }
    validate  :path_segments_are_allowed

    # Does `pattern` name `path`? Both are "" for the library root, segments joined by "/".
    # A "*" segment matches exactly one segment -- never zero, never several.
    def self.matches?(pattern, path)
      ps = pattern.to_s.split("/")
      xs = path.to_s.split("/")
      return false unless ps.size == xs.size

      ps.zip(xs).all? { |p, x| p == WILDCARD || p == x }
    end

    # ONCE PER USER, GUARDED BY users.shelves_seeded_at. Called from both doors that can be the
    # first a user reaches -- the settings page and the sweep -- so neither has to be first.
    #
    # WITHOUT THE STAMP, deleting every shelf resurrects all three on the next tick: the
    # fight-the-user shape 14f exists to prevent, and the same argument that makes a dismissed
    # model stay dismissed.
    def self.seed_once!(user)
      return if user.shelves_seeded_at.present?

      # find_or_create_by!, NOT create!, AND THE STAMP IS WHAT ENDS THE LOOP. A user holding a seed
      # path WITHOUT the stamp made every later sweep raise "Path has already been taken" --
      # permanently, because `create!` cannot tolerate the row it finds and the stamp that would
      # stop it being tried again is written after. Reachable two ways: a process that died between
      # the rows and the stamp, and anyone who creates "" themselves before their first sweep.
      # A permanent failure on the recurring job's own first line is not a state to leave live.
      SEEDS.each { |path| user.maker_shelves.find_or_create_by!(path:) }
      user.update_column(:shelves_seeded_at, Time.current)
    rescue ActiveRecord::RecordNotUnique
      # Two callers seeding at once -- the settings page and the sweep -- with the unique index
      # deciding which one lost. The rows exist either way, so the loser stamps and carries on;
      # failing a whole sweep over "someone else already did this" is the wrong answer, and it is
      # the same reading Models::AttachmentsController#create records for a double-clicked Attach.
      user.update_column(:shelves_seeded_at, Time.current)
    end

    private

    # THE SAME TWO QUESTIONS EVERY OTHER LEAF-NAME DOOR ASKS, composed rather than re-spelled:
    # Maker::MoveNode.valid_leaf_name? for syntax and Library::ReservedNames.reserved? for the
    # library's own namespace (14b -- a private, weaker spelling is how `..` becomes a live node).
    #
    # NEITHER COMPOSED CALL KNOWS ABOUT `*` -- it is Shelf's own pattern syntax, not a library
    # naming rule, so "does this segment embed a literal wildcard character without BEING the
    # wildcard" is asked here rather than folded into either call or spelled a second time inside
    # them. `valid_leaf_name?("*x")` is true (`*` is an ordinary, legal filesystem byte) and
    # `reserved?("*x")` is false, so without this clause a segment like `*x` -- almost certainly a
    # typo for the wildcard -- would validate and then silently never match anything in
    # .matches?, exactly the "refused rather than silently never matching" the WILDCARD comment
    # above promises.
    def path_segments_are_allowed
      # NIL IS NOT THE ROOT, AND THE DIFFERENCE MATTERS AT A DOOR. `""` is the library root and is
      # valid; a MISSING path is a caller that forgot one. Without this the record validates and
      # then dies on the database's NOT NULL, turning a routine form error into a 500 in
      # ShelvesController.
      return errors.add(:path, "isn't allowed - a shelf needs a path (\"\" is the library root)") if path.nil?

      raw = path
      # The library root, which is a perfectly ordinary shelf and has no segments to check.
      return if raw.empty?

      if raw.start_with?("/") || raw.end_with?("/") || raw.include?("//")
        errors.add(:path, "isn't allowed - use folder names joined by /, with no leading or trailing slash")
        return
      end

      raw.split("/").each do |segment|
        next if segment == WILDCARD
        next if !segment.include?(WILDCARD) &&
                Maker::MoveNode.valid_leaf_name?(segment) &&
                !Library::ReservedNames.reserved?(segment)

        errors.add(:path, "isn't allowed - #{segment.inspect} can't be a folder name")
        return
      end
    end
  end
end
