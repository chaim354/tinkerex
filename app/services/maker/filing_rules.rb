module Maker
  # THE EXTENSION MAP, PER USER (stage 3, S3-1): which subfolder of Projects/<slug>/ the intake
  # sweep files each extension into. Seeded ONCE from the thirteen-role default
  # (ProjectFolders::ROLE_FOLDERS over FileAttachment::ROLE_BY_EXT) PLUS `BEYOND_ROLE_BY_EXT`, the
  # keys the vocabulary itself cannot carry (stage 4, S4-2), on the first read; from then on the
  # user's rows are the truth — the seed is a starting point, never a fallback that would silently
  # overrule an edit.
  class FilingRules
    def self.for(user) = new(user).to_h

    # KEYS THE VOCABULARY CANNOT CARRY, SEEDED BESIDE IT (stage 4, S4-2; story 2.8).
    # `kicad_sch`/`kicad_pcb` fail `FilesController::EXT_RE`, so they can never be
    # `Maker::FileAttachment::ROLE_BY_EXT` entries and this map — built from ROLE_BY_EXT — could
    # never reach them. `Maker::FilingRule::KEY_RE` admits them, so a destination is expressible;
    # this is where a NEW user gets one, and db/migrate/20260907120100 is where an existing one does.
    #
    # `pcb`, NOT `cad`: a schematic and a board layout are the project the fabrication outputs came
    # from, and the folder holds the whole board — the same argument `.gbrjob` carries for being
    # `pcb` rather than `document`. Spelled as a literal folder name rather than through
    # ROLE_FOLDERS because there is no ROLE here to look one up by; the totality test in
    # project_folders_test.rb has nothing to say about these two, so filing_rules_test.rb asserts
    # they pass Maker::FilingRule's own validation instead.
    #
    # KEEP THIS SMALL. Every entry is a claim that a real format exists whose extension the Files
    # page cannot filter by. Two today.
    BEYOND_ROLE_BY_EXT = { "kicad_sch" => "pcb", "kicad_pcb" => "pcb" }.freeze

    # IDEMPOTENT, GUARDED BY `exists?` RATHER THAN A STAMP COLUMN — unlike Maker::Shelf.seed_once!,
    # which needs `users.shelves_seeded_at` specifically because it must tell "never seeded" apart
    # from "seeded, then every row deleted" (an all-rows-deleted user must never reseed — that
    # would fight a deliberate "I use none of these" the same way re-filing a subfolder would fight
    # a user's own filing, §14f). `exists?` CANNOT tell those two states apart — it reads false in
    # both — so, UNLIKE Shelf, this guard does NOT protect a fully-emptied user from being reseeded
    # on their next read. That is an accepted gap, not an oversight: an emptied filing map recovers
    # to the same thirteen-role default a brand-new user gets, the reasonable, low-stakes outcome
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
      rows += BEYOND_ROLE_BY_EXT.map do |ext, folder|
        { user_id: user.id, ext:, folder:, created_at: now, updated_at: now }
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
