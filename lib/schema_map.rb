# frozen_string_literal: true

# Builds `docs/schema-map.html`: one self-contained page showing every table, every column and
# every relationship across all four databases. `bin/rails schema:map` regenerates it, and
# `test/schema_map_test.rb` goes red when the checked-in page no longer matches what this
# produces — so the map cannot quietly describe a schema that has moved on, which is the failure
# mode a generated document checked into `docs/` otherwise has by construction.
#
# THE MAP HAS TWO HALVES AND ONLY ONE OF THEM IS DERIVED.
#
#   Derived  — tables, columns, types, nullability, defaults, indexes, and the foreign-key
#              constraints. Parsed out of the schema dumps, so a migration carries them for free.
#   Authored — the structural relationships (EDGES) and the layout (LAYOUT). These CANNOT be
#              derived: this schema joins the file layer by BARE STRING — every arrow into
#              `nodes.node_id` — with no constraint anywhere, which is precisely the fact the map
#              exists to show. Most of its links are kept by the app alone; the page's legend
#              counts each kind from the data.
#
# WHAT `problems` CATCHES, and the suite runs it on every leg:
#   * an edge naming a table or column that no longer exists (a rename, a drop);
#   * an edge drawn as a database foreign key that ISN'T one;
#   * an edge drawn as app-level that the database DOES enforce;
#   * a real `add_foreign_key` nobody drew;
#   * a table absent from LAYOUT, or a LAYOUT entry naming a table that no longer exists;
#   * a reference nobody classified. Every `*_id` column of the primary schema but `user_id`
#     (which `edges` draws itself) is DRAWN in EDGES or LISTED in NOT_EDGES with the reason it is
#     not a join — exactly one (`classification_problems`). That makes the authored half complete
#     by check rather than by memory, and test/models/structural_orphan_test.rb with it: that test
#     derives its cases from EDGES, so a pointer nobody drew was a pointer nothing considered.
#
# WHAT NOTHING HERE CATCHES — state it plainly, because the guard above reads stronger than it is:
#   * a reference whose column name does not end in `_id`. None in the primary schema is a join
#     the map could draw — `addon_key` names an addon, `content_token` and `chunk_hash` name
#     content, `bom_revision` is a copy taken at release time — so name a new reference `*_id` (a
#     node id `node_id` or `*_node_id`) and the rule asks about it for free;
#   * a new target of a polymorphic pair EDGES already draws (`taskable_id` naming a third type):
#     the column is classified, so nothing asks whether every target is;
#   * an arrow to the WRONG target: the rule asks that a column be classified, not that the
#     classification be true.
module SchemaMap
  # The four databases (§4: Solid Queue/Cache/Cable each get their own).
  SOURCES = {
    "primary" => "db/schema.rb",
    "queue"   => "db/queue_schema.rb",
    "cache"   => "db/cache_schema.rb",
    "cable"   => "db/cable_schema.rb"
  }.freeze

  OUTPUT   = "docs/schema-map.html"
  TEMPLATE = "lib/schema_map/template.html"

  # Left-to-right columns on the canvas. Grouping is *architectural*, not alphabetical: accounts
  # and the file layer on the left, the maker layer in the middle, Rails' own plumbing and then the
  # separate databases on the right — so most arrows run LEFTWARDS, nearly all of them into the two
  # tables everything else hangs off: `users` (ownership, which the page can hide) and `nodes` (the
  # bare-string references the map exists to show). A new table must be placed here (`problems`
  # refuses otherwise) because only a person can say where it belongs.
  LAYOUT = [
    { "label" => "Accounts & devices", "group" => "sync",
      "tables" => %w[users devices user_identities] },
    # THE "Sync control plane" ROW IS GONE AND "File layer" IS DOWN TO `nodes`. Arc D Part 2
    # retired embedded chunk and 2026-08-25's DropRetiredSyncEngineTables dropped the eight tables
    # that were the engine's: changelog_entries, pending_commits, conflicts, file_locks,
    # share_links, versions, manifest_chunks, chunks. They live in chaim354/tinkerex-sync's own
    # database now, so this map -- which is about THIS app's schema -- has nothing to place.
    #
    # `nodes` STAYS, and is no longer a sync table at all: it is the maker app's catalog on every
    # backend (share and s3 index into it; chunk_remote mirrors a remote changelog into it).
    { "label" => "File layer", "group" => "sync",
      "tables" => %w[nodes] },
    # chunk_remote's LOCAL MIRROR of a remote server's manifests (Stage 4), written by a client that
    # only talks to a sync server (FileLayer::ChunkRemote::ChangelogSync). Its `version_id` names a
    # version in THAT server's database, so it is listed in NOT_EDGES rather than drawn.
    { "label" => "Remote sync mirror", "group" => "sync",
      "tables" => %w[remote_manifest_chunks] },
    # `maker_repo_edits` sits here rather than with the projects: it is a row ABOUT A FILE, keyed
    # on `nodes.node_id` like every other table in this column, and it names no project at all.
    # `maker_file_links` (stage 4, S4-8) belongs here for the same reason twice over: it is keyed
    # on `nodes.node_id` at BOTH ends and names no project either.
    { "label" => "Files ↔ maker", "group" => "maker",
      "tables" => %w[maker_file_attachments maker_previews maker_notes maker_addon_files
                     maker_addon_states maker_addon_state_revisions maker_repo_edits
                     maker_file_links] },
    { "label" => "Library", "group" => "maker",
      "tables" => %w[maker_items maker_collection_items maker_collections maker_taggings
                     maker_tags maker_tasks maker_pins] },
    { "label" => "Models & projects", "group" => "maker",
      "tables" => %w[maker_models maker_print_runs maker_projects maker_build_log_entries
                     maker_sheets maker_shelves maker_shelf_groups maker_filing_rules
                     maker_connections maker_project_blocks maker_releases maker_release_files
                     maker_calculations] },
    { "label" => "Inventory & BOM", "group" => "maker",
      "tables" => %w[maker_boms maker_bom_lines maker_inventory_items
                     maker_inventory_transactions maker_suppliers maker_locations] },
    { "label" => "Rails plumbing", "group" => "rails",
      "tables" => %w[action_text_rich_texts active_storage_attachments active_storage_blobs
                     active_storage_variant_records] },
    { "label" => "Deployment settings", "group" => "ops",
      "tables" => %w[settings] },
    { "label" => "Queue database", "group" => "ops", "sub" => "separate DB",
      "tables" => %w[solid_queue_jobs solid_queue_ready_executions
                     solid_queue_claimed_executions solid_queue_scheduled_executions
                     solid_queue_blocked_executions solid_queue_failed_executions
                     solid_queue_recurring_executions] },
    { "label" => "Queue support · Cache · Cable", "group" => "ops", "sub" => "separate DBs",
      "tables" => %w[solid_queue_processes solid_queue_recurring_tasks solid_queue_semaphores
                     solid_queue_pauses solid_cache_entries solid_cable_messages] }
  ].freeze

  # [source, target, kind, label]. `fk` = enforced by the database, `app` = the application keeps
  # it and nothing else does, `poly` = one arm of a polymorphic pair. The `user_id` ownership
  # edges are NOT here — they are derived below, because every one of them is the same edge.
  EDGES = [
    # --- sync core ---------------------------------------------------------------
    #
    # ONE EDGE LEFT, WHERE THERE WERE TWENTY-TWO. The rest joined `versions`, `manifest_chunks`,
    # `chunks`, `changelog_entries`, `conflicts`, `file_locks`, `pending_commits` and
    # `share_links` -- all dropped on 2026-08-25 with the retired sync engine. They were never
    # constraints, which is the fact this map exists to show: they were bare-string joins, and
    # they now cross a PROCESS BOUNDARY as well, since the tables they pointed at belong to
    # chaim354/tinkerex-sync's database and are reached over HTTP.
    #
    # `nodes.current_version_id` SURVIVES AS A COLUMN BUT NOT AS AN EDGE: NOT_EDGES says why.
    [ "nodes.parent_node_id",            "nodes.node_id",               "app", "child of" ],
    # A TRASH ROW NAMES THE ENTRY IT WENT INTO (2026-10-20, F-S02-1): its own node_id on the node a
    # delete was asked for, that node's on everything live that travelled with it, NULL on a live row
    # and on a scan tombstone. SHARE AND S3 ONLY — chunk_remote's trash is the sync server's and its
    # mirror records no entry. Soft like every arrow into `nodes`: it records MEMBERSHIP, so a member
    # still names its entry after the purge has taken the bytes (FileLayer::TrashMembership).
    [ "nodes.trash_root_node_id",        "nodes.node_id",               "app", "trashed with" ],
    # --- the maker layer's grip on the file layer: every one a bare string, §14a ---
    [ "maker_file_attachments.node_id",    "nodes.node_id",       "app", "attaches" ],
    [ "maker_previews.node_id",            "nodes.node_id",       "app", "depicts" ],
    # `maker_file_attachments.version_id` and `maker_previews.version_id` are DELIBERATELY NOT
    # drawn: each is a content token, not a join, and NOT_EDGES carries the argument.
    [ "maker_notes.node_id",               "nodes.node_id",       "app", "note on" ],
    # Stage 4, S4-8. TWO edges from one table, because a link is a statement about a PAIR: both
    # ends are `nodes.node_id`, both are bare strings, and neither is enforced by anything. Drawn
    # for the same reason maker_notes.node_id and maker_file_attachments.node_id are — this map
    # exists to show the app-level references no constraint would ever notice.
    [ "maker_file_links.from_node_id", "nodes.node_id", "app", "links from" ],
    [ "maker_file_links.to_node_id",   "nodes.node_id", "app", "links to" ],
    [ "maker_items.primary_node_id",       "nodes.node_id",       "app", "primary file" ],
    [ "maker_models.cover_node_id",        "nodes.node_id",       "app", "cover" ],
    [ "maker_models.folder_node_id",       "nodes.node_id",       "app", "bundle dir" ],
    # THE THIRD BARE-STRING JOIN OUT OF maker_models: an app-level reference nothing derives, so
    # the arrow is authored here — and leaving it out goes red, because the completeness rule
    # (`classification_problems`, beside NOT_EDGES below) refuses a `*_id` column that is neither
    # drawn nor listed. Maker::ModelIntake keys an auto-catalogued model on the node it came from
    # -- a DIR for a folder model, a FILE for a one-file model -- which is why it points at
    # `nodes.node_id` and not at either kind specifically.
    [ "maker_models.auto_node_id",         "nodes.node_id",       "app", "catalogued from" ],
    [ "maker_projects.cover_node_id",      "nodes.node_id",       "app", "cover" ],
    [ "maker_projects.folder_node_id",     "nodes.node_id",       "app", "Projects/<slug>" ],
    [ "maker_bom_lines.node_id",           "nodes.node_id",       "app", "part file" ],
    [ "maker_addon_files.node_id",         "nodes.node_id",       "app", "output" ],
    # A PENDING EDIT NAMES TWO NODES AND NEITHER IS A CONSTRAINT — the file that was written, and
    # the repository root the ancestor walk landed on. Both stay bare strings for the reason every
    # arrow into `nodes` above is: a tombstone outliving its row is the design (§14a). The row is a
    # HINT, never an authority — the commit box asks git (app/models/maker/repo_edit.rb).
    [ "maker_repo_edits.node_id",           "nodes.node_id",      "app", "edited" ],
    [ "maker_repo_edits.repo_root_node_id", "nodes.node_id",      "app", "pending in" ],
    # A RELEASE RECORDS A REFERENCE, NEVER BYTES (stage 3, S3-5): one row per file naming the node
    # and the content token the port reported at release time. Soft like every arrow into `nodes`
    # above — a file deleted after a release keeps its row, and the page says so.
    [ "maker_release_files.node_id",        "nodes.node_id",      "app", "released file" ],
    # A RELEASE RECORDS THE REPOSITORY ITS TAG WAS VERIFIED IN — a dir node, written by
    # Maker::ReleaseSnapshot only when the tag resolved there — soft like every arrow into `nodes`
    # above. It went undrawn until the completeness rule (NOT_EDGES, below) asked about it.
    [ "maker_releases.repo_node_id",        "nodes.node_id",      "app", "tagged in" ],
    # AN IMAGE BLOCK POINTS AT THE PICTURE IT SHOWS (2026-09-09, content blocks), and the pointer
    # is a bare string like every one above it: the file can be deleted after the block was made,
    # and the block KEEPS ITS ROW and renders nothing (spec §8) rather than being swept — the same
    # softness `maker_file_links` and `maker_notes` rely on.
    [ "maker_project_blocks.node_id",       "nodes.node_id",      "app", "pictures" ],
    [ "maker_pins.node_id",                 "nodes.node_id",      "app", "pins" ],
    # --- maker layer internals ----------------------------------------------------
    [ "maker_boms.project_id",                        "maker_projects.id",        "app", "BOM for" ],
    [ "maker_bom_lines.bom_id",                       "maker_boms.id",            "app", "line of" ],
    [ "maker_bom_lines.inventory_item_id",            "maker_inventory_items.id", "app", "stocked as" ],
    [ "maker_bom_lines.supplier_id",                  "maker_suppliers.id",       "app", "buy from" ],
    [ "maker_build_log_entries.project_id",           "maker_projects.id",        "app", "logs" ],
    [ "maker_sheets.project_id",                      "maker_projects.id",        "app", "sheet of" ],
    [ "maker_connections.project_id",                 "maker_projects.id",        "app", "wired in" ],
    # A SAVED CALCULATION NAMES ITS PROJECT (2026-10-21) and nothing else: the row is meaningless
    # without it, so Maker::Project's `dependent: :destroy` takes it (structural_orphan_test.rb).
    [ "maker_calculations.project_id",                "maker_projects.id",        "app", "worked out for" ],
    # A CONTENT BLOCK NAMES ITS PROJECT AND, IF IT IS AN IMAGE, ONE NODE (2026-09-09, content
    # blocks). The project pointer is structural — the row is meaningless without it, and
    # Maker::Project's `dependent: :destroy` is what test/models/structural_orphan_test.rb checks.
    # The node pointer is SOFT like every arrow into `nodes` above: a tombstoned picture leaves the
    # block's row alone and the page renders nothing for it (spec §8), which is why it is drawn
    # here (the map exists to show references no constraint would notice) and NOT registered as a
    # structural case — the orphan guard derives its set from edges whose parent is a real `.id`.
    [ "maker_project_blocks.project_id",              "maker_projects.id",        "app", "placed on" ],
    [ "maker_releases.project_id",                    "maker_projects.id",        "app", "released from" ],
    [ "maker_releases.bom_id",                        "maker_boms.id",            "app", "BOM revision recorded" ],
    [ "maker_release_files.release_id",               "maker_releases.id",        "app", "file of" ],
    [ "maker_collection_items.collection_id",         "maker_collections.id",     "app", "in" ],
    [ "maker_collection_items.item_id",               "maker_items.id",           "app", "holds" ],
    [ "maker_inventory_items.location_id",            "maker_locations.id",       "app", "stored at" ],
    [ "maker_inventory_items.supplier_id",            "maker_suppliers.id",       "app", "bought from" ],
    [ "maker_inventory_transactions.inventory_item_id", "maker_inventory_items.id", "app", "moves" ],
    [ "maker_inventory_transactions.project_id",      "maker_projects.id",        "app", "consumed by" ],
    [ "maker_locations.parent_id",                    "maker_locations.id",       "app", "inside" ],
    [ "maker_print_runs.model_id",                    "maker_models.id",          "app", "print of" ],
    # A SHELF IN A GROUP (2026-10-20). Display only, so the group's `dependent: :nullify` leaves the
    # shelf standing; the folder name a shelf joins Maker::FilingRule by is a string, not an edge.
    [ "maker_shelves.shelf_group_id",                 "maker_shelf_groups.id",    "app", "in group" ],
    [ "maker_taggings.tag_id",                        "maker_tags.id",            "app", "tag" ],
    [ "maker_addon_files.addon_state_id",             "maker_addon_states.id",    "fk",  "saved by" ],
    [ "maker_addon_state_revisions.addon_state_id",   "maker_addon_states.id",    "fk",  "history of" ],
    # --- polymorphic: one edge per concrete target the pair can name ---------------
    [ "maker_file_attachments.attachable_id", "maker_projects.id",          "poly", "attachable" ],
    [ "maker_file_attachments.attachable_id", "maker_items.id",             "poly", "attachable" ],
    [ "maker_file_attachments.attachable_id", "maker_build_log_entries.id", "poly", "attachable" ],
    [ "maker_file_attachments.attachable_id", "maker_models.id",            "poly", "attachable" ],
    [ "maker_taggings.taggable_id",           "maker_items.id",             "poly", "taggable" ],
    [ "maker_taggings.taggable_id",           "maker_models.id",            "poly", "taggable" ],
    [ "maker_tasks.taskable_id",              "maker_projects.id",          "poly", "taskable" ],
    [ "maker_tasks.taskable_id",              "maker_items.id",             "poly", "taskable" ],
    # Rich text is TEXT-ONLY on the server (Maker::TextOnlyRichText, §15), so an ActionText body
    # carries no Active Storage attachment: `maker_previews` is the only record an attachment
    # ever names, via has_one_attached :asset.
    [ "action_text_rich_texts.record_id",     "maker_notes.id",             "poly", "body" ],
    [ "action_text_rich_texts.record_id",     "maker_build_log_entries.id", "poly", "body" ],
    [ "action_text_rich_texts.record_id",     "maker_releases.id",          "poly", "notes" ],
    [ "active_storage_attachments.record_id", "maker_previews.id",          "poly", "asset" ],
    # --- Rails plumbing -----------------------------------------------------------
    [ "active_storage_attachments.blob_id",     "active_storage_blobs.id", "fk", "bytes" ],
    [ "active_storage_variant_records.blob_id", "active_storage_blobs.id", "fk", "variant of" ],
    # --- Solid Queue, in its own database -----------------------------------------
    [ "solid_queue_ready_executions.job_id",     "solid_queue_jobs.id", "fk", "ready" ],
    [ "solid_queue_claimed_executions.job_id",   "solid_queue_jobs.id", "fk", "claimed" ],
    [ "solid_queue_blocked_executions.job_id",   "solid_queue_jobs.id", "fk", "blocked" ],
    [ "solid_queue_failed_executions.job_id",    "solid_queue_jobs.id", "fk", "failed" ],
    [ "solid_queue_scheduled_executions.job_id", "solid_queue_jobs.id", "fk", "scheduled" ],
    [ "solid_queue_recurring_executions.job_id", "solid_queue_jobs.id", "fk", "recurring" ],
    [ "solid_queue_claimed_executions.process_id", "solid_queue_processes.id",        "app", "worker" ],
    [ "solid_queue_processes.supervisor_id",       "solid_queue_processes.id",        "app", "supervised by" ],
    [ "solid_queue_recurring_executions.task_key", "solid_queue_recurring_tasks.key", "app", "task" ]
  ].freeze

  # THE `*_id` COLUMNS OF THE PRIMARY SCHEMA THAT ARE DELIBERATELY NOT JOINS, each with the reason
  # an arrow would be wrong. `classification_problems` asks every such column but `user_id` to be
  # drawn in EDGES or listed here — exactly one — so a new `*_id` column cannot reach
  # `bin/rails schema:map` (or a green suite) unclassified. Listing is the deliberate answer, never
  # the convenient one: a structural pointer belongs in EDGES, where
  # test/models/structural_orphan_test.rb then demands the `dependent:` decision for it.
  NOT_EDGES = {
    "nodes.node_id" =>
      "a KEY, not a reference: the file layer's stable identity, which every arrow into `nodes` " \
      "lands on",
    "nodes.current_version_id" =>
      "a version id from the SYNC SERVER's `versions` table (chunk_remote only), which this " \
      "database does not have: an arrow would claim a join that cannot be made locally",
    "remote_manifest_chunks.version_id" =>
      "the same sync-server version id, naming the version a mirrored manifest belongs to: there " \
      "is no `versions` row here to point at",
    "maker_previews.version_id" =>
      "FileLayer::FileInfo#content_token under the name it kept from before that port: a version " \
      "id on chunk_remote, a CONTENT HASH on share/s3 — two value spaces, and neither keys a row " \
      "in this database. This map once drew it into `versions`, a recorded mistake (CLAUDE.md §5)",
    "maker_file_attachments.version_id" =>
      "the same content token as maker_previews.version_id, and the same recorded mistake " \
      "(CLAUDE.md §5)"
  }.freeze

  class << self
    def root = defined?(Rails) ? Rails.root : Pathname.new(File.expand_path("..", __dir__))
    def output_path   = root.join(OUTPUT)
    def template_path = root.join(TEMPLATE)

    # ---- the derived half ------------------------------------------------------
    #
    # Reads the DUMPS, not the live database: `bin/rails schema:map` then needs no database, no
    # LIBRARY_* env and no network, and the map describes what is checked in rather than whatever
    # happens to be on this machine.
    def tables
      @tables ||= SOURCES.flat_map { |db, path| parse(db, root.join(path).read) }
    end

    # [table, column] pairs the database itself enforces.
    def foreign_keys
      @foreign_keys ||= SOURCES.flat_map { |_db, path|
        root.join(path).read.lines.filter_map do |line|
          m = line.match(/^\s*add_foreign_key\s+"([^"]+)",\s*"([^"]+)"(.*)$/)
          next unless m
          [ m[1], m[3][/column:\s*"([^"]+)"/, 1] || "#{m[2].sub(/s$/, '')}_id" ]
        end
      }.freeze
    end

    # EDGES plus one derived ownership edge per table carrying `user_id`. Derived rather than
    # listed because they are all the same edge, and a new user-scoped table should get its
    # ownership arrow without anyone remembering to add one. `fk` records whether the database
    # enforces THAT one — most do not (tinkerex#152 declined the rest: SQLite rebuilds a whole
    # table to add one) — and the legend counts both from the data.
    def edges
      @edges ||= begin
        authored = EDGES.map { |f, t, k, l| { "f" => f, "t" => t, "k" => k, "l" => l } }
        owned = tables.filter_map do |t|
          next if t["name"] == "users"
          next unless t["columns"].any? { |c| c["n"] == "user_id" }
          { "f" => "#{t['name']}.user_id", "t" => "users.id", "k" => "tenant", "l" => "owns",
            "fk" => foreign_keys.include?([ t["name"], "user_id" ]) }
        end
        (authored + owned).freeze
      end
    end

    # ---- the guard -------------------------------------------------------------
    # Empty means the authored half still agrees with the schema. Anything else is a sentence a
    # person has to act on, so each names the table and the fix.
    def problems
      found = tables.to_h { |t| [ t["name"], t ] }
      out = []

      placed = LAYOUT.flat_map { |c| c["tables"] }
      (found.keys - placed).each do |name|
        out << "#{name} is not in SchemaMap::LAYOUT — decide which column it belongs in"
      end
      (placed - found.keys).each do |name|
        out << "SchemaMap::LAYOUT places #{name}, which no schema dump defines"
      end

      EDGES.each do |from, to, kind, _label|
        [ from, to ].each do |ref|
          table, column = ref.split(".", 2)
          t = found[table]
          next out << "edge #{from} -> #{to} names table #{table}, which does not exist" unless t
          next if column == "id"
          unless t["columns"].any? { |c| c["n"] == column }
            out << "edge #{from} -> #{to} names #{ref}, which does not exist"
          end
        end

        enforced = foreign_keys.include?(from.split(".", 2))
        if kind == "fk" && !enforced
          out << "#{from} is drawn as a database foreign key, but no add_foreign_key declares it"
        elsif kind == "app" && enforced
          out << "#{from} is drawn as app-level, but the database enforces it — mark it \"fk\""
        end
      end

      foreign_keys.each do |table, column|
        next if column == "user_id" # carried by the derived ownership edges
        next if EDGES.any? { |from, _t, _k, _l| from == "#{table}.#{column}" }
        out << "#{table}.#{column} is a foreign key no edge draws — add it to SchemaMap::EDGES"
      end

      out.concat(classification_problems(tables))
    end

    # THE COMPLETENESS RULE. Every column `reference_shaped_columns` names is DRAWN (the source of a
    # line in EDGES) or LISTED in NOT_EDGES with the reason it is not a join — exactly one. Its
    # inputs are arguments so the suite can plant each failure on synthetic tables; `problems` runs
    # it on the real dumps.
    def classification_problems(tables, edges: EDGES, not_edges: NOT_EDGES)
      asked = reference_shaped_columns(tables)
      drawn = edges.map(&:first).to_set
      out = asked.filter_map do |ref|
        listed = not_edges.key?(ref)
        next if drawn.include?(ref) != listed # exactly one of the two: classified

        if listed
          "#{ref} is both drawn in SchemaMap::EDGES and listed in SchemaMap::NOT_EDGES — it is one or the other"
        else
          "#{ref} looks like a reference and nothing classifies it — draw it in SchemaMap::EDGES, " \
          "or list it in SchemaMap::NOT_EDGES with the reason it is not a join"
        end
      end
      (not_edges.keys - asked).each do |ref|
        out << "SchemaMap::NOT_EDGES lists #{ref}, which is not a *_id column the rule asks about " \
               "(the primary schema's, user_id aside) — remove it"
      end
      out
    end

    # What the rule asks about, as "table.column": every `*_id` column of the PRIMARY schema except
    # `user_id`, which `edges` draws by construction — one derived ownership edge per column of that
    # name. The other three dumps are Solid Queue/Cache/Cable's own schema: this app writes no
    # migration there and decides no join in them.
    def reference_shaped_columns(tables)
      tables.select { |t| t["db"] == "primary" }.flat_map do |t|
        t["columns"].filter_map do |c|
          "#{t['name']}.#{c['n']}" if c["n"].end_with?("_id") && c["n"] != "user_id"
        end
      end
    end

    # ---- assembly + render -----------------------------------------------------
    def data
      by_name = tables.to_h { |t| [ t["name"], t ] }
      sources = edges.map { |e| e["f"] }.to_set
      targets = edges.map { |e| e["t"] }.to_set

      placed = LAYOUT.each_with_index.flat_map do |col, ci|
        col["tables"].each_with_index.map do |name, oi|
          t = by_name.fetch(name)
          columns = [ { "n" => "id", "t" => "bigint", "req" => true, "pk" => true } ] + t["columns"]
          columns = columns.map { |c| annotate(c, t, name, sources, targets) }
          { "name" => name, "db" => t["db"], "group" => col["group"],
            "col" => ci, "order" => oi, "columns" => columns }
        end
      end

      { "columns" => LAYOUT.map { |c| c.slice("label", "group", "sub") },
        "tables" => placed, "edges" => edges }
    end

    # The JSON the page carries. Public because the suite asks whether a stale page is stale
    # because the SCHEMA moved or because the template did, and that is the difference.
    def payload
      json = JSON.generate(data, ascii_only: true, script_safe: true)
      raise "the data carries a </script> sequence" if json.include?("</script")
      json
    end

    def render
      html = template_path.read.sub("__DATA__") { payload }
      raise "the template kept its __DATA__ placeholder" if html.include?("__DATA__")
      # The page is written pure ASCII on purpose: it is opened straight off disk as often as it
      # is served, and a file:// load with no charset declared decodes as the platform default,
      # which turns every glyph in the legend into mojibake.
      raise "non-ASCII leaked into the page" if html.bytes.any? { |b| b > 127 }
      html
    end

    def write!
      output_path.write(render)
      output_path
    end

    def current? = output_path.exist? && output_path.read == render

    private

    # Per-column badges the page draws. `key` marks a column something POINTS AT that is not a
    # primary key — `nodes.node_id` above all, which is most of what is load-bearing about this
    # schema.
    #
    # It RETURNS A COPY and must keep doing so. `tables` is memoized, so badging the column hash in
    # place edited the PARSE RESULT: `SchemaMap.tables` then meant one thing before `data`/`payload`/
    # `render` had run in this process and another after, and the suite's parse assertions passed or
    # failed on the minitest seed rather than on the parser. Absent badges are OMITTED, never written
    # as nil, and the six are appended in u/ix/ref/fkc/key/cu order: `JSON.generate` emits keys in
    # insertion order and the checked-in page is compared byte for byte, so a reorder here is a stale
    # page (`test/schema_map_test.rb`, "the checked-in map is the current schema").
    def annotate(col, table, name, sources, targets)
      ref = "#{name}.#{col['n']}"
      single = table["indexes"].find { |i| i["cols"] == [ col["n"] ] }
      badges = {}
      badges["u"]   = true if single && single["unique"]
      badges["ix"]  = true if table["indexes"].any? { |i| i["cols"].first == col["n"] } && !col["pk"]
      badges["ref"] = true if sources.include?(ref)
      badges["fkc"] = true if foreign_keys.include?([ name, col["n"] ])
      badges["key"] = true if targets.include?(ref) && !col["pk"]
      composite = table["indexes"].find { |i| i["unique"] && i["cols"].size > 1 && i["cols"].include?(col["n"]) }
      badges["cu"] = composite["cols"].join(", ") if composite
      col.merge(badges)
    end

    # A schema dump is generated Ruby with a shape that has been stable for years, so it is read
    # line by line rather than evaluated: `load`ing it would need a database connection and would
    # run migrations' worth of code to answer a question about text.
    def parse(db, source)
      out = []
      current = nil
      source.each_line do |line|
        if (m = line.match(/^\s*create_table\s+"([^"]+)"/))
          current = { "name" => m[1], "db" => db, "columns" => [], "indexes" => [] }
          out << current
        elsif current.nil?
          next
        elsif line.match?(/^  end$/) # closes the create_table block; nothing else sits at 2 spaces
          current = nil
        elsif (m = line.match(/^\s*t\.(\w+)\s+"([^"]+)"(.*)$/))
          current["columns"] << column(m[1], m[2], m[3])
        elsif (m = line.match(/^\s*t\.index\s+\[\s*("[^\]]*?)\s*\](.*)$/))
          current["indexes"] << { "cols" => m[1].scan(/"([^"]+)"/).flatten,
                                  "unique" => m[2].include?("unique: true") }
        end
      end
      out
    end

    def column(type, name, opts)
      precision = opts[/precision:\s*(\d+)/, 1]
      scale     = opts[/scale:\s*(\d+)/, 1]
      limit     = opts[/limit:\s*(\d+)/, 1]
      rendered = type.dup
      rendered << "(#{precision},#{scale})" if precision && scale
      rendered << "(#{limit})" if limit && !precision
      col = { "n" => name, "t" => rendered }
      col["req"] = true if opts.include?("null: false")
      if (default = opts[/default:\s*("(?:[^"]*)"|\{\}|\[\]|[-\w.]+)/, 1])
        col["d"] = default.delete('"')
      end
      col
    end
  end
end
