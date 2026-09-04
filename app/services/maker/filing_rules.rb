module Maker
  # THE EXTENSION MAP, PER USER (stage 3, S3-1): which subfolder of Projects/<slug>/ the intake
  # sweep files each extension into. Seeded ONCE from the eleven-role default
  # (ProjectFolders::ROLE_FOLDERS over FileAttachment::ROLE_BY_EXT) on the first read, then the
  # user's rows are the truth — the seed is a starting point, never a fallback that would silently
  # overrule an edit.
  class FilingRules
    def self.for(user) = new(user).to_h

    # IDEMPOTENT, GUARDED BY `exists?` RATHER THAN A STAMP COLUMN — unlike Maker::Shelf.seed_once!,
    # which needs `users.shelves_seeded_at` specifically because it must tell "never seeded" apart
    # from "seeded, then every row deleted" (an all-rows-deleted user must never reseed — that
    # would fight a deliberate "I use none of these" the same way re-filing a subfolder would fight
    # a user's own filing, §14f). `exists?` CANNOT tell those two states apart — it reads false in
    # both — so, UNLIKE Shelf, this guard does NOT protect a fully-emptied user from being reseeded
    # on their next read. That is an accepted gap, not an oversight: an emptied filing map recovers
    # to the same eleven-role default a brand-new user gets, the reasonable, low-stakes outcome
    # here (a shelf's "I use none of these" is a real product choice; a folder for every extension
    # existing again is not a comparable loss).
    #
    # WHAT `exists?` DOES PROTECT, MUTATION-CHECKED RATHER THAN ASSUMED: a user who holds ANY row
    # at all, seeded or not. Dropping this guard lets `seed!` attempt all
    # Maker::FileAttachment::ROLE_BY_EXT.size rows on EVERY read — and `insert_all`'s own default
    # `ON CONFLICT DO NOTHING` (no `unique_by:`/`on_duplicate:` given) quietly no-ops the ones that
    # already exist, so a FULLY seeded user's count does not move and an edited row is not
    # overwritten either way. What the guard alone stops is a user holding only SOME rows — one
    # custom rule made before ever visiting /settings/filing, reachable in practice only by a
    # direct POST or the console — from silently getting every MISSING extension topped up from
    # the seed instead of staying at exactly the row count they made.
    def self.seed!(user)
      return if user.maker_filing_rules.exists?

      now = Time.current
      rows = Maker::FileAttachment::ROLE_BY_EXT.map do |ext, role|
        { user_id: user.id, ext:, folder: Maker::ProjectFolders::ROLE_FOLDERS.fetch(role),
          created_at: now, updated_at: now }
      end
      Maker::FilingRule.insert_all(rows) if rows.any?
    end

    def initialize(user)
      self.class.seed!(user)
      @map = user.maker_filing_rules.pluck(:ext, :folder).to_h # ONE query after the seed
    end

    def to_h = @map
  end
end
