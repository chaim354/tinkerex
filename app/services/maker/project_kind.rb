module Maker
  # WHAT KIND OF PROJECT THIS IS, AND WHAT THAT PRESETS (stage 4, S4-7; decision D4; stories
  # 6.1-6.5). Three answers live here and nowhere else: what a folder looks like (#suggest), which
  # panels a kind's page renders and in what order (PRESETS, #layout_for), and which file the hero
  # should prefer (#hero_roles).
  #
  # A KIND IS A GUESS AND THE MAKER'S OVERRIDES ARE AN ANSWER, so #layout_for merges preset then
  # overrides and never the other way round. It is also TOTAL: `panels` is a JSON column nothing
  # validates on the way in, and an unknown key would reach `render "projects/#{key}"` in
  # projects/show.html.erb as a MissingPartial — a 500 on the maker's own page. Filtering here is
  # the guard that cannot be bypassed by the v1 API, a console or a later migration; a write-time
  # validation could be.
  #
  # NOTHING HERE TOUCHES THE PORT. #suggest reads roles off filenames (ProjectFolderListing::Row
  # #role -> Maker::FileAttachment.role_for) and one boolean (#root_repo?), both in memory over a
  # listing built from `nodes`, the catalog all three backends populate — which is why the whole
  # class is testable with no library on disk and behaves identically on the three legs.
  module ProjectKind
    DEFAULT = "other".freeze

    # Plain language, on the edit form and the cards. Not `kind.humanize`: "Electronics & firmware"
    # and "3D printing" are what a maker calls these, and "Cnc" is not a word.
    LABELS = {
      "laser" => "Laser cutting", "print" => "3D printing", "cnc" => "CNC",
      "electronics" => "Electronics & firmware", "mixed" => "Mixed", "other" => "Other"
    }.freeze

    # The panels that open EVERY project page whatever its kind: the folder, then its pictures.
    # A preset may lift panels to sit AFTER these, never before them.
    LEAD = %w[attachments photos].freeze

    # The panels no preset and no override may hide — A DIFFERENT QUESTION FROM `LEAD`, which the
    # two members they share make easy to miss (the same coincidence §14a records for `scannable`
    # and `port_writable` agreeing on three backends). `attachments` is the folder, and the folder
    # is the truth (spec §7). `photos` already omits itself when empty, so hiding it can only ever
    # be invisible or wrong. `publish` is the target of the page head's `#publish` anchor (S4-4),
    # and a dead anchor is worse than a panel nobody wanted.
    ALWAYS = %w[attachments photos publish].freeze

    # ORDER IS DERIVED, NOT SPELLED OUT: `(LEAD + first + PANELS) & PANELS`. Only `electronics`
    # supplies a `first`, so five of the six kinds cannot drift from PANELS at all, and the sixth
    # says only what story 6.2 asks for — schematic and wiring at the top.
    #
    # `schematics` IS IN NO HIDDEN SET, AND THAT IS AN ARGUMENT. projects/_schematics renders
    # nothing when the folder holds no KiCad file, so hiding it for laser/print/cnc has no
    # observable effect EXCEPT in the one case where it is wrong — a laser project that does hold a
    # board. A default that can only be invisible or wrong is not worth having.
    #
    # WHY EACH HIDDEN SET IS WHAT IT IS: `laser` is story 6.1 verbatim ("not BOM, wiring and
    # releases") plus `sheets`, which story 6.1 does not name among what should come first and
    # which real use puts at zero across nine projects. `print` keeps `bom` because a printed
    # assembly is printed parts plus hardware. `cnc` drops `bom` because a milled part is one
    # billet, and keeps `sheets` because feeds, speeds and a job sheet are the CNC bench's
    # paperwork. `electronics` hides only `sheets`. `mixed` and `other` hide nothing, and `other`
    # is the column default — which is what makes this migration invisible to every existing
    # project (spec §4).
    PRESETS = {
      "laser"       => { first: [],                    hidden: %w[bom wiring releases sheets] },
      "print"       => { first: [],                    hidden: %w[wiring releases sheets] },
      "cnc"         => { first: [],                    hidden: %w[bom wiring releases] },
      "electronics" => { first: %w[schematics wiring], hidden: %w[sheets] },
      "mixed"       => { first: [],                    hidden: [] },
      "other"       => { first: [],                    hidden: [] }
    }.freeze

    # WHICH FILE THE HERO PREFERS, as a preference LIST rather than one role, so a print project
    # with no model attached still shows its photo instead of nothing. `other`'s list is
    # `%w[image model]`, which is Maker::Project#derived_cover_node_id's original
    # `find image || find model || first` written as data — that equality is what makes this
    # migration invisible, and project_kind_test.rb asserts it directly.
    HERO_ROLES = {
      "print" => %w[model image], "electronics" => %w[pcb image model]
    }.freeze
    DEFAULT_HERO_ROLES = %w[image model].freeze

    # --- the suggestion -------------------------------------------------------------------------

    # The families a folder is read for. Each is a pair of roles that arrive together on one bench:
    # `.lbrn2` beside the `.svg` it was drawn from, a `.stl` beside the `.step` it was exported
    # from, a `.nc` beside the `.mage` that generated it, a `.c` beside the Gerbers it drives.
    # ROLES THIS MAP DOES NOT NAME ARE DELIBERATELY SILENT: `image`, `document`, `instructions`,
    # `source_archive` and `other` appear in every kind of project, so counting them would say
    # nothing about which kind this is.
    FAMILIES = {
      "laser"       => %w[laser vector],
      "print"       => %w[model cad_source],
      "cnc"         => %w[gcode cnc_design],
      "electronics" => %w[code pcb]
    }.freeze

    # KICAD FILES COUNT TOWARD ELECTRONICS BY NAME, because `ROLE_BY_EXT` deliberately does not
    # know them (they fail `FilesController::EXT_RE`, so `role_for` answers "other") — and a board
    # project that has not yet exported Gerbers or written firmware is exactly the shape the
    # `electronics` preset exists for (found in review: `b.kicad_pcb b.kicad_sch` suggested `other`).
    # The vocabulary is FilePreview's, aliased rather than re-spelled, and the read stays catalog-only.
    KICAD_EXTS = FilePreview::KICANVAS_EXTS

    # A `.git` marker at the folder's own root is EVIDENCE, not a verdict — and WEAK evidence,
    # measured: a read-only probe of the share deployment (2026-09-07, S4-7's close-out) found a
    # `.git` in six of its nine project folders, spanning laser, print and electronics. So the bonus
    # is an AMPLIFIER, never a vote of its own: it applies only when the folder already holds code
    # or board files, and it counts for two files' worth — enough to tip a firmware checkout with a
    # few sources, not enough to outvote five laser files, and nothing at all for a checkout holding
    # only a README (that one reads `other`, the honest answer to "nothing was there to read"). An
    # earlier version voted unconditionally, which made an EMPTY checkout `electronics` and flipped
    # any four-file leader to `mixed`. All of this is pinned in project_kind_test.rb.
    REPO_WEIGHT = 2

    # A SECOND STRONG FAMILY MAKES IT `mixed`, and "strong" is measured against the LEADER rather
    # than against the folder's total: a project with forty photos and two SVGs is a laser project,
    # while one with six SVGs and six STLs is genuinely both. Half the leader is the line.
    MIXED_SHARE = 0.5

    # The kind this folder looks like. Reads at most ProjectFolderListing::FILE_CAP rows (300) —
    # the 300 ALPHABETICALLY-FIRST visible files of the whole subtree, not a sample, so a folder
    # whose kind-bearing files all sort after three hundred others reads `other` (measured in
    # review). Acceptable: the guess is one click to change, decision 5 forbids re-suggesting, and
    # `other`'s preset hides nothing — the cap fails toward today's page. Otherwise read
    # in memory, no query of its own.
    def self.suggest(listing)
      rows = listing.all_rows
      counts = FAMILIES.transform_values { |roles| rows.count { |row| roles.include?(row.role) } }
      counts["electronics"] += rows.count { |row| KICAD_EXTS.include?(File.extname(row.node.name).downcase.delete(".")) }
      counts["electronics"] += REPO_WEIGHT if listing.root_repo? && counts["electronics"].positive?

      # Deterministic: by count, then by FAMILIES' own order, so the same folder always answers the
      # same kind. A tie goes to `mixed` below in any case — this only keeps the sort stable.
      ranked = counts.reject { |_kind, n| n.zero? }
                     .sort_by { |kind, n| [ -n, FAMILIES.keys.index(kind) ] }
      return DEFAULT if ranked.empty?

      top_kind, top = ranked.first
      runner = ranked.dig(1, 1).to_i
      runner >= (top * MIXED_SHARE) ? "mixed" : top_kind
    end

    # THE DOOR EVERY WRITER USES. It answers about a FOLDER, so it can be asked before the project
    # row exists — which is what lets `kind:` be part of Maker::ProjectDiscovery's `create!` rather
    # than an `update_column` after it: one write, and a project is never momentarily `other`.
    #
    # THE THROWAWAY `Maker::Project.new` IS NOT A SMELL, IT IS THE CONTRACT: ProjectFolderListing
    # reads exactly one attribute of the project it is handed, `project.folder_node_id.presence`
    # (project_folder_listing.rb), and widening its constructor to take a bare id would be a change
    # to a class four other slices are editing.
    #
    # `tree:` IS HOW A SWEEP PAYS THE DIRS PLUCK ONCE. Without it, Maker::ProjectDiscovery's capped
    # run would build fifty LibraryTrees; with it, one, plus two queries per project created.
    def self.suggest_for(user:, folder_node_id:, tree: nil)
      return DEFAULT if folder_node_id.blank?

      listing = Maker::ProjectFolderListing.new(user, Maker::Project.new(folder_node_id:),
                                                tree: tree || Maker::LibraryTree.new(user))
      suggest(listing)
    end

    # --- the layout -----------------------------------------------------------------------------

    # One project page's panel list. `order` is always a permutation of Maker::Project::PANELS;
    # `hidden` is always a subset of it with ALWAYS removed. `visible` is what the loop renders.
    Layout = Data.define(:order, :hidden) do
      def visible = order - hidden
      def visible?(key) = order.include?(key) && !hidden.include?(key)
      def hidden?(key) = hidden.include?(key)
    end

    def self.label(kind) = LABELS.fetch(kind.to_s, LABELS.fetch(DEFAULT))

    def self.hero_roles(kind) = HERO_ROLES.fetch(kind.to_s, DEFAULT_HERO_ROLES)

    # THE MAKER'S ANSWER WINS, INCLUDING "nothing hidden" — which is why the test below is `key?`
    # and not `.present?`. A maker who unhides every panel their kind's preset hid stores
    # `"hidden" => []`, and `.present?` would read that as "no override" and hand the preset
    # straight back: the Save button would visibly do nothing for exactly the maker who used it.
    #
    # A PANEL THE STORED ORDER DOES NOT NAME IS APPENDED IN ITS PRESET PLACE, NEVER DROPPED.
    # Shipping an eleventh panel would otherwise make it invisible to every project that has ever
    # saved a layout — silently, and only for the makers who used the feature.
    #
    # AN UNKNOWN KIND FALLS BACK TO `other`'s PRESET rather than raising: `kind` is validated on the
    # way in, but a row written before a kind was retired, or by a future version, must still
    # render a page.
    def self.layout_for(kind:, overrides:)
      preset = PRESETS.fetch(kind.to_s, PRESETS.fetch(DEFAULT))
      over = overrides.is_a?(Hash) ? overrides : {}

      order = (known(over["order"]) + preset_order(preset))
      hidden = (over.key?("hidden") ? known(over["hidden"]) : preset[:hidden]) - ALWAYS
      Layout.new(order: order & Maker::Project::PANELS, hidden:)
    end

    # `Array#&` FILTERS, DEDUPS AND KEEPS THE RECEIVER'S ORDER in one operation, which is all three
    # things this needs — and it is what makes the read total: a key that is not a panel simply is
    # not there, whatever wrote it.
    def self.known(list) = Array(list).map(&:to_s) & Maker::Project::PANELS

    def self.preset_order(preset) = (LEAD + preset[:first] + Maker::Project::PANELS) & Maker::Project::PANELS
    private_class_method :known, :preset_order
  end
end
