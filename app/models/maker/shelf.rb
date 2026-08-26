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

      SEEDS.each { |path| user.maker_shelves.create!(path:) }
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
      raw = path.to_s
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
